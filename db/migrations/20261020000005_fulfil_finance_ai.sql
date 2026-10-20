-- migrate:up
-- 发货/退货、发票（增值税专票/普票）、应收应付流水、收付款核销、总账、月结、AI

CREATE TABLE delivery_note (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('DN'),
  customer_id bigint NOT NULL REFERENCES party,
  plant_id bigint NOT NULL REFERENCES plant,
  posting_date date NOT NULL DEFAULT current_date,
  is_return boolean NOT NULL DEFAULT false,
  return_against bigint REFERENCES delivery_note,
  return_reason text,
  status text NOT NULL DEFAULT 'draft',
  CHECK (NOT is_return OR return_against IS NOT NULL)
);
CREATE TABLE delivery_note_item (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  delivery_note_id bigint NOT NULL REFERENCES delivery_note ON DELETE CASCADE,
  so_item_id bigint NOT NULL REFERENCES sales_order_item,
  item_id bigint NOT NULL REFERENCES item,
  warehouse_id bigint NOT NULL REFERENCES warehouse,
  qty numeric(14,4) NOT NULL CHECK (qty > 0),     -- 退货单也填正数
  unit_price numeric(14,4) NOT NULL,
  return_against_item_id bigint REFERENCES delivery_note_item
);

-- 增值税发票（销项 sales / 进项 purchase）。不对接税局，可导出。
CREATE TABLE invoice (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('INV'),
  direction text NOT NULL CHECK (direction IN ('sales','purchase')),
  invoice_kind text NOT NULL CHECK (invoice_kind IN ('vat_special','vat_normal')),  -- 专票/普票
  is_red boolean NOT NULL DEFAULT false,            -- 红字发票（退货冲减）
  red_of bigint REFERENCES invoice,
  party_id bigint NOT NULL REFERENCES party,
  buyer_name text NOT NULL, buyer_tax_no text, buyer_addr_phone text, buyer_bank_account text,
  seller_name text NOT NULL, seller_tax_no text,
  invoice_code text, invoice_no text,               -- 税局号码（外部录入）
  invoice_date date NOT NULL DEFAULT current_date,
  due_date date,
  amount_ex_tax numeric(14,2) NOT NULL DEFAULT 0,
  tax_amount numeric(14,2) NOT NULL DEFAULT 0,
  total_amount numeric(14,2) GENERATED ALWAYS AS (amount_ex_tax + tax_amount) STORED,
  source_type text, source_id bigint,
  status text NOT NULL DEFAULT 'draft',
  CHECK (invoice_kind <> 'vat_special' OR buyer_tax_no IS NOT NULL),
  CHECK (NOT is_red OR red_of IS NOT NULL)
);
CREATE TABLE invoice_item (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  invoice_id bigint NOT NULL REFERENCES invoice ON DELETE CASCADE,
  goods_name text NOT NULL, spec text, uom text,
  qty numeric(14,4) NOT NULL,
  unit_price_ex_tax numeric(16,8) NOT NULL,
  amount_ex_tax numeric(14,2) NOT NULL,
  tax_rate numeric(5,4) NOT NULL CHECK (tax_rate IN (0,0.03,0.06,0.09,0.13)),
  tax_amount numeric(14,2) NOT NULL,
  source_line_type text, source_line_id bigint
);

