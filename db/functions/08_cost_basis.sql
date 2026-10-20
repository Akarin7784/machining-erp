-- 成本口径修复：两层复盘 + 月末制造费用分摊

-- 月末制造费用分摊：当月实际制造费用（不含税）按各工单当月报工机时分摊
-- 借：未完工工单 → 5001 生产成本；已完工工单 → 6401 主营业务成本（成本差异直接进当期）；贷：5101 制造费用
CREATE OR REPLACE FUNCTION fn_allocate_overhead(p_from date, p_to date, p_pool numeric) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE aid bigint; tot numeric; rate numeric; r record; ln jsonb := '[]'; amt numeric; left_amt numeric; n int; i int := 0;
BEGIN
  SELECT sum(j.hours) INTO tot FROM job_card j WHERE j.reported_at::date BETWEEN p_from AND p_to;
  IF coalesce(tot,0) = 0 THEN RAISE EXCEPTION '期间 %~% 没有报工机时，无法分摊', p_from, p_to; END IF;
  rate := round(p_pool/tot, 6);
  INSERT INTO overhead_allocation(period_start, period_end, pool_amount, total_hours, rate_per_hour)
  VALUES (p_from, p_to, p_pool, tot, rate) RETURNING id INTO aid;
  left_amt := p_pool;
  SELECT count(DISTINCT o.work_order_id) INTO n FROM job_card j JOIN wo_operation o ON o.id=j.wo_operation_id WHERE j.reported_at::date BETWEEN p_from AND p_to;
  FOR r IN SELECT o.work_order_id wo, w.status, w.plant_id, sum(j.hours) h
           FROM job_card j JOIN wo_operation o ON o.id=j.wo_operation_id JOIN work_order w ON w.id=o.work_order_id
           WHERE j.reported_at::date BETWEEN p_from AND p_to GROUP BY 1,2,3 ORDER BY 1 LOOP
    i := i + 1;
    amt := CASE WHEN i = n THEN left_amt ELSE round(p_pool*r.h/tot, 2) END;   -- 尾差落最后一张工单
    left_amt := left_amt - amt;
    INSERT INTO wo_cost_entry(work_order_id, cost_type, amount, hours, source_type, source_id) VALUES (r.wo, 'overhead', amt, r.h, 'overhead_allocation', aid);
    ln := ln || jsonb_build_object('a', CASE WHEN r.status IN ('completed','closed') THEN '6401' ELSE '5001' END, 'd', amt, 'wo', r.wo, 'plant', r.plant_id)
             || jsonb_build_object('a','5101','c',amt,'plant',r.plant_id);
  END LOOP;
  PERFORM fn_post_je('overhead_allocation', aid, p_to, format('月末制造费用分摊 %s~%s', p_from, p_to), ln);
  RETURN aid;
END $$;

-- 逐行复盘：报价标准（不含税，按实际入库数折算） vs 实际（工单树成本流水，不含税）
--   layer=direct   ：material / purchased / hours / subcontract / rework / scrap，双方都不乘管理费系数
--   layer=overhead ：报价管理费行 vs 月末分摊
--   layer=pending  ：计件工资。100 元/h 费率是否已含人工与管理费【待确认】，暂不计入差异合计
-- 工时行的标准按该工序合格数折算（std_hours = 单件定额 × 工序合格数）
CREATE OR REPLACE FUNCTION fn_cost_review_lines(p_qi bigint, p_root_wo bigint, p_qty numeric)
RETURNS TABLE(layer text, line_type text, item_id bigint, routing_op_id bigint, line_name text,
              std_qty numeric, actual_qty numeric, std_hours numeric, actual_hours numeric,
              std_amount numeric, actual_amount numeric, variance numeric)
LANGUAGE sql STABLE AS $$
WITH RECURSIVE tree(id) AS (SELECT p_root_wo UNION ALL SELECT w.id FROM work_order w JOIN tree t ON w.parent_work_order_id=t.id),
e AS (SELECT c.* FROM wo_cost_entry c JOIN tree t ON t.id=c.work_order_id),
op_qty AS (SELECT routing_op_id, sum(qty) q FROM e WHERE cost_type='labor' GROUP BY 1),
std AS (
  SELECT CASE WHEN l.cost_type='overhead' THEN 'overhead' ELSE 'direct' END layer,
         CASE l.cost_type WHEN 'machining' THEN 'hours' WHEN 'heat_treat' THEN 'subcontract' WHEN 'surface' THEN 'subcontract' ELSE l.cost_type END lt,
         CASE WHEN l.cost_type IN ('material','purchased') THEN l.ref_item_id END iid,
         CASE WHEN l.cost_type IN ('machining','heat_treat','surface') THEN l.routing_op_id END rid,
         sum(l.basis_qty) bq, sum(l.amount) amt, max(l.unit_rate) rate
  FROM quotation_cost_line l WHERE l.quotation_item_id=p_qi GROUP BY 1,2,3,4),
