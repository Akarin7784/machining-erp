-- migrate:up
-- 状态迁移规则、触发器挂载、多租户 RLS、角色与列权限、视图

INSERT INTO doc_state_rule(doc_table, from_status, to_status) VALUES
 ('quotation',NULL,'draft'),('quotation','draft','submitted'),('quotation','submitted','pending_approval'),
 ('quotation','submitted','approved'),('quotation','pending_approval','approved'),('quotation','pending_approval','rejected'),
 ('quotation','approved','ordered'),('quotation','draft','cancelled'),('quotation','submitted','cancelled'),('quotation','approved','expired'),
 ('drawing_revision',NULL,'draft'),('drawing_revision','draft','released'),('drawing_revision','released','superseded'),
 ('sales_order',NULL,'draft'),('sales_order','draft','confirmed'),('sales_order','confirmed','in_production'),
 ('sales_order','in_production','partially_delivered'),('sales_order','in_production','delivered'),
 ('sales_order','partially_delivered','delivered'),('sales_order','delivered','closed'),
 ('sales_order','draft','cancelled'),('sales_order','confirmed','cancelled'),
 ('production_plan',NULL,'draft'),('production_plan','draft','planned'),('production_plan','planned','closed'),
 ('work_order',NULL,'draft'),('work_order','draft','released'),('work_order','released','in_process'),
 ('work_order','in_process','completed'),('work_order','completed','closed'),('work_order','draft','cancelled'),('work_order','released','cancelled'),
 ('wo_operation',NULL,'pending'),('wo_operation','pending','in_process'),('wo_operation','in_process','done'),
 ('wo_operation','pending','subcontracted'),('wo_operation','subcontracted','done'),('wo_operation','done','rework'),('wo_operation','rework','done'),
 ('purchase_order',NULL,'draft'),('purchase_order','draft','submitted'),('purchase_order','submitted','partially_received'),
 ('purchase_order','submitted','received'),('purchase_order','partially_received','received'),('purchase_order','received','closed'),
 ('purchase_order','submitted','cancelled'),
 ('purchase_receipt',NULL,'draft'),('purchase_receipt','draft','inspecting'),('purchase_receipt','inspecting','posted'),('purchase_receipt','posted','cancelled'),
 ('quality_inspection',NULL,'draft'),('quality_inspection','draft','completed'),
 ('subcontract_order',NULL,'draft'),('subcontract_order','draft','sent'),('subcontract_order','sent','partially_received'),
 ('subcontract_order','sent','received'),('subcontract_order','partially_received','received'),('subcontract_order','received','settled'),
 ('stock_transfer',NULL,'draft'),('stock_transfer','draft','in_transit'),('stock_transfer','in_transit','received'),
 ('delivery_note',NULL,'draft'),('delivery_note','draft','posted'),('delivery_note','posted','cancelled'),
 ('invoice',NULL,'draft'),('invoice','draft','issued'),('invoice','issued','cancelled'),
 ('payment_entry',NULL,'draft'),('payment_entry','draft','posted'),
 ('remnant',NULL,'available'),('remnant','available','reused'),('remnant','available','scrapped'),
 ('ai_request',NULL,'pending'),('ai_request','pending','succeeded'),('ai_request','pending','failed');

-- 挂载：审计 + 状态机 + 只增不改
SELECT util_attach(t, s, a) FROM (VALUES
 ('quotation',true,false),('drawing_revision',true,false),('sales_order',true,false),('production_plan',true,false),
 ('work_order',true,false),('wo_operation',true,false),('purchase_order',true,false),('purchase_receipt',true,false),
 ('quality_inspection',true,false),('subcontract_order',true,false),('stock_transfer',true,false),('delivery_note',true,false),
 ('invoice',true,false),('payment_entry',true,false),('remnant',true,false),('ai_request',true,false),
 ('stock_ledger',false,true),('payment_ledger',false,true),('gl_entry',false,true),('journal_entry',false,true),
 ('job_card',false,true),('wo_cost_entry',false,true),('subcontract_movement',false,true),('subcontract_settlement',false,true),
 ('quotation_item',false,false),('sales_order_item',false,false),('item',false,false),('party',false,false),
 ('routing_operation',false,false),('bom_item',false,false),('employee',false,false),('ref_param',false,false),
 ('engineering_change',false,false),('ai_cost_review',false,false)
) v(t,s,a);

