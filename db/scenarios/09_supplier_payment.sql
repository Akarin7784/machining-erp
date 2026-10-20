-- 剧本 09：供应商/外协厂付款核销
SELECT use_tenant('DEMO');
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT i.id, i.party_id, o.outstanding FROM invoice i JOIN v_invoice_outstanding o ON o.invoice_id=i.id
           WHERE i.direction='purchase' AND i.party_id IN (pty('SUP-STEEL'), pty('SUP-BRG'), pty('SUB-PL')) LOOP
    PERFORM fn_payment('pay', r.party_id, r.outstanding, jsonb_build_array(jsonb_build_object('invoice', r.id, 'amount', r.outstanding)));
  END LOOP;
  -- 热处理厂只付一半
  PERFORM fn_payment('pay', pty('SUB-HT'), round((SELECT outstanding FROM v_invoice_outstanding o JOIN invoice i ON i.id=o.invoice_id WHERE i.party_id=pty('SUB-HT'))/2,2),
     jsonb_build_array(jsonb_build_object('invoice',(SELECT id FROM invoice WHERE party_id=pty('SUB-HT')),
                                          'amount',round((SELECT outstanding FROM v_invoice_outstanding o JOIN invoice i ON i.id=o.invoice_id WHERE i.party_id=pty('SUB-HT'))/2,2))));
  PERFORM assert_eq('钢材/轴承/电镀厂应付结清', (SELECT coalesce(sum(balance),0) FROM v_party_balance WHERE ledger_type='payable' AND party_id IN (pty('SUP-STEEL'),pty('SUP-BRG'),pty('SUB-PL'))), 0);
  PERFORM assert_eq('热处理厂剩余应付=一半', (SELECT balance FROM v_party_balance WHERE ledger_type='payable' AND party_id=pty('SUB-HT')),
                    (SELECT total_amount FROM invoice WHERE party_id=pty('SUB-HT')) - round((SELECT total_amount FROM invoice WHERE party_id=pty('SUB-HT'))/2,2));
  PERFORM assert_eq('应付总账=明细账', (SELECT sum(credit-debit) FROM gl_entry WHERE account_id=fn_acct('2202')),
                    (SELECT sum(balance) FROM v_party_balance WHERE ledger_type='payable'));
END $$;
