-- 剧本 2：客户中途改图换版本
BEGIN;
SELECT plan(6);
SELECT use_tenant('DEMO');
UPDATE accounting_period SET status='open';
SELECT is((SELECT count(*) FROM drawing_revision WHERE item_id=it('SHAFT-SEMI')), 2::bigint, '精密轴有 A、B 两个版本');
SELECT is((SELECT revision FROM drawing_revision d JOIN item i ON i.current_drawing_id=d.id WHERE i.item_code='SHAFT-SEMI'), 'B', '当前生效 B 版');
SELECT is((SELECT count(*) FROM engineering_change), 1::bigint, '有 1 条 ECN');
SELECT throws_like($$UPDATE drawing_revision SET status='released' WHERE revision='A' AND item_id=it('SHAFT-SEMI')$$, '%不允许的状态迁移%', '作废版本不能重新生效');
-- 再改一次图（C 版）：样件工单跟随切换，B 版报工被拒
INSERT INTO drawing_revision(item_id, revision, change_note) VALUES (it('SHAFT-SEMI'), 'C', '再次改图');
SELECT fn_change_drawing(it('SHAFT-SEMI'), (SELECT id FROM drawing_revision WHERE revision='C'), '测试', '样件按 C 版');
SELECT throws_like(format($$SELECT fn_report(%s,10,'E001',1,0,0.01,false,NULL,%s)$$,
   (SELECT id FROM work_order WHERE sales_order_item_id IS NULL AND parent_work_order_id IS NULL AND item_id=it('SHAFT-SEMI')),
   (SELECT id FROM drawing_revision WHERE revision='B' AND item_id=it('SHAFT-SEMI'))), '%图纸版本已失效%', 'B 版报工被拒');
SELECT lives_ok(format($$SELECT fn_report(%s,10,'E001',1,0,0.01)$$,
   (SELECT id FROM work_order WHERE sales_order_item_id IS NULL AND parent_work_order_id IS NULL AND item_id=it('SHAFT-SEMI'))), 'C 版报工成功');
SELECT * FROM finish();
ROLLBACK;