-- 多租户 RLS：所有带 tenant_id 的表
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.table_name FROM information_schema.columns c
           JOIN information_schema.tables t USING (table_schema, table_name)
           WHERE c.table_schema='public' AND c.column_name='tenant_id' AND t.table_type='BASE TABLE'
             AND c.table_name NOT IN ('audit_log')
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', r.table_name);
    EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (tenant_id = app_tid()) WITH CHECK (tenant_id = app_tid())', r.table_name);
  END LOOP;
END $$;
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON audit_log USING (tenant_id = app_tid());

-- 角色
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['erp_manager','erp_finance','erp_sales','erp_planner','erp_operator','erp_qc'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname=r) THEN EXECUTE format('CREATE ROLE %I NOLOGIN', r); END IF;
    EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', r);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO %I', r);
    EXECUTE format('GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO %I', r);
  END LOOP;
END $$;

-- 列权限：敏感字段（成本/毛利/工资/机时成本/库存金额）
-- 规则见 docs/05：sales 看不到成本与工资；operator/qc 看不到成本、毛利、工资（除了本表计件结果由报表给出）；planner 看不到工资与毛利
CREATE FUNCTION util_hide_columns(p_role text, p_table text, p_hidden text[]) RETURNS void LANGUAGE plpgsql AS $$
DECLARE cols text;
BEGIN
  EXECUTE format('REVOKE SELECT, INSERT, UPDATE ON %I FROM %I', p_table, p_role);
  SELECT string_agg(quote_ident(column_name), ',') INTO cols FROM information_schema.columns
   WHERE table_schema='public' AND table_name=p_table AND column_name <> ALL(p_hidden);
  EXECUTE format('GRANT SELECT (%s) ON %I TO %I', cols, p_table, p_role);
  SELECT string_agg(quote_ident(column_name), ',') INTO cols FROM information_schema.columns
   WHERE table_schema='public' AND table_name=p_table AND column_name <> ALL(p_hidden) AND is_generated='NEVER' AND is_identity='NO';
  EXECUTE format('GRANT INSERT (%s), UPDATE (%s) ON %I TO %I', cols, cols, p_table, p_role);
END $$;

SELECT util_hide_columns('erp_sales','quotation_item', ARRAY['material_cost','machining_cost','heat_treat_cost','surface_cost','purchased_cost','special_cost','overhead_factor','unit_cost']);
SELECT util_hide_columns('erp_sales','job_card', ARRAY['piece_wage','machine_cost']);
SELECT util_hide_columns('erp_sales','employee', ARRAY['base_monthly']);
SELECT util_hide_columns('erp_sales','item', ARRAY['std_cost']);
SELECT util_hide_columns('erp_sales','stock_ledger', ARRAY['incoming_rate','valuation_rate','value_change','value_after']);
SELECT util_hide_columns('erp_operator','quotation_item', ARRAY['material_cost','machining_cost','heat_treat_cost','surface_cost','purchased_cost','special_cost','overhead_factor','unit_cost','margin_rate','unit_price','amount','suggested_price']);
SELECT util_hide_columns('erp_operator','job_card', ARRAY['machine_cost']);
SELECT util_hide_columns('erp_operator','employee', ARRAY['base_monthly']);
SELECT util_hide_columns('erp_operator','item', ARRAY['std_cost']);
SELECT util_hide_columns('erp_qc','job_card', ARRAY['piece_wage','machine_cost']);
SELECT util_hide_columns('erp_qc','employee', ARRAY['base_monthly']);
SELECT util_hide_columns('erp_planner','employee', ARRAY['base_monthly']);
SELECT util_hide_columns('erp_planner','job_card', ARRAY['piece_wage']);
SELECT util_hide_columns('erp_planner','quotation_item', ARRAY['margin_rate']);
-- 完全不可见的表
REVOKE ALL ON wo_cost_entry, quotation_cost_line, gl_entry, journal_entry, subcontract_settlement FROM erp_sales, erp_operator, erp_qc;
REVOKE ALL ON payment_ledger, payment_entry, payment_allocation FROM erp_operator, erp_qc, erp_planner;
-- 流水表：任何业务角色不可 UPDATE/DELETE（触发器再兜底）
REVOKE UPDATE, DELETE ON stock_ledger, payment_ledger, gl_entry, journal_entry, job_card, wo_cost_entry, subcontract_movement, audit_log
  FROM erp_manager, erp_finance, erp_sales, erp_planner, erp_operator, erp_qc;

-- 视图
CREATE VIEW v_trial_balance WITH (security_invoker = true) AS
SELECT g.tenant_id, a.account_code, a.account_name, a.account_type,
       sum(g.debit) AS debit, sum(g.credit) AS credit, sum(g.debit - g.credit) AS balance
