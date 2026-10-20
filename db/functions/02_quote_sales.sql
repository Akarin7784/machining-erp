-- 图纸版本、读图报价（AI 结果落表）、报价成本计算、审批、销售订单、改图

CREATE OR REPLACE FUNCTION fn_release_drawing(p_drawing bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d drawing_revision;
BEGIN
  SELECT * INTO d FROM drawing_revision WHERE id=p_drawing FOR UPDATE;
  UPDATE drawing_revision SET status='superseded' WHERE item_id=d.item_id AND status='released' AND id<>d.id;
  UPDATE drawing_revision SET status='released', released_at=now() WHERE id=d.id;
  UPDATE item SET current_drawing_id=d.id WHERE id=d.item_id;
END $$;

-- AI 读图报价：写 ai_request + ai_drawing_feature（AI 输出由外部服务给出，这里只落表）
CREATE OR REPLACE FUNCTION fn_ai_record_drawing_quote(p_input jsonb, p_output jsonb, p_model text DEFAULT 'mock')
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE rid bigint;
BEGIN
  INSERT INTO ai_request(kind, input, output, model, prompt_version) VALUES ('drawing_quote', p_input, p_output, p_model, 'v1') RETURNING id INTO rid;
  INSERT INTO ai_drawing_feature(ai_request_id, material_code, stock_diameter_mm, stock_length_mm, finished_weight_kg, plated_area_dm2,
    tightest_tolerance_mm, surface_treatment, heat_treatment, similar_item_id, confidence)
  VALUES (rid, p_output->>'material_code', (p_output->>'stock_diameter_mm')::numeric, (p_output->>'stock_length_mm')::numeric,
    (p_output->>'finished_weight_kg')::numeric, (p_output->>'plated_area_dm2')::numeric, (p_output->>'tightest_tolerance_mm')::numeric,
    p_output->>'surface_treatment', p_output->>'heat_treatment', (p_output->>'similar_item_id')::bigint, (p_output->>'confidence')::numeric);
  UPDATE ai_request SET status='succeeded' WHERE id=rid;
  RETURN rid;
END $$;

-- 报价成本计算：多层 BOM × 工艺路线 × 参数表
CREATE OR REPLACE FUNCTION fn_quote_cost(p_qi bigint) RETURNS quotation_item LANGUAGE plpgsql AS $$
DECLARE qi quotation_item; q quotation; r record; amt numeric; hrs numeric; rate numeric; cat text;
BEGIN
  SELECT * INTO qi FROM quotation_item WHERE id=p_qi;
  SELECT * INTO q FROM quotation WHERE id=qi.quotation_id;
  DELETE FROM quotation_cost_line WHERE quotation_item_id=p_qi;
  FOR r IN
    WITH RECURSIVE ex(item_id, qty, lvl) AS (
      SELECT qi.item_id, 1::numeric, 0
      UNION ALL
      SELECT bi.component_id, ex.qty*bi.qty_per/b.quantity, ex.lvl+1
      FROM ex JOIN bom b ON b.item_id=ex.item_id AND b.is_default AND b.status='active'
      JOIN bom_item bi ON bi.bom_id=b.id)
    SELECT ex.*, i.item_kind, i.material_param_key, i.std_cost FROM ex JOIN item i ON i.id=ex.item_id
  LOOP
    IF r.item_kind='raw' THEN
      rate := p(r.material_param_key);
      INSERT INTO quotation_cost_line(quotation_item_id,cost_type,ref_item_id,basis_qty,basis_uom,unit_rate,param_key,amount)
      VALUES (p_qi,'material',r.item_id,r.qty,'kg',rate,r.material_param_key,round(r.qty*rate,4));
    ELSIF r.item_kind='purchased' THEN
      INSERT INTO quotation_cost_line(quotation_item_id,cost_type,ref_item_id,basis_qty,basis_uom,unit_rate,amount)
      VALUES (p_qi,'purchased',r.item_id,r.qty,'pcs',r.std_cost,round(r.qty*r.std_cost,4));
    ELSE
      INSERT INTO quotation_cost_line(quotation_item_id,cost_type,ref_item_id,routing_op_id,basis_qty,basis_uom,unit_rate,param_key,amount)
      SELECT p_qi,
        CASE WHEN NOT ro.is_subcontracted THEN 'machining' WHEN ro.subcon_price_key LIKE 'ht\_%' THEN 'heat_treat' ELSE 'surface' END,
        r.item_id, ro.id,
        CASE WHEN ro.is_subcontracted THEN ro.subcon_basis_per_unit*r.qty ELSE (ro.std_hours + ro.setup_hours*ceil(qi.qty/ro.batch_size)/qi.qty)*r.qty END,
        CASE WHEN ro.is_subcontracted THEN ro.subcon_basis ELSE 'h' END,
        p(coalesce(ro.subcon_price_key, w.rate_param_key)),
        coalesce(ro.subcon_price_key, w.rate_param_key),
        round(CASE WHEN ro.is_subcontracted THEN ro.subcon_basis_per_unit*r.qty ELSE (ro.std_hours + ro.setup_hours*ceil(qi.qty/ro.batch_size)/qi.qty)*r.qty END
              * p(coalesce(ro.subcon_price_key, w.rate_param_key)),4)
      FROM routing rt JOIN routing_operation ro ON ro.routing_id=rt.id LEFT JOIN workstation w ON w.id=ro.workstation_id
      WHERE rt.item_id=r.item_id;
    END IF;
  END LOOP;
  UPDATE quotation_item SET
    material_cost   = coalesce((SELECT sum(amount) FROM quotation_cost_line WHERE quotation_item_id=p_qi AND cost_type='material'),0),
    machining_cost  = coalesce((SELECT sum(amount) FROM quotation_cost_line WHERE quotation_item_id=p_qi AND cost_type='machining'),0),
    heat_treat_cost = coalesce((SELECT sum(amount) FROM quotation_cost_line WHERE quotation_item_id=p_qi AND cost_type='heat_treat'),0),
    surface_cost    = coalesce((SELECT sum(amount) FROM quotation_cost_line WHERE quotation_item_id=p_qi AND cost_type='surface'),0),
    purchased_cost  = coalesce((SELECT sum(amount) FROM quotation_cost_line WHERE quotation_item_id=p_qi AND cost_type='purchased'),0),
    overhead_factor = p('quote_overhead_factor')
  WHERE id=p_qi;
  UPDATE quotation_item SET suggested_price = round(unit_cost/(1-q.min_margin),2),
         unit_price = CASE WHEN unit_price=0 THEN round(unit_cost/(1-q.min_margin),2) ELSE unit_price END
  WHERE id=p_qi RETURNING * INTO qi;
  RETURN qi;
END $$;

-- 提交报价：任一行毛利低于底线 → 待审批，否则自动批准
CREATE OR REPLACE FUNCTION fn_quote_submit(p_q bigint) RETURNS text LANGUAGE plpgsql AS $$
DECLARE q quotation; low boolean;
BEGIN
  SELECT * INTO q FROM quotation WHERE id=p_q FOR UPDATE;
  UPDATE quotation SET status='submitted' WHERE id=p_q;
  SELECT bool_or(margin_rate < q.min_margin) INTO low FROM quotation_item WHERE quotation_id=p_q;
  IF low THEN UPDATE quotation SET status='pending_approval' WHERE id=p_q; RETURN 'pending_approval';
  ELSE UPDATE quotation SET status='approved', approved_by='system', approved_at=now() WHERE id=p_q; RETURN 'approved'; END IF;
END $$;

CREATE OR REPLACE FUNCTION fn_quote_decide(p_q bigint, p_approve boolean, p_note text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT pg_has_role(current_user,'erp_manager','member') AND NOT (SELECT rolsuper FROM pg_roles WHERE rolname=current_user) THEN
    RAISE EXCEPTION '只有经理角色可以审批低毛利报价';
  END IF;
  UPDATE quotation SET status=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
         approved_by=app_user(), approved_at=now(), approval_note=p_note WHERE id=p_q;
END $$;

-- 报价转销售订单
CREATE OR REPLACE FUNCTION fn_so_from_quote(p_q bigint, p_plant bigint, p_delivery date) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE q quotation; so bigint;
BEGIN
  SELECT * INTO q FROM quotation WHERE id=p_q;
  IF q.status <> 'approved' THEN RAISE EXCEPTION '报价 % 状态 % 不能转订单', q.doc_no, q.status; END IF;
  INSERT INTO sales_order(customer_id, plant_id, quotation_id, delivery_date) VALUES (q.customer_id, p_plant, p_q, p_delivery) RETURNING id INTO so;
  INSERT INTO sales_order_item(sales_order_id, quotation_item_id, item_id, drawing_id, qty, unit_price)
  SELECT so, qi.id, qi.item_id, qi.drawing_id, qi.qty, qi.unit_price FROM quotation_item qi WHERE qi.quotation_id=p_q;
  UPDATE quotation SET status='ordered' WHERE id=p_q;
  UPDATE sales_order SET status='confirmed' WHERE id=so;
  RETURN so;
END $$;

-- 客户中途改图：发布新版本，订单行/未完工工单切换到新版本，记录 ECN；旧版本报工将被拒绝
CREATE OR REPLACE FUNCTION fn_change_drawing(p_item bigint, p_new_drawing bigint, p_reason text, p_disposition text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE old_d bigint; ecn bigint; wip numeric;
BEGIN
  SELECT current_drawing_id INTO old_d FROM item WHERE id=p_item;
  PERFORM fn_release_drawing(p_new_drawing);
  SELECT coalesce(sum(o.completed_qty),0) INTO wip FROM work_order w JOIN wo_operation o ON o.work_order_id=w.id
   WHERE w.item_id=p_item AND w.status IN ('released','in_process') AND o.seq=(SELECT min(seq) FROM wo_operation WHERE work_order_id=w.id);
  UPDATE sales_order_item s SET drawing_id=p_new_drawing FROM sales_order so
   WHERE s.item_id=p_item AND so.id=s.sales_order_id AND so.status NOT IN ('delivered','closed','cancelled');
  UPDATE work_order SET drawing_id=p_new_drawing WHERE item_id=p_item AND status IN ('draft','released','in_process');
  INSERT INTO engineering_change(item_id, from_drawing_id, to_drawing_id, reason, affected_wip_qty, disposition)
  VALUES (p_item, old_d, p_new_drawing, p_reason, wip, p_disposition) RETURNING id INTO ecn;
  RETURN ecn;
END $$;
