-- migrate:up
-- 库存流水、余料、调拨、采购、质检、计划、生产、委外

CREATE TABLE stock_ledger (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  plant_id bigint NOT NULL REFERENCES plant,
  warehouse_id bigint NOT NULL REFERENCES warehouse,
  item_id bigint NOT NULL REFERENCES item,
  batch_no text,
  posting_ts timestamptz NOT NULL DEFAULT clock_timestamp(),
  voucher_type text NOT NULL,
  voucher_id bigint NOT NULL,
  voucher_line_id bigint,
  qty numeric(16,4) NOT NULL CHECK (qty <> 0),          -- 正入负出
  incoming_rate numeric(16,6),                          -- 入库单价（入库时必填）
  valuation_rate numeric(16,6),                         -- 移动加权平均价（触发器计算）
  value_change numeric(16,4),                           -- 金额变动（触发器计算）
  qty_after numeric(16,4),
  value_after numeric(16,4),
  work_order_id bigint,
  is_reversal boolean NOT NULL DEFAULT false,
  reverses_id bigint REFERENCES stock_ledger,
  created_by text NOT NULL DEFAULT app_user()
);
CREATE UNIQUE INDEX ux_stock_ledger_reversed_once ON stock_ledger(reverses_id) WHERE reverses_id IS NOT NULL;
CREATE INDEX ix_stock_ledger_item_wh ON stock_ledger(tenant_id, item_id, warehouse_id, id);
CREATE INDEX ix_stock_ledger_voucher ON stock_ledger(voucher_type, voucher_id);

CREATE FUNCTION trg_stock_ledger_value() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE pq numeric := 0; pv numeric := 0; o stock_ledger;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.tenant_id::text||':'||NEW.item_id||':'||NEW.warehouse_id,0));
  SELECT qty_after, value_after INTO pq, pv FROM stock_ledger
   WHERE tenant_id=NEW.tenant_id AND item_id=NEW.item_id AND warehouse_id=NEW.warehouse_id
   ORDER BY id DESC LIMIT 1;
  pq := coalesce(pq,0); pv := coalesce(pv,0);
  IF NEW.is_reversal THEN
    SELECT * INTO o FROM stock_ledger WHERE id=NEW.reverses_id;
    IF o.id IS NULL OR o.is_reversal THEN RAISE EXCEPTION '冲销目标不存在或本身是冲销'; END IF;
    NEW.qty := -o.qty; NEW.value_change := -o.value_change; NEW.valuation_rate := o.valuation_rate;
  ELSIF NEW.qty > 0 THEN
    IF NEW.incoming_rate IS NULL THEN RAISE EXCEPTION '入库必须给出 incoming_rate'; END IF;
    NEW.value_change := round(NEW.qty*NEW.incoming_rate,4);
  ELSE
    IF pq <= 0 THEN RAISE EXCEPTION '库存不足：物料 % 仓库 % 现存 %，需出 %', NEW.item_id, NEW.warehouse_id, pq, -NEW.qty; END IF;
    NEW.valuation_rate := pv/pq;
    NEW.value_change := round(NEW.qty*pv/pq,4);
    IF -NEW.qty = pq THEN NEW.value_change := -pv; END IF;
  END IF;
  NEW.qty_after := pq + NEW.qty;
  NEW.value_after := pv + NEW.value_change;
  IF NEW.qty_after < 0 THEN
    RAISE EXCEPTION '库存不足：物料 % 仓库 % 现存 %，需出 %', NEW.item_id, NEW.warehouse_id, pq, -NEW.qty;
  END IF;
  IF NEW.qty_after > 0 THEN NEW.valuation_rate := coalesce(NEW.valuation_rate, NEW.value_after/NEW.qty_after); END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER stock_ledger_value BEFORE INSERT ON stock_ledger FOR EACH ROW EXECUTE FUNCTION trg_stock_ledger_value();

