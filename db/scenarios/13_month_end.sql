-- 剧本 13：月底客户对账单 → 试算平衡 → 子账与总账核对 → 关账（关账后不能再过账）
SELECT use_tenant('DEMO');
DO $$
DECLARE st customer_statement; per text := to_char(current_date,'YYYY-MM'); inv_gl numeric; inv_sub numeric;
BEGIN
  st := fn_customer_statement(pty('CUST01'), per);
  PERFORM assert_eq('对账单期末=应收余额', st.closing_balance, (SELECT balance FROM v_party_balance WHERE party_id=pty('CUST01') AND ledger_type='receivable'));
  PERFORM assert_eq('对账单本期借方=两张专票', st.debit_total, (SELECT sum(total_amount) FROM invoice WHERE direction='sales' AND NOT is_red));
  PERFORM assert_eq('对账单本期贷方=收款+红字发票', st.credit_total,
     (SELECT sum(paid_amount) FROM payment_entry WHERE payment_type='receive') - (SELECT sum(total_amount) FROM invoice WHERE is_red));
  PERFORM assert_eq('对账单明细行(2票+1红票+2核销)', jsonb_array_length(st.lines), 5);
  PERFORM assert_eq('已发货未开票=0', st.delivered_not_invoiced, 0);
  PERFORM assert_true('试算平衡', (SELECT sum(debit)=sum(credit) FROM gl_entry));
  PERFORM assert_true('每张凭证借贷平衡', NOT EXISTS (SELECT 1 FROM gl_entry GROUP BY journal_entry_id HAVING sum(debit)<>sum(credit)));
  SELECT sum(debit-credit) INTO inv_gl FROM gl_entry WHERE account_id IN (fn_acct('1403'),fn_acct('1405'),fn_acct('1411'));
  SELECT sum(value) INTO inv_sub FROM v_stock_balance WHERE tenant_id=app_tid();
  PERFORM assert_eq('存货总账≈库存流水金额(分位舍入)', inv_gl, inv_sub, 0.10);
  PERFORM fn_close_period(per);
  PERFORM assert_raises('关账后不能过账', format('SELECT fn_post_je(%L, 0, current_date, %L, %L::jsonb)', 'manual', 'x', '[]'), '已结账');
END $$;
