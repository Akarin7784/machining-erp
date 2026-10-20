#!/usr/bin/env python3
"""从已建好的数据库 + 迁移脚本中的行尾注释，生成 docs/03_数据字典.md 与 docs/04_单据状态迁移表.md。
由 scripts/run_all.sh 在 GEN_DOCS=1 时调用（需要 PG* 环境变量指向数据库）。"""
import os, re, subprocess, pathlib, collections
ROOT = pathlib.Path(__file__).resolve().parent.parent
DB = os.environ.get('ERP_DB', 'machining_erp')

def q(sql):
    out = subprocess.run(['psql', '-X', '-At', '-F', '\t', '-d', DB, '-c', sql], check=True, capture_output=True, text=True).stdout
    return [l.split('\t') for l in out.splitlines() if l]

# 1) 迁移脚本中的说明：表头注释与列行尾注释
col_note, tbl_note = {}, {}
for f in sorted((ROOT/'db/migrations').glob('*.sql')):
    cur, prev_comment = None, None
    for line in f.read_text(encoding='utf-8').splitlines():
        m = re.match(r'\s*CREATE TABLE (\w+)', line)
        if m:
            cur = m.group(1)
            c = re.search(r'--\s*(.+)$', line)
            tbl_note[cur] = (c.group(1) if c else '') or (prev_comment or '')
            continue
        if line.startswith(')'): cur = None
        if line.startswith('--'): prev_comment = line.lstrip('- ').strip()
        if cur:
            m = re.match(r'\s*(\w+)\s+[\w(]', line)
            c = re.search(r'--\s*(.+)$', line)
            if m and c: col_note[(cur, m.group(1))] = c.group(1).strip()
COMMON = {'id':'主键(自增)','tenant_id':'租户 ID，RLS 隔离键','doc_no':'单据编号(按前缀自动编号)','status':'单据状态，迁移规则见 04',
          'created_by':'创建人','created_at':'创建时间','item_id':'物料','party_id':'往来单位','plant_id':'工厂','warehouse_id':'仓库',
          'work_order_id':'工单','customer_id':'客户','supplier_id':'供应商/外协厂','qty':'数量','unit_price':'单价',
          'voucher_type':'来源单据类型','voucher_id':'来源单据 ID','posting_date':'过账日期','drawing_id':'图纸版本'}

for line in (ROOT/'scripts/column_notes.tsv').read_text(encoding='utf-8').splitlines():
    k, _, v = line.partition('\t'); COMMON.setdefault(k, v)

cols = q("""SELECT c.table_name, c.column_name, c.data_type || coalesce('('||c.character_maximum_length||')','') ||
            CASE WHEN c.data_type='numeric' AND c.numeric_precision IS NOT NULL THEN '('||c.numeric_precision||','||c.numeric_scale||')' ELSE '' END,
            c.is_nullable, coalesce(c.column_default,''), c.is_generated
           FROM information_schema.columns c JOIN information_schema.tables t USING (table_schema, table_name)
           WHERE c.table_schema='public' AND t.table_type='BASE TABLE' ORDER BY c.table_name, c.ordinal_position""")
pk = {(r[0], r[1]) for r in q("""SELECT tc.table_name, kcu.column_name FROM information_schema.table_constraints tc
      JOIN information_schema.key_column_usage kcu USING (constraint_schema, constraint_name) WHERE tc.constraint_type='PRIMARY KEY' AND tc.table_schema='public'""")}
fk = {(r[0], r[1]): r[2] for r in q("""SELECT cl.relname, a.attname, fcl.relname FROM pg_constraint co JOIN pg_class cl ON cl.oid=co.conrelid
      JOIN pg_class fcl ON fcl.oid=co.confrelid JOIN pg_attribute a ON a.attrelid=co.conrelid AND a.attnum=ANY(co.conkey)
      WHERE co.contype='f' AND cl.relnamespace='public'::regnamespace""")}
checks = collections.defaultdict(list)
for t, d in q("""SELECT cl.relname, pg_get_constraintdef(co.oid) FROM pg_constraint co JOIN pg_class cl ON cl.oid=co.conrelid
                 WHERE co.contype IN ('c','u') AND cl.relnamespace='public'::regnamespace ORDER BY 1,2"""):
    checks[t].append(d)
trig = collections.defaultdict(list)
for t, n in q("""SELECT c.relname, tg.tgname FROM pg_trigger tg JOIN pg_class c ON c.oid=tg.tgrelid
                 WHERE NOT tg.tgisinternal AND c.relnamespace='public'::regnamespace ORDER BY 1,2"""):
    trig[t].append(n)
rls = {r[0] for r in q("SELECT relname FROM pg_class WHERE relrowsecurity AND relnamespace='public'::regnamespace")}

out = ['# 03 数据字典', '', '> 本文件由 `scripts/gen_docs.py` 从数据库目录和迁移脚本注释自动生成，请勿手改。',
       f'> 表数量：{len({c[0] for c in cols})}。约定：所有业务表含 `tenant_id` 并启用 RLS；金额 numeric(14,2)，单价/工时用更高精度。', '']
by_t = collections.defaultdict(list)
for c in cols: by_t[c[0]].append(c)
for t in sorted(by_t):
    out += [f'## {t}', '', (tbl_note.get(t) or '').strip() or '', '',
            f"RLS：{'启用' if t in rls else '无（全局表）'}；触发器：{', '.join(trig[t]) or '无'}", '',
            '| 字段 | 类型 | 约束 | 说明 |', '|---|---|---|---|']
    for _, col, typ, nul, dflt, gen in by_t[t]:
        cons = []
        if (t, col) in pk: cons.append('PK')
        if (t, col) in fk: cons.append('FK→' + fk[(t, col)])
        if nul == 'NO': cons.append('NOT NULL')
        if gen == 'ALWAYS': cons.append('生成列')
        elif dflt: cons.append('默认 `' + dflt.replace('|', '\\|')[:40] + '`')
        note = col_note.get((t, col)) or COMMON.get(col, '')
        out.append(f'| {col} | {typ} | {"; ".join(cons)} | {note} |')
    if checks[t]:
        out += ['', '表级约束：', ''] + [f'- `{d.replace("|", "/")}`' for d in checks[t]]
    out.append('')
(ROOT/'docs/03_数据字典.md').write_text('\n'.join(out), encoding='utf-8')

rules = q("SELECT doc_table, coalesce(from_status,'(新建)'), to_status FROM doc_state_rule ORDER BY doc_table, from_status NULLS FIRST, to_status")
o2 = ['# 04 单据状态迁移表', '', '> 自动生成自 `doc_state_rule`。表中未列出的迁移一律被触发器 `trg_state_machine` 拒绝（错误码 EP002）；',
      '> 进入终态（cancelled/closed/posted/paid/settled 等）的单据内容不可再改（EP003）。流水表另由 `trg_append_only` 禁止 UPDATE/DELETE。', '']
g = collections.defaultdict(list)
for t, a, b in rules: g[t].append((a, b))
for t in g:
    o2 += [f'## {t}', '', '```mermaid', 'stateDiagram-v2']
    for a, b in g[t]:
        o2.append(f'    {"[*]" if a=="(新建)" else a} --> {b}')
    o2 += ['```', '', '| 当前状态 | 可迁移到 |', '|---|---|']
    agg = collections.OrderedDict()
    for a, b in g[t]: agg.setdefault(a, []).append(b)
    for a, bs in agg.items(): o2.append(f'| {a} | {", ".join(bs)} |')
    o2.append('')
(ROOT/'docs/04_单据状态迁移表.md').write_text('\n'.join(o2), encoding='utf-8')
print('docs generated')
