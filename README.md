# machining-erp：中小机加工/装配厂 AI 原生 ERP（日式详细设计 + SQL 全业务跑通）

面向按订单生产（MTO）的中小机械加工、装配厂。按日式「详细设计」一次覆盖全部业务：**报价 → 订单 → MRP → 采购/来料检 → 工单报工(计件) → 委外 → 质检/返工 → 完工入库 → 发货 → 开票 → 收付款 → 总账 → 月结**，外加多工厂、有限能力排产、余料管理和 4 个 AI 功能。所有业务规则写在 PostgreSQL 里，并用端到端剧本在 SQL 层真实跑通。

> 设计参考 ERPNext 的单据链与字段思路、InvenTree 的参数模板思路，**未复制任何 GPL 代码**。

## 快速运行

```bash
# 方式 1：本机已装 PostgreSQL 16（含 initdb）、pgTAP 扩展和 pg_prove
bash scripts/run_all.sh            # 在 /tmp 起临时实例 → 建库 → 迁移 → 函数 → 种子 → 剧本 → pgTAP → 停止
# 方式 2：使用已有实例
PGHOST=localhost PGPORT=5432 PGUSER=postgres bash scripts/run_all.sh
# 重新生成参数种子 / 数据字典与状态迁移文档
make seed
GEN_DOCS=1 bash scripts/run_all.sh
```

Ubuntu 安装依赖：`sudo apt-get install postgresql-16 postgresql-16-pgtap libtap-parser-sourcehandler-pgtap-perl`。
没有 `pg_prove` 时脚本会退回到 `prove --exec psql`。迁移脚本带 `-- migrate:up` 头，兼容 dbmate 的编号风格。

运行结果（本地，PostgreSQL 16）：13 个端到端剧本 128 条断言全部通过；6 个 pgTAP 文件 53 项测试全部通过；63 张表、8 个视图、59 个函数/触发器函数。

## 目录结构

```
params/                 行情参数（主数据源 market_2026-10.yaml + 补充 real_params_2026-10.csv）
db/migrations/          dbmate 风格编号迁移：框架/主数据/技术销售/库存采购生产委外/发货财务AI/规则权限视图
db/functions/           过账与状态流转函数（报价、MRP、报工、委外、发货开票、收付款、总账、排产、AI 落表）
db/seed/                由 scripts/gen_seed.py 从 params/ 生成的参数与来源（勿手改）
db/scenarios/           13 个端到端剧本，每步 DO 块断言
db/tests/               pgTAP 测试，每个剧本一个文件 + 通用守护
docs/                   00 概要 ~ 07 测试场景（03、04 自动生成）
scripts/run_all.sh      一键从零建库并跑完全部
.github/workflows/ci.yml  GitHub Actions：同样脚本
```

## 设计亮点

- **流水只增不改，写死在库里**：库存、应收应付、凭证、报工、工单成本、委外流水、审计日志都有 `trg_append_only`，UPDATE/DELETE 直接报错；单据作废写冲销记录（`fn_reverse_stock_voucher`、`fn_reverse_je`）。
- **状态机写死**：`doc_state_rule` + `trg_state_machine`，任何不在规则表中的迁移被拒；新单据必须从初始状态开始。
- **数量守恒**：工序可报数 = 投入 − 完工 − 报废 − 待返工；发货 ≤ 订单；退货 ≤ 原发货；委外回料 ≤ 发出；库存不允许负数。
- **借贷必平**：每张凭证延迟约束检查借贷平衡；月结前校验试算平衡、应收/应付总账与明细账一致，关账后禁止过账。
- **报价成本拆分可追溯**：`quotation_cost_line` 记录每一行用的参数键与单价；公式 `(材料kg价×毛重 + Σ工时×费率 + 热处理 + 表面处理 + 外购 + 特殊) × 管理费系数`。
- **委外损耗定额**：短少 + 不良超出 `发出×定额` 的部分，按在制品单件成本自动从应付中扣款；AI 识别外协对账单后逐字段比对。
- **客户中途改图**：图纸版本唯一生效（部分唯一索引），ECN 记录受影响在制品，旧版报工被拒。
- **余料**：按长度/重量登记回库、冲减订单材料成本、可再领用。
- **多租户 + 列权限**：RLS 隔离租户；销售看不到成本，操作工看不到价格和机时成本，工资只有经理/财务可见。
- **完工复盘闭环**：实际 vs 报价 → 工时定额修正建议 → 人工确认 → 下一次报价自动更准。

