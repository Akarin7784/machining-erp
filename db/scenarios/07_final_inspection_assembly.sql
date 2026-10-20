-- 剧本 07：精密轴成品检入半成品仓 → 组件装配（父工单领用子工单产出 + 轴承）→ 成品检 → 入成品仓；余料再利用
SELECT use_tenant('DEMO');
DO $$
DECLARE semi work_order; assy work_order; v_semi numeric; v_assy numeric; sample bigint;
BEGIN
  SELECT * INTO semi FROM work_order WHERE item_id=it('SHAFT-SEMI') AND parent_work_order_id IS NOT NULL;
  SELECT * INTO assy FROM work_order WHERE id=semi.parent_work_order_id;
  PERFORM assert_raises('未成品检不能入库', format('SELECT fn_wo_receive(%s, 1)', semi.id), '超过成品检合格数');
  PERFORM fn_final_inspection(semi.id, 95, 95, 0);
  v_semi := fn_wo_receive(semi.id, 95);
  PERFORM assert_eq('半成品入库金额=子工单全部成本', v_semi, (SELECT sum(amount) FROM wo_cost_entry WHERE work_order_id=semi.id), 0.01);
  PERFORM assert_true('子工单自动完工(入库95+报废5=100)', (SELECT status FROM work_order WHERE id=semi.id)='completed');
  PERFORM assert_eq('生产成本科目中子工单余额结平(分位舍入容差)', (SELECT coalesce(sum(debit-credit),0) FROM gl_entry WHERE account_id=fn_acct('5001') AND work_order_id=semi.id), 0, 0.05);

  PERFORM fn_issue_material(assy.id, it('SHAFT-SEMI'), 95, wh('WIP1'));
  PERFORM fn_issue_material(assy.id, it('BRG-6205'), 190, wh('RAW1'));
  PERFORM assert_true('父工单领用半成品记为结转(不重复计入订单成本)', EXISTS (SELECT 1 FROM wo_cost_entry WHERE work_order_id=assy.id AND cost_type='semi_transfer'));
  PERFORM fn_report(assy.id, 10, 'E003', 95, 0, 9.8);
  PERFORM fn_final_inspection(assy.id, 95, 95, 0);
  v_assy := fn_wo_receive(assy.id, 95);
  PERFORM fn_wo_finish(assy.id);
  PERFORM assert_eq('成品入库金额=半成品+轴承+装配工资+机时', v_assy, (SELECT sum(amount) FROM wo_cost_entry WHERE work_order_id=assy.id), 0.01);
  PERFORM assert_eq('成品仓数量', stock_qty('SHAFT-ASSY','FG1'), 95);
  PERFORM assert_eq('半成品仓清空', stock_qty('SHAFT-SEMI','WIP1'), 0);
  PERFORM assert_true('组件工单短缺完结', (SELECT status FROM work_order WHERE id=assy.id)='completed');

  -- 余料再利用：样件工单领用余料仓的短料
  sample := fn_create_wo(it('SHAFT-SEMI'), 1, plant_of('P1'), NULL, NULL, NULL, wh('WIP1'));
  PERFORM fn_release_wo(sample);
  PERFORM fn_reuse_remnant((SELECT id FROM remnant WHERE status='available' LIMIT 1), sample);
  PERFORM assert_eq('余料仓已用完', stock_qty('RAW-45-D40','REM1'), 0);
  PERFORM assert_true('余料状态=reused', NOT EXISTS (SELECT 1 FROM remnant WHERE status='available'));
  PERFORM assert_raises('余料不能重复领用', format('SELECT fn_reuse_remnant(%s,%s)', (SELECT id FROM remnant LIMIT 1), sample), '已不可用');
END $$;
