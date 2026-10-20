-- 剧本 03：报价转销售订单 → MRP 展开多层 BOM → 生成父子工单 → 有限能力排产 → AI 交期预测
SELECT use_tenant('DEMO');
DO $$
DECLARE so bigint; plan bigint; w numeric := (SELECT qty_per FROM bom_item WHERE component_id=it('RAW-45-D40')); n numeric := p('ex_order_qty');
  wo_assy work_order; wo_semi work_order; fin date; lt ai_leadtime_prediction;
BEGIN
  so := fn_so_from_quote((SELECT id FROM quotation WHERE status='approved' LIMIT 1), plant_of('P1'), current_date+30);
  PERFORM assert_true('报价已转订单', (SELECT status FROM quotation WHERE id=(SELECT quotation_id FROM sales_order WHERE id=so))='ordered');
  plan := fn_run_mrp(so, wh('FG1'), wh('WIP1'));
  PERFORM assert_eq('MRP: 钢材毛需求=数量×毛重', (SELECT gross_qty FROM mrp_line WHERE production_plan_id=plan AND item_id=it('RAW-45-D40')), n*w, 0.001);
  PERFORM assert_eq('MRP: 轴承毛需求=数量×2', (SELECT net_qty FROM mrp_line WHERE production_plan_id=plan AND item_id=it('BRG-6205')), n*2);
  PERFORM assert_true('MRP: 钢材/轴承=外购，轴/组件=自制',
    (SELECT string_agg(action, ',' ORDER BY action) FROM mrp_line WHERE production_plan_id=plan) = 'buy,buy,make,make');
  SELECT * INTO wo_assy FROM work_order WHERE production_plan_id=plan AND item_id=it('SHAFT-ASSY');
  SELECT * INTO wo_semi FROM work_order WHERE production_plan_id=plan AND item_id=it('SHAFT-SEMI');
  PERFORM assert_true('子工单挂在父工单下', wo_semi.parent_work_order_id = wo_assy.id);
  PERFORM assert_true('工单已下达且首工序投入=计划数', wo_semi.status='released'
     AND (SELECT input_qty FROM wo_operation WHERE work_order_id=wo_semi.id AND seq=10)=n);
  PERFORM assert_true('订单状态=生产中', (SELECT status FROM sales_order WHERE id=so)='in_production');

  fin := fn_schedule_finite(plant_of('P1'), current_date);
  PERFORM assert_true('排产：任何设备任何一天不超产能', NOT EXISTS (
    SELECT 1 FROM schedule_slot s JOIN workstation ws ON ws.id=s.workstation_id GROUP BY s.workstation_id, s.work_date, ws.hours_per_day HAVING sum(s.hours) > ws.hours_per_day));
  PERFORM assert_eq('排产：粗车总工时=数量×标准工时', (SELECT sum(s.hours) FROM schedule_slot s JOIN wo_operation o ON o.id=s.wo_operation_id WHERE o.work_order_id=wo_semi.id AND o.seq=20), n*p('ex_hours_rough_turn'));
  PERFORM assert_true('排产：父工单开工晚于子工单完工', (SELECT min(sched_start) FROM wo_operation WHERE work_order_id=wo_assy.id) >
                                                     (SELECT max(sched_end) FROM wo_operation WHERE work_order_id=wo_semi.id));
  PERFORM assert_true('排产：工序先后不重叠', NOT EXISTS (SELECT 1 FROM wo_operation a JOIN wo_operation b ON a.work_order_id=b.work_order_id AND b.seq>a.seq WHERE b.sched_start < a.sched_end));
  lt := fn_ai_leadtime(so, '{"delay_days":2,"p90_delay_days":5,"risk_note":"电镀厂近 3 单平均延误 2 天（假数据）"}');
  PERFORM assert_true('交期预测：AI 预测=基线+2天', lt.predicted_finish = lt.baseline_finish + 2 AND lt.baseline_finish = fin + 1);
END $$;
