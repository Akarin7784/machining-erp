-- 查找与断言辅助
CREATE OR REPLACE FUNCTION it(p_code text) RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT id FROM item WHERE item_code=p_code AND tenant_id=app_tid() $$;
CREATE OR REPLACE FUNCTION wh(p_code text) RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT id FROM warehouse WHERE wh_code=p_code AND tenant_id=app_tid() $$;
CREATE OR REPLACE FUNCTION pty(p_code text) RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT id FROM party WHERE party_code=p_code AND tenant_id=app_tid() $$;
CREATE OR REPLACE FUNCTION plant_of(p_code text) RETURNS bigint LANGUAGE sql STABLE AS $$ SELECT id FROM plant WHERE plant_code=p_code AND tenant_id=app_tid() $$;
CREATE OR REPLACE FUNCTION use_tenant(p_code text) RETURNS uuid LANGUAGE sql AS
$$ SELECT set_config('app.tenant_id', (SELECT tenant_id::text FROM tenant WHERE tenant_code=p_code), false)::uuid $$;
CREATE OR REPLACE FUNCTION stock_qty(p_item text, p_wh text) RETURNS numeric LANGUAGE sql STABLE AS
$$ SELECT coalesce((SELECT qty FROM v_stock_balance WHERE item_id=it(p_item) AND warehouse_id=wh(p_wh) AND tenant_id=app_tid()),0) $$;
CREATE OR REPLACE FUNCTION stock_value(p_item text, p_wh text) RETURNS numeric LANGUAGE sql STABLE AS
$$ SELECT coalesce((SELECT value FROM v_stock_balance WHERE item_id=it(p_item) AND warehouse_id=wh(p_wh) AND tenant_id=app_tid()),0) $$;

CREATE OR REPLACE FUNCTION assert_eq(p_label text, p_actual numeric, p_expected numeric, p_tol numeric DEFAULT 0.005) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_actual IS NULL OR p_expected IS NULL OR abs(p_actual - p_expected) > p_tol THEN
    RAISE EXCEPTION '断言失败 [%]: 实际 %，预期 %（容差 %）', p_label, p_actual, p_expected, p_tol;
  END IF;
  RAISE NOTICE 'OK  %: %', p_label, p_actual;
END $$;
CREATE OR REPLACE FUNCTION assert_true(p_label text, p_cond boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS NOT TRUE THEN RAISE EXCEPTION '断言失败 [%]', p_label; END IF;
  RAISE NOTICE 'OK  %', p_label;
END $$;
-- 预期某语句抛错（错误信息包含 p_like）
CREATE OR REPLACE FUNCTION assert_raises(p_label text, p_sql text, p_like text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%'||p_like||'%' THEN RAISE NOTICE 'OK  % (拒绝: %)', p_label, SQLERRM; RETURN; END IF;
    RAISE EXCEPTION '断言失败 [%]: 错误信息不符: %', p_label, SQLERRM;
  END;
  RAISE EXCEPTION '断言失败 [%]: 预期报错但执行成功', p_label;
END $$;
