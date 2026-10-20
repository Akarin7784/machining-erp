-- #7 序列号 / #6 替代料 / #15 物料需求单
BEGIN;
SELECT plan(16);
SELECT use_tenant('DEMO');
UPDATE accounting_period SET status='open';
-- 序列号：二厂成品仓 2 台组件登记序列号，发货 1 台按台绑定
UPDATE item SET has_serial_no=true WHERE item_code='SHAFT-ASSY';
SELECT is(fn_serial_receive(it('SHAFT-ASSY'), ARRAY['SA-2610-0001','SA-2610-0002'], wh('FG2'), 'manual', 0,
          (SELECT id FROM work_order WHERE item_id=it('SHAFT-ASSY'))), 2, '登记 2 个序列号');
SELECT throws_like($$SELECT fn_serial_receive(it('SHAFT-ASSY'), ARRAY['SA-2610-0001'], wh('FG2'), 'manual', 0)$$, '%duplicate key%', '序列号不能重复');
SELECT fn_deliver((SELECT id FROM sales_order LIMIT 1), jsonb_build_array(jsonb_build_object('so_item',(SELECT id FROM sales_order_item LIMIT 1),'qty',1,'wh',wh('FG2'))));
SELECT throws_like($$SELECT fn_serial_bind_delivery((SELECT max(id) FROM delivery_note_item), ARRAY['SA-2610-0001','SA-2610-0002'])$$, '%超过发货数量%', '绑定数不能超过发货数');
SELECT is(fn_serial_bind_delivery((SELECT max(id) FROM delivery_note_item), ARRAY['SA-2610-0001']), 1, '按台绑定发货');
SELECT is((SELECT status FROM serial_no WHERE serial_no='SA-2610-0001'), 'delivered', '序列号状态=已发货');
SELECT is((SELECT customer FROM v_serial_trace WHERE serial_no='SA-2610-0001' AND direction='out'), '示例自动化设备有限公司', '按台追溯到客户');
SELECT ok((SELECT work_order_no FROM v_serial_trace WHERE serial_no='SA-2610-0001' LIMIT 1) IS NOT NULL, '按台追溯到生产工单');
SELECT throws_like($$UPDATE serial_ledger SET direction='in'$$, '%只增不改%', '序列号履历不可改');

-- 替代料：Φ42 圆钢可替代 Φ40（换算率=重量比，示例）
INSERT INTO item(item_code, item_name, item_kind, stock_uom, material_param_key) VALUES ('RAW-45-D42','45号钢圆钢 Φ42','raw','kg','mat_45_kg');
INSERT INTO item_alternative(item_id, alt_item_id, conversion_ratio) VALUES (it('RAW-45-D40'), it('RAW-45-D42'), round((42.0/40)^2,6));
SELECT fn_stock_move(wh('RAW1'), it('RAW-45-D42'), 10, round(p('mat_45_kg')/1.13,6), 'manual', 0);
SELECT is(round(fn_on_hand_alt(it('RAW-45-D40'), plant_of('P1'), true),4), round(10/round((42.0/40)^2,6),4)::numeric, 'MRP 可用量把替代料按换算率折算');
SELECT throws_like(format($$SELECT fn_issue_with_alternative(%s, it('RAW-45-D40'), 1.9729, wh('RAW1'))$$,
   (SELECT id FROM work_order WHERE sales_order_item_id IS NULL AND parent_work_order_id IS NULL AND item_id=it('SHAFT-SEMI'))), '%不允许替代%', 'BOM 未允许替代时不能用替代料');
UPDATE bom_item SET allow_alternative=true WHERE component_id=it('RAW-45-D40');
SELECT is(jsonb_array_length(fn_issue_with_alternative((SELECT id FROM work_order WHERE sales_order_item_id IS NULL AND parent_work_order_id IS NULL AND item_id=it('SHAFT-SEMI')),
   it('RAW-45-D40'), 1.9729, wh('RAW1'))), 1, '主料为 0 时全部用替代料领用');

-- 物料需求单：车间补料(关联工单)，分两次发料
SELECT fn_mr_create('replenish', it('RAW-45-D42'), 4, wh('RAW1'),
   (SELECT id FROM work_order WHERE sales_order_item_id IS NULL AND parent_work_order_id IS NULL AND item_id=it('SHAFT-SEMI')), NULL, '试切报废补料');
SELECT fn_mr_issue((SELECT max(id) FROM material_request), 2);
SELECT is((SELECT per_received FROM material_request ORDER BY id DESC LIMIT 1), 50.00::numeric, '补料单完成 50%');
SELECT is((SELECT status FROM material_request ORDER BY id DESC LIMIT 1), 'partially_fulfilled', '补料单部分满足');
SELECT throws_like($$SELECT fn_mr_issue((SELECT max(id) FROM material_request), 3)$$, '%超过需求数量%', '发料不能超过需求数');
SELECT fn_mr_issue((SELECT max(id) FROM material_request), 2);
SELECT is((SELECT status FROM material_request ORDER BY id DESC LIMIT 1), 'fulfilled', '补料单全部满足');
-- 采购类需求单 → 采购单 → 入库回写
SELECT fn_mr_create('purchase', it('BRG-6205'), 50, wh('RAW1'));
SELECT fn_mr_to_po((SELECT max(id) FROM material_request), pty('SUP-BRG'), p('ex_bearing_6205_price'));
SELECT fn_po_receive((SELECT max(id) FROM purchase_order), wh('RAW1'),
   jsonb_build_array(jsonb_build_object('po_item',(SELECT max(id) FROM purchase_order_item),'qty',50)));
SELECT fn_incoming_inspection((SELECT max(id) FROM purchase_receipt_item), 50, 0);
SELECT fn_receipt_post((SELECT max(id) FROM purchase_receipt));
SELECT ok((SELECT per_ordered=100 AND per_received=100 AND status='fulfilled' FROM material_request ORDER BY id DESC LIMIT 1), '采购需求单已订 100%、已收 100%');
SELECT * FROM finish();
ROLLBACK;
