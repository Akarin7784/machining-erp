-- 剧本 02：读图报价（AI 结果为假数据落表）→ 成本拆分 → 低毛利转审批 → 经理批准
SELECT use_tenant('DEMO');

DO $$
DECLARE rid bigint; q bigint; qi bigint; r quotation_item;
  w numeric; semi numeric; semi_gross numeric; assy numeric; expect_cost numeric; st text;
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
  -- 成本口径：含税行情价（tax_included）÷(1+13%) 后计入成本；厂内机时费率不涉税
  semi := w*p_net('mat_45_kg')
        + (p('ex_hours_rough_turn')+p('ex_hours_finish_turn'))*p('rate_cnc_lathe') + p('ex_hours_cut')*p('rate_lathe_conventional')
        + p('ex_shaft_finished_kg')*p_net('ht_quench_temper_electric')
        + p('ex_shaft_chrome_area_dm2')*p_net('surface_chrome_cu_ni_cr');
  semi_gross := w*p('mat_45_kg')
        + (p('ex_hours_rough_turn')+p('ex_hours_finish_turn'))*p('rate_cnc_lathe') + p('ex_hours_cut')*p('rate_lathe_conventional')
        + p('ex_shaft_finished_kg')*p('ht_quench_temper_electric')
        + p('ex_shaft_chrome_area_dm2')*p('surface_chrome_cu_ni_cr');
  assy := 2*p_net('ex_bearing_6205_price') + p('ex_hours_assembly')*p('rate_fitter');
  expect_cost := round((semi+assy)*p('quote_overhead_factor'),4);
  PERFORM assert_eq('不含税换算：p_net=含税价/(1+税率)', p_net('mat_45_kg'), round(p('mat_45_kg')/(1+p('vat_rate_general')),6));
  PERFORM assert_eq('材料费(不含税)=毛重×45#kg价/1.13', r.material_cost, w*p_net('mat_45_kg'), 0.001);
  PERFORM assert_eq('材料行含税金额=毛重×含税价', (SELECT amount_gross FROM quotation_cost_line WHERE quotation_item_id=qi AND cost_type='material'), w*p('mat_45_kg'), 0.001);
  PERFORM assert_eq('热处理费(不含税)=成品重×调质单价/1.13', r.heat_treat_cost, p('ex_shaft_finished_kg')*p_net('ht_quench_temper_electric'), 0.001);
  PERFORM assert_eq('表面处理费(不含税)=镀铬面积×单价/1.13', r.surface_cost, p('ex_shaft_chrome_area_dm2')*p_net('surface_chrome_cu_ni_cr'), 0.001);
  PERFORM assert_eq('单件成本(不含税直接成本×管理费系数)', r.unit_cost, expect_cost, 0.01);
  PERFORM assert_eq('管理费单独一行=直接成本合计×(系数-1)', (SELECT amount FROM quotation_cost_line WHERE quotation_item_id=qi AND cost_type='overhead'),
                    (semi+assy)*(p('quote_overhead_factor')-1), 0.01);
  PERFORM assert_eq('直接成本行+管理费行=单件成本', (SELECT sum(amount) FROM quotation_cost_line WHERE quotation_item_id=qi), r.unit_cost, 0.01);
  -- 与企业调研员剧本1手算对照：含税口径小计≈58.90（参数来源较旧，用容差）；改为不含税后小计、报价按公式重算
  PERFORM assert_eq('剧本1 轴小计(含税口径，对照调研员)≈58.90', semi_gross, 58.90, 0.05);
  PERFORM assert_true('剧本1 不含税小计 < 含税小计', semi < semi_gross);
  RAISE NOTICE '剧本1(不含税口径): 轴小计 %, ×管理费系数 %, 按毛利底线报价 %', round(semi,2), round(semi*p('quote_overhead_factor'),2),
    round(semi*p('quote_overhead_factor')/(1-p('min_margin')),2);
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
  PERFORM assert_eq('成本拆分明细行数(材料1+厂内工时3+委外2+外购1+装配1+管理费1)', (SELECT count(*) FROM quotation_cost_line WHERE quotation_item_id=qi), 9);
END $$;
