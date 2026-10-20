-- 通用守护：流水只增不改、状态机、凭证平衡、作废冲销、多租户 RLS、列权限
BEGIN;
SELECT plan(17);
SELECT use_tenant('DEMO');
UPDATE accounting_period SET status='open';

SELECT throws_like($$UPDATE stock_ledger SET qty=qty+1 WHERE id=(SELECT min(id) FROM stock_ledger)$$, '%只增不改%', '库存流水禁止 UPDATE');
SELECT throws_like($$DELETE FROM stock_ledger WHERE id=(SELECT min(id) FROM stock_ledger)$$, '%只增不改%', '库存流水禁止 DELETE');
SELECT throws_like($$UPDATE payment_ledger SET amount=0 WHERE id=(SELECT min(id) FROM payment_ledger)$$, '%只增不改%', '应收应付流水禁止 UPDATE');
SELECT throws_like($$DELETE FROM gl_entry WHERE id=(SELECT min(id) FROM gl_entry)$$, '%只增不改%', '总账分录禁止 DELETE');
SELECT throws_like($$UPDATE job_card SET good_qty=0 WHERE id=(SELECT min(id) FROM job_card)$$, '%只增不改%', '报工记录禁止 UPDATE');
SELECT throws_like($$DELETE FROM audit_log$$, '%只增不改%', '审计日志禁止 DELETE');
SELECT throws_like($$UPDATE quotation SET status='draft' WHERE status='ordered'$$, '%不允许的状态迁移%', '报价 ordered→draft 被拒');
SELECT throws_like($$UPDATE sales_order SET status='closed' WHERE status='partially_delivered'$$, '%不允许的状态迁移%', '未全部发货的订单不能直接关闭');
SELECT throws_like($$INSERT INTO sales_order(customer_id, plant_id, status) VALUES (pty('CUST01'), plant_of('P1'), 'delivered')$$, '%新建单据不能是状态%', '新单据必须从初始状态开始');
SET CONSTRAINTS ALL IMMEDIATE;
SELECT throws_like($$SELECT fn_post_je('manual', 0, current_date, 'x', '[{"a":"1002","d":1},{"a":"6001","c":2}]')$$, '%借贷不平%', '借贷不平的凭证被拒');
SET CONSTRAINTS ALL DEFERRED;

-- 发货作废：写冲销记录，原记录保留
SELECT lives_ok($$SELECT fn_cancel_delivery(fn_deliver((SELECT id FROM sales_order LIMIT 1),
   jsonb_build_array(jsonb_build_object('so_item',(SELECT id FROM sales_order_item LIMIT 1),'qty',1,'wh',wh('FG2')))))$$, '发货后作废');
SELECT is((SELECT count(*) FROM stock_ledger WHERE voucher_type='delivery_note' AND is_reversal), 1::bigint, '作废生成 1 条冲销库存流水');
SELECT is(stock_qty('SHAFT-ASSY','FG2'), 2::numeric, '作废后库存恢复');

-- 多租户：切到 OTHER 租户，以业务角色访问看不到 DEMO 的数据
SELECT use_tenant('OTHER');
SET LOCAL ROLE erp_manager;
SELECT is((SELECT count(*) FROM item), 0::bigint, 'RLS：其他租户看不到 DEMO 的物料');
RESET ROLE;
SELECT use_tenant('DEMO');
-- 列权限
SET LOCAL ROLE erp_sales;
SELECT throws_ok($$SELECT unit_cost FROM quotation_item$$, '42501', NULL, '销售看不到报价成本');
SELECT lives_ok($$SELECT unit_price, amount, margin_rate FROM quotation_item$$, '销售可以看售价和毛利率');
RESET ROLE;
SET LOCAL ROLE erp_operator;
SELECT throws_ok($$SELECT machine_cost FROM job_card$$, '42501', NULL, '操作工看不到机时成本');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