act AS (
  SELECT CASE WHEN cost_type='overhead' THEN 'overhead' WHEN cost_type='labor' THEN 'pending' ELSE 'direct' END layer,
         CASE cost_type WHEN 'machine' THEN 'hours' WHEN 'remnant_credit' THEN 'material' WHEN 'labor' THEN 'piece_wage' ELSE cost_type END lt,
         CASE WHEN cost_type IN ('material','remnant_credit','purchased') THEN item_id END iid,
         CASE WHEN cost_type IN ('machine','subcontract') THEN routing_op_id END rid,
         sum(CASE WHEN cost_type='remnant_credit' THEN -qty WHEN cost_type='subcontract' AND amount<0 THEN 0 ELSE qty END) q,
         sum(hours) h, sum(amount) amt
  FROM e WHERE cost_type <> 'semi_transfer' GROUP BY 1,2,3,4)
SELECT coalesce(s.layer,a.layer), coalesce(s.lt,a.lt), coalesce(s.iid,a.iid), coalesce(s.rid,a.rid),
       coalesce((SELECT item_name FROM item WHERE id=coalesce(s.iid,a.iid)), (SELECT op_name FROM routing_operation WHERE id=coalesce(s.rid,a.rid)),
                CASE coalesce(s.lt,a.lt) WHEN 'overhead' THEN '管理费/制造费用' WHEN 'rework' THEN '返工' WHEN 'piece_wage' THEN '计件工资(待确认)' ELSE coalesce(s.lt,a.lt) END),
       CASE WHEN s.lt='hours' THEN NULL ELSE round(s.bq*p_qty,4) END,
       CASE WHEN coalesce(s.lt,a.lt) IN ('hours','overhead') THEN NULL ELSE a.q END,
       CASE WHEN s.lt='hours' THEN round(s.bq*coalesce(oq.q,p_qty),4) END,
       CASE WHEN coalesce(s.lt,a.lt)='hours' THEN coalesce(a.h,0) END,
       coalesce(CASE WHEN s.lt='hours' THEN round(s.bq*coalesce(oq.q,p_qty)*s.rate,2)
                     WHEN s.lt='overhead' THEN round(s.amt*p_qty,2) ELSE round(s.amt*p_qty,2) END, 0),
       coalesce(a.amt,0),
       coalesce(a.amt,0) - coalesce(CASE WHEN s.lt='hours' THEN round(s.bq*coalesce(oq.q,p_qty)*s.rate,2) ELSE round(s.amt*p_qty,2) END, 0)
FROM std s FULL JOIN act a ON a.layer=s.layer AND a.lt=s.lt AND a.iid IS NOT DISTINCT FROM s.iid AND a.rid IS NOT DISTINCT FROM s.rid
LEFT JOIN op_qty oq ON oq.routing_op_id=s.rid AND s.lt='hours'
$$;

CREATE OR REPLACE VIEW v_order_cost_review WITH (security_invoker = true) AS
SELECT v.sales_order_item_id, v.root_work_order_id, v.produced_qty, l.*
FROM v_order_cost_actual v
JOIN sales_order_item soi ON soi.id=v.sales_order_item_id
CROSS JOIN LATERAL fn_cost_review_lines(soi.quotation_item_id, v.root_work_order_id, v.produced_qty) l;

CREATE OR REPLACE VIEW v_order_cost_review_summary WITH (security_invoker = true) AS
SELECT sales_order_item_id, layer, sum(std_amount) std_amount, sum(actual_amount) actual_amount, sum(variance) variance
FROM v_order_cost_review GROUP BY 1,2;

-- 完工复盘 → 工时定额修正建议：只取工时行差异
-- 建议定额 = 原定额 + 权重 × (实际单件工时 − 报价单件工时)
CREATE OR REPLACE FUNCTION fn_cost_review(p_soi bigint) RETURNS int LANGUAGE plpgsql AS $$
DECLARE rid bigint; n int; a numeric := p('ex_std_hours_learning_rate');
BEGIN
  INSERT INTO ai_request(kind, input, model) VALUES ('cost_review', jsonb_build_object('sales_order_item_id',p_soi), 'rule:ewma') RETURNING id INTO rid;
  INSERT INTO ai_cost_review(ai_request_id, sales_order_item_id, work_order_id, routing_op_id, line_type, quoted_hours, actual_hours_per_unit, proposed_hours,
                             std_hours_total, actual_hours_total, variance_hours)
  SELECT rid, p_soi, v.root_work_order_id, l.routing_op_id, 'hours', ro.std_hours,
         round(l.actual_hours*ql.basis_qty/l.std_hours, 4),
         round(ro.std_hours + a*(l.actual_hours - l.std_hours)*ql.basis_qty/l.std_hours, 4),
         l.std_hours, l.actual_hours, l.actual_hours - l.std_hours
  FROM v_order_cost_review l
  JOIN v_order_cost_actual v ON v.sales_order_item_id=l.sales_order_item_id
  JOIN sales_order_item soi ON soi.id=p_soi
  JOIN quotation_cost_line ql ON ql.quotation_item_id=soi.quotation_item_id AND ql.routing_op_id=l.routing_op_id AND ql.cost_type='machining'
  JOIN routing_operation ro ON ro.id=l.routing_op_id
  WHERE l.sales_order_item_id=p_soi AND l.line_type='hours' AND l.std_hours > 0 AND l.actual_hours > 0;
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE ai_request SET status='succeeded', output=(SELECT jsonb_agg(to_jsonb(c)) FROM ai_cost_review c WHERE c.ai_request_id=rid) WHERE id=rid;
  RETURN n;
END $$;
