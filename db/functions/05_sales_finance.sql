-- 发货、销项发票、退货联动（红字发票+冲减应收）、收付款核销、对账单、月结

CREATE OR REPLACE FUNCTION fn_deliver(p_so bigint, p_lines jsonb, p_date date DEFAULT current_date) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE so sales_order; dn bigint; r record; sl stock_ledger; cogs numeric := 0;
BEGIN
  SELECT * INTO so FROM sales_order WHERE id=p_so FOR UPDATE;
  IF so.status NOT IN ('confirmed','in_production','partially_delivered') THEN RAISE EXCEPTION '订单 % 状态 % 不能发货', so.doc_no, so.status; END IF;
  INSERT INTO delivery_note(customer_id, plant_id, posting_date) VALUES (so.customer_id, so.plant_id, p_date) RETURNING id INTO dn;
  FOR r IN SELECT s.*, (l->>'qty')::numeric dqty, (l->>'wh')::bigint wh FROM jsonb_array_elements(p_lines) l
           JOIN sales_order_item s ON s.id=(l->>'so_item')::bigint AND s.sales_order_id=p_so LOOP
    IF r.delivered_qty + r.dqty > r.qty THEN RAISE EXCEPTION '发货数量超过订单数量：已发 % + 本次 % > 订单 %', r.delivered_qty, r.dqty, r.qty; END IF;
    INSERT INTO delivery_note_item(delivery_note_id, so_item_id, item_id, warehouse_id, qty, unit_price)
    VALUES (dn, r.id, r.item_id, r.wh, r.dqty, r.unit_price);
    sl := fn_stock_move(r.wh, r.item_id, -r.dqty, NULL, 'delivery_note', dn, r.id);
    cogs := cogs - sl.value_change;
    UPDATE sales_order_item SET delivered_qty=delivered_qty+r.dqty WHERE id=r.id;
  END LOOP;
  UPDATE delivery_note SET status='posted' WHERE id=dn;
  PERFORM fn_post_je('delivery_note', dn, p_date, '销售出库', jsonb_build_array(
    jsonb_build_object('a','6401','d',cogs,'plant',so.plant_id),
    jsonb_build_object('a','1405','c',cogs,'plant',so.plant_id)));
  UPDATE sales_order SET status = CASE WHEN (SELECT bool_and(delivered_qty>=qty) FROM sales_order_item WHERE sales_order_id=p_so) THEN 'delivered' ELSE 'partially_delivered' END
   WHERE id=p_so AND status <> CASE WHEN (SELECT bool_and(delivered_qty>=qty) FROM sales_order_item WHERE sales_order_id=p_so) THEN 'delivered' ELSE 'partially_delivered' END;
  RETURN dn;
END $$;

