-- #3 amended_from / #10 batch_size / #11 production_capacity / #12 WIP·废品仓 / #13 多段计时 / #14 安全库存·MOQ
-- #18 质检读数+审核 / #20 分期收款 / #29 AI 字段置信度+人工确认审计 / 成本口径
BEGIN;
SELECT plan(20);
SELECT use_tenant('DEMO');
UPDATE accounting_period SET status='open';

-- #3
INSERT INTO quotation(customer_id, min_margin) VALUES (pty('CUST01'), 0.25);
INSERT INTO quotation_item(quotation_id, item_id, qty) VALUES ((SELECT max(id) FROM quotation), it('SHAFT-ASSY'), 10);
SELECT fn_quote_cost((SELECT max(id) FROM quotation_item));
SELECT throws_like($$SELECT fn_amend_quotation((SELECT max(id) FROM quotation))$$, '%只有已取消%', '草稿报价不能修订');
UPDATE quotation SET status='cancelled' WHERE id=(SELECT max(id) FROM quotation);
SELECT fn_amend_quotation((SELECT max(id) FROM quotation));
SELECT ok((SELECT amended_from IS NOT NULL AND doc_no LIKE '%-1' FROM quotation ORDER BY id DESC LIMIT 1), '修订单 amended_from 指向原单，编号加 -1');
SELECT has_column('sales_order','amended_from','销售订单有 amended_from');

-- #10 #11
SELECT is(fn_op_hours(0.25, 1, 50, 100), 27::numeric, '准备工时按批分摊：0.25×100 + 1×ceil(100/50)');
UPDATE routing_operation SET setup_hours=1, batch_size=50 WHERE op_name='粗车';
SELECT fn_quote_cost((SELECT max(id) FROM quotation_item));
SELECT is((SELECT basis_qty FROM quotation_cost_line c JOIN routing_operation ro ON ro.id=c.routing_op_id WHERE c.quotation_item_id=(SELECT max(id) FROM quotation_item) AND ro.op_name='粗车'),
          round((SELECT std_hours FROM routing_operation WHERE op_name='粗车') + 1*ceil(10/50.0)/10, 4), '报价单件工时含按批分摊的准备工时');
UPDATE workstation SET production_capacity=2 WHERE ws_code='CNC1';
SELECT fn_schedule_finite(plant_of('P1'), current_date);
SELECT ok(NOT EXISTS (SELECT 1 FROM schedule_slot s JOIN workstation w ON w.id=s.workstation_id GROUP BY s.workstation_id, s.work_date, w.hours_per_day, w.production_capacity
                      HAVING sum(s.hours) > w.hours_per_day*w.production_capacity), '排产不超过 每日工时×并行工位数');

-- #12
SELECT ok((SELECT bool_and(wip_warehouse_id IS NOT NULL AND scrap_warehouse_id IS NOT NULL) FROM work_order WHERE id=(SELECT max(id) FROM work_order)), '新工单自动带 WIP 仓和废品仓');
SELECT throws_like($$UPDATE work_order SET scrap_warehouse_id=wh('FG1') WHERE id=(SELECT max(id) FROM work_order)$$, '%reject%', '废品仓必须是不良品类型');

-- #13 多段计时：8:00-10:00 工作，10:00-10:30 暂停，10:30-11:00 工作 → 2.5h
SELECT fn_report_with_logs((SELECT id FROM work_order WHERE sales_order_item_id IS NULL AND parent_work_order_id IS NULL AND item_id=it('SHAFT-SEMI')), 10, 'E001', 1, 0,
  '[{"kind":"work","from":"2026-10-21 08:00+08","to":"2026-10-21 10:00+08"},{"kind":"pause","from":"2026-10-21 10:00+08","to":"2026-10-21 10:30+08","reason":"换刀"},{"kind":"work","from":"2026-10-21 10:30+08","to":"2026-10-21 11:00+08"}]');
