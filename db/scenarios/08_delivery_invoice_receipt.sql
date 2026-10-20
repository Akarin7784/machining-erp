-- 剧本 08：部分发货(60+35) → 销项专票(价税分离) → 收款核销(第一张全额、第二张部分)
SELECT use_tenant('DEMO');
DO $$
DECLARE tmp bigint; so sales_order; soi sales_order_item; dn1 bigint; dn2 bigint; inv1 invoice; inv2 invoice; pe bigint; part numeric := 1000;
BEGIN
  SELECT * INTO so FROM sales_order LIMIT 1;
  SELECT * INTO soi FROM sales_order_item WHERE sales_order_id=so.id;
  dn1 := fn_deliver(so.id, jsonb_build_array(jsonb_build_object('so_item',soi.id,'qty',60,'wh',wh('FG1'))));
  PERFORM assert_true('部分发货→订单状态 partially_delivered', (SELECT status FROM sales_order WHERE id=so.id)='partially_delivered');
  PERFORM assert_raises('超订单数量发货被拒', format('SELECT fn_deliver(%s, %L::jsonb)', so.id,
          jsonb_build_array(jsonb_build_object('so_item',soi.id,'qty',41,'wh',wh('FG1')))::text), '超过订单数量');
  tmp := fn_sales_invoice(dn1, 'vat_special'); SELECT * INTO inv1 FROM invoice WHERE id=tmp;
  PERFORM assert_eq('专票1 价税合计=60×含税单价', inv1.total_amount, round(60*soi.unit_price,2));
  PERFORM assert_eq('专票1 不含税金额=合计/1.13', inv1.amount_ex_tax, round(60*soi.unit_price/1.13,2));
  PERFORM assert_eq('专票1 税额≈不含税×13%', inv1.tax_amount, inv1.amount_ex_tax*0.13, 0.011);
  PERFORM assert_true('专票必须有购方税号', inv1.buyer_tax_no IS NOT NULL AND inv1.invoice_kind='vat_special');
  dn2 := fn_deliver(so.id, jsonb_build_array(jsonb_build_object('so_item',soi.id,'qty',35,'wh',wh('FG1'))));
  tmp := fn_sales_invoice(dn2, 'vat_special'); SELECT * INTO inv2 FROM invoice WHERE id=tmp;
  PERFORM assert_eq('已发货 95', (SELECT delivered_qty FROM sales_order_item WHERE id=soi.id), 95);
  PERFORM assert_eq('应收=两张发票合计', (SELECT balance FROM v_party_balance WHERE party_id=pty('CUST01') AND ledger_type='receivable'), inv1.total_amount+inv2.total_amount);
  PERFORM assert_raises('核销超过发票未清额被拒', format('SELECT fn_payment(%L,%s,%s,%L::jsonb)', 'receive', pty('CUST01'), inv1.total_amount+1,
          jsonb_build_array(jsonb_build_object('invoice',inv1.id,'amount',inv1.total_amount+1))::text), '超过发票未清');
  pe := fn_payment('receive', pty('CUST01'), inv1.total_amount + part, jsonb_build_array(
          jsonb_build_object('invoice',inv1.id,'amount',inv1.total_amount), jsonb_build_object('invoice',inv2.id,'amount',part)));
  PERFORM assert_eq('发票1 已结清', (SELECT outstanding FROM v_invoice_outstanding WHERE invoice_id=inv1.id), 0);
  PERFORM assert_eq('发票2 未清=合计-1000', (SELECT outstanding FROM v_invoice_outstanding WHERE invoice_id=inv2.id), inv2.total_amount-part);
  PERFORM assert_eq('应收总账=明细账', (SELECT sum(debit-credit) FROM gl_entry WHERE account_id=fn_acct('1122')),
                    (SELECT balance FROM v_party_balance WHERE party_id=pty('CUST01') AND ledger_type='receivable'));
END $$;
