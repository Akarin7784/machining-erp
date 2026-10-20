-- 多工厂调拨、有限能力排产、AI（委外对账单核对、完工复盘、交期预测）

CREATE OR REPLACE FUNCTION fn_transfer_ship(p_tr bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE t stock_transfer; sl stock_ledger; fp bigint; tp bigint;
BEGIN
  SELECT * INTO t FROM stock_transfer WHERE id=p_tr FOR UPDATE;
  sl := fn_stock_move(t.from_warehouse_id, t.item_id, -t.qty, NULL, 'stock_transfer', p_tr);
  PERFORM fn_stock_move(t.transit_warehouse_id, t.item_id, t.qty, -sl.value_change/t.qty, 'stock_transfer', p_tr);
  SELECT plant_id INTO fp FROM warehouse WHERE id=t.from_warehouse_id;
  PERFORM fn_post_je('stock_transfer_ship', p_tr, current_date, '调拨发出 '||t.doc_no, jsonb_build_array(
    jsonb_build_object('a','1411','d',-sl.value_change,'plant',fp), jsonb_build_object('a',fn_inv_acct(t.item_id),'c',-sl.value_change,'plant',fp)));
  UPDATE stock_transfer SET status='in_transit', shipped_at=now() WHERE id=p_tr;
END $$;

CREATE OR REPLACE FUNCTION fn_transfer_receive(p_tr bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE t stock_transfer; sl stock_ledger; tp bigint;
BEGIN
  SELECT * INTO t FROM stock_transfer WHERE id=p_tr FOR UPDATE;
  sl := fn_stock_move(t.transit_warehouse_id, t.item_id, -t.qty, NULL, 'stock_transfer', p_tr);
  PERFORM fn_stock_move(t.to_warehouse_id, t.item_id, t.qty, -sl.value_change/t.qty, 'stock_transfer', p_tr);
  SELECT plant_id INTO tp FROM warehouse WHERE id=t.to_warehouse_id;
  PERFORM fn_post_je('stock_transfer_receive', p_tr, current_date, '调拨收货 '||t.doc_no, jsonb_build_array(
    jsonb_build_object('a',fn_inv_acct(t.item_id),'d',-sl.value_change,'plant',tp), jsonb_build_object('a','1411','c',-sl.value_change,'plant',tp)));
  UPDATE stock_transfer SET status='received', received_at=now() WHERE id=p_tr;
END $$;

-- 有限能力排产（正排）：按工单下达顺序、工序顺序，逐日占用设备剩余产能；委外工序按外协周期（参数）顺延
CREATE OR REPLACE FUNCTION fn_schedule_finite(p_plant bigint, p_start date) RETURNS date LANGUAGE plpgsql AS $$
DECLARE o record; need numeric; d date; cap numeric; used numeric; take numeric; prev_end date; first_day date; last_end date := p_start;
        wo_prev bigint := NULL;
BEGIN
  DELETE FROM schedule_slot s USING wo_operation xo, work_order xw WHERE s.wo_operation_id=xo.id AND xo.work_order_id=xw.id AND xw.plant_id=p_plant;
  FOR o IN SELECT op.*, w.qty AS wo_qty, w.parent_work_order_id, ws.hours_per_day*ws.production_capacity AS hours_per_day,
                  coalesce(ro.setup_hours,0) AS setup_hours
           FROM wo_operation op JOIN work_order w ON w.id=op.work_order_id
           LEFT JOIN workstation ws ON ws.id=op.workstation_id LEFT JOIN routing_operation ro ON ro.id=op.routing_op_id
           WHERE w.plant_id=p_plant AND w.status IN ('released','in_process') AND op.status <> 'done'
           ORDER BY coalesce(w.parent_work_order_id, w.id), w.parent_work_order_id IS NULL, w.id, op.seq LOOP
    IF wo_prev IS DISTINCT FROM o.work_order_id THEN
      -- 父工单要等子工单完工
      prev_end := greatest(p_start, coalesce((SELECT max(c.planned_end)+1 FROM work_order c WHERE c.parent_work_order_id=o.work_order_id), p_start));
      wo_prev := o.work_order_id;
    END IF;
    IF o.is_subcontracted THEN
      UPDATE wo_operation SET sched_start=prev_end, sched_end=prev_end + p('ex_subcon_lead_days')::int WHERE id=o.id;
      prev_end := prev_end + p('ex_subcon_lead_days')::int;
    ELSE
      need := greatest(fn_op_hours(o.std_hours, o.setup_hours, o.batch_size, o.wo_qty - o.completed_qty), 0.01);
      d := prev_end; first_day := NULL;
      WHILE need > 0 LOOP
        IF extract(isodow FROM d) < 7 THEN   -- 周日休息
          SELECT coalesce(sum(hours),0) INTO used FROM schedule_slot WHERE workstation_id=o.workstation_id AND work_date=d;
          cap := o.hours_per_day - used;
          IF cap > 0 THEN
            take := least(cap, need);
            INSERT INTO schedule_slot(wo_operation_id, workstation_id, work_date, hours) VALUES (o.id, o.workstation_id, d, take);
            need := need - take; first_day := coalesce(first_day, d);
          END IF;
        END IF;
        IF need > 0 THEN d := d + 1; END IF;
      END LOOP;
      UPDATE wo_operation SET sched_start=first_day, sched_end=d WHERE id=o.id;
      prev_end := d;
    END IF;
    UPDATE work_order SET planned_start=coalesce(planned_start, p_start), planned_end=prev_end WHERE id=o.work_order_id;
    last_end := greatest(last_end, prev_end);
  END LOOP;
  RETURN last_end;
END $$;

-- AI 交期预测：基线=排产完工日+发货1天；AI 输出(外部给出)落表
CREATE OR REPLACE FUNCTION fn_ai_leadtime(p_so bigint, p_output jsonb) RETURNS ai_leadtime_prediction LANGUAGE plpgsql AS $$
DECLARE base date; rid bigint; r ai_leadtime_prediction;
BEGIN
  SELECT max(w.planned_end)+1 INTO base FROM work_order w JOIN production_plan pp ON pp.id=w.production_plan_id WHERE pp.sales_order_id=p_so;
  INSERT INTO ai_request(kind, input, output, model) VALUES ('leadtime_predict', jsonb_build_object('sales_order_id',p_so,'baseline_finish',base), p_output, 'mock') RETURNING id INTO rid;
  UPDATE ai_request SET status='succeeded' WHERE id=rid;
  INSERT INTO ai_leadtime_prediction(ai_request_id, sales_order_id, baseline_finish, predicted_finish, p90_finish, risk_note)
  VALUES (rid, p_so, base, base + (p_output->>'delay_days')::int, base + (p_output->>'p90_delay_days')::int, p_output->>'risk_note') RETURNING * INTO r;
  RETURN r;
END $$;

-- AI 委外对账单核对：外协厂对账单(AI 从照片识别出的 JSON) vs 系统结算
CREATE OR REPLACE FUNCTION fn_ai_check_subcon_statement(p_supplier bigint, p_statement jsonb) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE rid bigint; l jsonb; sc subcontract_order; s subcontract_settlement; f text; sv numeric; yv numeric;
BEGIN
  INSERT INTO ai_request(kind, input, output, model) VALUES ('subcon_statement_check', jsonb_build_object('supplier_id',p_supplier), p_statement, 'mock') RETURNING id INTO rid;
  UPDATE ai_request SET status='succeeded' WHERE id=rid;
  FOR l IN SELECT * FROM jsonb_array_elements(p_statement->'lines') LOOP
    SELECT * INTO sc FROM subcontract_order WHERE doc_no=l->>'order_no' AND supplier_id=p_supplier;
    IF sc.id IS NULL THEN
      INSERT INTO ai_subcon_check_line(ai_request_id, field, statement_value, verdict) VALUES (rid, 'order_no:'||(l->>'order_no'), (l->>'amount')::numeric, 'missing_in_system');
      CONTINUE;
    END IF;
    SELECT * INTO s FROM subcontract_settlement WHERE subcontract_order_id=sc.id;
    FOREACH f IN ARRAY ARRAY['sent_qty','good_qty','defect_qty','amount'] LOOP
      sv := (l->>f)::numeric;
      yv := CASE f WHEN 'sent_qty' THEN sc.sent_qty WHEN 'good_qty' THEN sc.received_good_qty WHEN 'defect_qty' THEN sc.received_defect_qty
                   ELSE s.payable_amount END;
      INSERT INTO ai_subcon_check_line(ai_request_id, subcontract_order_id, field, statement_value, system_value, diff, verdict)
      VALUES (rid, sc.id, f, sv, yv, sv - yv, CASE WHEN sv = yv THEN 'match' ELSE 'mismatch' END);
    END LOOP;
  END LOOP;
  RETURN rid;
END $$;

-- 完工复盘：比较报价工时与实际工时，按权重给出新定额（需人工确认后生效）
CREATE OR REPLACE FUNCTION fn_cost_review(p_wo bigint) RETURNS int LANGUAGE plpgsql AS $$
DECLARE rid bigint; n int; a numeric := p('ex_std_hours_learning_rate');
BEGIN
  INSERT INTO ai_request(kind, input, model) VALUES ('cost_review', jsonb_build_object('work_order_id',p_wo), 'rule:ewma') RETURNING id INTO rid;
  INSERT INTO ai_cost_review(ai_request_id, work_order_id, routing_op_id, quoted_hours, actual_hours_per_unit, proposed_hours)
  SELECT rid, p_wo, o.routing_op_id, ro.std_hours,
         round(sum(j.hours)/nullif(sum(j.good_qty),0),4),
         round(a*sum(j.hours)/nullif(sum(j.good_qty),0) + (1-a)*ro.std_hours, 4)
  FROM wo_operation o JOIN routing_operation ro ON ro.id=o.routing_op_id JOIN job_card j ON j.wo_operation_id=o.id AND NOT j.is_rework
  WHERE o.work_order_id=p_wo AND NOT o.is_subcontracted AND ro.std_hours > 0
  GROUP BY o.routing_op_id, ro.std_hours HAVING sum(j.good_qty) > 0;
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE ai_request SET status='succeeded', output=(SELECT jsonb_agg(to_jsonb(c)) FROM ai_cost_review c WHERE c.ai_request_id=rid) WHERE id=rid;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION fn_apply_cost_review(p_review bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE c ai_cost_review;
BEGIN
  SELECT * INTO c FROM ai_cost_review WHERE id=p_review FOR UPDATE;
  IF c.applied THEN RAISE EXCEPTION '已应用'; END IF;
  UPDATE routing_operation SET std_hours=c.proposed_hours WHERE id=c.routing_op_id;
  UPDATE ai_cost_review SET applied=true, applied_by=app_user(), applied_at=now() WHERE id=p_review;
END $$;
