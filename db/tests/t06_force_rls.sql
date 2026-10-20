-- #24 FORCE ROW LEVEL SECURITY：表所有者（非超级用户）也读不到其他租户
BEGIN;
SELECT plan(8);
SELECT is((SELECT rolsuper FROM pg_roles WHERE rolname='erp_owner'), false, '表所有者 erp_owner 不是超级用户');
SELECT is((SELECT pg_get_userbyid(relowner) FROM pg_class WHERE relname='item' AND relnamespace='public'::regnamespace), 'erp_owner', 'item 表所有者是 erp_owner');
SELECT is((SELECT count(*) FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind='r' AND relrowsecurity AND NOT relforcerowsecurity), 0::bigint, '所有启用 RLS 的表都 FORCE');
SELECT ok((SELECT count(*) FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind='r' AND relforcerowsecurity) >= 60, '至少 60 张表 FORCE RLS');
SELECT use_tenant('OTHER');
SET LOCAL ROLE erp_owner;
SELECT is((SELECT count(*) FROM item), 0::bigint, '所有者在 OTHER 租户下看不到 DEMO 物料');
SELECT is((SELECT count(*) FROM stock_ledger), 0::bigint, '所有者在 OTHER 租户下看不到 DEMO 库存流水');
SELECT throws_ok($$INSERT INTO plant(tenant_id, plant_code, plant_name) SELECT tenant_id, 'X', 'x' FROM (SELECT (SELECT tenant_id FROM tenant LIMIT 1)) t(tenant_id) WHERE false
                  UNION ALL SELECT '00000000-0000-0000-0000-000000000000'::uuid, 'X', 'x'$$, '42501', NULL, '所有者不能写入其他租户的行');
RESET ROLE;
SELECT use_tenant('DEMO');
SET LOCAL ROLE erp_owner;
SELECT ok((SELECT count(*) FROM item) > 0, '所有者在 DEMO 租户下能看到 DEMO 物料');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
