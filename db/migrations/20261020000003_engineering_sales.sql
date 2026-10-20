-- migrate:up
-- 技术（BOM、工艺路线）与销售（报价、审批、销售订单）

CREATE TABLE bom (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  item_id bigint NOT NULL REFERENCES item,
  drawing_id bigint REFERENCES drawing_revision,
  quantity numeric(14,4) NOT NULL DEFAULT 1 CHECK (quantity > 0),
  is_default boolean NOT NULL DEFAULT true,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('draft','active','obsolete'))
);
CREATE UNIQUE INDEX ux_bom_default ON bom(item_id) WHERE is_default AND status='active';
CREATE TABLE bom_item (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  bom_id bigint NOT NULL REFERENCES bom ON DELETE CASCADE,
  component_id bigint NOT NULL REFERENCES item,
  qty_per numeric(14,6) NOT NULL CHECK (qty_per > 0),       -- 毛需求（含下料余量）
  net_qty_per numeric(14,6),                                -- 成品净重等，用于热处理计价
  attrition_rate numeric(6,4) NOT NULL DEFAULT 0 CHECK (attrition_rate BETWEEN 0 AND 1),
  issue_at_seq int                                          -- 在第几道工序发料
);

CREATE TABLE routing (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  item_id bigint NOT NULL REFERENCES item,
  routing_name text NOT NULL,
  UNIQUE (item_id)
);
CREATE TABLE routing_operation (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  routing_id bigint NOT NULL REFERENCES routing ON DELETE CASCADE,
  seq int NOT NULL,
  op_name text NOT NULL,
  workstation_id bigint REFERENCES workstation,
  std_hours numeric(10,4) NOT NULL DEFAULT 0 CHECK (std_hours >= 0),   -- 单件标准工时
  setup_hours numeric(10,4) NOT NULL DEFAULT 0,
  is_subcontracted boolean NOT NULL DEFAULT false,
  subcon_price_key text REFERENCES ref_param,                   -- 外协单价参数
  subcon_basis text CHECK (subcon_basis IN ('kg','dm2','pcs')),
  subcon_basis_per_unit numeric(12,4),                          -- 每件计价基数(kg 或 dm2)
  piece_rate numeric(10,4) NOT NULL DEFAULT 0,                  -- 计件单价（敏感，示例）
  qc_required boolean NOT NULL DEFAULT false,
  UNIQUE (routing_id, seq),
  CHECK (NOT is_subcontracted OR (subcon_price_key IS NOT NULL AND subcon_basis IS NOT NULL)),
  CHECK (is_subcontracted OR workstation_id IS NOT NULL)
);

-- 报价
CREATE TABLE quotation (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('QT'),
  customer_id bigint NOT NULL REFERENCES party,
  plant_id bigint REFERENCES plant,
  quote_date date NOT NULL DEFAULT current_date,
  valid_till date,
  revision_of bigint REFERENCES quotation,
  ai_request_id bigint,
  min_margin numeric(6,4) NOT NULL DEFAULT 0.25,
  status text NOT NULL DEFAULT 'draft',
  approved_by text, approved_at timestamptz, approval_note text,
  created_by text NOT NULL DEFAULT app_user(), created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, doc_no)
);
CREATE TABLE quotation_item (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  quotation_id bigint NOT NULL REFERENCES quotation ON DELETE CASCADE,
  item_id bigint NOT NULL REFERENCES item,
  drawing_id bigint REFERENCES drawing_revision,
  qty numeric(14,4) NOT NULL CHECK (qty > 0),
  -- 成本拆分（公式：材料kg价×毛重 + Σ工时×费率 + 热处理费 + 表面处理费 + 特殊费用，再 × 管理费系数）
  material_cost numeric(14,4) NOT NULL DEFAULT 0,
  machining_cost numeric(14,4) NOT NULL DEFAULT 0,
  heat_treat_cost numeric(14,4) NOT NULL DEFAULT 0,
  surface_cost numeric(14,4) NOT NULL DEFAULT 0,
  purchased_cost numeric(14,4) NOT NULL DEFAULT 0,
  special_cost numeric(14,4) NOT NULL DEFAULT 0,
  overhead_factor numeric(6,4) NOT NULL DEFAULT 1,
  unit_cost numeric(14,4) GENERATED ALWAYS AS
    (round((material_cost+machining_cost+heat_treat_cost+surface_cost+purchased_cost+special_cost)*overhead_factor,4)) STORED,
  suggested_price numeric(14,4),
  unit_price numeric(14,4) NOT NULL DEFAULT 0,
  amount numeric(14,2) GENERATED ALWAYS AS (round(qty*unit_price,2)) STORED,
  margin_rate numeric(8,4) GENERATED ALWAYS AS
    (CASE WHEN unit_price>0 THEN round(1 - round((material_cost+machining_cost+heat_treat_cost+surface_cost+purchased_cost+special_cost)*overhead_factor,4)/unit_price,4) END) STORED,
  customer_part_no text
);
CREATE TABLE quotation_cost_line (            -- 每道工序/材料的明细，便于复盘
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  quotation_item_id bigint NOT NULL REFERENCES quotation_item ON DELETE CASCADE,
  cost_type text NOT NULL CHECK (cost_type IN ('material','machining','heat_treat','surface','purchased','special')),
  ref_item_id bigint REFERENCES item, routing_op_id bigint REFERENCES routing_operation,
  basis_qty numeric(14,4) NOT NULL, basis_uom text NOT NULL, unit_rate numeric(14,4) NOT NULL,
  param_key text REFERENCES ref_param,
  amount numeric(14,4) NOT NULL
);

CREATE TABLE sales_order (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('SO'),
  customer_id bigint NOT NULL REFERENCES party,
  plant_id bigint NOT NULL REFERENCES plant,
  quotation_id bigint REFERENCES quotation,
  order_date date NOT NULL DEFAULT current_date,
  delivery_date date,
  status text NOT NULL DEFAULT 'draft',
  created_by text NOT NULL DEFAULT app_user(), created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, doc_no)
);
CREATE TABLE sales_order_item (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  sales_order_id bigint NOT NULL REFERENCES sales_order ON DELETE CASCADE,
  quotation_item_id bigint REFERENCES quotation_item,
  item_id bigint NOT NULL REFERENCES item,
  drawing_id bigint REFERENCES drawing_revision,
  qty numeric(14,4) NOT NULL CHECK (qty > 0),
  unit_price numeric(14,4) NOT NULL CHECK (unit_price >= 0),
  tax_rate numeric(5,4) NOT NULL DEFAULT 0.13,
  delivered_qty numeric(14,4) NOT NULL DEFAULT 0 CHECK (delivered_qty >= 0),
  returned_qty numeric(14,4) NOT NULL DEFAULT 0 CHECK (returned_qty >= 0),
  invoiced_qty numeric(14,4) NOT NULL DEFAULT 0,
  CHECK (delivered_qty <= qty)
);
-- 图纸变更记录（ECN）
CREATE TABLE engineering_change (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('ECN'),
  item_id bigint NOT NULL REFERENCES item,
  from_drawing_id bigint NOT NULL REFERENCES drawing_revision,
  to_drawing_id bigint NOT NULL REFERENCES drawing_revision,
  reason text, affected_wip_qty numeric(14,4) DEFAULT 0, disposition text,
  created_by text NOT NULL DEFAULT app_user(), created_at timestamptz NOT NULL DEFAULT now()
);
-- migrate:down