FROM gl_entry g JOIN gl_account a ON a.id=g.account_id
GROUP BY g.tenant_id, a.account_code, a.account_name, a.account_type;

CREATE VIEW v_party_balance WITH (security_invoker = true) AS
SELECT tenant_id, party_id, ledger_type, sum(amount) AS balance
FROM payment_ledger GROUP BY tenant_id, party_id, ledger_type;

CREATE VIEW v_invoice_outstanding WITH (security_invoker = true) AS
SELECT i.id AS invoice_id, i.tenant_id, i.party_id, i.direction, i.total_amount,
       coalesce((SELECT sum(-amount) FROM payment_ledger pl WHERE pl.against_invoice_id=i.id AND pl.voucher_type='payment_entry'),0) AS paid,
       i.total_amount - coalesce((SELECT sum(-amount) FROM payment_ledger pl WHERE pl.against_invoice_id=i.id AND pl.voucher_type='payment_entry'),0) AS outstanding
FROM invoice i WHERE i.status='issued';

-- 订单实际成本 vs 报价（完工复盘）
CREATE VIEW v_order_cost_actual WITH (security_invoker = true) AS
WITH RECURSIVE wo_tree AS (
  SELECT w.id, w.id AS root_id FROM work_order w WHERE w.parent_work_order_id IS NULL
  UNION ALL
  SELECT c.id, t.root_id FROM work_order c JOIN wo_tree t ON c.parent_work_order_id=t.id
)
SELECT r.tenant_id, r.sales_order_item_id, r.id AS root_work_order_id, r.qty, r.produced_qty,
  sum(e.amount) FILTER (WHERE e.cost_type IN ('material','remnant_credit','purchased','scrap')) AS material_actual,
  sum(e.amount) FILTER (WHERE e.cost_type IN ('labor')) AS labor_actual,
  sum(e.amount) FILTER (WHERE e.cost_type IN ('machine')) AS machine_actual,
  sum(e.amount) FILTER (WHERE e.cost_type IN ('subcontract')) AS subcontract_actual,
  sum(e.amount) FILTER (WHERE e.cost_type IN ('rework')) AS rework_actual,
  sum(e.amount) FILTER (WHERE e.cost_type<>'semi_transfer') AS total_actual,
  round(sum(e.amount) FILTER (WHERE e.cost_type<>'semi_transfer')/nullif(r.produced_qty,0),4) AS unit_actual,
  qi.unit_cost AS unit_quoted_cost, qi.unit_price AS unit_price,
  round(1 - (sum(e.amount) FILTER (WHERE e.cost_type<>'semi_transfer')/nullif(r.produced_qty,0))/nullif(qi.unit_price,0),4) AS actual_margin
FROM work_order r
JOIN wo_tree t ON t.root_id=r.id
LEFT JOIN wo_cost_entry e ON e.work_order_id=t.id
LEFT JOIN sales_order_item soi ON soi.id=r.sales_order_item_id
LEFT JOIN quotation_item qi ON qi.id=soi.quotation_item_id
WHERE r.parent_work_order_id IS NULL
GROUP BY r.tenant_id, r.sales_order_item_id, r.id, r.qty, r.produced_qty, qi.unit_cost, qi.unit_price;
-- migrate:down

-- 发票导出（供开票软件/税务 UKey 客户端导入；不直连税局）
CREATE VIEW v_invoice_export WITH (security_invoker = true) AS
SELECT i.tenant_id, i.doc_no AS 单据号, CASE i.invoice_kind WHEN 'vat_special' THEN '增值税专用发票' ELSE '增值税普通发票' END AS 发票种类,
       CASE WHEN i.is_red THEN '红字' ELSE '蓝字' END AS 红蓝字, i.buyer_name AS 购方名称, i.buyer_tax_no AS 购方税号,
       i.buyer_addr_phone AS 购方地址电话, i.buyer_bank_account AS 购方开户行及账号, i.seller_name AS 销方名称, i.seller_tax_no AS 销方税号,
       ii.goods_name AS 货物名称, ii.spec AS 规格型号, ii.uom AS 单位, ii.qty AS 数量, ii.unit_price_ex_tax AS 不含税单价,
       ii.amount_ex_tax AS 不含税金额, ii.tax_rate AS 税率, ii.tax_amount AS 税额, i.invoice_date AS 开票日期
FROM invoice i JOIN invoice_item ii ON ii.invoice_id=i.id
WHERE i.direction='sales' AND i.status='issued';