-- 应收/应付流水（只增不改）：amount 正数=债权/债务增加，负数=减少
CREATE TABLE payment_ledger (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  ledger_type text NOT NULL CHECK (ledger_type IN ('receivable','payable')),
  party_id bigint NOT NULL REFERENCES party,
  posting_date date NOT NULL,
  voucher_type text NOT NULL, voucher_id bigint NOT NULL,
  against_invoice_id bigint REFERENCES invoice,
  amount numeric(14,2) NOT NULL,
  due_date date,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ix_payment_ledger_party ON payment_ledger(tenant_id, party_id, ledger_type);

CREATE TABLE payment_entry (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('PAY'),
  payment_type text NOT NULL CHECK (payment_type IN ('receive','pay')),
  party_id bigint NOT NULL REFERENCES party,
  posting_date date NOT NULL DEFAULT current_date,
  mode_of_payment text NOT NULL DEFAULT 'bank',
  paid_amount numeric(14,2) NOT NULL CHECK (paid_amount > 0),
  status text NOT NULL DEFAULT 'draft'
);
CREATE TABLE payment_allocation (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  payment_entry_id bigint NOT NULL REFERENCES payment_entry ON DELETE CASCADE,
  invoice_id bigint NOT NULL REFERENCES invoice,
  allocated_amount numeric(14,2) NOT NULL CHECK (allocated_amount > 0)
);

-- 总账
CREATE TABLE journal_entry (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  doc_no text NOT NULL DEFAULT next_doc_no('JE'),
  posting_date date NOT NULL,
  period text NOT NULL,                          -- YYYY-MM
  voucher_type text NOT NULL, voucher_id bigint NOT NULL,
  memo text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE gl_entry (                          -- 只增不改
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  journal_entry_id bigint NOT NULL REFERENCES journal_entry,
  account_id bigint NOT NULL REFERENCES gl_account,
  plant_id bigint REFERENCES plant,
  party_id bigint REFERENCES party,
  work_order_id bigint REFERENCES work_order,
  debit numeric(14,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit numeric(14,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  CHECK ((debit = 0) <> (credit = 0))
);
-- 凭证借贷必须平衡（延迟到提交时检查）
CREATE FUNCTION trg_je_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE d numeric; c numeric;
BEGIN
  SELECT sum(debit), sum(credit) INTO d, c FROM gl_entry WHERE journal_entry_id = NEW.journal_entry_id;
  IF d <> c THEN RAISE EXCEPTION '凭证 % 借贷不平：借 % 贷 %', NEW.journal_entry_id, d, c; END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER gl_entry_balanced AFTER INSERT ON gl_entry
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION trg_je_balanced();

-- 会计期间（月结后禁止过账）
CREATE TABLE accounting_period (
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  period text NOT NULL, status text NOT NULL DEFAULT 'open',
  closed_at timestamptz, PRIMARY KEY (tenant_id, period)
);
CREATE FUNCTION trg_je_period_open() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM accounting_period WHERE tenant_id=NEW.tenant_id AND period=NEW.period AND status='closed') THEN
    RAISE EXCEPTION '期间 % 已结账，不能过账', NEW.period;
  END IF; RETURN NEW;
END $$;
CREATE TRIGGER journal_entry_period BEFORE INSERT ON journal_entry FOR EACH ROW EXECUTE FUNCTION trg_je_period_open();

-- 客户月度对账单（快照）
CREATE TABLE customer_statement (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  party_id bigint NOT NULL REFERENCES party,
  period text NOT NULL,
  opening_balance numeric(14,2) NOT NULL, debit_total numeric(14,2) NOT NULL,
  credit_total numeric(14,2) NOT NULL, closing_balance numeric(14,2) NOT NULL,
  delivered_not_invoiced numeric(14,2) NOT NULL DEFAULT 0,
  lines jsonb NOT NULL,
  generated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (party_id, period)
);

-- AI
CREATE TABLE ai_request (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  kind text NOT NULL CHECK (kind IN ('drawing_quote','subcon_statement_check','cost_review','leadtime_predict')),
  input jsonb NOT NULL, output jsonb,
  model text, prompt_version text, latency_ms int, cost_cny numeric(10,4),
  status text NOT NULL DEFAULT 'pending',
  requested_by text NOT NULL DEFAULT app_user(), created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE quotation ADD FOREIGN KEY (ai_request_id) REFERENCES ai_request;
CREATE TABLE ai_drawing_feature (                -- 读图结果
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  ai_request_id bigint NOT NULL REFERENCES ai_request,
  material_code text, stock_diameter_mm numeric, stock_length_mm numeric,
  finished_weight_kg numeric, plated_area_dm2 numeric,
  tightest_tolerance_mm numeric, surface_treatment text, heat_treatment text,
  similar_item_id bigint REFERENCES item, confidence numeric(4,3) CHECK (confidence BETWEEN 0 AND 1)
);
CREATE TABLE ai_subcon_check_line (             -- 委外对账单核对差异
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  ai_request_id bigint NOT NULL REFERENCES ai_request,
  subcontract_order_id bigint REFERENCES subcontract_order,
  field text NOT NULL, statement_value numeric, system_value numeric, diff numeric,
  verdict text NOT NULL CHECK (verdict IN ('match','mismatch','missing_in_system','missing_in_statement'))
);
CREATE TABLE ai_cost_review (                   -- 完工复盘：修正工时定额
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  ai_request_id bigint REFERENCES ai_request,
  work_order_id bigint NOT NULL REFERENCES work_order,
  routing_op_id bigint NOT NULL REFERENCES routing_operation,
  quoted_hours numeric(10,4) NOT NULL, actual_hours_per_unit numeric(10,4) NOT NULL,
  proposed_hours numeric(10,4) NOT NULL, applied boolean NOT NULL DEFAULT false,
  applied_by text, applied_at timestamptz
);
CREATE TABLE ai_leadtime_prediction (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  ai_request_id bigint REFERENCES ai_request,
  sales_order_id bigint NOT NULL REFERENCES sales_order,
  baseline_finish date NOT NULL,      -- SQL 排产给出的完工日
  predicted_finish date NOT NULL, p90_finish date, risk_note text
);
-- migrate:down
