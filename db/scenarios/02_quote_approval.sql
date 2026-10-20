-- 剧本 02：读图报价（AI 结果为假数据落表）→ 成本拆分 → 低毛利转审批 → 经理批准
SELECT use_tenant('DEMO');

DO $$
DECLARE rid bigint; q bigint; qi bigint; r quotation_item;
  w numeric; semi numeric; assy numeric; expect_cost numeric; st text;
BEGIN
  -- AI 读图（假数据：模拟模型从 PDF 图纸中识别的特征）
  rid := fn_ai_record_drawing_quote(
    jsonb_build_object('drawing_uri','s3://drawings/SHAFT-ASSY-A.pdf','customer','CUST01','qty',p('ex_order_qty')),
    jsonb_build_object('material_code','45#','stock_diameter_mm',p('ex_shaft_stock_dia_mm'),'stock_length_mm',p('ex_shaft_stock_len_mm'),
      'finished_weight_kg',p('ex_shaft_finished_kg'),'plated_area_dm2',p('ex_shaft_chrome_area_dm2'),'tightest_tolerance_mm',0.016,
      'surface_treatment','镀铬','heat_treatment','调质','similar_item_id',it('SHAFT-SEMI'),'confidence',0.86));
  INSERT INTO quotation(customer_id, plant_id, valid_till, ai_request_id, min_margin)
  VALUES (pty('CUST01'), plant_of('P1'), current_date+30, rid, p('min_margin')) RETURNING id INTO q;
  INSERT INTO quotation_item(quotation_id, item_id, drawing_id, qty, customer_part_no)
  VALUES (q, it('SHAFT-ASSY'), (SELECT current_drawing_id FROM item WHERE id=it('SHAFT-ASSY')), p('ex_order_qty'), 'CUST-P-38-195') RETURNING id INTO qi;
  r := fn_quote_cost(qi);

  -- 期望值：完全由参数推导（不硬编码价格）
  w := round(pi()::numeric*(p('ex_shaft_stock_dia_mm')/2)^2*p('ex_shaft_stock_len_mm')*p('density_45_steel')/1000000,4);
  semi := w*p('mat_45_kg')
        + (p('ex_hours_rough_turn')+p('ex_hours_finish_turn'))*p('rate_cnc_lathe') + p('ex_hours_cut')*p('rate_lathe_conventional')
        + p('ex_shaft_finished_kg')*p('ht_quench_temper_electric')
        + p('ex_shaft_chrome_area_dm2')*p('surface_chrome_cu_ni_cr');
  assy := 2*p('ex_bearing_6205_price') + p('ex_hours_assembly')*p('rate_fitter');
  expect_cost := round((semi+assy)*p('quote_overhead_factor'),4);
  PERFORM assert_eq('材料费=毛重×45#kg价', r.material_cost, w*p('mat_45_kg'), 0.001);
  PERFORM assert_eq('热处理费=成品重×调质单价', r.heat_treat_cost, p('ex_shaft_finished_kg')*p('ht_quench_temper_electric'), 0.001);
  PERFORM assert_eq('表面处理费=镀铬面积×单价', r.surface_cost, p('ex_shaft_chrome_area_dm2')*p('surface_chrome_cu_ni_cr'), 0.001);
  PERFORM assert_eq('单件成本(含管理费系数)', r.unit_cost, expect_cost, 0.01);
  -- 与企业调研员剧本1手算结果对照（参数来源较旧，用容差）：轴小计≈58.90，×1.2≈70.68，25%毛利≈94.24
  PERFORM assert_eq('剧本1 轴小计≈58.90', semi, 58.90, 0.05);
  PERFORM assert_eq('剧本1 轴报价≈94.24', round(semi*p('quote_overhead_factor')/(1-p('min_margin')),2), 94.24, 0.05);
  PERFORM assert_eq('建议价=成本/(1-毛利底线)', r.suggested_price, round(expect_cost/(1-p('min_margin')),2), 0.01);

  -- 销售为抢单只按 20% 毛利报价 → 低于底线 → 待审批
  UPDATE quotation_item SET unit_price = round(unit_cost/0.80,2) WHERE id=qi;
  st := fn_quote_submit(q);
  PERFORM assert_true('低毛利报价进入待审批', st='pending_approval');
  PERFORM assert_raises('待审批报价不能转订单', format('SELECT fn_so_from_quote(%s,%s,current_date+30)', q, plant_of('P1')), '不能转订单');
  PERFORM set_config('app.user','manager_liu',false);
  PERFORM fn_quote_decide(q, true, '战略客户首单，同意按 20% 毛利');
  PERFORM set_config('app.user','',false);
  PERFORM assert_true('经理批准后状态=approved', (SELECT status FROM quotation WHERE id=q)='approved');
  PERFORM assert_true('审计日志记录了审批人', EXISTS (SELECT 1 FROM audit_log WHERE table_name='quotation' AND new_data->>'status'='approved' AND actor='manager_liu'));
  PERFORM assert_eq('成本拆分明细行数(材料1+厂内工时3+委外2+外购1+装配1)', (SELECT count(*) FROM quotation_cost_line WHERE quotation_item_id=qi), 8);
END $$;
