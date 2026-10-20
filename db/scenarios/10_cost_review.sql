-- 剧本 10：订单实际成本 vs 报价复盘 → 修正工时定额 → 重新报价更准
SELECT use_tenant('DEMO');
DO $$
DECLARE c record; semi bigint; n int; aid bigint; d record; o record; hl record; rough_review ai_cost_review; q bigint; qi bigint; old_cost numeric; new_cost numeric;
BEGIN
  SELECT * INTO c FROM v_order_cost_actual WHERE sales_order_item_id IS NOT NULL;
  PERFORM assert_eq('订单实际总成本=各工单成本(不含半成品结转)', c.total_actual,
     (SELECT sum(amount) FROM wo_cost_entry e JOIN work_order w ON w.id=e.work_order_id WHERE (w.id=c.root_work_order_id OR w.parent_work_order_id=c.root_work_order_id) AND e.cost_type<>'semi_transfer'), 0.01);
  PERFORM assert_eq('实际单件成本=总成本/入库数', c.unit_actual, round(c.total_actual/95,4), 0.0001);
  PERFORM assert_true('有返工成本和外协成本', c.rework_actual > 0 AND c.subcontract_actual > 0);
  RAISE NOTICE '复盘: 报价单件成本 %, 实际单件成本 %, 售价 %, 实际毛利率 %', c.unit_quoted_cost, c.unit_actual, c.unit_price, c.actual_margin;

  -- 月末制造费用分摊（示例：当月实际制造费用池）
  aid := fn_allocate_overhead(date_trunc('month',current_date)::date, (date_trunc('month',current_date)+interval '1 month - 1 day')::date, p('ex_month_overhead_pool'));
  PERFORM assert_eq('分摊合计=费用池', (SELECT sum(amount) FROM wo_cost_entry WHERE source_type='overhead_allocation' AND source_id=aid), p('ex_month_overhead_pool'));
  PERFORM assert_eq('分摊凭证借贷平衡且贷 5101', (SELECT sum(credit) FROM gl_entry g JOIN journal_entry j ON j.id=g.journal_entry_id
        JOIN gl_account ga ON ga.id=g.account_id WHERE j.voucher_type='overhead_allocation' AND j.voucher_id=aid AND ga.account_code='5101'), p('ex_month_overhead_pool'));

  -- 第一层：直接成本逐行（不含税，不乘管理费系数）
  SELECT sum(std_amount) s, sum(actual_amount) a, sum(variance) v INTO d FROM v_order_cost_review WHERE sales_order_item_id=c.sales_order_item_id AND layer='direct';
  PERFORM assert_eq('直接成本层：标准=报价直接成本(不含税)×入库数', d.s,
     (SELECT round(sum(l.amount)*95,2) FROM quotation_cost_line l JOIN sales_order_item soi ON soi.quotation_item_id=l.quotation_item_id
       WHERE soi.id=c.sales_order_item_id AND l.cost_type NOT IN ('overhead','machining'))
     + (SELECT sum(std_amount) FROM v_order_cost_review WHERE sales_order_item_id=c.sales_order_item_id AND line_type='hours'), 0.01);
  PERFORM assert_eq('直接成本层：实际=工单不含税流水(去计件、管理费、半成品结转)', d.a,
     (SELECT sum(amount) FROM wo_cost_entry e JOIN work_order w ON w.id=e.work_order_id WHERE (w.id=c.root_work_order_id OR w.parent_work_order_id=c.root_work_order_id)
        AND e.cost_type NOT IN ('semi_transfer','labor','overhead')), 0.01);
  PERFORM assert_true('直接成本层不含管理费系数：没有任何直接行带系数', NOT EXISTS (SELECT 1 FROM v_order_cost_review WHERE layer='direct' AND line_type='overhead'));
  RAISE NOTICE '直接成本层: 标准 %, 实际 %, 差异 %', d.s, d.a, d.v;
  FOR hl IN SELECT * FROM v_order_cost_review WHERE sales_order_item_id=c.sales_order_item_id ORDER BY layer, line_type, line_name LOOP
    RAISE NOTICE '  [%] % % 标准 % 实际 % 差异 % (工时 %→%)', hl.layer, hl.line_type, hl.line_name, hl.std_amount, hl.actual_amount, hl.variance, hl.std_hours, hl.actual_hours;
  END LOOP;
  -- 第二层：管理费 vs 月末分摊
  SELECT * INTO o FROM v_order_cost_review WHERE sales_order_item_id=c.sales_order_item_id AND layer='overhead';
  PERFORM assert_eq('管理费层：标准=报价管理费行×入库数', o.std_amount,
     (SELECT round(l.amount*95,2) FROM quotation_cost_line l JOIN sales_order_item soi ON soi.quotation_item_id=l.quotation_item_id WHERE soi.id=c.sales_order_item_id AND l.cost_type='overhead'));
  PERFORM assert_eq('管理费层：实际=本订单工单分到的月末分摊', o.actual_amount,
     (SELECT sum(amount) FROM wo_cost_entry e JOIN work_order w ON w.id=e.work_order_id WHERE (w.id=c.root_work_order_id OR w.parent_work_order_id=c.root_work_order_id) AND e.cost_type='overhead'));
  RAISE NOTICE '管理费层: 标准 %, 月末分摊 %, 差异 %', o.std_amount, o.actual_amount, o.variance;

  SELECT id INTO semi FROM work_order WHERE item_id=it('SHAFT-SEMI') AND parent_work_order_id IS NOT NULL;
  n := fn_cost_review(c.sales_order_item_id);
  PERFORM assert_eq('复盘只从工时行生成修正建议：粗车/精车/装配', n, (SELECT count(*) FROM v_order_cost_review WHERE sales_order_item_id=c.sales_order_item_id AND line_type='hours' AND std_hours>0 AND actual_hours>0));
  PERFORM assert_true('修正建议全部来自工时行', NOT EXISTS (SELECT 1 FROM ai_cost_review WHERE line_type<>'hours'));
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
     old_cost + (SELECT sum((r.proposed_hours-r.quoted_hours)*p(w.rate_param_key)) FROM ai_cost_review r JOIN routing_operation ro ON ro.id=r.routing_op_id JOIN workstation w ON w.id=ro.workstation_id)*p('quote_overhead_factor'), 0.01);
END $$;
