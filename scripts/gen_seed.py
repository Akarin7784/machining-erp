#!/usr/bin/env python3
"""从 params/market_2026-10.yaml（主数据源）+ params/real_params_2026-10.csv（补充）+ 示例参数
生成 db/seed/001_ref_params.sql。无第三方依赖（YAML 为单行 flow 映射格式，手写解析）。"""
import csv, re, pathlib
ROOT = pathlib.Path(__file__).resolve().parent.parent
FETCHED = '2026-10-20'

def parse_flow(s):
    s = s.strip().lstrip('-').strip().strip('{}')
    out = {}
    for m in re.finditer(r'(\w+):\s*("([^"]*)"|[^,]+)', s):
        v = m.group(3) if m.group(3) is not None else m.group(2).strip()
        out[m.group(1)] = v
    return out

def load_yaml(path):
    data, sect = {}, None
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        if not line.startswith(' '):
            k, _, rest = line.partition(':')
            rest = rest.split('#')[0].strip()
            sect = k.strip()
            data[sect] = parse_flow(rest) if rest.startswith('{') else []
        else:
            data[sect].append(parse_flow(line))
    return data

y = load_yaml(ROOT/'params/market_2026-10.yaml')
params = {}   # key -> dict
def add(key, name, value, unit, src=None, title=None, lo=None, hi=None, example=False, note=None):
    params[key] = dict(key=key, name=name, value=value, unit=unit, lo=lo, hi=hi, example=example, note=note,
                       sources=[(src, title or name)] if src else [])

matmap = {'45#': ('mat_45_kg','45号钢圆钢'), 'SUS304_D21-45': ('mat_304_d21_45_kg','304不锈钢棒Φ21-45'),
          'SUS304_D65-130': ('mat_304_d65_130_kg','304不锈钢棒Φ65-130'), 'AL6061_D90': ('mat_6061_d90_kg','6061铝棒Φ90')}
for m in y['materials']:
    k, n = matmap[m['code']]
    add(k, n, m['price'], '元/kg', m['source'], note=m.get('note'))
ratemap = {'普通车床':'rate_lathe_conventional','数控车床':'rate_cnc_lathe','加工中心':'rate_machining_center',
           '钳工':'rate_fitter','五轴加工中心':'rate_5axis'}
for m in y['machine_rates']:
    k = ratemap[m['type']]
    v = m.get('rate') or m.get('default') or str((float(m['min'])+float(m['max']))/2)
    add(k, m['type']+'机时费率', v, '元/小时', m['source'], lo=m.get('min'), hi=m.get('max'),
        note=m.get('note') or ('取默认值' if m.get('default') else ('取区间中值' if m.get('min') and not m.get('rate') else None)))
o = y['overhead_factor']; add('quote_overhead_factor','报价管理费系数',o['value'],'倍',o['source'])
submap = {'调质_电炉':'ht_quench_temper_electric','调质_盐炉':'ht_quench_temper_salt','发黑':'surface_blacken','镀铬_铜镍铬':'surface_chrome_cu_ni_cr'}
for m in y['subcontract']:
    add(submap[m['process']], '外协'+m['process'], m['price'], m['unit'], m['source'], note=m.get('note'))
for i, m in enumerate(y['labor']):
    k = 'wage_cnc_lathe_monthly' if i == 0 else 'wage_cnc_lathe_c6130_monthly'
    add(k, m['role']+'月薪('+m['mode']+')', (float(m['monthly_min'])+float(m['monthly_max']))/2, '元/月', m['source'],
        lo=m['monthly_min'], hi=m['monthly_max'], note='取区间中值')
for m in y['business_rules']:
    if m['key'] == 'piece_rate_per_op': continue
    add(m['key'], {'min_margin':'报价毛利底线','subcontract_loss_allowance':'外协损耗定额'}[m['key']], m['value'], '比例', example=True)