SELECT is((SELECT hours FROM job_card ORDER BY id DESC LIMIT 1), 2.5::numeric, '报工工时=工作段合计(不含暂停)');
SELECT is((SELECT count(*) FROM job_card_time_log WHERE job_card_id=(SELECT max(id) FROM job_card)), 3::bigint, '保存 3 段计时');

-- #14
UPDATE item SET safety_stock=20, min_order_qty=500 WHERE item_code='BRG-6205';
INSERT INTO sales_order(customer_id, plant_id) VALUES (pty('CUST01'), plant_of('P1'));
INSERT INTO sales_order_item(sales_order_id, item_id, qty, unit_price) VALUES ((SELECT max(id) FROM sales_order), it('SHAFT-ASSY'), 10, 100);
UPDATE sales_order SET status='confirmed' WHERE id=(SELECT max(id) FROM sales_order);
SELECT fn_run_mrp((SELECT max(id) FROM sales_order), wh('FG1'), wh('WIP1'));
SELECT is((SELECT net_qty FROM mrp_line WHERE item_id=it('BRG-6205') ORDER BY id DESC LIMIT 1), 20 + 20 - stock_qty('BRG-6205','RAW1'), 'MRP 净需求 = 毛需求 + 安全库存 - 现存');
SELECT is((SELECT order_qty FROM mrp_line WHERE item_id=it('BRG-6205') ORDER BY id DESC LIMIT 1), 500::numeric, '建议订购量按最小订购量取整');

-- #18
SELECT fn_qi_add_readings((SELECT min(id) FROM quality_inspection WHERE inspection_type='final'),
  '[{"parameter":"外径Φ38h6","min":37.984,"max":38.000,"value":37.992,"sample":1},{"parameter":"外径Φ38h6","min":37.984,"max":38.000,"value":38.004,"sample":2}]');
SELECT is((SELECT count(*) FILTER (WHERE NOT is_ok) FROM quality_inspection_reading), 1::bigint, '超差读数自动判不合格');
SELECT set_config('app.user', current_user, true);
SELECT throws_like($$SELECT fn_qi_review((SELECT min(id) FROM quality_inspection WHERE inspection_type='final'))$$, '%不能是检验员本人%', '检验员不能自审');
SELECT set_config('app.user', 'qc_lead_chen', true);
SELECT lives_ok($$SELECT fn_qi_review((SELECT min(id) FROM quality_inspection WHERE inspection_type='final'))$$, '质检主管审核');

-- #20
SELECT throws_like($$SELECT fn_set_payment_schedule((SELECT min(id) FROM sales_order), '[{"name":"预付","due":"2026-10-25","portion":0.3},{"name":"发货","due":"2026-11-20","portion":0.6}]')$$, '%100%%', '分期比例合计必须 100%');
SELECT fn_set_payment_schedule((SELECT min(id) FROM sales_order), '[{"name":"预付","due":"2026-10-25","portion":0.3},{"name":"发货","due":"2026-11-20","portion":0.7}]');
SELECT is((SELECT sum(amount) FROM payment_schedule WHERE sales_order_id=(SELECT min(id) FROM sales_order)),
          (SELECT sum(round(qty*unit_price,2)) FROM sales_order_item WHERE sales_order_id=(SELECT min(id) FROM sales_order)), '分期金额合计=订单总额');

-- #29
SELECT fn_ai_record_field_confidence((SELECT min(id) FROM ai_request WHERE kind='drawing_quote'),
  '{"material_code":{"value":"45#","confidence":0.97},"plated_area_dm2":{"value":"2.04","confidence":0.62}}');
SELECT is((SELECT field FROM ai_field_confidence WHERE needs_review), 'plated_area_dm2', '低置信度字段标记待人工确认');
SELECT is(fn_ai_confirm_field((SELECT id FROM ai_field_confidence WHERE field='plated_area_dm2'), '2.10'), 'corrected', '人工更正');
SELECT ok(EXISTS (SELECT 1 FROM audit_log WHERE table_name='ai_field_confidence' AND action='UPDATE' AND new_data->>'confirmed_by'='qc_lead_chen'), '确认记录进入审计日志');

SELECT * FROM finish();
ROLLBACK;