CREATE VIEW v_stock_balance AS
SELECT DISTINCT ON (tenant_id, item_id, warehouse_id)
       tenant_id, plant_id, warehouse_id, item_id, qty_after AS qty, value_after AS value,
       CASE WHEN qty_after<>0 THEN round(value_after/qty_after,6) END AS avg_rate
FROM stock_ledger ORDER BY tenant_id, item_id, warehouse_id, id DESC;

-- 余料（边角料/短料）登记，可再利用
CREATE TABLE remnant (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  item_id bigint NOT NULL REFERENCES item,
  warehouse_id bigint NOT NULL REFERENCES warehouse,
  length_mm numeric(10,2), diameter_mm numeric(10,2),
  weight_kg numeric(12,4) NOT NULL CHECK (weight_kg > 0),
  unit_value numeric(14,6) NOT NULL,               -- 回库计价（元/kg）
  source_work_order_id bigint, reused_work_order_id bigint,
  status text NOT NULL DEFAULT 'available',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 多工厂调拨
CREATE TABLE stock_transfer (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('TR'),
  from_warehouse_id bigint NOT NULL REFERENCES warehouse,
  transit_warehouse_id bigint NOT NULL REFERENCES warehouse,
  to_warehouse_id bigint NOT NULL REFERENCES warehouse,
  item_id bigint NOT NULL REFERENCES item,
  qty numeric(14,4) NOT NULL CHECK (qty > 0),
  status text NOT NULL DEFAULT 'draft',
  shipped_at timestamptz, received_at timestamptz,
  CHECK (from_warehouse_id <> to_warehouse_id)
);

-- 采购
CREATE TABLE purchase_order (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('PO'),
  supplier_id bigint NOT NULL REFERENCES party,
  plant_id bigint NOT NULL REFERENCES plant,
  order_date date NOT NULL DEFAULT current_date,
  status text NOT NULL DEFAULT 'draft',
  created_by text NOT NULL DEFAULT app_user()
);
CREATE TABLE purchase_order_item (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  purchase_order_id bigint NOT NULL REFERENCES purchase_order ON DELETE CASCADE,
  item_id bigint NOT NULL REFERENCES item,
  mrp_line_id bigint,
  qty numeric(14,4) NOT NULL CHECK (qty > 0),
  unit_price numeric(14,6) NOT NULL CHECK (unit_price >= 0),   -- 含税价
  tax_rate numeric(5,4) NOT NULL DEFAULT 0.13,
  received_qty numeric(14,4) NOT NULL DEFAULT 0,
  rejected_qty numeric(14,4) NOT NULL DEFAULT 0,
  invoiced_qty numeric(14,4) NOT NULL DEFAULT 0,
  CHECK (received_qty <= qty * 1.05)
);
CREATE TABLE purchase_receipt (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('PR'),
  purchase_order_id bigint NOT NULL REFERENCES purchase_order,
  warehouse_id bigint NOT NULL REFERENCES warehouse,
  receipt_date date NOT NULL DEFAULT current_date,
  status text NOT NULL DEFAULT 'draft'
);
CREATE TABLE purchase_receipt_item (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  purchase_receipt_id bigint NOT NULL REFERENCES purchase_receipt ON DELETE CASCADE,
  po_item_id bigint NOT NULL REFERENCES purchase_order_item,
  item_id bigint NOT NULL REFERENCES item,
  batch_no text,
  received_qty numeric(14,4) NOT NULL CHECK (received_qty > 0),
  accepted_qty numeric(14,4), rejected_qty numeric(14,4)
);

-- 质检（来料/工序/成品）
CREATE TABLE quality_inspection (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('QI'),
  inspection_type text NOT NULL CHECK (inspection_type IN ('incoming','process','final','subcontract')),
  ref_type text NOT NULL, ref_id bigint NOT NULL,
  item_id bigint NOT NULL REFERENCES item,
  inspected_qty numeric(14,4) NOT NULL CHECK (inspected_qty > 0),
  accepted_qty numeric(14,4) NOT NULL DEFAULT 0,
  rework_qty numeric(14,4) NOT NULL DEFAULT 0,
  scrap_qty numeric(14,4) NOT NULL DEFAULT 0,
  concession_qty numeric(14,4) NOT NULL DEFAULT 0,          -- 让步接收
  defect_note text, inspected_by text NOT NULL DEFAULT app_user(),
  status text NOT NULL DEFAULT 'draft',
  CHECK (accepted_qty+rework_qty+scrap_qty+concession_qty <= inspected_qty)
);

-- 计划：MRP
CREATE TABLE production_plan (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('PP'),
  sales_order_id bigint NOT NULL REFERENCES sales_order,
  plant_id bigint NOT NULL REFERENCES plant,
  status text NOT NULL DEFAULT 'draft',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE mrp_line (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  production_plan_id bigint NOT NULL REFERENCES production_plan ON DELETE CASCADE,
  item_id bigint NOT NULL REFERENCES item,
  bom_level int NOT NULL,
  parent_item_id bigint REFERENCES item,
  gross_qty numeric(16,4) NOT NULL,
  on_hand_qty numeric(16,4) NOT NULL DEFAULT 0,
  net_qty numeric(16,4) NOT NULL,
  action text NOT NULL CHECK (action IN ('make','buy','none')),
  UNIQUE (production_plan_id, item_id, parent_item_id)
);
ALTER TABLE purchase_order_item ADD FOREIGN KEY (mrp_line_id) REFERENCES mrp_line;

-- 生产
CREATE TABLE work_order (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('WO'),
  plant_id bigint NOT NULL REFERENCES plant,
  item_id bigint NOT NULL REFERENCES item,
  drawing_id bigint REFERENCES drawing_revision,
  bom_id bigint REFERENCES bom,
  sales_order_item_id bigint REFERENCES sales_order_item,
  production_plan_id bigint REFERENCES production_plan,
  parent_work_order_id bigint REFERENCES work_order,
  qty numeric(14,4) NOT NULL CHECK (qty > 0),
  produced_qty numeric(14,4) NOT NULL DEFAULT 0,
  scrap_qty numeric(14,4) NOT NULL DEFAULT 0,
  fg_warehouse_id bigint REFERENCES warehouse,
  planned_start date, planned_end date,
  status text NOT NULL DEFAULT 'draft',
  CHECK (produced_qty <= qty)
);
ALTER TABLE stock_ledger ADD FOREIGN KEY (work_order_id) REFERENCES work_order;
ALTER TABLE remnant ADD FOREIGN KEY (source_work_order_id) REFERENCES work_order, ADD FOREIGN KEY (reused_work_order_id) REFERENCES work_order;

CREATE TABLE wo_operation (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  work_order_id bigint NOT NULL REFERENCES work_order ON DELETE CASCADE,
  routing_op_id bigint REFERENCES routing_operation,
  seq int NOT NULL, op_name text NOT NULL,
  workstation_id bigint REFERENCES workstation,
  std_hours numeric(10,4) NOT NULL, is_subcontracted boolean NOT NULL DEFAULT false,
  piece_rate numeric(10,4) NOT NULL DEFAULT 0,
  input_qty numeric(14,4) NOT NULL DEFAULT 0,       -- 流入本工序的合格数
  completed_qty numeric(14,4) NOT NULL DEFAULT 0,
  scrap_qty numeric(14,4) NOT NULL DEFAULT 0,
  rework_pending_qty numeric(14,4) NOT NULL DEFAULT 0,
  sched_start timestamptz, sched_end timestamptz,
  status text NOT NULL DEFAULT 'pending',
  UNIQUE (work_order_id, seq)
);

-- 报工（只增不改）
CREATE TABLE job_card (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('JC'),
  wo_operation_id bigint NOT NULL REFERENCES wo_operation,
  employee_id bigint NOT NULL REFERENCES employee,
  workstation_id bigint REFERENCES workstation,
  drawing_id bigint REFERENCES drawing_revision,      -- 报工时依据的图纸版本（必须为生效版）
  good_qty numeric(14,4) NOT NULL DEFAULT 0 CHECK (good_qty >= 0),
  scrap_qty numeric(14,4) NOT NULL DEFAULT 0 CHECK (scrap_qty >= 0),
  hours numeric(10,4) NOT NULL CHECK (hours >= 0),
  started_at timestamptz, finished_at timestamptz,
  is_rework boolean NOT NULL DEFAULT false,
  rework_of_inspection_id bigint REFERENCES quality_inspection,
  piece_wage numeric(12,2) NOT NULL DEFAULT 0,       -- 计件工资（敏感，触发器计算）
  machine_cost numeric(12,2) NOT NULL DEFAULT 0,     -- 机时成本（敏感）
  reported_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CHECK (good_qty + scrap_qty > 0 OR hours > 0)
);

-- 工单成本流水（只增不改）
CREATE TABLE wo_cost_entry (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  work_order_id bigint NOT NULL REFERENCES work_order,
  cost_type text NOT NULL CHECK (cost_type IN ('material','labor','machine','subcontract','rework','remnant_credit','scrap','purchased','semi_transfer')),
  amount numeric(14,4) NOT NULL,
  qty numeric(14,4), hours numeric(10,4),
  source_type text NOT NULL, source_id bigint NOT NULL,
  posted_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- 有限能力排产结果
CREATE TABLE schedule_slot (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  wo_operation_id bigint NOT NULL REFERENCES wo_operation ON DELETE CASCADE,
  workstation_id bigint NOT NULL REFERENCES workstation,
  work_date date NOT NULL,
  hours numeric(8,4) NOT NULL CHECK (hours > 0)
);
CREATE INDEX ix_schedule_ws_date ON schedule_slot(workstation_id, work_date);

-- 委外
CREATE TABLE subcontract_order (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('SC'),
  supplier_id bigint NOT NULL REFERENCES party,
  wo_operation_id bigint NOT NULL REFERENCES wo_operation,
  subcon_warehouse_id bigint REFERENCES warehouse,
  price_param_key text NOT NULL REFERENCES ref_param,
  price_basis text NOT NULL CHECK (price_basis IN ('kg','dm2','pcs')),
  basis_per_unit numeric(12,4) NOT NULL,           -- 每件 kg 或 dm²
  unit_price numeric(14,6) NOT NULL,               -- 单价（元/kg、元/dm²、元/件）快照
  loss_allowance numeric(6,4) NOT NULL,            -- 损耗定额（比例）
  part_value numeric(14,4) NOT NULL DEFAULT 0,     -- 超定额短少/不良的扣款单价（元/件）
  sent_qty numeric(14,4) NOT NULL DEFAULT 0,
  received_good_qty numeric(14,4) NOT NULL DEFAULT 0,
  received_defect_qty numeric(14,4) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'draft',
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (received_good_qty + received_defect_qty <= sent_qty)
);
CREATE TABLE subcontract_movement (            -- 发料/回料（只增不改）
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  subcontract_order_id bigint NOT NULL REFERENCES subcontract_order,
  movement_type text NOT NULL CHECK (movement_type IN ('send','receive')),
  good_qty numeric(14,4) NOT NULL DEFAULT 0 CHECK (good_qty >= 0),
  defect_qty numeric(14,4) NOT NULL DEFAULT 0 CHECK (defect_qty >= 0),
  delivery_note_no text,
  moved_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
-- 委外结算（关闭时生成）：加工费 - 超定额扣款
CREATE TABLE subcontract_settlement (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  subcontract_order_id bigint NOT NULL UNIQUE REFERENCES subcontract_order,
  sent_qty numeric(14,4) NOT NULL, good_qty numeric(14,4) NOT NULL, defect_qty numeric(14,4) NOT NULL,
  shortage_qty numeric(14,4) NOT NULL,
  allowance_qty numeric(14,4) NOT NULL,
  over_loss_qty numeric(14,4) NOT NULL,
  processing_fee numeric(14,2) NOT NULL,
  deduction numeric(14,2) NOT NULL,
  payable_amount numeric(14,2) NOT NULL,
  settled_at timestamptz NOT NULL DEFAULT now()
);
-- migrate:down
