-- 剧本 10：订单实际成本 vs 报价复盘 → 修正工时定额 → 重新报价更准
SELECT use_tenant('DEMO');
DO $$
DECLARE c record; semi bigint; n int; rough_review ai_cost_review; q bigint; qi bigint; old_cost numeric; new_cost numeric;
BEGIN
  SELECT * INTO c FROM v_order_cost_actual WHERE sales_order_item_id IS NOT NULL;
  PERFORM assert_eq('订单实际总成本=各工单成本(不含半成品结转)', c.total_actual,
     (SELECT sum(amount) FROM wo_cost_entry e JOIN work_order w ON w.id=e.work_order_id WHERE (w.id=c.root_work_order_id OR w.parent_work_order_id=c.root_work_order_id) AND e.cost_type<>'semi_transfer'), 0.01);
  PERFORM assert_eq('实际单件成本=总成本/入库数', c.unit_actual, round(c.total_actual/95,4), 0.0001);
  PERFORM assert_true('有返工成本和外协成本', c.rework_actual > 0 AND c.subcontract_actual > 0);
  RAISE NOTICE '复盘: 报价单件成本 %, 实际单件成本 %, 售价 %, 实际毛利率 %', c.unit_quoted_cost, c.unit_actual, c.unit_price, c.actual_margin;

  SELECT id INTO semi FROM work_order WHERE item_id=it('SHAFT-SEMI') AND parent_work_order_id IS NOT NULL;
  n := fn_cost_review(semi);
  PERFORM assert_eq('复盘生成 2 条工时修正建议(粗车/精车)', n, 2);
  SELECT r.* INTO rough_review FROM ai_cost_review r JOIN routing_operation ro ON ro.id=r.routing_op_id WHERE ro.op_name='粗车';
  PERFORM assert_eq('粗车实际单件工时=26h/100', rough_review.actual_hours_per_unit, 0.26);
  PERFORM assert_eq('粗车建议定额=0.7×实际+0.3×原定额', rough_review.proposed_hours,
                    round(p('ex_std_hours_learning_rate')*0.26 + (1-p('ex_std_hours_learning_rate'))*p('ex_hours_rough_turn'),4));
  SELECT unit_cost INTO old_cost FROM quotation_item LIMIT 1;
  PERFORM fn_apply_cost_review(id) FROM ai_cost_review;
  -- 用新定额重新报价
  INSERT INTO quotation(customer_id, plant_id, min_margin, revision_of) VALUES (pty('CUST01'), plant_of('P1'), p('min_margin'), (SELECT min(id) FROM quotation)) RETURNING id INTO q;
  INSERT INTO quotation_item(quotation_id, item_id, qty) VALUES (q, it('SHAFT-ASSY'), p('ex_order_qty')) RETURNING id INTO qi;
  SELECT unit_cost INTO new_cost FROM fn_quote_cost(qi);
  PERFORM assert_eq('新报价成本=旧成本+工时增量×费率×管理费系数', new_cost,
     old_cost + ((SELECT sum(proposed_hours-quoted_hours) FROM ai_cost_review))*p('rate_cnc_lathe')*p('quote_overhead_factor'), 0.01);
END $$;
