-- 剧本 05：精密轴 下料→粗车→外协调质→(客户改图 A→B)→精车→工序检→返工 ；余料回库；计件工资
SELECT use_tenant('DEMO');
DO $$
DECLARE wo work_order; n numeric := p('ex_order_qty'); issued numeric; rem bigint; rem_w numeric; sc bigint; s subcontract_settlement;
  old_d bigint; new_d bigint; ecn bigint; qi bigint; jc bigint; rate_cnc numeric := p('rate_cnc_lathe');
BEGIN
  SELECT * INTO wo FROM work_order WHERE item_id=it('SHAFT-SEMI') AND parent_work_order_id IS NOT NULL;
  -- 发料：整批钢材领用
  issued := fn_issue_material(wo.id, it('RAW-45-D40'), stock_qty('RAW-45-D40','RAW1'), wh('RAW1'));
  PERFORM assert_eq('领料后原材料仓为 0', stock_qty('RAW-45-D40','RAW1'), 0);
  -- 下料（锯床，计件）
  PERFORM fn_report(wo.id, 10, 'E001', n, 0, 0);
  -- 余料回库：一根 Φ40×300 短料，按重量登记、按领料均价计价，冲减工单材料成本
  rem_w := fn_bar_weight_kg(40, 300, p('density_45_steel'));
  rem := fn_return_remnant(wo.id, it('RAW-45-D40'), wh('REM1'), 300, 40, rem_w);
  PERFORM assert_eq('余料仓重量', stock_qty('RAW-45-D40','REM1'), rem_w);
  PERFORM assert_eq('工单净材料成本=领料-余料', (SELECT sum(amount) FROM wo_cost_entry WHERE work_order_id=wo.id AND cost_type IN ('material','remnant_credit')),
                    issued - round(rem_w*(SELECT unit_value FROM remnant WHERE id=rem),4), 0.01);
  -- 粗车：分两次报工，实际工时略高于定额
  PERFORM fn_report(wo.id, 20, 'E001', 60, 0, 15.5);
  PERFORM fn_report(wo.id, 20, 'E001', 40, 0, 10.5);
  PERFORM assert_raises('超量报工被拒', format('SELECT fn_report(%s,20,%L,1,0,0.2)', wo.id, 'E001'), '超过可报数量');
  PERFORM assert_eq('E001 计件工资=下料+粗车', (SELECT sum(j.piece_wage) FROM job_card j JOIN employee e ON e.id=j.employee_id WHERE e.emp_code='E001'),
                    n*p('ex_piece_rate_cut') + n*p('ex_piece_rate_rough'));
  PERFORM assert_eq('粗车机时成本=实际工时×数控车费率', (SELECT sum(machine_cost) FROM job_card j JOIN wo_operation o ON o.id=j.wo_operation_id WHERE o.work_order_id=wo.id AND o.seq=20), 26*rate_cnc);
  -- 外协调质
  sc := fn_subcon_create(wo.id, 30, pty('SUB-HT'), wh('SUB-HT'));
  PERFORM assert_raises('委外工序不能厂内报工', format('SELECT fn_report(%s,30,%L,1,0,1)', wo.id, 'E001'), '委外工序');
  PERFORM fn_subcon_send(sc, n, 'FH-HT-001');
  PERFORM fn_subcon_receive(sc, n, 0, 'HT-SH-001');
  s := fn_subcon_settle(sc);
  PERFORM assert_eq('调质加工费=件数×成品重×单价', s.processing_fee, n*p('ex_shaft_finished_kg')*p('ht_quench_temper_electric'), 0.01);
  PERFORM assert_eq('调质无扣款', s.deduction, 0);
  PERFORM fn_purchase_invoice('subcontract_settlement', s.id, 'JX-HT-01');

  -- 客户中途改图：B 版把一处倒角从 C1 改为 C0.5（不影响已粗车件）
  old_d := wo.drawing_id;
  INSERT INTO drawing_revision(item_id, revision, file_uri, change_note) VALUES (it('SHAFT-SEMI'),'B','s3://drawings/SHAFT-SEMI-B.pdf','倒角 C1→C0.5') RETURNING id INTO new_d;
  ecn := fn_change_drawing(it('SHAFT-SEMI'), new_d, '客户 2026-10 邮件通知改图', '已粗车 100 件按 B 版精车可用');
  PERFORM assert_true('旧版本已失效', (SELECT status FROM drawing_revision WHERE id=old_d)='superseded');
  PERFORM assert_true('工单与订单行已切换到 B 版', (SELECT drawing_id FROM work_order WHERE id=wo.id)=new_d);
  PERFORM assert_eq('ECN 记录受影响在制品数', (SELECT affected_wip_qty FROM engineering_change WHERE id=ecn), n);
  PERFORM assert_raises('按旧版图纸报工被拒', format('SELECT fn_report(%s,40,%L,1,0,0.2,false,NULL,%s)', wo.id, 'E002', old_d), '图纸版本已失效');
  -- 精车（按 B 版）
  PERFORM fn_report(wo.id, 40, 'E002', n, 0, 22);
  -- 工序检：95 合格、4 返工、1 报废
  qi := fn_process_inspection(wo.id, 40, n, 95, 4, 1, 0, '外圆 Φ38h6 超差');
  PERFORM assert_true('精车工序进入返工状态', (SELECT status FROM wo_operation WHERE work_order_id=wo.id AND seq=40)='rework');
  PERFORM assert_eq('镀铬工序可投入数=95', (SELECT input_qty FROM wo_operation WHERE work_order_id=wo.id AND seq=50), 95);
  jc := fn_report(wo.id, 40, 'E004', 4, 0, 1.2, true, qi);
  PERFORM assert_eq('返工不计件', (SELECT piece_wage FROM job_card WHERE id=jc), 0);
  PERFORM assert_eq('返工成本单列', (SELECT sum(amount) FROM wo_cost_entry WHERE work_order_id=wo.id AND cost_type='rework'), 1.2*rate_cnc);
  PERFORM assert_true('返工完成后精车工序=done', (SELECT status FROM wo_operation WHERE work_order_id=wo.id AND seq=40)='done');
  PERFORM assert_eq('镀铬工序可投入数=99', (SELECT input_qty FROM wo_operation WHERE work_order_id=wo.id AND seq=50), 99);
  PERFORM assert_eq('工单报废数=1', (SELECT scrap_qty FROM work_order WHERE id=wo.id), 1);
END $$;