# CSV 补充（不覆盖 YAML 中已有的同义参数，按自身 key 入库）
with open(ROOT/'params/real_params_2026-10.csv', encoding='utf-8') as f:
    for r in csv.DictReader(f):
        if r['param_key'] in params:   # YAML 为主：同名参数只追加来源
            params[r['param_key']]['sources'].append((r['source_url'], r['source_title']))
            continue
        add(r['param_key'], r['name_cn'], r['value'], r['unit'], r['source_url'], r['source_title'],
            r['range_low'] or None, r['range_high'] or None, note=r['note'] or None)

# 示例参数（查不到公开来源：零件尺寸、工时、计件单价等）
EX = [
 ('ex_shaft_stock_dia_mm','精密轴坯料直径',40,'mm'), ('ex_shaft_stock_len_mm','精密轴坯料长度',200,'mm'),
 ('ex_shaft_finished_kg','精密轴成品重量',1.5,'kg'), ('ex_shaft_chrome_area_dm2','精密轴镀铬面积',2.04,'dm2'),
 ('ex_hours_cut','下料工时(计入材料，不计机时)',0,'h/件'), ('ex_hours_rough_turn','粗车工时',0.25,'h/件'),
 ('ex_hours_finish_turn','精车工时',0.2,'h/件'), ('ex_hours_assembly','装配工时',0.1,'h/件'),
 ('ex_piece_rate_cut','下料计件单价',0.5,'元/件'), ('ex_piece_rate_rough','粗车计件单价',3.0,'元/件'),
 ('ex_piece_rate_finish','精车计件单价',2.5,'元/件'), ('ex_piece_rate_assembly','装配计件单价',1.0,'元/件'),
 ('ex_bearing_6205_price','轴承6205采购价(含税)',8.0,'元/个'), ('ex_subcon_lead_days','外协周期',3,'天'),
 ('ex_std_hours_learning_rate','工时定额修正权重(实际值)',0.7,'比例'),
 ('ex_order_qty','示例订单数量',100,'件'),
]
for k, n, v, u in EX:
    add(k, n, v, u, example=True, note='示例数据：公开资料查不到，作为演示假设')

def q(v):
    return 'NULL' if v in (None, '') else "'" + str(v).replace("'", "''") + "'"
def n(v):
    return 'NULL' if v in (None, '') else str(v)
lines = ['-- 自动生成：python3 scripts/gen_seed.py  （请勿手改）',
         '-- 主数据源 params/market_2026-10.yaml，补充 params/real_params_2026-10.csv，查询日期 ' + FETCHED, 'BEGIN;']
lines.append("INSERT INTO reference_source(url,title,fetched_date,is_example,note) VALUES (NULL,'示例数据（无公开来源）',NULL,true,'is_example') ON CONFLICT DO NOTHING;")
for p in params.values():
    lines.append(f"INSERT INTO ref_param(param_key,name_cn,value,unit,range_low,range_high,is_example,note) VALUES "
                 f"({q(p['key'])},{q(p['name'])},{n(p['value'])},{q(p['unit'])},{n(p['lo'])},{n(p['hi'])},{str(p['example']).lower()},{q(p['note'])});")
    if p['example']:
        lines.append(f"INSERT INTO ref_param_source SELECT {q(p['key'])}, id FROM reference_source WHERE is_example AND url IS NULL;")
    for url, title in p['sources']:
        lines.append(f"INSERT INTO reference_source(url,title,fetched_date,is_example) VALUES ({q(url)},{q(title)},'{FETCHED}',false) ON CONFLICT (url,title) DO NOTHING;")
        lines.append(f"INSERT INTO ref_param_source SELECT {q(p['key'])}, id FROM reference_source WHERE url={q(url)} AND title={q(title)} ON CONFLICT DO NOTHING;")
lines.append('COMMIT;')
(ROOT/'db/seed/001_ref_params.sql').write_text('\n'.join(lines)+'\n', encoding='utf-8')
print(f'{len(params)} params written')
