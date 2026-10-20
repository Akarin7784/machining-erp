-- migrate:up
-- 开源调研员评审缺口补齐：FORCE RLS、序列号、替代料、物料需求单、amended_from、批量/产能、WIP/废品仓、
-- 报工多段计时、安全库存/最小订购量、质检读数与审核、分期收款计划、AI 字段置信度与人工确认

-- #3 修订链
ALTER TABLE quotation        ADD COLUMN amended_from bigint REFERENCES quotation;
ALTER TABLE sales_order      ADD COLUMN amended_from bigint REFERENCES sales_order;
ALTER TABLE purchase_order   ADD COLUMN amended_from bigint REFERENCES purchase_order;
ALTER TABLE work_order       ADD COLUMN amended_from bigint REFERENCES work_order;
ALTER TABLE delivery_note    ADD COLUMN amended_from bigint REFERENCES delivery_note;
ALTER TABLE invoice          ADD COLUMN amended_from bigint REFERENCES invoice;
ALTER TABLE subcontract_order ADD COLUMN amended_from bigint REFERENCES subcontract_order;
ALTER TABLE payment_entry    ADD COLUMN amended_from bigint REFERENCES payment_entry;
INSERT INTO doc_state_rule(doc_table, from_status, to_status) VALUES ('quotation','rejected','cancelled'), ('quality_inspection','completed','reviewed');

-- #10 批量（准备工时按批分摊） #11 设备并行能力
ALTER TABLE routing_operation ADD COLUMN batch_size numeric(14,4) NOT NULL DEFAULT 1 CHECK (batch_size > 0);  -- 每批件数
ALTER TABLE wo_operation      ADD COLUMN batch_size numeric(14,4) NOT NULL DEFAULT 1 CHECK (batch_size > 0);
ALTER TABLE workstation       ADD COLUMN production_capacity int NOT NULL DEFAULT 1 CHECK (production_capacity >= 1);  -- 可同时加工的工位数
CREATE FUNCTION fn_op_hours(p_std numeric, p_setup numeric, p_batch numeric, p_qty numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$ SELECT p_std*p_qty + p_setup*ceil(p_qty/p_batch) $$;

-- #12 工单 WIP 仓 / 废品仓
ALTER TABLE work_order ADD COLUMN wip_warehouse_id bigint REFERENCES warehouse, ADD COLUMN scrap_warehouse_id bigint REFERENCES warehouse;
CREATE FUNCTION trg_wo_warehouse_types() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.wip_warehouse_id IS NOT NULL AND (SELECT wh_type FROM warehouse WHERE id=NEW.wip_warehouse_id) <> 'wip' THEN
    RAISE EXCEPTION '工单在制品仓必须是 wip 类型'; END IF;
  IF NEW.scrap_warehouse_id IS NOT NULL AND (SELECT wh_type FROM warehouse WHERE id=NEW.scrap_warehouse_id) <> 'reject' THEN
    RAISE EXCEPTION '工单废品仓必须是 reject 类型'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER work_order_wh_types BEFORE INSERT OR UPDATE OF wip_warehouse_id, scrap_warehouse_id ON work_order FOR EACH ROW EXECUTE FUNCTION trg_wo_warehouse_types();

-- #13 报工多段计时（含暂停）
CREATE TABLE job_card_time_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  job_card_id bigint NOT NULL REFERENCES job_card,
  log_kind text NOT NULL CHECK (log_kind IN ('work','pause')),
  from_time timestamptz NOT NULL, to_time timestamptz NOT NULL,
  minutes numeric(10,2) GENERATED ALWAYS AS (round(extract(epoch FROM (to_time - from_time))/60, 2)) STORED,
  pause_reason text,
  CHECK (to_time > from_time)
);

-- #14 安全库存 / 最小订购量
ALTER TABLE item ADD COLUMN safety_stock numeric(14,4) NOT NULL DEFAULT 0 CHECK (safety_stock >= 0),
                 ADD COLUMN min_order_qty numeric(14,4) NOT NULL DEFAULT 0 CHECK (min_order_qty >= 0);
ALTER TABLE mrp_line ADD COLUMN safety_stock numeric(16,4) NOT NULL DEFAULT 0, ADD COLUMN order_qty numeric(16,4);

