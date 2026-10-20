-- 成本口径：不含税换算、含税/不含税两列、两层复盘、实际=标准时逐行差异为 0、工时修正只用工时行
BEGIN;
SELECT plan(11);
SELECT use_tenant('DEMO');
UPDATE accounting_period SET status='open';

SELECT ok((SELECT tax_included FROM ref_param WHERE param_key='mat_45_kg') AND NOT (SELECT tax_included FROM ref_param WHERE param_key='rate_cnc_lathe'),
          '钢材行情价标记含税，厂内机时费率不含税');
SELECT is(p_net('mat_45_kg'), round(p('mat_45_kg')/(1+p('vat_rate_general')),6), '含税行情价 ÷(1+13%)');
SELECT is(p_net('rate_cnc_lathe'), p('rate_cnc_lathe'), '不含税参数原值');

-- 新报价（10 件）
INSERT INTO quotation(customer_id, min_margin) VALUES (pty('CUST01'), p('min_margin'));
INSERT INTO quotation_item(quotation_id, item_id, qty) VALUES ((SELECT max(id) FROM quotation), it('SHAFT-ASSY'), 10);
SELECT fn_quote_cost((SELECT max(id) FROM quotation_item));
SELECT is((SELECT count(*) FROM quotation_cost_line WHERE quotation_item_id=(SELECT max(id) FROM quotation_item)
            AND tax_included AND abs(amount_gross - amount*(1+p('vat_rate_general'))) > 0.001), 0::bigint, '含税行：含税金额=不含税×1.13');
SELECT is((SELECT count(*) FROM quotation_cost_line WHERE quotation_item_id=(SELECT max(id) FROM quotation_item)
            AND NOT tax_included AND amount_gross <> amount), 0::bigint, '不含税行：两列相等');

-- 构造一张"实际=标准"的工单：按报价行逐行写入相同的不含税实际成本
CREATE TEMP TABLE t_wo AS SELECT fn_create_wo(it('SHAFT-ASSY'), 10, plant_of('P1'), NULL, NULL, NULL,
   (SELECT fg_warehouse_id FROM work_order WHERE parent_work_order_id IS NULL ORDER BY id LIMIT 1)) AS id;
INSERT INTO wo_cost_entry(work_order_id, cost_type, amount, qty, hours, item_id, routing_op_id, source_type, source_id)
SELECT (SELECT id FROM t_wo),
       CASE l.cost_type WHEN 'machining' THEN 'machine' WHEN 'heat_treat' THEN 'subcontract' WHEN 'surface' THEN 'subcontract' ELSE l.cost_type END,
       round(sum(l.amount)*10,2), CASE WHEN l.cost_type<>'machining' THEN sum(l.basis_qty)*10 END,
       CASE WHEN l.cost_type='machining' THEN sum(l.basis_qty)*10 END,
       CASE WHEN l.cost_type IN ('material','purchased') THEN l.ref_item_id END,
       CASE WHEN l.cost_type IN ('machining','heat_treat','surface') THEN l.routing_op_id END, 'test', 0
FROM quotation_cost_line l WHERE l.quotation_item_id=(SELECT max(id) FROM quotation_item)
GROUP BY l.cost_type, l.ref_item_id, l.routing_op_id;
INSERT INTO wo_cost_entry(work_order_id, cost_type, amount, qty, routing_op_id, source_type, source_id)
SELECT (SELECT id FROM t_wo), 'labor', 0, 10, l.routing_op_id, 'test', 0
FROM quotation_cost_line l WHERE l.quotation_item_id=(SELECT max(id) FROM quotation_item) AND l.cost_type='machining';

SELECT is((SELECT count(*) FROM fn_cost_review_lines((SELECT max(id) FROM quotation_item), (SELECT id FROM t_wo), 10) WHERE variance <> 0),
          0::bigint, '实际=标准时每一行差异都为 0');
SELECT is((SELECT count(*) FROM fn_cost_review_lines((SELECT max(id) FROM quotation_item), (SELECT id FROM t_wo), 10) WHERE layer IN ('direct','overhead')),
          (SELECT count(DISTINCT (cost_type, coalesce(ref_item_id,0), coalesce(routing_op_id,0))) FROM quotation_cost_line WHERE quotation_item_id=(SELECT max(id) FROM quotation_item)),
          '每条报价行都有对应复盘行');
SELECT is((SELECT sum(std_amount) FROM fn_cost_review_lines((SELECT max(id) FROM quotation_item), (SELECT id FROM t_wo), 10) WHERE layer='direct'),
          (SELECT round(sum(amount)*10,2) FROM quotation_cost_line WHERE quotation_item_id=(SELECT max(id) FROM quotation_item) AND cost_type<>'overhead'),
          '直接成本层标准不乘管理费系数');
SELECT is((SELECT std_amount FROM fn_cost_review_lines((SELECT max(id) FROM quotation_item), (SELECT id FROM t_wo), 10) WHERE layer='overhead'),
          (SELECT round(amount*10,2) FROM quotation_cost_line WHERE quotation_item_id=(SELECT max(id) FROM quotation_item) AND cost_type='overhead'),
          '管理费单独一层');
SELECT throws_ok($$INSERT INTO ai_cost_review(work_order_id, routing_op_id, line_type, quoted_hours, actual_hours_per_unit, proposed_hours)
                   VALUES ((SELECT id FROM t_wo), (SELECT min(id) FROM routing_operation), 'material', 1, 1, 1)$$, '23514', NULL, '工时定额修正只能来自工时行');
SELECT hasnt_view('v_order_cost_compare', '旧的乘管理费系数比较视图已删除');
SELECT * FROM finish();
ROLLBACK;
