-- 采购、来料检、入库；委外发料/回料/损耗定额/结算扣款；进项发票

CREATE OR REPLACE FUNCTION fn_po_create(p_supplier bigint, p_plant bigint, p_lines jsonb) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE po bigint;
BEGIN
  INSERT INTO purchase_order(supplier_id, plant_id) VALUES (p_supplier, p_plant) RETURNING id INTO po;
  INSERT INTO purchase_order_item(purchase_order_id, item_id, qty, unit_price, mrp_line_id)
  SELECT po, (l->>'item')::bigint, (l->>'qty')::numeric, (l->>'price')::numeric, (l->>'mrp_line')::bigint FROM jsonb_array_elements(p_lines) l;
  UPDATE purchase_order SET status='submitted' WHERE id=po;
  RETURN po;
END $$;

CREATE OR REPLACE FUNCTION fn_po_receive(p_po bigint, p_wh bigint, p_lines jsonb) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE pr bigint;
BEGIN
  INSERT INTO purchase_receipt(purchase_order_id, warehouse_id) VALUES (p_po, p_wh) RETURNING id INTO pr;
  INSERT INTO purchase_receipt_item(purchase_receipt_id, po_item_id, item_id, received_qty, batch_no)
  SELECT pr, pi.id, pi.item_id, (l->>'qty')::numeric, l->>'batch'
  FROM jsonb_array_elements(p_lines) l JOIN purchase_order_item pi ON pi.id=(l->>'po_item')::bigint;
  UPDATE purchase_receipt SET status='inspecting' WHERE id=pr;
  RETURN pr;
END $$;