-- #6 替代料
CREATE TABLE item_alternative (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  item_id bigint NOT NULL REFERENCES item,
  alt_item_id bigint NOT NULL REFERENCES item,
  conversion_ratio numeric(12,6) NOT NULL DEFAULT 1 CHECK (conversion_ratio > 0),  -- 1 单位主料 = ratio 单位替代料
  priority int NOT NULL DEFAULT 1,
  two_way boolean NOT NULL DEFAULT false,
  UNIQUE (item_id, alt_item_id), CHECK (item_id <> alt_item_id)
);
ALTER TABLE bom_item ADD COLUMN allow_alternative boolean NOT NULL DEFAULT false;

-- #7 序列号
ALTER TABLE item ADD COLUMN has_serial_no boolean NOT NULL DEFAULT false;
CREATE TABLE serial_no (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  item_id bigint NOT NULL REFERENCES item,
  serial_no text NOT NULL,
  status text NOT NULL DEFAULT 'in_stock',
  warehouse_id bigint REFERENCES warehouse,
  work_order_id bigint REFERENCES work_order,          -- 由哪张工单生产
  customer_id bigint REFERENCES party,
  delivery_note_id bigint REFERENCES delivery_note,
  warranty_expiry date,
  UNIQUE (tenant_id, item_id, serial_no)
);
CREATE TABLE serial_ledger (                      -- 每台的出入库履历（只增不改）
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  serial_id bigint NOT NULL REFERENCES serial_no,
  direction text NOT NULL CHECK (direction IN ('in','out')),
  warehouse_id bigint REFERENCES warehouse,
  voucher_type text NOT NULL, voucher_id bigint NOT NULL, voucher_line_id bigint,
  moved_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
INSERT INTO doc_state_rule(doc_table, from_status, to_status) VALUES
 ('serial_no',NULL,'in_stock'),('serial_no','in_stock','delivered'),('serial_no','delivered','returned'),
 ('serial_no','returned','in_stock'),('serial_no','in_stock','scrapped');

-- #15 物料需求单
CREATE TABLE material_request (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('MR'),
  request_type text NOT NULL CHECK (request_type IN ('purchase','issue','replenish')),  -- 采购/领料/补料
  work_order_id bigint REFERENCES work_order,
  job_card_id bigint REFERENCES job_card,
  item_id bigint NOT NULL REFERENCES item,
  warehouse_id bigint REFERENCES warehouse,
  qty numeric(14,4) NOT NULL CHECK (qty > 0),
  ordered_qty numeric(14,4) NOT NULL DEFAULT 0,
  received_qty numeric(14,4) NOT NULL DEFAULT 0,
  per_ordered numeric(6,2) GENERATED ALWAYS AS (round(least(ordered_qty/qty,1)*100,2)) STORED,
  per_received numeric(6,2) GENERATED ALWAYS AS (round(least(received_qty/qty,1)*100,2)) STORED,
  schedule_date date, reason text,
  status text NOT NULL DEFAULT 'draft',
  created_by text NOT NULL DEFAULT app_user(), created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (request_type <> 'replenish' OR work_order_id IS NOT NULL),
  CHECK (received_qty <= qty)
);
ALTER TABLE purchase_order_item ADD COLUMN material_request_id bigint REFERENCES material_request;
INSERT INTO doc_state_rule(doc_table, from_status, to_status) VALUES
 ('material_request',NULL,'draft'),('material_request','draft','submitted'),('material_request','submitted','partially_fulfilled'),
 ('material_request','submitted','fulfilled'),('material_request','partially_fulfilled','fulfilled'),('material_request','submitted','cancelled');

-- #18 质检读数 + 审核人
CREATE TABLE quality_inspection_reading (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  inspection_id bigint NOT NULL REFERENCES quality_inspection,
  parameter text NOT NULL, spec_min numeric, spec_max numeric, reading numeric NOT NULL, sample_no int,
  is_ok boolean GENERATED ALWAYS AS ((spec_min IS NULL OR reading >= spec_min) AND (spec_max IS NULL OR reading <= spec_max)) STORED
);
ALTER TABLE quality_inspection ADD COLUMN reviewed_by text, ADD COLUMN reviewed_at timestamptz;

-- #20 分期收款计划
CREATE TABLE payment_schedule (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  sales_order_id bigint NOT NULL REFERENCES sales_order,
  seq int NOT NULL, term_name text NOT NULL,       -- 预付款/发货款/质保金
  due_date date NOT NULL,
  portion numeric(6,4) NOT NULL CHECK (portion > 0 AND portion <= 1),
  amount numeric(14,2) NOT NULL,
  UNIQUE (sales_order_id, seq)
);

-- #29 AI 字段级置信度与人工确认
CREATE TABLE ai_field_confidence (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  ai_request_id bigint NOT NULL REFERENCES ai_request,
  field text NOT NULL, ai_value text, confidence numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  needs_review boolean GENERATED ALWAYS AS (confidence < 0.8) STORED,
  confirmed_value text, confirmed_by text, confirmed_at timestamptz,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','confirmed','corrected')),
  UNIQUE (ai_request_id, field)
);

-- 挂载审计/状态机/只增不改
SELECT util_attach(t, s, a) FROM (VALUES ('job_card_time_log',false,true),('serial_no',true,false),('serial_ledger',false,true),
  ('material_request',true,false),('item_alternative',false,false),('quality_inspection_reading',false,true),
  ('payment_schedule',false,false),('ai_field_confidence',false,false)) v(t,s,a);

-- 新表 RLS + 权限
DO $$
DECLARE t text; r text;
BEGIN
  FOREACH t IN ARRAY ARRAY['job_card_time_log','item_alternative','serial_no','serial_ledger','material_request','quality_inspection_reading','payment_schedule','ai_field_confidence'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY tenant_isolation ON %I USING (tenant_id = app_tid()) WITH CHECK (tenant_id = app_tid())', t);
    FOREACH r IN ARRAY ARRAY['erp_manager','erp_finance','erp_sales','erp_planner','erp_operator','erp_qc'] LOOP
      EXECUTE format('GRANT SELECT, INSERT, UPDATE ON %I TO %I', t, r);
    END LOOP;
  END LOOP;
  -- 新增的敏感列保持隐藏：已隐藏列的表需重新按列授权
  PERFORM util_hide_columns('erp_sales','item', ARRAY['std_cost']);
  PERFORM util_hide_columns('erp_operator','item', ARRAY['std_cost']);
  PERFORM util_hide_columns('erp_sales','quotation_item', ARRAY['material_cost','machining_cost','heat_treat_cost','surface_cost','purchased_cost','special_cost','overhead_factor','unit_cost']);
  PERFORM util_hide_columns('erp_operator','quotation_item', ARRAY['material_cost','machining_cost','heat_treat_cost','surface_cost','purchased_cost','special_cost','overhead_factor','unit_cost','margin_rate','unit_price','amount','suggested_price']);
  PERFORM util_hide_columns('erp_planner','quotation_item', ARRAY['margin_rate']);
END $$;
REVOKE UPDATE, DELETE ON job_card_time_log, serial_ledger, quality_inspection_reading FROM erp_manager, erp_finance, erp_sales, erp_planner, erp_operator, erp_qc;

-- #24 FORCE RLS：表所有者（非超级用户）也受租户隔离约束
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='erp_owner') THEN CREATE ROLE erp_owner NOLOGIN; END IF;
END $$;
GRANT USAGE, CREATE ON SCHEMA public TO erp_owner;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.relname FROM pg_class c WHERE c.relnamespace='public'::regnamespace AND c.relkind='r' AND c.relrowsecurity LOOP
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', r.relname);
    EXECUTE format('ALTER TABLE %I OWNER TO erp_owner', r.relname);
  END LOOP;
END $$;

-- 成本口径：订单实际成本按与报价相同口径（含管理费系数）比较
CREATE OR REPLACE VIEW v_order_cost_compare WITH (security_invoker = true) AS
SELECT v.*, qi.overhead_factor,
       round(v.unit_actual * qi.overhead_factor, 4) AS unit_actual_with_overhead,
       round(v.unit_actual * qi.overhead_factor - v.unit_quoted_cost, 4) AS cost_variance,
       round(1 - v.unit_actual * qi.overhead_factor / nullif(v.unit_price,0), 4) AS actual_margin_same_basis
FROM v_order_cost_actual v
LEFT JOIN sales_order_item soi ON soi.id=v.sales_order_item_id
LEFT JOIN quotation_item qi ON qi.id=soi.quotation_item_id;
-- migrate:down
