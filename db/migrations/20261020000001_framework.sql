-- migrate:up
-- 基础框架：多租户上下文、审计日志、只增不改流水保护、单据状态机
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE tenant (
  tenant_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_code text NOT NULL UNIQUE,
  tenant_name text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- 当前租户：由应用在会话里 SET app.tenant_id
CREATE FUNCTION app_tid() RETURNS uuid LANGUAGE sql STABLE AS
$$ SELECT nullif(current_setting('app.tenant_id', true), '')::uuid $$;
CREATE FUNCTION app_user() RETURNS text LANGUAGE sql STABLE AS
$$ SELECT coalesce(nullif(current_setting('app.user', true), ''), current_user) $$;

-- 审计日志（只增不改）
CREATE TABLE audit_log (
  audit_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tenant_id   uuid,
  table_name  text NOT NULL,
  row_pk      text,
  action      text NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
  old_data    jsonb,
  new_data    jsonb,
  actor       text NOT NULL DEFAULT app_user(),
  acted_at    timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE FUNCTION trg_audit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE r jsonb; o jsonb;
BEGIN
  IF TG_OP <> 'DELETE' THEN r := to_jsonb(NEW); END IF;
  IF TG_OP <> 'INSERT' THEN o := to_jsonb(OLD); END IF;
  INSERT INTO audit_log(tenant_id, table_name, row_pk, action, old_data, new_data)
  VALUES (coalesce((r->>'tenant_id')::uuid,(o->>'tenant_id')::uuid), TG_TABLE_NAME,
          coalesce(r->>'id', o->>'id'), TG_OP, o, r);
  RETURN coalesce(NEW, OLD);
END $$;

-- 流水表保护：禁止 UPDATE / DELETE
CREATE FUNCTION trg_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% 是只增不改的流水表，禁止 %；请用冲销记录更正', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'EP001';
END $$;

-- 单据状态机规则
CREATE TABLE doc_state_rule (
  doc_table   text NOT NULL,
  from_status text,            -- NULL 表示新建时允许的初始状态
  to_status   text NOT NULL,
  note        text,
  UNIQUE (doc_table, from_status, to_status)
);

CREATE FUNCTION trg_state_machine() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT EXISTS (SELECT 1 FROM doc_state_rule WHERE doc_table=TG_TABLE_NAME AND from_status IS NULL AND to_status=NEW.status) THEN
      RAISE EXCEPTION '%: 新建单据不能是状态 %', TG_TABLE_NAME, NEW.status USING ERRCODE='EP002';
    END IF;
  ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT EXISTS (SELECT 1 FROM doc_state_rule WHERE doc_table=TG_TABLE_NAME AND from_status=OLD.status AND to_status=NEW.status) THEN
      RAISE EXCEPTION '%: 不允许的状态迁移 % -> %', TG_TABLE_NAME, OLD.status, NEW.status USING ERRCODE='EP002';
    END IF;
  ELSIF OLD.status IN ('cancelled','closed','completed','posted','paid','settled') AND TG_TABLE_NAME NOT IN ('sales_order','work_order','purchase_order','subcontract_order') THEN
    -- 终态单据不可再改内容（主单据的进度字段除外）
    RAISE EXCEPTION '%: 终态单据(%)不可修改', TG_TABLE_NAME, OLD.status USING ERRCODE='EP003';
  END IF;
  RETURN NEW;
END $$;

-- 帮助过程：为表挂上租户默认值、审计、状态机
CREATE FUNCTION util_attach(p_table text, p_state boolean DEFAULT false, p_append_only boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION trg_audit()', p_table||'_audit', p_table);
  IF p_state THEN
    EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION trg_state_machine()', p_table||'_state', p_table);
  END IF;
  IF p_append_only THEN
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION trg_append_only()', p_table||'_append_only', p_table);
  END IF;
END $$;

CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION trg_append_only();

-- 单据编号
CREATE TABLE doc_sequence (tenant_id uuid NOT NULL, prefix text NOT NULL, last_no int NOT NULL DEFAULT 0, PRIMARY KEY(tenant_id,prefix));
CREATE FUNCTION next_doc_no(p_prefix text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  INSERT INTO doc_sequence(tenant_id,prefix,last_no) VALUES (app_tid(),p_prefix,1)
  ON CONFLICT (tenant_id,prefix) DO UPDATE SET last_no=doc_sequence.last_no+1 RETURNING last_no INTO n;
  RETURN p_prefix||'-'||lpad(n::text,5,'0');
END $$;
-- migrate:down