-- 来料检
CREATE OR REPLACE FUNCTION fn_incoming_inspection(p_pri bigint, p_accepted numeric, p_rejected numeric, p_note text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE r purchase_receipt_item; qi bigint;
BEGIN
  SELECT * INTO r FROM purchase_receipt_item WHERE id=p_pri;
  IF p_accepted + p_rejected <> r.received_qty THEN RAISE EXCEPTION '来料检合格+不合格必须等于到货数'; END IF;
  INSERT INTO quality_inspection(inspection_type, ref_type, ref_id, item_id, inspected_qty, accepted_qty, scrap_qty, defect_note)
  VALUES ('incoming','purchase_receipt_item',p_pri,r.item_id,r.received_qty,p_accepted,p_rejected,p_note) RETURNING id INTO qi;
  UPDATE quality_inspection SET status='completed' WHERE id=qi;
  UPDATE purchase_receipt_item SET accepted_qty=p_accepted, rejected_qty=p_rejected WHERE id=p_pri;
  RETURN qi;
END $$;

-- 入库过账：合格品按不含税价入库，贷应付暂估
CREATE OR REPLACE FUNCTION fn_receipt_post(p_pr bigint) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE pr purchase_receipt; r record; sl stock_ledger; total numeric := 0; po purchase_order; rate numeric;
BEGIN
  SELECT * INTO pr FROM purchase_receipt WHERE id=p_pr FOR UPDATE;
  SELECT * INTO po FROM purchase_order WHERE id=pr.purchase_order_id;
  IF EXISTS (SELECT 1 FROM purchase_receipt_item WHERE purchase_receipt_id=p_pr AND accepted_qty IS NULL) THEN
    RAISE EXCEPTION '入库单 % 有未检验的行', pr.doc_no;
  END IF;
  FOR r IN SELECT ri.*, pi.unit_price, pi.tax_rate FROM purchase_receipt_item ri JOIN purchase_order_item pi ON pi.id=ri.po_item_id
           WHERE ri.purchase_receipt_id=p_pr LOOP
    rate := round(r.unit_price/(1+r.tax_rate), 6);
    IF r.accepted_qty > 0 THEN
      sl := fn_stock_move(pr.warehouse_id, r.item_id, r.accepted_qty, rate, 'purchase_receipt', p_pr, r.id, NULL, r.batch_no);
      total := total + round(sl.value_change,2);
    END IF;
    UPDATE purchase_order_item SET received_qty=received_qty+r.accepted_qty, rejected_qty=rejected_qty+r.rejected_qty WHERE id=r.po_item_id;
  END LOOP;
  PERFORM fn_post_je('purchase_receipt', p_pr, pr.receipt_date, '采购入库 '||pr.doc_no, jsonb_build_array(
    jsonb_build_object('a','1403','d',total,'plant',po.plant_id),
    jsonb_build_object('a','220201','c',total,'party',po.supplier_id,'plant',po.plant_id)));
  UPDATE purchase_receipt SET status='posted' WHERE id=p_pr;
  UPDATE purchase_order SET status = CASE WHEN (SELECT bool_and(received_qty>=qty) FROM purchase_order_item WHERE purchase_order_id=po.id)
                                     THEN 'received' ELSE 'partially_received' END
   WHERE id=po.id AND status IN ('submitted','partially_received')
     AND status <> CASE WHEN (SELECT bool_and(received_qty>=qty) FROM purchase_order_item WHERE purchase_order_id=po.id) THEN 'received' ELSE 'partially_received' END;
  RETURN total;
END $$;

-- 委外单：单价、损耗定额从参数表快照；扣款单价 = 发出时工单在制品单件成本
CREATE OR REPLACE FUNCTION fn_subcon_create(p_wo bigint, p_seq int, p_supplier bigint, p_wh bigint) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE op wo_operation; ro routing_operation; w work_order; sc bigint;
BEGIN
  SELECT * INTO op FROM wo_operation WHERE work_order_id=p_wo AND seq=p_seq;
  SELECT * INTO ro FROM routing_operation WHERE id=op.routing_op_id;
  SELECT * INTO w FROM work_order WHERE id=p_wo;
  IF NOT op.is_subcontracted THEN RAISE EXCEPTION '工序 % 不是委外工序', op.op_name; END IF;
  INSERT INTO subcontract_order(supplier_id, wo_operation_id, subcon_warehouse_id, price_param_key, price_basis, basis_per_unit, unit_price, loss_allowance, part_value)
  VALUES (p_supplier, op.id, p_wh, ro.subcon_price_key, ro.subcon_basis, ro.subcon_basis_per_unit, p(ro.subcon_price_key),
          p('subcontract_loss_allowance'),
          round(coalesce((SELECT sum(amount) FROM wo_cost_entry WHERE work_order_id=p_wo),0)/w.qty, 4))
  RETURNING id INTO sc;
  RETURN sc;
END $$;

CREATE OR REPLACE FUNCTION fn_subcon_send(p_sc bigint, p_qty numeric, p_note text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE sc subcontract_order; op wo_operation;
BEGIN
  SELECT * INTO sc FROM subcontract_order WHERE id=p_sc FOR UPDATE;
  SELECT * INTO op FROM wo_operation WHERE id=sc.wo_operation_id FOR UPDATE;
  IF p_qty > op.input_qty - op.completed_qty - op.scrap_qty - (SELECT coalesce(sum(sent_qty-received_good_qty-received_defect_qty),0) FROM subcontract_order WHERE wo_operation_id=op.id AND status NOT IN ('settled')) THEN
    RAISE EXCEPTION '委外发出数量 % 超过本工序可发数量', p_qty;
  END IF;
  INSERT INTO subcontract_movement(subcontract_order_id, movement_type, good_qty, delivery_note_no) VALUES (p_sc, 'send', p_qty, p_note);
  UPDATE subcontract_order SET sent_qty=sent_qty+p_qty, status=CASE WHEN status='draft' THEN 'sent' ELSE status END WHERE id=p_sc;
  IF op.status='pending' THEN UPDATE wo_operation SET status='subcontracted' WHERE id=op.id; END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_subcon_receive(p_sc bigint, p_good numeric, p_defect numeric, p_note text DEFAULT NULL) RETURNS void LANGUAGE plpgsql AS $$
DECLARE sc subcontract_order; op wo_operation; nxt bigint; qi bigint;
BEGIN
  SELECT * INTO sc FROM subcontract_order WHERE id=p_sc FOR UPDATE;
  IF sc.received_good_qty + sc.received_defect_qty + p_good + p_defect > sc.sent_qty THEN RAISE EXCEPTION '回料数量超过发出数量'; END IF;
  INSERT INTO subcontract_movement(subcontract_order_id, movement_type, good_qty, defect_qty, delivery_note_no) VALUES (p_sc,'receive',p_good,p_defect,p_note);
  -- 委外回料检验
  INSERT INTO quality_inspection(inspection_type, ref_type, ref_id, item_id, inspected_qty, accepted_qty, scrap_qty, defect_note)
  SELECT 'subcontract','subcontract_order',p_sc,w.item_id,p_good+p_defect,p_good,p_defect,p_note
  FROM wo_operation o JOIN work_order w ON w.id=o.work_order_id WHERE o.id=sc.wo_operation_id RETURNING id INTO qi;
  UPDATE quality_inspection SET status='completed' WHERE id=qi;
  UPDATE subcontract_order SET received_good_qty=received_good_qty+p_good, received_defect_qty=received_defect_qty+p_defect,
         status=CASE WHEN status='sent' THEN 'partially_received' ELSE status END WHERE id=p_sc;
  UPDATE wo_operation SET completed_qty=completed_qty+p_good, scrap_qty=scrap_qty+p_defect WHERE id=sc.wo_operation_id RETURNING * INTO op;
  UPDATE work_order SET scrap_qty=scrap_qty+p_defect WHERE id=op.work_order_id;
  SELECT id INTO nxt FROM wo_operation WHERE work_order_id=op.work_order_id AND seq>op.seq ORDER BY seq LIMIT 1;
  IF nxt IS NOT NULL THEN UPDATE wo_operation SET input_qty=input_qty+p_good WHERE id=nxt; END IF;
END $$;

-- 委外结算：短少计入报废；超过损耗定额的(短少+不良)按件扣款；加工费按合格数计
CREATE OR REPLACE FUNCTION fn_subcon_settle(p_sc bigint) RETURNS subcontract_settlement LANGUAGE plpgsql AS $$
DECLARE sc subcontract_order; s subcontract_settlement; shortage numeric; allowance numeric; over numeric;
        fee numeric; ded numeric; op wo_operation; w work_order; ex_net numeric;
BEGIN
  SELECT * INTO sc FROM subcontract_order WHERE id=p_sc FOR UPDATE;
  shortage := sc.sent_qty - sc.received_good_qty - sc.received_defect_qty;
  allowance := round(sc.sent_qty * sc.loss_allowance, 4);
  over := greatest(shortage + sc.received_defect_qty - allowance, 0);
  fee := round(sc.received_good_qty * sc.basis_per_unit * sc.unit_price, 2);
  ded := round(over * sc.part_value, 2);
  INSERT INTO subcontract_settlement(subcontract_order_id, sent_qty, good_qty, defect_qty, shortage_qty, allowance_qty, over_loss_qty, processing_fee, deduction, payable_amount)
  VALUES (p_sc, sc.sent_qty, sc.received_good_qty, sc.received_defect_qty, shortage, allowance, over, fee, ded, fee - ded) RETURNING * INTO s;
  UPDATE subcontract_order SET status='received' WHERE id=p_sc AND status IN ('sent','partially_received');
  UPDATE subcontract_order SET status='settled' WHERE id=p_sc;
  UPDATE wo_operation SET scrap_qty=scrap_qty+shortage WHERE id=sc.wo_operation_id RETURNING * INTO op;
  UPDATE work_order SET scrap_qty=scrap_qty+shortage WHERE id=op.work_order_id RETURNING * INTO w;
  IF op.completed_qty + op.scrap_qty >= op.input_qty AND op.status='subcontracted' THEN UPDATE wo_operation SET status='done' WHERE id=op.id; END IF;
  -- 成本(不含税)：加工费入工单，扣款冲减工单
  ex_net := round((fee - ded)/(1+p('vat_rate_general')), 2);
  INSERT INTO wo_cost_entry(work_order_id, cost_type, amount, qty, source_type, source_id) VALUES
    (w.id, 'subcontract', round(fee/(1+p('vat_rate_general')),2), sc.received_good_qty, 'subcontract_settlement', s.id),
    (w.id, 'subcontract', -(round(fee/(1+p('vat_rate_general')),2) - ex_net), over, 'subcontract_settlement', s.id);
  PERFORM fn_post_je('subcontract_settlement', s.id, current_date, '委外结算 '||sc.doc_no, jsonb_build_array(
    jsonb_build_object('a','5001','d',ex_net,'wo',w.id,'plant',w.plant_id),
    jsonb_build_object('a','220201','c',ex_net,'party',sc.supplier_id,'plant',w.plant_id)));
  RETURN s;
END $$;

-- 进项发票（采购入库 / 委外结算），生成应付流水与凭证
CREATE OR REPLACE FUNCTION fn_purchase_invoice(p_src_type text, p_src bigint, p_invoice_no text, p_kind text DEFAULT 'vat_special')
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE inv bigint; sup bigint; ex numeric; tax numeric; t tenant; i invoice; pl bigint; s subcontract_settlement;
BEGIN
  SELECT * INTO t FROM tenant WHERE tenant_id=app_tid();
  IF p_src_type='purchase_receipt' THEN
    SELECT po.supplier_id, po.plant_id INTO sup, pl FROM purchase_receipt pr JOIN purchase_order po ON po.id=pr.purchase_order_id WHERE pr.id=p_src;
  ELSE
    SELECT * INTO s FROM subcontract_settlement WHERE id=p_src;
    SELECT sc.supplier_id, w.plant_id INTO sup, pl FROM subcontract_order sc JOIN wo_operation o ON o.id=sc.wo_operation_id JOIN work_order w ON w.id=o.work_order_id WHERE sc.id=s.subcontract_order_id;
  END IF;
  INSERT INTO invoice(direction, invoice_kind, party_id, buyer_name, buyer_tax_no, seller_name, seller_tax_no, invoice_no, source_type, source_id, due_date)
  SELECT 'purchase', p_kind, sup, t.tenant_name, (SELECT tax_no FROM party WHERE party_code='SELF' AND tenant_id=app_tid()), pa.party_name, pa.tax_no,
         p_invoice_no, p_src_type, p_src, current_date + pa.payment_days FROM party pa WHERE pa.id=sup RETURNING id INTO inv;
  IF p_src_type='purchase_receipt' THEN
    INSERT INTO invoice_item(invoice_id, goods_name, spec, uom, qty, unit_price_ex_tax, amount_ex_tax, tax_rate, tax_amount, source_line_type, source_line_id)
    SELECT inv, it.item_name, it.item_code, it.stock_uom, ri.accepted_qty, round(pi.unit_price/(1+pi.tax_rate),8),
           round(ri.accepted_qty*round(pi.unit_price/(1+pi.tax_rate),6),2), pi.tax_rate,
           round(round(ri.accepted_qty*round(pi.unit_price/(1+pi.tax_rate),6),2)*pi.tax_rate,2), 'purchase_receipt_item', ri.id
    FROM purchase_receipt_item ri JOIN purchase_order_item pi ON pi.id=ri.po_item_id JOIN item it ON it.id=ri.item_id
    WHERE ri.purchase_receipt_id=p_src AND ri.accepted_qty>0;
    UPDATE purchase_order_item pi SET invoiced_qty=invoiced_qty+ri.accepted_qty FROM purchase_receipt_item ri WHERE ri.purchase_receipt_id=p_src AND pi.id=ri.po_item_id;
  ELSE
    INSERT INTO invoice_item(invoice_id, goods_name, spec, uom, qty, unit_price_ex_tax, amount_ex_tax, tax_rate, tax_amount, source_line_type, source_line_id)
    VALUES (inv, '委外加工费', NULL, 'pcs', s.good_qty, round(round(s.payable_amount/(1+p('vat_rate_general')),2)/nullif(s.good_qty,0),8),
            round(s.payable_amount/(1+p('vat_rate_general')),2), 0.13, s.payable_amount - round(s.payable_amount/(1+p('vat_rate_general')),2), 'subcontract_settlement', s.id);
  END IF;
  SELECT sum(amount_ex_tax), sum(tax_amount) INTO ex, tax FROM invoice_item WHERE invoice_id=inv;
  UPDATE invoice SET amount_ex_tax=ex, tax_amount=tax, status='issued' WHERE id=inv RETURNING * INTO i;
  INSERT INTO payment_ledger(ledger_type, party_id, posting_date, voucher_type, voucher_id, against_invoice_id, amount, due_date)
  VALUES ('payable', sup, i.invoice_date, 'invoice', inv, inv, i.total_amount, i.due_date);
  PERFORM fn_post_je('invoice', inv, i.invoice_date, '进项发票 '||coalesce(p_invoice_no,i.doc_no), jsonb_build_array(
    jsonb_build_object('a','220201','d',ex,'party',sup,'plant',pl),
    jsonb_build_object('a','22210101','d',tax,'plant',pl),
    jsonb_build_object('a','2202','c',i.total_amount,'party',sup,'plant',pl)));
  RETURN inv;
END $$;
