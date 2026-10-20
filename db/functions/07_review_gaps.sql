-- 评审缺口补齐：序列号、替代料领料、物料需求单、修订(amend)、多段计时报工、质检读数审核、分期收款、AI 字段确认

-- 序列号：完工/入库登记
CREATE OR REPLACE FUNCTION fn_serial_receive(p_item bigint, p_serials text[], p_wh bigint, p_vtype text, p_vid bigint, p_wo bigint DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE s text; sid bigint; n int := 0;
BEGIN
  FOREACH s IN ARRAY p_serials LOOP
    INSERT INTO serial_no(item_id, serial_no, warehouse_id, work_order_id) VALUES (p_item, s, p_wh, p_wo) RETURNING id INTO sid;
    INSERT INTO serial_ledger(serial_id, direction, warehouse_id, voucher_type, voucher_id) VALUES (sid, 'in', p_wh, p_vtype, p_vid);
    n := n + 1;
  END LOOP;
  IF n > (SELECT coalesce(qty,0) FROM v_stock_balance WHERE item_id=p_item AND warehouse_id=p_wh AND tenant_id=app_tid())
       - (SELECT count(*) FROM serial_no WHERE item_id=p_item AND warehouse_id=p_wh AND status='in_stock') + n THEN
    RAISE EXCEPTION '登记序列号数量超过该仓库库存';
  END IF;
  RETURN n;
END $$;

-- 序列号：绑定到发货行（按台出库）
CREATE OR REPLACE FUNCTION fn_serial_bind_delivery(p_dn_item bigint, p_serials text[]) RETURNS int LANGUAGE plpgsql AS $$
DECLARE di delivery_note_item; d delivery_note; s text; sn serial_no; bound int;
BEGIN
  SELECT * INTO di FROM delivery_note_item WHERE id=p_dn_item;
  SELECT * INTO d FROM delivery_note WHERE id=di.delivery_note_id;
  SELECT count(*) INTO bound FROM serial_ledger WHERE voucher_type='delivery_note' AND voucher_line_id=p_dn_item AND direction='out';
  IF bound + array_length(p_serials,1) > di.qty THEN RAISE EXCEPTION '绑定序列号数 % 超过发货数量 %', bound + array_length(p_serials,1), di.qty; END IF;
  FOREACH s IN ARRAY p_serials LOOP
    SELECT * INTO sn FROM serial_no WHERE item_id=di.item_id AND serial_no=s AND tenant_id=app_tid() FOR UPDATE;
    IF sn.id IS NULL THEN RAISE EXCEPTION '序列号 % 不存在', s; END IF;
    IF sn.status <> 'in_stock' OR sn.warehouse_id <> di.warehouse_id THEN
      RAISE EXCEPTION '序列号 % 不在发货仓库存中(状态 %)', s, sn.status; END IF;
    UPDATE serial_no SET status='delivered', warehouse_id=NULL, customer_id=d.customer_id, delivery_note_id=d.id,
           warranty_expiry=d.posting_date + 365 WHERE id=sn.id;
    INSERT INTO serial_ledger(serial_id, direction, warehouse_id, voucher_type, voucher_id, voucher_line_id)
    VALUES (sn.id, 'out', di.warehouse_id, 'delivery_note', d.id, p_dn_item);
  END LOOP;
  RETURN array_length(p_serials,1);
END $$;

CREATE OR REPLACE VIEW v_serial_trace WITH (security_invoker = true) AS
SELECT s.tenant_id, s.serial_no, i.item_code, s.status, w.doc_no AS work_order_no, c.party_name AS customer, s.warranty_expiry,
       l.direction, l.voucher_type, l.voucher_id, l.moved_at
FROM serial_no s JOIN item i ON i.id=s.item_id LEFT JOIN work_order w ON w.id=s.work_order_id
LEFT JOIN party c ON c.id=s.customer_id LEFT JOIN serial_ledger l ON l.serial_id=s.id;

-- 替代料领料：主料不足且 BOM 行允许替代时，差额按优先级用替代料补足
CREATE OR REPLACE FUNCTION fn_issue_with_alternative(p_wo bigint, p_item bigint, p_qty numeric, p_wh bigint) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE avail numeric; need numeric := p_qty; take numeric; a record; res jsonb := '[]'; allowed boolean;
BEGIN
  SELECT bool_or(bi.allow_alternative) INTO allowed FROM work_order w JOIN bom_item bi ON bi.bom_id=w.bom_id AND bi.component_id=p_item WHERE w.id=p_wo;
  avail := coalesce((SELECT qty FROM v_stock_balance WHERE item_id=p_item AND warehouse_id=p_wh AND tenant_id=app_tid()),0);
  take := least(avail, need);
  IF take > 0 THEN PERFORM fn_issue_material(p_wo, p_item, take, p_wh); need := need - take;
    res := res || jsonb_build_object('item', p_item, 'qty', take); END IF;
  IF need > 0 AND NOT coalesce(allowed,false) THEN RAISE EXCEPTION '主料不足 % 且 BOM 不允许替代', need; END IF;
  FOR a IN SELECT * FROM item_alternative WHERE item_id=p_item AND tenant_id=app_tid() ORDER BY priority LOOP
    EXIT WHEN need <= 0;
    avail := coalesce((SELECT qty FROM v_stock_balance WHERE item_id=a.alt_item_id AND warehouse_id=p_wh AND tenant_id=app_tid()),0);
    take := least(avail, need*a.conversion_ratio);
    IF take > 0 THEN
      PERFORM fn_issue_material(p_wo, a.alt_item_id, take, p_wh);
      need := need - take/a.conversion_ratio;
      res := res || jsonb_build_object('item', a.alt_item_id, 'qty', take, 'alternative', true);
    END IF;
  END LOOP;
  IF need > 0.00001 THEN RAISE EXCEPTION '主料与替代料合计仍不足 %', need; END IF;
  RETURN res;
END $$;

-- 物料需求单
CREATE OR REPLACE FUNCTION fn_mr_create(p_type text, p_item bigint, p_qty numeric, p_wh bigint, p_wo bigint DEFAULT NULL, p_jc bigint DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE mr bigint;
BEGIN
  INSERT INTO material_request(request_type, item_id, qty, warehouse_id, work_order_id, job_card_id, reason, schedule_date)
  VALUES (p_type, p_item, p_qty, p_wh, p_wo, p_jc, p_reason, current_date) RETURNING id INTO mr;
  UPDATE material_request SET status='submitted' WHERE id=mr;
  RETURN mr;
END $$;
CREATE OR REPLACE FUNCTION fn_mr_progress(p_mr bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE m material_request;
BEGIN
  SELECT * INTO m FROM material_request WHERE id=p_mr;
  IF m.received_qty >= m.qty AND m.status <> 'fulfilled' THEN UPDATE material_request SET status='fulfilled' WHERE id=p_mr;
  ELSIF m.received_qty > 0 AND m.status='submitted' THEN UPDATE material_request SET status='partially_fulfilled' WHERE id=p_mr; END IF;
END $$;
-- 车间领料/补料：按需求单发料到工单
CREATE OR REPLACE FUNCTION fn_mr_issue(p_mr bigint, p_qty numeric) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE m material_request; v numeric;
BEGIN
  SELECT * INTO m FROM material_request WHERE id=p_mr FOR UPDATE;
  IF m.request_type NOT IN ('issue','replenish') THEN RAISE EXCEPTION '采购类需求单不能直接发料'; END IF;
  IF m.received_qty + p_qty > m.qty THEN RAISE EXCEPTION '发料超过需求数量'; END IF;
  v := fn_issue_material(m.work_order_id, m.item_id, p_qty, m.warehouse_id);
  UPDATE material_request SET received_qty=received_qty+p_qty, ordered_qty=ordered_qty+p_qty WHERE id=p_mr;
  PERFORM fn_mr_progress(p_mr);
  RETURN v;
END $$;
-- 采购类需求单：下采购单后回写已订数，入库后回写已收数
CREATE OR REPLACE FUNCTION fn_mr_to_po(p_mr bigint, p_supplier bigint, p_price numeric) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE m material_request; po bigint;
BEGIN
  SELECT * INTO m FROM material_request WHERE id=p_mr FOR UPDATE;
  po := fn_po_create(p_supplier, (SELECT plant_id FROM warehouse WHERE id=m.warehouse_id),
                     jsonb_build_array(jsonb_build_object('item',m.item_id,'qty',m.qty-m.ordered_qty,'price',p_price)));
  UPDATE purchase_order_item SET material_request_id=p_mr WHERE purchase_order_id=po;
  UPDATE material_request SET ordered_qty=qty WHERE id=p_mr;
  RETURN po;
END $$;
CREATE OR REPLACE FUNCTION trg_po_item_mr_received() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.material_request_id IS NOT NULL AND NEW.received_qty <> OLD.received_qty THEN
    UPDATE material_request SET received_qty=least(qty, received_qty + NEW.received_qty - OLD.received_qty) WHERE id=NEW.material_request_id;
    PERFORM fn_mr_progress(NEW.material_request_id);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS po_item_mr_received ON purchase_order_item;
CREATE TRIGGER po_item_mr_received AFTER UPDATE OF received_qty ON purchase_order_item FOR EACH ROW EXECUTE FUNCTION trg_po_item_mr_received();

-- 修订：取消/驳回后复制为新版本，amended_from 指向原单
CREATE OR REPLACE FUNCTION fn_amend_quotation(p_q bigint) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE q quotation; nq bigint; n int;
BEGIN
  SELECT * INTO q FROM quotation WHERE id=p_q;
  IF q.status NOT IN ('cancelled','rejected','expired') THEN RAISE EXCEPTION '只有已取消/驳回/过期的报价可以修订(当前 %)', q.status; END IF;
  SELECT count(*) INTO n FROM quotation WHERE amended_from=p_q;
  INSERT INTO quotation(doc_no, customer_id, plant_id, valid_till, min_margin, amended_from)
  VALUES (q.doc_no||'-'||(n+1), q.customer_id, q.plant_id, current_date+30, q.min_margin, p_q) RETURNING id INTO nq;
  INSERT INTO quotation_item(quotation_id, item_id, drawing_id, qty, customer_part_no)
  SELECT nq, item_id, drawing_id, qty, customer_part_no FROM quotation_item WHERE quotation_id=p_q;
  PERFORM fn_quote_cost(id) FROM quotation_item WHERE quotation_id=nq;
  RETURN nq;
END $$;

-- 多段计时报工：工时 = Σ work 段分钟 / 60（暂停段不计）
CREATE OR REPLACE FUNCTION fn_report_with_logs(p_wo bigint, p_seq int, p_emp text, p_good numeric, p_scrap numeric, p_logs jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE jc bigint; hrs numeric;
BEGIN
  SELECT round(sum(extract(epoch FROM ((l->>'to')::timestamptz - (l->>'from')::timestamptz))/3600)::numeric, 4) INTO hrs
  FROM jsonb_array_elements(p_logs) l WHERE l->>'kind'='work';
  jc := fn_report(p_wo, p_seq, p_emp, p_good, p_scrap, coalesce(hrs,0));
  -- job_card 只增不改：起止时间由时间段子表给出
  INSERT INTO job_card_time_log(job_card_id, log_kind, from_time, to_time, pause_reason)
  SELECT jc, l->>'kind', (l->>'from')::timestamptz, (l->>'to')::timestamptz, l->>'reason' FROM jsonb_array_elements(p_logs) l;
  RETURN jc;
END $$;

-- 质检读数与审核（审核人不能是检验员本人）
CREATE OR REPLACE FUNCTION fn_qi_add_readings(p_qi bigint, p_readings jsonb) RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  INSERT INTO quality_inspection_reading(inspection_id, parameter, spec_min, spec_max, reading, sample_no)
  SELECT p_qi, r->>'parameter', (r->>'min')::numeric, (r->>'max')::numeric, (r->>'value')::numeric, (r->>'sample')::int
  FROM jsonb_array_elements(p_readings) r;
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $$;
CREATE OR REPLACE FUNCTION fn_qi_review(p_qi bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE q quality_inspection;
BEGIN
  SELECT * INTO q FROM quality_inspection WHERE id=p_qi;
  IF q.inspected_by = app_user() THEN RAISE EXCEPTION '审核人不能是检验员本人(%)', q.inspected_by; END IF;
  IF q.reviewed_by IS NOT NULL THEN RAISE EXCEPTION '已审核'; END IF;
  UPDATE quality_inspection SET status='reviewed', reviewed_by=app_user(), reviewed_at=now() WHERE id=p_qi;
END $$;

-- 分期收款计划：比例合计必须 = 100%，金额按订单含税总额分配（尾差落在最后一期）
CREATE OR REPLACE FUNCTION fn_set_payment_schedule(p_so bigint, p_terms jsonb) RETURNS int LANGUAGE plpgsql AS $$
DECLARE total numeric; s numeric; n int;
BEGIN
  SELECT sum(portion) INTO s FROM (SELECT (t->>'portion')::numeric portion FROM jsonb_array_elements(p_terms) t) x;
  IF s <> 1 THEN RAISE EXCEPTION '分期比例合计必须为 100%%（当前 %）', s*100; END IF;
  SELECT sum(round(qty*unit_price,2)) INTO total FROM sales_order_item WHERE sales_order_id=p_so;
  DELETE FROM payment_schedule WHERE sales_order_id=p_so;
  INSERT INTO payment_schedule(sales_order_id, seq, term_name, due_date, portion, amount)
  SELECT p_so, o::int, t->>'name', (t->>'due')::date, (t->>'portion')::numeric, round(total*(t->>'portion')::numeric,2)
  FROM jsonb_array_elements(p_terms) WITH ORDINALITY AS x(t,o);
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE payment_schedule SET amount = amount + (total - (SELECT sum(amount) FROM payment_schedule WHERE sales_order_id=p_so))
   WHERE sales_order_id=p_so AND seq=n;
  RETURN n;
END $$;
-- 分期到期情况：客户已收款按到期顺序冲抵
CREATE OR REPLACE VIEW v_payment_schedule_status WITH (security_invoker = true) AS
SELECT ps.*, least(ps.amount, greatest(0, r.received - coalesce(sum(ps.amount) OVER (PARTITION BY ps.sales_order_id ORDER BY ps.seq ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0))) AS covered_amount
FROM payment_schedule ps JOIN sales_order so ON so.id=ps.sales_order_id
CROSS JOIN LATERAL (SELECT coalesce(sum(paid_amount),0) received FROM payment_entry pe WHERE pe.party_id=so.customer_id AND pe.payment_type='receive' AND pe.status='posted') r;

-- AI 字段级置信度：读图结果逐字段落表；人工确认/更正写审计
CREATE OR REPLACE FUNCTION fn_ai_record_field_confidence(p_req bigint, p_fields jsonb) RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  INSERT INTO ai_field_confidence(ai_request_id, field, ai_value, confidence)
  SELECT p_req, f.key, f.value->>'value', (f.value->>'confidence')::numeric FROM jsonb_each(p_fields) f;
  GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $$;
CREATE OR REPLACE FUNCTION fn_ai_confirm_field(p_id bigint, p_value text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE f ai_field_confidence; st text;
BEGIN
  SELECT * INTO f FROM ai_field_confidence WHERE id=p_id FOR UPDATE;
  IF f.status <> 'pending' THEN RAISE EXCEPTION '字段 % 已确认', f.field; END IF;
  st := CASE WHEN p_value IS NOT DISTINCT FROM f.ai_value THEN 'confirmed' ELSE 'corrected' END;
  UPDATE ai_field_confidence SET confirmed_value=p_value, confirmed_by=app_user(), confirmed_at=now(), status=st WHERE id=p_id;
  RETURN st;
END $$;
