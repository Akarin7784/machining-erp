-- 剧本 11：客户退货 2 件 → 自动入库、冲减销售成本、开红字发票、冲减应收
SELECT use_tenant('DEMO');
DO $$
DECLARE dn2 delivery_note; di delivery_note_item; ar_before numeric; fg_before numeric; rn bigint; red invoice;
BEGIN
  SELECT * INTO dn2 FROM delivery_note WHERE NOT is_return ORDER BY id DESC LIMIT 1;
  SELECT * INTO di FROM delivery_note_item WHERE delivery_note_id=dn2.id;
  ar_before := (SELECT balance FROM v_party_balance WHERE party_id=pty('CUST01') AND ledger_type='receivable');
  fg_before := stock_qty('SHAFT-ASSY','FG1');
  rn := fn_sales_return(dn2.id, jsonb_build_array(jsonb_build_object('dn_item',di.id,'qty',2)), '镀层划伤');
  SELECT * INTO red FROM invoice WHERE is_red AND source_id=rn;
  PERFORM assert_eq('退货入库', stock_qty('SHAFT-ASSY','FG1'), fg_before+2);
  PERFORM assert_eq('红字发票金额=-2×含税单价', red.total_amount, -round(2*di.unit_price,2));
  PERFORM assert_eq('应收自动冲减', (SELECT balance FROM v_party_balance WHERE party_id=pty('CUST01') AND ledger_type='receivable'), ar_before - round(2*di.unit_price,2));
  PERFORM assert_eq('订单行退货数', (SELECT returned_qty FROM sales_order_item WHERE id=di.so_item_id), 2);
  PERFORM assert_raises('退货不能超过原发货数', format('SELECT fn_sales_return(%s, %L::jsonb, %L)', dn2.id,
          jsonb_build_array(jsonb_build_object('dn_item',di.id,'qty',34))::text, 'x'), '超过原发货数量');
  PERFORM assert_eq('应收总账=明细账', (SELECT sum(debit-credit) FROM gl_entry WHERE account_id=fn_acct('1122')),
                    (SELECT balance FROM v_party_balance WHERE party_id=pty('CUST01') AND ledger_type='receivable'));
END $$;