## 数据来源

所有价格、费率、工价、工资参数集中在 `params/`，由 `scripts/gen_seed.py` 生成 `ref_param`，每条参数通过 `ref_param_source` 关联 `reference_source`（URL、查询日期、是否示例）。查询日期均为 2026-10-20（北京时间）。

| 参数 | 取值 | 来源 |
|---|---|---|
| 45# 圆钢 | 3.59 元/kg（3590 元/吨） | [我的钢铁网](https://www.mysteel.com/hot/59930.html)；补充 [中钢网](http://baojia.steelcn.cn/default.aspx?date=2026-10-20)、[钢之家](https://www.steelhome.com/xhbj.php) |
| 304 不锈钢棒 | Φ21-45 13.45、Φ65-130 13.20 元/kg | [中钢网](http://hq.steelcn.cn/20261020/5061418.html)；补充 [我的钢铁网](https://list1.mysteel.com/zhishi/jrzxwxTP304bxgjg.html) |
| 6061 铝棒 Φ90 | 24.00 元/kg | [上海有色网](https://www.smm.cn/mpdb/1705462054881_live)；补充 [江西保太](https://jxbt01.baotaigroup.com.cn/en/offer/index/catid/165.html) |
| 机时费率 | 普车 60、数控车 100（60-120）、加工中心 90（60-120）、钳工 80 元/h；五轴 400 元/h | [前沿数控](https://www.cnclead.com/category/view/1436.html)、[中山大学](https://saa.sysu.edu.cn/article/736) |
| 管理费系数 | 1.2 | [前沿数控](https://www.cnclead.com/category/view/1436.html) |
| 报价公式口径 | 材料kg价×毛重+Σ工序工时价×工时+热处理+表面处理+特殊费用 | [库卡竞价公告(采招网)](https://www.bidcenter.com.cn/news-342199042-5.html) |
| 调质 | 电炉 2.30、盐炉 2.60 元/kg（年份不明，作参考） | [人人文库](https://www.renrendoc.com/paper/167875780.html) |
| 发黑 | 1.20 元/kg | [人人文库](https://www.renrendoc.com/paper/167875780.html) |
| 镀铬(铜镍铬 10-20μm) | 1.65 元/dm²（光亮 1.85） | [合金圆钢网](https://www.jbcsxfh.com/show/73.html) |
| 数控车工月薪 | 7000-10000 元（计件） | [南安招聘](https://www.nanan.love/job/30534)、[职友集](https://www.jobui.com/salary/quanguo-shukongchegong/) |
| 材料密度 | 45# 7.85、304 7.93、6061 2.70 g/cm³ | [BestAI CAM](https://bestaicam.com/tools/metal-weight-calculator) |

**示例数据（`is_example=true`，公开资料查不到）**：零件尺寸（Φ40×200 坯料、成品 1.5kg、镀铬面积 2.04dm²）、各工序工时、计件单价、轴承 6205 采购价、毛利底线 25%、外协损耗定额 1%、外协周期、工时修正权重、示例订单数量；公司名称与税号也为示例。来源较旧或为网文经验价的参数（如调质、镀铬），剧本断言用参数推导并对剧本手算值留容差。完整清单见 `SELECT * FROM ref_param JOIN ref_param_source USING(param_key) JOIN reference_source s ON s.id=source_id`。

## 已知简化

- 销售/采购单价按含税价录入，库存与成本按不含税计；报价成本按含税行情价计，所以复盘时实际成本会略低于报价成本。
- 委外加工费税率统一按 13%；工资只做计件计提，不做发放。
- AI 在剧本中为假数据（model=`mock`）；接口与落表见 `docs/06_AI接口设计.md`。
