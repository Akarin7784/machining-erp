-- migrate:up
-- 主数据：工厂/仓库、参与方、员工、物料、参数模型、图纸版本、设备、参考参数与来源

CREATE TABLE reference_source (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  url          text,
  title        text,
  fetched_date date,
  is_example   boolean NOT NULL DEFAULT false,
  note         text,
  UNIQUE (url, title)
);

-- 全部价格/工时/费率/规则参数（全局行情，不分租户）
CREATE TABLE ref_param (
  param_key   text PRIMARY KEY,
  name_cn     text NOT NULL,
  value       numeric NOT NULL,
  unit        text NOT NULL,
  range_low   numeric,
  range_high  numeric,
  is_example  boolean NOT NULL DEFAULT false,
  note        text,
  CHECK (range_low IS NULL OR range_high IS NULL OR range_low <= range_high)
);
-- 参数 × 来源（多对多）
CREATE TABLE ref_param_source (
  param_key  text NOT NULL REFERENCES ref_param,
  source_id  bigint NOT NULL REFERENCES reference_source,
  PRIMARY KEY (param_key, source_id)
);
CREATE FUNCTION p(k text) RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE v numeric;
BEGIN IF k IS NULL THEN RETURN NULL; END IF;
  SELECT value INTO v FROM ref_param WHERE param_key=k;
  IF v IS NULL THEN RAISE EXCEPTION '参数 % 不存在', k; END IF; RETURN v; END $$;

CREATE TABLE plant (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  plant_code text NOT NULL, plant_name text NOT NULL,
  UNIQUE (tenant_id, plant_code)
);
CREATE TABLE warehouse (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  plant_id bigint NOT NULL REFERENCES plant,
  wh_code text NOT NULL, wh_name text NOT NULL,
  wh_type text NOT NULL CHECK (wh_type IN ('raw','wip','fg','subcontract','transit','remnant','reject')),
  supplier_id bigint,           -- 外协仓对应的外协厂
  UNIQUE (tenant_id, wh_code)
);

CREATE TABLE party (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  party_type text NOT NULL CHECK (party_type IN ('customer','supplier','subcontractor')),
  party_code text NOT NULL, party_name text NOT NULL,
  tax_no text,                  -- 统一社会信用代码/纳税人识别号
  bank_account text, address_phone text,
  credit_limit numeric(14,2) DEFAULT 0,
  payment_days int NOT NULL DEFAULT 30,
  owner_user text,              -- 负责销售/采购
  UNIQUE (tenant_id, party_code)
);
ALTER TABLE warehouse ADD FOREIGN KEY (supplier_id) REFERENCES party;

CREATE TABLE employee (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  emp_code text NOT NULL, emp_name text NOT NULL,
  plant_id bigint REFERENCES plant,
  pay_mode text NOT NULL DEFAULT 'piece' CHECK (pay_mode IN ('piece','hourly','monthly')),
  base_monthly numeric(12,2),   -- 敏感：工资
  UNIQUE (tenant_id, emp_code)
);

CREATE TABLE uom (code text PRIMARY KEY, name_cn text NOT NULL);
INSERT INTO uom VALUES ('pcs','件'),('kg','千克'),('m','米'),('mm','毫米'),('h','小时'),('dm2','平方分米'),('set','套');

CREATE TABLE item (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  item_code text NOT NULL, item_name text NOT NULL,
  item_kind text NOT NULL CHECK (item_kind IN ('raw','purchased','semi','finished','service')),
  stock_uom text NOT NULL REFERENCES uom,
  material_param_key text REFERENCES ref_param,  -- 原材料对应的行情参数（元/吨）
  density_param_key text REFERENCES ref_param,
  std_cost numeric(14,4),        -- 外购件标准价（敏感）
  is_batch_tracked boolean NOT NULL DEFAULT false,
  current_drawing_id bigint,
  UNIQUE (tenant_id, item_code)
);
CREATE TABLE item_uom_conversion (
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  item_id bigint NOT NULL REFERENCES item, uom text NOT NULL REFERENCES uom,
  factor numeric(18,6) NOT NULL CHECK (factor > 0),   -- 1 uom = factor stock_uom
  PRIMARY KEY (item_id, uom)
);
-- 参数模板（参考 InvenTree 的 PartParameterTemplate 思路，自行实现）
CREATE TABLE param_template (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  name text NOT NULL, unit text, UNIQUE (tenant_id,name)
);
CREATE TABLE item_param (
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  item_id bigint NOT NULL REFERENCES item, template_id bigint NOT NULL REFERENCES param_template,
  value_text text, value_num numeric,
  PRIMARY KEY (item_id, template_id)
);

CREATE TABLE drawing_revision (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  item_id bigint NOT NULL REFERENCES item,
  revision text NOT NULL,
  file_uri text, change_note text,
  status text NOT NULL DEFAULT 'draft',
  released_at timestamptz,
  UNIQUE (item_id, revision)
);
-- 同一物料只能有一个生效版本
CREATE UNIQUE INDEX ux_drawing_one_released ON drawing_revision(item_id) WHERE status='released';
ALTER TABLE item ADD FOREIGN KEY (current_drawing_id) REFERENCES drawing_revision;

CREATE TABLE workstation (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  plant_id bigint NOT NULL REFERENCES plant,
  ws_code text NOT NULL, ws_name text NOT NULL,
  rate_param_key text NOT NULL REFERENCES ref_param,   -- 机时费率参数
  hours_per_day numeric(5,2) NOT NULL DEFAULT 8 CHECK (hours_per_day > 0),
  UNIQUE (tenant_id, ws_code)
);

-- 会计科目（总账）
CREATE TABLE gl_account (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id uuid NOT NULL DEFAULT app_tid() REFERENCES tenant,
  account_code text NOT NULL, account_name text NOT NULL,
  account_type text NOT NULL CHECK (account_type IN ('asset','liability','equity','income','expense')),
  UNIQUE (tenant_id, account_code)
);
-- migrate:down
