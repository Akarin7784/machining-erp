-- migrate:up
-- 成本口径修复：
--   1) 含税行情价入账时 ÷(1+税率) 换算为不含税；报价成本明细同时保留含税/不含税两列，成本一律用不含税。
--   2) 复盘分两层：直接成本（材料、外协、工时）逐行对比，双方都不含税、不乘管理费系数；
--      管理费单独一行，与月末制造费用分摊对比。工时定额修正只能取工时行差异。

-- 参数是否含税
ALTER TABLE ref_param ADD COLUMN tax_included boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN ref_param.tax_included IS '行情价是否含增值税；true 时成本取 value/(1+vat_rate_general)';

-- 报价成本明细：含税与不含税两列；unit_rate/amount 为不含税（成本口径）
ALTER TABLE quotation_cost_line
  ADD COLUMN tax_included boolean NOT NULL DEFAULT false,
  ADD COLUMN unit_rate_gross numeric(14,4),
  ADD COLUMN amount_gross numeric(14,4);
COMMENT ON COLUMN quotation_cost_line.unit_rate IS '不含税单价（成本口径）';
COMMENT ON COLUMN quotation_cost_line.amount IS '不含税金额（成本口径）';
COMMENT ON COLUMN quotation_cost_line.unit_rate_gross IS '含税单价（行情原价；不含税参数与 unit_rate 相同）';
COMMENT ON COLUMN quotation_cost_line.amount_gross IS '含税金额';
ALTER TABLE quotation_cost_line DROP CONSTRAINT quotation_cost_line_cost_type_check;
ALTER TABLE quotation_cost_line ADD CONSTRAINT quotation_cost_line_cost_type_check
  CHECK (cost_type IN ('material','machining','heat_treat','surface','purchased','special','overhead'));

-- 工单成本流水：带上物料/工序，便于逐行对比；新增 overhead（月末分摊）
ALTER TABLE wo_cost_entry ADD COLUMN item_id bigint REFERENCES item, ADD COLUMN routing_op_id bigint REFERENCES routing_operation;
ALTER TABLE wo_cost_entry DROP CONSTRAINT wo_cost_entry_cost_type_check;
ALTER TABLE wo_cost_entry ADD CONSTRAINT wo_cost_entry_cost_type_check
  CHECK (cost_type IN ('material','labor','machine','subcontract','rework','remnant_credit','scrap','purchased','semi_transfer','overhead'));

CREATE OR REPLACE FUNCTION trg_wo_cost_entry_keys() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.item_id IS NULL AND NEW.source_type='stock_ledger' THEN
    SELECT item_id INTO NEW.item_id FROM stock_ledger WHERE id=NEW.source_id;
  ELSIF NEW.item_id IS NULL AND NEW.source_type='remnant' THEN
    SELECT item_id INTO NEW.item_id FROM remnant WHERE id=NEW.source_id;
  ELSIF NEW.routing_op_id IS NULL AND NEW.source_type='job_card' THEN
    SELECT o.routing_op_id INTO NEW.routing_op_id FROM job_card j JOIN wo_operation o ON o.id=j.wo_operation_id WHERE j.id=NEW.source_id;
  ELSIF NEW.routing_op_id IS NULL AND NEW.source_type='subcontract_settlement' THEN
    SELECT o.routing_op_id INTO NEW.routing_op_id FROM subcontract_settlement s JOIN subcontract_order sc ON sc.id=s.subcontract_order_id
      JOIN wo_operation o ON o.id=sc.wo_operation_id WHERE s.id=NEW.source_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER wo_cost_entry_keys BEFORE INSERT ON wo_cost_entry FOR EACH ROW EXECUTE FUNCTION trg_wo_cost_entry_keys();

-- 月末制造费用分摊（按当月报工机时）
CREATE TABLE overhead_allocation (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  period_start date NOT NULL, period_end date NOT NULL,
  pool_amount numeric(14,2) NOT NULL CHECK (pool_amount >= 0),   -- 当月实际制造费用（不含税）
  total_hours numeric(12,4) NOT NULL,
  rate_per_hour numeric(14,6) NOT NULL,
  created_by text NOT NULL DEFAULT app_user(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, period_start)
);
SELECT util_attach('overhead_allocation', false, true);
ALTER TABLE overhead_allocation ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON overhead_allocation USING (tenant_id = app_tid()) WITH CHECK (tenant_id = app_tid());
ALTER TABLE overhead_allocation FORCE ROW LEVEL SECURITY;
ALTER TABLE overhead_allocation OWNER TO erp_owner;
GRANT SELECT, INSERT ON overhead_allocation TO erp_manager, erp_finance;
GRANT SELECT ON overhead_allocation TO erp_planner;

-- 工时定额修正只能来自工时行差异
ALTER TABLE ai_cost_review
  ADD COLUMN line_type text NOT NULL DEFAULT 'hours' CHECK (line_type = 'hours'),
  ADD COLUMN sales_order_item_id bigint REFERENCES sales_order_item,
  ADD COLUMN std_hours_total numeric(12,4), ADD COLUMN actual_hours_total numeric(12,4),
  ADD COLUMN variance_hours numeric(12,4);
ALTER TABLE ai_cost_review ALTER COLUMN work_order_id DROP NOT NULL;
-- migrate:down