-- 销项发票（订单单价为含税价，价税分离）
CREATE OR REPLACE FUNCTION fn_sales_invoice(p_dn bigint, p_kind text DEFAULT 'vat_special', p_date date DEFAULT current_date) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE inv bigint; d delivery_note; c party; t tenant; i invoice; ex numeric; tax numeric;
BEGIN
  SELECT * INTO d FROM delivery_note WHERE id=p_dn;
  SELECT * INTO c FROM party WHERE id=d.customer_id;
  SELECT * INTO t FROM tenant WHERE tenant_id=app_tid();
  INSERT INTO invoice(direction, invoice_kind, party_id, buyer_name, buyer_tax_no, buyer_addr_phone, buyer_bank_account, seller_name, seller_tax_no,
                      invoice_date, due_date, source_type, source_id)
  VALUES ('sales', p_kind, c.id, c.party_name, c.tax_no, c.address_phone, c.bank_account, t.tenant_name,
          (SELECT tax_no FROM party WHERE party_code='SELF' AND tenant_id=app_tid()), p_date, p_date + c.payment_days, 'delivery_note', p_dn)
  RETURNING id INTO inv;
  INSERT INTO invoice_item(invoice_id, goods_name, spec, uom, qty, unit_price_ex_tax, amount_ex_tax, tax_rate, tax_amount, source_line_type, source_line_id)
  SELECT inv, it.item_name, it.item_code, it.stock_uom, di.qty, round(di.unit_price/(1+s.tax_rate),8),
         round(di.qty*di.unit_price/(1+s.tax_rate),2), s.tax_rate,
         round(di.qty*di.unit_price,2) - round(di.qty*di.unit_price/(1+s.tax_rate),2), 'delivery_note_item', di.id
  FROM delivery_note_item di JOIN sales_order_item s ON s.id=di.so_item_id JOIN item it ON it.id=di.item_id WHERE di.delivery_note_id=p_dn;
  UPDATE sales_order_item s SET invoiced_qty=invoiced_qty+di.qty FROM delivery_note_item di WHERE di.delivery_note_id=p_dn AND s.id=di.so_item_id;
  SELECT sum(amount_ex_tax), sum(tax_amount) INTO ex, tax FROM invoice_item WHERE invoice_id=inv;
  UPDATE invoice SET amount_ex_tax=ex, tax_amount=tax, status='issued' WHERE id=inv RETURNING * INTO i;
  INSERT INTO payment_ledger(ledger_type, party_id, posting_date, voucher_type, voucher_id, against_invoice_id, amount, due_date)
  VALUES ('receivable', c.id, p_date, 'invoice', inv, inv, i.total_amount, i.due_date);
  PERFORM fn_post_je('invoice', inv, p_date, '销项发票 '||i.doc_no, jsonb_build_array(
    jsonb_build_object('a','1122','d',i.total_amount,'party',c.id,'plant',d.plant_id),
    jsonb_build_object('a','6001','c',ex,'plant',d.plant_id),
    jsonb_build_object('a','22210102','c',tax,'plant',d.plant_id)));
  RETURN inv;
END $$;

-- 销售退货：建退货单并过账（触发器联动：入库、冲成本、红字发票、冲减应收）
CREATE OR REPLACE FUNCTION fn_sales_return(p_dn bigint, p_lines jsonb, p_reason text, p_date date DEFAULT current_date) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE d delivery_note; rn bigint;
BEGIN
  SELECT * INTO d FROM delivery_note WHERE id=p_dn;
  INSERT INTO delivery_note(customer_id, plant_id, posting_date, is_return, return_against, return_reason)
  VALUES (d.customer_id, d.plant_id, p_date, true, p_dn, p_reason) RETURNING id INTO rn;
  INSERT INTO delivery_note_item(delivery_note_id, so_item_id, item_id, warehouse_id, qty, unit_price, return_against_item_id)
  SELECT rn, di.so_item_id, di.item_id, coalesce((l->>'wh')::bigint, di.warehouse_id), (l->>'qty')::numeric, di.unit_price, di.id
  FROM jsonb_array_elements(p_lines) l JOIN delivery_note_item di ON di.id=(l->>'dn_item')::bigint AND di.delivery_note_id=p_dn;
  UPDATE delivery_note SET status='posted' WHERE id=rn;   -- 触发 trg_return_posted
  RETURN rn;
END $$;

