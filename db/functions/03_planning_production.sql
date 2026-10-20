-- MRP 展开、工单、发料、报工（计件）、工序检/返工、完工入库、余料

CREATE OR REPLACE FUNCTION fn_on_hand(p_item bigint, p_plant bigint) RETURNS numeric LANGUAGE sql STABLE AS $$
SELECT coalesce(sum(b.qty),0) FROM v_stock_balance b JOIN warehouse w ON w.id=b.warehouse_id
WHERE b.item_id=p_item AND w.plant_id=p_plant AND w.wh_type IN ('raw','fg') AND b.tenant_id=app_tid() $$;

CREATE OR REPLACE FUNCTION fn_create_wo(p_item bigint, p_qty numeric, p_plant bigint, p_so_item bigint,
  p_parent bigint, p_plan bigint, p_fg_wh bigint) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE wo bigint;
BEGIN
  INSERT INTO work_order(plant_id, item_id, drawing_id, bom_id, sales_order_item_id, production_plan_id, parent_work_order_id, qty, fg_warehouse_id)
  SELECT p_plant, p_item, i.current_drawing_id, (SELECT id FROM bom WHERE item_id=p_item AND is_default AND status='active'),
         p_so_item, p_plan, p_parent, p_qty, p_fg_wh FROM item i WHERE i.id=p_item RETURNING id INTO wo;
  INSERT INTO wo_operation(work_order_id, routing_op_id, seq, op_name, workstation_id, std_hours, is_subcontracted, piece_rate)
  SELECT wo, ro.id, ro.seq, ro.op_name, ro.workstation_id, ro.std_hours, ro.is_subcontracted, ro.piece_rate
  FROM routing r JOIN routing_operation ro ON ro.routing_id=r.id WHERE r.item_id=p_item ORDER BY ro.seq;
  RETURN wo;
END $$;

