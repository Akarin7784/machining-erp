#!/usr/bin/env python3
"""从剧本与 pgTAP 文件提取断言，生成 docs/07_测试场景与预期结果.md。"""
import re, pathlib
R = pathlib.Path(__file__).resolve().parent.parent
out = ['# 07 测试场景与预期结果','',
'两层测试，全部由 `scripts/run_all.sh` 执行：','',
'1. **端到端剧本** `db/scenarios/*.sql`：在同一个库里按顺序提交数据，每步后用 `assert_eq / assert_true / assert_raises`（DO 块中 RAISE EXCEPTION）断言，任一失败即中止。期望值全部由 `ref_param` 参数推导，不硬编码价格。',
'2. **pgTAP 测试** `db/tests/*.sql`：在剧本数据之上以事务运行并回滚，用 `pg_prove` 执行。','',
'数据说明：价格、费率、外协工价、工资来自 `params/`（真实公开行情，2026-10-20 查询）；零件尺寸、工时、计件单价、毛利底线、损耗定额等标为示例（`is_example=true`）。','',
'## 企业调研员 5 个剧本 → 覆盖位置','',
'| 剧本 | 剧本脚本 | pgTAP |','|---|---|---|',
'| 1 报价靠老师傅（读图报价+成本拆分+低毛利审批，Φ40×200 45# 轴：小计≈58.90，×1.2，25% 毛利≈94.24） | 02 | t01_quote_approval |',
'| 2 图纸和 BOM 版本乱（客户中途改图 A→B，旧版报工被拒） | 05 | t02_drawing_change |',
'| 3 委外失控（镀铬回料短少 2 + 不良 2，1% 损耗定额，超定额扣款进应付，AI 核对对账单） | 06 | t03_subcontract_shortage |',
'| 4 报工滞后/计件纠纷（扫码报工、计件、工序检返工不计件、多段计时） | 05 | t04_rework_piecewage, t08 |',
'| 5 订单毛利算不清（实际 vs 报价同口径复盘、部分发货后月底对账） | 08/10/13 | t05_partial_delivery_statement, t08 |','',
'评审缺口（序列号、替代料、物料需求单、FORCE RLS 等）的测试见 t06–t08 与 `docs/08_验收清单.md`。','']
total = 0
for f in sorted((R/'db/scenarios').glob('*.sql')):
    s = f.read_text(encoding='utf-8')
    labels = re.findall(r"assert_(?:eq|true|raises)\('([^']+)'", s)
    total += len(labels)
    out += [f'## {f.name}', '', s.splitlines()[0].lstrip('- '), '', '| # | 断言(预期) |', '|---|---|'] + [f'| {i+1} | {l} |' for i, l in enumerate(labels)] + ['']
tap = 0
out += ['## pgTAP 测试', '']
for f in sorted((R/'db/tests').glob('*.sql')):
    s = f.read_text(encoding='utf-8')
    n = int(re.search(r'plan\((\d+)\)', s).group(1)); tap += n
    names = re.findall(r"'([^']+)'\);\s*$", s, re.M)
    out += [f'### {f.name}（{n} 项）', ''] + [f'- {x}' for x in names] + ['']
out.insert(2, f'> 剧本断言 {total} 条，pgTAP 测试 {tap} 项。')
(R/'docs/07_测试场景与预期结果.md').write_text('\n'.join(out), encoding='utf-8')
print(total, tap)