CREATE OR REPLACE FUNCTION trg_return_posted() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r record; sl stock_ledger; out_rate numeric; cogs numeric := 0; orig invoice; red bigint; ex numeric; tax numeric; i invoice;
BEGIN
  IF NOT (NEW.is_return AND OLD.status='draft' AND NEW.status='posted') THEN RETURN NEW; END IF;
  FOR r IN SELECT ri.*, oi.qty AS orig_qty, (SELECT coalesce(sum(x.qty),0) FROM delivery_note_item x JOIN delivery_note y ON y.id=x.delivery_note_id
                                             WHERE x.return_against_item_id=oi.id AND y.status='posted') AS already
           FROM delivery_note_item ri JOIN delivery_note_item oi ON oi.id=ri.return_against_item_id WHERE ri.delivery_note_id=NEW.id LOOP
    IF r.already + r.qty > r.orig_qty THEN RAISE EXCEPTION '退货数量超过原发货数量'; END IF;
    SELECT -value_change/(-qty) INTO out_rate FROM stock_ledger WHERE voucher_type='delivery_note' AND voucher_id=NEW.return_against AND voucher_line_id=r.so_item_id AND NOT is_reversal LIMIT 1;
    sl := fn_stock_move(r.warehouse_id, r.item_id, r.qty, out_rate, 'sales_return', NEW.id, r.so_item_id);
    cogs := cogs + sl.value_change;
    UPDATE sales_order_item SET returned_qty=returned_qty+r.qty WHERE id=r.so_item_id;
  END LOOP;
  PERFORM fn_post_je('sales_return', NEW.id, NEW.posting_date, '销售退货入库', jsonb_build_array(
    jsonb_build_object('a','1405','d',cogs,'plant',NEW.plant_id), jsonb_build_object('a','6401','c',cogs,'plant',NEW.plant_id)));
  -- 原发货已开票 → 开红字发票并冲减应收
  SELECT * INTO orig FROM invoice WHERE source_type='delivery_note' AND source_id=NEW.return_against AND direction='sales' AND NOT is_red AND status='issued';
  IF orig.id IS NOT NULL THEN
    INSERT INTO invoice(direction, invoice_kind, is_red, red_of, party_id, buyer_name, buyer_tax_no, seller_name, seller_tax_no, invoice_date, source_type, source_id)
    VALUES ('sales', orig.invoice_kind, true, orig.id, orig.party_id, orig.buyer_name, orig.buyer_tax_no, orig.seller_name, orig.seller_tax_no, NEW.posting_date, 'delivery_note', NEW.id)
    RETURNING id INTO red;
    INSERT INTO invoice_item(invoice_id, goods_name, spec, uom, qty, unit_price_ex_tax, amount_ex_tax, tax_rate, tax_amount, source_line_type, source_line_id)
    SELECT red, ii.goods_name, ii.spec, ii.uom, -ri.qty, ii.unit_price_ex_tax, -round(ri.qty*ri.unit_price/(1+ii.tax_rate),2), ii.tax_rate,
           -(round(ri.qty*ri.unit_price,2) - round(ri.qty*ri.unit_price/(1+ii.tax_rate),2)), 'delivery_note_item', ri.id
    FROM delivery_note_item ri JOIN invoice_item ii ON ii.invoice_id=orig.id AND ii.source_line_id=ri.return_against_item_id
    WHERE ri.delivery_note_id=NEW.id;
    SELECT sum(amount_ex_tax), sum(tax_amount) INTO ex, tax FROM invoice_item WHERE invoice_id=red;
    UPDATE invoice SET amount_ex_tax=ex, tax_amount=tax, status='issued' WHERE id=red RETURNING * INTO i;
    INSERT INTO payment_ledger(ledger_type, party_id, posting_date, voucher_type, voucher_id, against_invoice_id, amount)
    VALUES ('receivable', orig.party_id, NEW.posting_date, 'invoice', red, orig.id, i.total_amount);   -- 负数，冲减原发票应收
    PERFORM fn_post_je('invoice', red, NEW.posting_date, '红字发票(退货)', jsonb_build_array(
      jsonb_build_object('a','1122','d',i.total_amount,'party',orig.party_id,'plant',NEW.plant_id),
      jsonb_build_object('a','6001','c',ex,'plant',NEW.plant_id),
      jsonb_build_object('a','22210102','c',tax,'plant',NEW.plant_id)));
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS delivery_note_return_posted ON delivery_note;
CREATE TRIGGER delivery_note_return_posted AFTER UPDATE OF status ON delivery_note FOR EACH ROW EXECUTE FUNCTION trg_return_posted();