CREATE OR REPLACE FUNCTION fn_release_wo(p_wo bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE w work_order;
BEGIN
  SELECT * INTO w FROM work_order WHERE id=p_wo;
  IF w.drawing_id IS NOT NULL AND (SELECT status FROM drawing_revision WHERE id=w.drawing_id) <> 'released' THEN
    RAISE EXCEPTION '工单 % 的图纸版本未生效，不能下达', w.doc_no;
  END IF;
  UPDATE work_order SET status='released' WHERE id=p_wo;
  UPDATE wo_operation SET input_qty=w.qty WHERE work_order_id=p_wo AND seq=(SELECT min(seq) FROM wo_operation WHERE work_order_id=p_wo);
END $$;

-- MRP：按销售订单逐层展开 BOM，扣减现存量，生成自制工单（父子关联）与外购需求
CREATE OR REPLACE FUNCTION fn_run_mrp(p_so bigint, p_fg_wh bigint, p_wip_wh bigint) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE so sales_order; plan bigint; r record; wo bigint; parent_wo bigint;
BEGIN
  SELECT * INTO so FROM sales_order WHERE id=p_so;
  INSERT INTO production_plan(sales_order_id, plant_id) VALUES (p_so, so.plant_id) RETURNING id INTO plan;
  INSERT INTO mrp_line(production_plan_id, item_id, bom_level, parent_item_id, gross_qty, on_hand_qty, net_qty, action)
  WITH RECURSIVE ex(item_id, parent_id, qty, lvl, so_item) AS (
    SELECT s.item_id, NULL::bigint, s.qty - s.delivered_qty, 0, s.id FROM sales_order_item s WHERE s.sales_order_id=p_so
    UNION ALL
    SELECT bi.component_id, ex.item_id, ex.qty*bi.qty_per*(1+bi.attrition_rate)/b.quantity, ex.lvl+1, ex.so_item
    FROM ex JOIN bom b ON b.item_id=ex.item_id AND b.is_default AND b.status='active' JOIN bom_item bi ON bi.bom_id=b.id)
  SELECT plan, ex.item_id, min(ex.lvl), ex.parent_id, sum(ex.qty),
         fn_on_hand(ex.item_id, so.plant_id),
         greatest(sum(ex.qty) - fn_on_hand(ex.item_id, so.plant_id), 0),
         CASE WHEN greatest(sum(ex.qty) - fn_on_hand(ex.item_id, so.plant_id),0)=0 THEN 'none'
              WHEN i.item_kind IN ('raw','purchased') THEN 'buy' ELSE 'make' END
  FROM ex JOIN item i ON i.id=ex.item_id GROUP BY ex.item_id, ex.parent_id, i.item_kind;
  -- 自制：按层级生成工单，子工单挂父工单
  FOR r IN SELECT m.*, (SELECT s.id FROM sales_order_item s WHERE s.sales_order_id=p_so AND s.item_id=m.item_id LIMIT 1) so_item
           FROM mrp_line m WHERE m.production_plan_id=plan AND m.action='make' ORDER BY m.bom_level LOOP
    SELECT w.id INTO parent_wo FROM work_order w WHERE w.production_plan_id=plan AND w.item_id=r.parent_item_id LIMIT 1;
    wo := fn_create_wo(r.item_id, r.net_qty, so.plant_id, CASE WHEN r.bom_level=0 THEN r.so_item END, parent_wo, plan,
                       CASE WHEN r.bom_level=0 THEN p_fg_wh ELSE p_wip_wh END);
    PERFORM fn_release_wo(wo);
  END LOOP;
  UPDATE production_plan SET status='planned' WHERE id=plan;
  UPDATE sales_order SET status='in_production' WHERE id=p_so AND status='confirmed';
  RETURN plan;
END $$;

-- 生产发料（含子工单产出的半成品转入父工单）
CREATE OR REPLACE FUNCTION fn_issue_material(p_wo bigint, p_item bigint, p_qty numeric, p_wh bigint) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE sl stock_ledger; w work_order; kind text; ctype text;
BEGIN
  SELECT * INTO w FROM work_order WHERE id=p_wo;
  IF w.status NOT IN ('released','in_process') THEN RAISE EXCEPTION '工单 % 状态 % 不能发料', w.doc_no, w.status; END IF;
  sl := fn_stock_move(p_wh, p_item, -p_qty, NULL, 'material_issue', p_wo, NULL, p_wo);
  SELECT item_kind INTO kind FROM item WHERE id=p_item;
  ctype := CASE WHEN EXISTS (SELECT 1 FROM work_order c WHERE c.parent_work_order_id=p_wo AND c.item_id=p_item) THEN 'semi_transfer'
                WHEN kind='purchased' THEN 'purchased' ELSE 'material' END;
  INSERT INTO wo_cost_entry(work_order_id, cost_type, amount, qty, source_type, source_id)
  VALUES (p_wo, ctype, -sl.value_change, p_qty, 'stock_ledger', sl.id);
  PERFORM fn_post_je('material_issue', sl.id, current_date, '生产发料 '||w.doc_no, jsonb_build_array(
    jsonb_build_object('a','5001','d',-sl.value_change,'wo',p_wo,'plant',w.plant_id),
    jsonb_build_object('a',fn_inv_acct(p_item),'c',-sl.value_change,'plant',w.plant_id)));
  IF w.status='released' THEN UPDATE work_order SET status='in_process' WHERE id=p_wo; END IF;
  RETURN -sl.value_change;
END $$;

-- 报工触发器：校验图纸版本与可报数量，计算计件工资和机时成本
CREATE OR REPLACE FUNCTION trg_job_card_before() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE op wo_operation; w work_order; avail numeric; d_status text;
BEGIN
  SELECT * INTO op FROM wo_operation WHERE id=NEW.wo_operation_id FOR UPDATE;
  SELECT * INTO w FROM work_order WHERE id=op.work_order_id;
  IF w.status NOT IN ('released','in_process') THEN RAISE EXCEPTION '工单 % 状态 % 不能报工', w.doc_no, w.status; END IF;
  IF op.is_subcontracted THEN RAISE EXCEPTION '委外工序 % 不能在厂内报工', op.op_name; END IF;
  NEW.drawing_id := coalesce(NEW.drawing_id, w.drawing_id);
  SELECT status INTO d_status FROM drawing_revision WHERE id=NEW.drawing_id;
  IF NEW.drawing_id IS NOT NULL AND (d_status <> 'released' OR NEW.drawing_id IS DISTINCT FROM w.drawing_id) THEN
    RAISE EXCEPTION '图纸版本已失效（%），请按最新版本报工', d_status USING ERRCODE='EP004';
  END IF;
  IF NEW.is_rework THEN avail := op.rework_pending_qty;
  ELSE avail := op.input_qty - op.completed_qty - op.scrap_qty - op.rework_pending_qty; END IF;
  IF NEW.good_qty + NEW.scrap_qty > avail THEN
    RAISE EXCEPTION '报工数量 % 超过可报数量 %（工序 %）', NEW.good_qty + NEW.scrap_qty, avail, op.op_name USING ERRCODE='EP005';
  END IF;
  NEW.workstation_id := coalesce(NEW.workstation_id, op.workstation_id);
  NEW.piece_wage := CASE WHEN NEW.is_rework THEN 0 ELSE round(NEW.good_qty*op.piece_rate,2) END;   -- 规则(示例)：返工不计件
  NEW.machine_cost := round(NEW.hours * p((SELECT rate_param_key FROM workstation WHERE id=NEW.workstation_id)),2);
  RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION trg_job_card_after() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE op wo_operation; w work_order; nxt bigint;
BEGIN
  SELECT * INTO op FROM wo_operation WHERE id=NEW.wo_operation_id;
  SELECT * INTO w FROM work_order WHERE id=op.work_order_id;
  IF op.status='pending' THEN UPDATE wo_operation SET status='in_process' WHERE id=op.id; END IF;
  UPDATE wo_operation SET completed_qty=completed_qty+NEW.good_qty, scrap_qty=scrap_qty+NEW.scrap_qty,
         rework_pending_qty=rework_pending_qty - CASE WHEN NEW.is_rework THEN NEW.good_qty+NEW.scrap_qty ELSE 0 END
   WHERE id=op.id RETURNING * INTO op;
  IF op.completed_qty + op.scrap_qty >= op.input_qty AND op.rework_pending_qty=0 AND op.status IN ('in_process','rework') THEN
    UPDATE wo_operation SET status='done' WHERE id=op.id;
  END IF;
  SELECT id INTO nxt FROM wo_operation WHERE work_order_id=op.work_order_id AND seq>op.seq ORDER BY seq LIMIT 1;
  IF nxt IS NOT NULL THEN UPDATE wo_operation SET input_qty=input_qty+NEW.good_qty WHERE id=nxt; END IF;
  UPDATE work_order SET scrap_qty=scrap_qty+NEW.scrap_qty WHERE id=w.id;
  IF w.status='released' THEN UPDATE work_order SET status='in_process' WHERE id=w.id; END IF;
  INSERT INTO wo_cost_entry(work_order_id, cost_type, amount, qty, hours, source_type, source_id) VALUES
    (w.id, CASE WHEN NEW.is_rework THEN 'rework' ELSE 'labor' END, NEW.piece_wage, NEW.good_qty, NULL, 'job_card', NEW.id),
    (w.id, CASE WHEN NEW.is_rework THEN 'rework' ELSE 'machine' END, NEW.machine_cost, NULL, NEW.hours, 'job_card', NEW.id);
  PERFORM fn_post_je('job_card', NEW.id, current_date, '报工 '||NEW.doc_no, jsonb_build_array(
    jsonb_build_object('a','5001','d',NEW.piece_wage+NEW.machine_cost,'wo',w.id,'plant',w.plant_id),
    jsonb_build_object('a','2211','c',NEW.piece_wage,'plant',w.plant_id),
    jsonb_build_object('a','5101','c',NEW.machine_cost,'plant',w.plant_id)));
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS job_card_before ON job_card;
DROP TRIGGER IF EXISTS job_card_after ON job_card;
CREATE TRIGGER job_card_before BEFORE INSERT ON job_card FOR EACH ROW EXECUTE FUNCTION trg_job_card_before();
CREATE TRIGGER job_card_after AFTER INSERT ON job_card FOR EACH ROW EXECUTE FUNCTION trg_job_card_after();

CREATE OR REPLACE FUNCTION fn_report(p_wo bigint, p_seq int, p_emp text, p_good numeric, p_scrap numeric, p_hours numeric,
  p_rework boolean DEFAULT false, p_qi bigint DEFAULT NULL, p_drawing bigint DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE jc bigint;
BEGIN
  INSERT INTO job_card(wo_operation_id, employee_id, good_qty, scrap_qty, hours, is_rework, rework_of_inspection_id, drawing_id)
  SELECT o.id, (SELECT id FROM employee WHERE emp_code=p_emp AND tenant_id=app_tid()), p_good, p_scrap, p_hours, p_rework, p_qi, p_drawing
  FROM wo_operation o WHERE o.work_order_id=p_wo AND o.seq=p_seq RETURNING id INTO jc;
  IF jc IS NULL THEN RAISE EXCEPTION '工单 % 没有工序 %', p_wo, p_seq; END IF;
  RETURN jc;
END $$;

-- 工序检：不合格品 → 返工 / 报废 / 让步接收
CREATE OR REPLACE FUNCTION fn_process_inspection(p_wo bigint, p_seq int, p_inspected numeric, p_accepted numeric,
  p_rework numeric, p_scrap numeric, p_concession numeric DEFAULT 0, p_note text DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE op wo_operation; qi bigint; nxt wo_operation;
BEGIN
  SELECT * INTO op FROM wo_operation WHERE work_order_id=p_wo AND seq=p_seq FOR UPDATE;
  INSERT INTO quality_inspection(inspection_type, ref_type, ref_id, item_id, inspected_qty, accepted_qty, rework_qty, scrap_qty, concession_qty, defect_note)
  SELECT 'process','wo_operation',op.id,w.item_id,p_inspected,p_accepted,p_rework,p_scrap,p_concession,p_note FROM work_order w WHERE w.id=p_wo RETURNING id INTO qi;
  UPDATE quality_inspection SET status='completed' WHERE id=qi;
  IF p_rework + p_scrap > 0 THEN
    SELECT * INTO nxt FROM wo_operation WHERE work_order_id=p_wo AND seq>p_seq ORDER BY seq LIMIT 1;
    IF nxt.id IS NOT NULL AND nxt.input_qty - nxt.completed_qty - nxt.scrap_qty - nxt.rework_pending_qty < p_rework + p_scrap THEN
      RAISE EXCEPTION '下道工序已加工，不能回退 % 件', p_rework + p_scrap;
    END IF;
    UPDATE wo_operation SET completed_qty=completed_qty-p_rework-p_scrap, rework_pending_qty=rework_pending_qty+p_rework,
           scrap_qty=scrap_qty+p_scrap, status=CASE WHEN p_rework>0 AND status='done' THEN 'rework' ELSE status END WHERE id=op.id;
    IF nxt.id IS NOT NULL THEN UPDATE wo_operation SET input_qty=input_qty-p_rework-p_scrap WHERE id=nxt.id; END IF;
    UPDATE work_order SET scrap_qty=scrap_qty+p_scrap WHERE id=p_wo;
  END IF;
  RETURN qi;
END $$;

CREATE OR REPLACE FUNCTION fn_final_inspection(p_wo bigint, p_inspected numeric, p_accepted numeric, p_scrap numeric, p_note text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE qi bigint; last_op wo_operation;
BEGIN
  SELECT * INTO last_op FROM wo_operation WHERE work_order_id=p_wo ORDER BY seq DESC LIMIT 1;
  IF p_inspected > last_op.completed_qty - (SELECT coalesce(sum(inspected_qty),0) FROM quality_inspection WHERE inspection_type='final' AND ref_type='work_order' AND ref_id=p_wo) THEN
    RAISE EXCEPTION '成品检数量超过末道工序完工数';
  END IF;
  INSERT INTO quality_inspection(inspection_type, ref_type, ref_id, item_id, inspected_qty, accepted_qty, scrap_qty, defect_note)
  SELECT 'final','work_order',p_wo,item_id,p_inspected,p_accepted,p_scrap,p_note FROM work_order WHERE id=p_wo RETURNING id INTO qi;
  UPDATE quality_inspection SET status='completed' WHERE id=qi;
  UPDATE work_order SET scrap_qty=scrap_qty+p_scrap WHERE id=p_wo;
  RETURN qi;
END $$;

-- 完工入库：按工单累计成本结转（剩余成本 × 本次数量 / 剩余可入库数量）
CREATE OR REPLACE FUNCTION fn_wo_receive(p_wo bigint, p_qty numeric) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE w work_order; accepted numeric; total_cost numeric; received_value numeric; val numeric; sl stock_ledger; remaining numeric;
BEGIN
  SELECT * INTO w FROM work_order WHERE id=p_wo FOR UPDATE;
  SELECT coalesce(sum(accepted_qty),0) INTO accepted FROM quality_inspection WHERE inspection_type='final' AND ref_type='work_order' AND ref_id=p_wo AND status='completed';
  IF w.produced_qty + p_qty > accepted THEN RAISE EXCEPTION '入库数 % 超过成品检合格数 %', w.produced_qty + p_qty, accepted; END IF;
  SELECT coalesce(sum(amount),0) INTO total_cost FROM wo_cost_entry WHERE work_order_id=p_wo;
  SELECT coalesce(sum(value_change),0) INTO received_value FROM stock_ledger WHERE voucher_type='wo_receipt' AND voucher_id=p_wo;
  remaining := accepted - w.produced_qty;
  val := round((total_cost - received_value) * p_qty / remaining, 4);
  sl := fn_stock_move(w.fg_warehouse_id, w.item_id, p_qty, val/p_qty, 'wo_receipt', p_wo, NULL, p_wo);
  PERFORM fn_post_je('wo_receipt', sl.id, current_date, '完工入库 '||w.doc_no, jsonb_build_array(
    jsonb_build_object('a','1405','d',sl.value_change,'plant',w.plant_id),
    jsonb_build_object('a','5001','c',sl.value_change,'wo',p_wo,'plant',w.plant_id)));
  UPDATE work_order SET produced_qty=produced_qty+p_qty WHERE id=p_wo RETURNING * INTO w;
  IF w.produced_qty + w.scrap_qty >= w.qty THEN UPDATE work_order SET status='completed' WHERE id=p_wo AND status='in_process'; END IF;
  RETURN sl.value_change;
END $$;

-- 余料回库：按长度/重量登记，按原材料当前均价计价，冲减工单材料成本
CREATE OR REPLACE FUNCTION fn_return_remnant(p_wo bigint, p_item bigint, p_wh bigint, p_len numeric, p_dia numeric, p_weight numeric)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE rate numeric; rid bigint; sl stock_ledger; w work_order;
BEGIN
  SELECT * INTO w FROM work_order WHERE id=p_wo;
  -- 计价：取本工单该材料的实际发料均价
  SELECT sum(-value_change)/sum(-qty) INTO rate FROM stock_ledger WHERE work_order_id=p_wo AND item_id=p_item AND voucher_type='material_issue';
  IF rate IS NULL THEN RAISE EXCEPTION '工单 % 未领用该材料，不能退余料', w.doc_no; END IF;
  INSERT INTO remnant(item_id, warehouse_id, length_mm, diameter_mm, weight_kg, unit_value, source_work_order_id)
  VALUES (p_item, p_wh, p_len, p_dia, p_weight, rate, p_wo) RETURNING id INTO rid;
  sl := fn_stock_move(p_wh, p_item, p_weight, rate, 'remnant_return', rid, NULL, p_wo);
  INSERT INTO wo_cost_entry(work_order_id, cost_type, amount, qty, source_type, source_id)
  VALUES (p_wo, 'remnant_credit', -sl.value_change, p_weight, 'remnant', rid);
  PERFORM fn_post_je('remnant_return', rid, current_date, '余料回库', jsonb_build_array(
    jsonb_build_object('a','1403','d',sl.value_change,'plant',w.plant_id),
    jsonb_build_object('a','5001','c',sl.value_change,'wo',p_wo,'plant',w.plant_id)));
  RETURN rid;
END $$;

CREATE OR REPLACE FUNCTION fn_reuse_remnant(p_remnant bigint, p_wo bigint) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE r remnant; v numeric;
BEGIN
  SELECT * INTO r FROM remnant WHERE id=p_remnant FOR UPDATE;
  IF r.status <> 'available' THEN RAISE EXCEPTION '余料 % 已不可用(%)', p_remnant, r.status; END IF;
  v := fn_issue_material(p_wo, r.item_id, r.weight_kg, r.warehouse_id);
  UPDATE remnant SET status='reused', reused_work_order_id=p_wo WHERE id=p_remnant;
  RETURN v;
END $$;

-- 工单完结（允许短缺完结：已入库数 < 计划数时记录短缺）
CREATE OR REPLACE FUNCTION fn_wo_finish(p_wo bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE w work_order;
BEGIN
  SELECT * INTO w FROM work_order WHERE id=p_wo FOR UPDATE;
  IF w.produced_qty = 0 THEN RAISE EXCEPTION '工单 % 尚未入库，不能完结', w.doc_no; END IF;
  IF w.status='in_process' THEN UPDATE work_order SET status='completed' WHERE id=p_wo; END IF;
END $$;
