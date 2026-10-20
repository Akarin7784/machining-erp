-- 剧本 5：部分发货后月底对账
BEGIN;
SELECT plan(8);
SELECT use_tenant('DEMO');
SELECT is((SELECT status FROM sales_order LIMIT 1), 'partially_delivered', '订单 100 件只发了 95 件');
SELECT is((SELECT count(*) FROM delivery_note WHERE NOT is_return AND status='posted'), 2::bigint, '两次发货');
SELECT is((SELECT count(*) FROM customer_statement), 1::bigint, '已生成月度对账单');
SELECT is((SELECT closing_balance FROM customer_statement), (SELECT balance FROM v_party_balance WHERE party_id=pty('CUST01') AND ledger_type='receivable'), '对账单期末=应收余额');
SELECT is((SELECT status FROM accounting_period LIMIT 1), 'closed', '本期已关账');
SELECT is((SELECT count(*) FROM v_invoice_export WHERE 红蓝字='红字'), 1::bigint, '发票导出含 1 行红字');
SELECT ok((SELECT bool_and(购方税号 IS NOT NULL) FROM v_invoice_export WHERE 发票种类='增值税专用发票'), '专票导出均有购方税号');
SELECT is((SELECT sum(debit) - sum(credit) FROM gl_entry), 0::numeric, '试算平衡');
SELECT * FROM finish();
ROLLBACK;
