-- 剧本 1：读图报价 + 低毛利审批
BEGIN;
SELECT plan(9);
SELECT use_tenant('DEMO');
SELECT is((SELECT count(*) FROM ai_drawing_feature), 1::bigint, '读图结果已落表');
SELECT ok((SELECT confidence FROM ai_drawing_feature LIMIT 1) BETWEEN 0 AND 1, '置信度在 0~1');
SELECT is((SELECT status FROM quotation ORDER BY id LIMIT 1), 'ordered', '首张报价已转订单');
SELECT ok((SELECT margin_rate < min_margin FROM quotation_item qi JOIN quotation q ON q.id=qi.quotation_id ORDER BY qi.id LIMIT 1), '首张报价毛利低于底线');
SELECT is((SELECT approved_by FROM quotation ORDER BY id LIMIT 1), 'manager_liu', '由经理审批');
-- 新报价：非经理不能审批
SELECT lives_ok($$
  WITH q AS (INSERT INTO quotation(customer_id, min_margin) VALUES (pty('CUST01'), p('min_margin')) RETURNING id)
  INSERT INTO quotation_item(quotation_id, item_id, qty, unit_price) SELECT id, it('SHAFT-ASSY'), 10, 0 FROM q$$, '新建一张报价');
SELECT fn_quote_cost((SELECT max(id) FROM quotation_item));
UPDATE quotation_item SET unit_price=1 WHERE id=(SELECT max(id) FROM quotation_item);
SELECT is(fn_quote_submit((SELECT max(id) FROM quotation)), 'pending_approval', '提交后进入待审批');
SET LOCAL ROLE erp_sales;
SELECT throws_like($$SELECT fn_quote_decide((SELECT max(id) FROM quotation), true, '自己批')$$, '%只有经理%', '销售不能审批');
RESET ROLE;
SELECT throws_like($$UPDATE quotation SET status='ordered' WHERE id=(SELECT max(id) FROM quotation)$$, '%不允许的状态迁移%', '待审批不能跳到已下单');
SELECT * FROM finish();
ROLLBACK;
