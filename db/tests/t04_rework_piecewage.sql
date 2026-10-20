-- 剧本 4：工序检返工 + 计件工资
BEGIN;
SELECT plan(6);
SELECT use_tenant('DEMO');
SELECT is((SELECT sum(piece_wage) FROM job_card j JOIN employee e ON e.id=j.employee_id WHERE e.emp_code='E002'), 100*p('ex_piece_rate_finish'), 'E002 精车计件=100×单价');
SELECT is((SELECT sum(piece_wage) FROM job_card j JOIN employee e ON e.id=j.employee_id WHERE e.emp_code='E004'), 0::numeric, '返工不计件');
SELECT is((SELECT rework_qty FROM quality_inspection WHERE inspection_type='process'), 4::numeric, '工序检判定返工 4 件');
SELECT ok((SELECT count(*) FROM job_card WHERE is_rework AND rework_of_inspection_id IS NOT NULL) = 1, '返工报工关联检验单');
SELECT is((SELECT rework_pending_qty FROM wo_operation WHERE seq=40 AND work_order_id=(SELECT id FROM work_order WHERE parent_work_order_id IS NOT NULL)), 0::numeric, '返工已清零');
SELECT ok((SELECT sum(amount) FROM wo_cost_entry WHERE cost_type='labor') =
          (SELECT sum(piece_wage) FROM job_card), '计件工资全部计入工单人工成本');
SELECT * FROM finish();
ROLLBACK;