-- 发货单作废：库存写冲销、凭证红冲（不删原记录）
CREATE OR REPLACE FUNCTION fn_cancel_delivery(p_dn bigint) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d delivery_note;
BEGIN
  SELECT * INTO d FROM delivery_note WHERE id=p_dn FOR UPDATE;
  IF EXISTS (SELECT 1 FROM invoice WHERE source_type='delivery_note' AND source_id=p_dn AND status='issued') THEN
    RAISE EXCEPTION '发货单 % 已开票，请走退货流程', d.doc_no;
  END IF;
  PERFORM fn_reverse_stock_voucher('delivery_note', p_dn);
  PERFORM fn_reverse_je('delivery_note', p_dn, current_date);
  UPDATE sales_order_item s SET delivered_qty=delivered_qty-di.qty FROM delivery_note_item di WHERE di.delivery_note_id=p_dn AND s.id=di.so_item_id;
  UPDATE delivery_note SET status='cancelled' WHERE id=p_dn;
END $$;

-- 收款 / 付款 与核销
CREATE OR REPLACE FUNCTION fn_payment(p_type text, p_party bigint, p_amount numeric, p_alloc jsonb, p_date date DEFAULT current_date)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE pe bigint; a jsonb; lt text := CASE WHEN p_type='receive' THEN 'receivable' ELSE 'payable' END; allocated numeric := 0; os numeric;
BEGIN
  INSERT INTO payment_entry(payment_type, party_id, posting_date, paid_amount) VALUES (p_type, p_party, p_date, p_amount) RETURNING id INTO pe;
  FOR a IN SELECT * FROM jsonb_array_elements(p_alloc) LOOP
    SELECT sum(amount) INTO os FROM payment_ledger WHERE against_invoice_id=(a->>'invoice')::bigint AND ledger_type=lt;
    IF (a->>'amount')::numeric > os THEN RAISE EXCEPTION '核销金额 % 超过发票未清 %', a->>'amount', os; END IF;
    INSERT INTO payment_allocation(payment_entry_id, invoice_id, allocated_amount) VALUES (pe, (a->>'invoice')::bigint, (a->>'amount')::numeric);
    INSERT INTO payment_ledger(ledger_type, party_id, posting_date, voucher_type, voucher_id, against_invoice_id, amount)
    VALUES (lt, p_party, p_date, 'payment_entry', pe, (a->>'invoice')::bigint, -(a->>'amount')::numeric);
    allocated := allocated + (a->>'amount')::numeric;
  END LOOP;
  IF allocated > p_amount THEN RAISE EXCEPTION '核销合计 % 超过收付款金额 %', allocated, p_amount; END IF;
  IF p_amount > allocated THEN   -- 预收/预付
    INSERT INTO payment_ledger(ledger_type, party_id, posting_date, voucher_type, voucher_id, amount)
    VALUES (lt, p_party, p_date, 'payment_entry', pe, -(p_amount-allocated));
  END IF;
  UPDATE payment_entry SET status='posted' WHERE id=pe;
  PERFORM fn_post_je('payment_entry', pe, p_date, CASE WHEN p_type='receive' THEN '收款' ELSE '付款' END,
    CASE WHEN p_type='receive' THEN jsonb_build_array(jsonb_build_object('a','1002','d',p_amount), jsonb_build_object('a','1122','c',p_amount,'party',p_party))
         ELSE jsonb_build_array(jsonb_build_object('a','2202','d',p_amount,'party',p_party), jsonb_build_object('a','1002','c',p_amount)) END);
  RETURN pe;
END $$;

