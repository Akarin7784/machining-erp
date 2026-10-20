-- 通用：科目表初始化、凭证过账、物料单价
CREATE OR REPLACE FUNCTION fn_seed_coa() RETURNS void LANGUAGE sql AS $$
INSERT INTO gl_account(account_code, account_name, account_type) VALUES
 ('1002','银行存款','asset'),('1122','应收账款','asset'),('1403','原材料','asset'),('1405','库存商品','asset'),
 ('1411','在途物资(厂间调拨)','asset'),('5001','生产成本','asset'),('22210101','应交税费-进项税额','asset'),
 ('2202','应付账款','liability'),('220201','应付暂估','liability'),('2211','应付职工薪酬','liability'),
 ('22210102','应交税费-销项税额','liability'),('5101','制造费用(机时吸收)','expense'),
 ('6001','主营业务收入','income'),('6401','主营业务成本','expense'),('6711','营业外支出(报废)','expense')
ON CONFLICT DO NOTHING;
$$;

CREATE OR REPLACE FUNCTION fn_acct(p_code text) RETURNS bigint LANGUAGE sql STABLE AS
$$ SELECT id FROM gl_account WHERE tenant_id=app_tid() AND account_code=p_code $$;

-- lines: [{"a":"1403","d":10,"c":0,"party":1,"wo":2,"plant":1}]
CREATE OR REPLACE FUNCTION fn_post_je(p_vtype text, p_vid bigint, p_date date, p_memo text, p_lines jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE je bigint; l jsonb; d numeric; c numeric;
BEGIN
  INSERT INTO journal_entry(posting_date, period, voucher_type, voucher_id, memo)
  VALUES (p_date, to_char(p_date,'YYYY-MM'), p_vtype, p_vid, p_memo) RETURNING id INTO je;
  FOR l IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    d := round(coalesce((l->>'d')::numeric,0),2); c := round(coalesce((l->>'c')::numeric,0),2);
    IF d < 0 THEN c := c - d; d := 0; END IF;
    IF c < 0 THEN d := d - c; c := 0; END IF;
    CONTINUE WHEN d = 0 AND c = 0;
    IF fn_acct(l->>'a') IS NULL THEN RAISE EXCEPTION '科目 % 不存在', l->>'a'; END IF;
    INSERT INTO gl_entry(journal_entry_id, account_id, debit, credit, party_id, work_order_id, plant_id)
    VALUES (je, fn_acct(l->>'a'), d, c, (l->>'party')::bigint, (l->>'wo')::bigint, (l->>'plant')::bigint);
  END LOOP;
  RETURN je;
END $$;

-- 库存出入库（带 GL 的调用方负责凭证）
CREATE OR REPLACE FUNCTION fn_stock_move(p_wh bigint, p_item bigint, p_qty numeric, p_rate numeric,
  p_vtype text, p_vid bigint, p_line bigint DEFAULT NULL, p_wo bigint DEFAULT NULL, p_batch text DEFAULT NULL)
RETURNS stock_ledger LANGUAGE plpgsql AS $$
DECLARE r stock_ledger;
BEGIN
  INSERT INTO stock_ledger(plant_id, warehouse_id, item_id, qty, incoming_rate, voucher_type, voucher_id, voucher_line_id, work_order_id, batch_no)
  SELECT w.plant_id, w.id, p_item, p_qty, CASE WHEN p_qty>0 THEN p_rate END, p_vtype, p_vid, p_line, p_wo, p_batch
  FROM warehouse w WHERE w.id=p_wh RETURNING * INTO r;
  RETURN r;
END $$;

-- 单据作废：对该单据所有库存流水写冲销记录（原记录不改不删）
CREATE OR REPLACE FUNCTION fn_reverse_stock_voucher(p_vtype text, p_vid bigint) RETURNS int LANGUAGE plpgsql AS $$
DECLARE r stock_ledger; n int := 0;
BEGIN
  FOR r IN SELECT * FROM stock_ledger s WHERE voucher_type=p_vtype AND voucher_id=p_vid AND NOT is_reversal
             AND NOT EXISTS (SELECT 1 FROM stock_ledger x WHERE x.reverses_id=s.id) ORDER BY id DESC LOOP
    INSERT INTO stock_ledger(plant_id, warehouse_id, item_id, qty, voucher_type, voucher_id, voucher_line_id, work_order_id, is_reversal, reverses_id)
    VALUES (r.plant_id, r.warehouse_id, r.item_id, -r.qty, p_vtype, p_vid, r.voucher_line_id, r.work_order_id, true, r.id);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- 凭证冲销（红字）
CREATE OR REPLACE FUNCTION fn_reverse_je(p_vtype text, p_vid bigint, p_date date) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE je bigint;
BEGIN
  INSERT INTO journal_entry(posting_date, period, voucher_type, voucher_id, memo)
  VALUES (p_date, to_char(p_date,'YYYY-MM'), p_vtype||'_reversal', p_vid, '冲销 '||p_vtype||' '||p_vid) RETURNING id INTO je;
  INSERT INTO gl_entry(journal_entry_id, account_id, debit, credit, party_id, work_order_id, plant_id)
  SELECT je, g.account_id, g.credit, g.debit, g.party_id, g.work_order_id, g.plant_id
  FROM gl_entry g JOIN journal_entry j ON j.id=g.journal_entry_id WHERE j.voucher_type=p_vtype AND j.voucher_id=p_vid;
  RETURN je;
END $$;

CREATE OR REPLACE FUNCTION fn_inv_acct(p_item bigint) RETURNS text LANGUAGE sql STABLE AS
$$ SELECT CASE WHEN item_kind IN ('raw','purchased') THEN '1403' ELSE '1405' END FROM item WHERE id=p_item $$;

-- 棒料毛重(kg) = π(d/2)²·L·ρ ；d,L 单位 mm，ρ g/cm³
CREATE OR REPLACE FUNCTION fn_bar_weight_kg(p_dia_mm numeric, p_len_mm numeric, p_density numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$ SELECT round(pi()::numeric*(p_dia_mm/2)^2*p_len_mm*p_density/1000000, 4) $$;