-- 客户月度对账单：期初、本期发票/红票/收款、期末，另列已发货未开票
CREATE OR REPLACE FUNCTION fn_customer_statement(p_party bigint, p_period text) RETURNS customer_statement LANGUAGE plpgsql AS $$
DECLARE s customer_statement; d1 date := to_date(p_period||'-01','YYYY-MM-DD'); d2 date; ob numeric; dr numeric; cr numeric; dni numeric; lines jsonb;
BEGIN
  d2 := (d1 + interval '1 month')::date;
  SELECT coalesce(sum(amount),0) INTO ob FROM payment_ledger WHERE party_id=p_party AND ledger_type='receivable' AND posting_date < d1;
  SELECT coalesce(sum(amount) FILTER (WHERE amount>0),0), coalesce(-sum(amount) FILTER (WHERE amount<0),0) INTO dr, cr
    FROM payment_ledger WHERE party_id=p_party AND ledger_type='receivable' AND posting_date >= d1 AND posting_date < d2;
  SELECT coalesce(jsonb_agg(jsonb_build_object('date',pl.posting_date,'voucher',pl.voucher_type,'doc',coalesce(i.doc_no,pe.doc_no),'amount',pl.amount) ORDER BY pl.id),'[]')
    INTO lines FROM payment_ledger pl LEFT JOIN invoice i ON pl.voucher_type='invoice' AND i.id=pl.voucher_id
    LEFT JOIN payment_entry pe ON pl.voucher_type='payment_entry' AND pe.id=pl.voucher_id
   WHERE pl.party_id=p_party AND pl.ledger_type='receivable' AND pl.posting_date >= d1 AND pl.posting_date < d2;
  SELECT coalesce(sum(round((s2.delivered_qty - s2.invoiced_qty)*s2.unit_price,2)),0) INTO dni
    FROM sales_order_item s2 JOIN sales_order so ON so.id=s2.sales_order_id WHERE so.customer_id=p_party;
  INSERT INTO customer_statement(party_id, period, opening_balance, debit_total, credit_total, closing_balance, delivered_not_invoiced, lines)
  VALUES (p_party, p_period, ob, dr, cr, ob+dr-cr, dni, lines)
  ON CONFLICT (party_id, period) DO UPDATE SET opening_balance=EXCLUDED.opening_balance, debit_total=EXCLUDED.debit_total,
     credit_total=EXCLUDED.credit_total, closing_balance=EXCLUDED.closing_balance, delivered_not_invoiced=EXCLUDED.delivered_not_invoiced,
     lines=EXCLUDED.lines, generated_at=now()
  RETURNING * INTO s;
  RETURN s;
END $$;

-- 月结：试算平衡 + 子账(应收/应付)与总账一致，才允许关账
CREATE OR REPLACE FUNCTION fn_close_period(p_period text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE d numeric; c numeric; ar_gl numeric; ar_sub numeric; ap_gl numeric; ap_sub numeric; dend date;
BEGIN
  dend := (to_date(p_period||'-01','YYYY-MM-DD') + interval '1 month')::date;
  SELECT sum(g.debit), sum(g.credit) INTO d, c FROM gl_entry g JOIN journal_entry j ON j.id=g.journal_entry_id WHERE j.period <= p_period;
  IF d <> c THEN RAISE EXCEPTION '试算不平：借 % 贷 %', d, c; END IF;
  SELECT coalesce(sum(g.debit-g.credit),0) INTO ar_gl FROM gl_entry g JOIN journal_entry j ON j.id=g.journal_entry_id WHERE g.account_id=fn_acct('1122') AND j.period<=p_period;
  SELECT coalesce(sum(amount),0) INTO ar_sub FROM payment_ledger WHERE ledger_type='receivable' AND posting_date < dend;
  SELECT coalesce(sum(g.credit-g.debit),0) INTO ap_gl FROM gl_entry g JOIN journal_entry j ON j.id=g.journal_entry_id WHERE g.account_id=fn_acct('2202') AND j.period<=p_period;
  SELECT coalesce(sum(amount),0) INTO ap_sub FROM payment_ledger WHERE ledger_type='payable' AND posting_date < dend;
  IF ar_gl <> ar_sub THEN RAISE EXCEPTION '应收总账 % 与明细账 % 不一致', ar_gl, ar_sub; END IF;
  IF ap_gl <> ap_sub THEN RAISE EXCEPTION '应付总账 % 与明细账 % 不一致', ap_gl, ap_sub; END IF;
  INSERT INTO accounting_period(period, status, closed_at) VALUES (p_period, 'closed', now())
  ON CONFLICT (tenant_id, period) DO UPDATE SET status='closed', closed_at=now();
END $$;
