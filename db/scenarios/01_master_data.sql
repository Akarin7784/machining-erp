-- 剧本 01：主数据（工厂/仓库/客户/供应商/员工/物料/图纸/BOM/工艺路线/设备）
-- 公司名、税号、零件尺寸等为示例数据；价格、费率来自 ref_param（见 params/）
INSERT INTO tenant(tenant_code, tenant_name) VALUES ('DEMO','苏州示例精密机械有限公司(示例)'), ('OTHER','另一家租户(示例)');
SELECT use_tenant('DEMO');
SELECT fn_seed_coa();

INSERT INTO plant(plant_code, plant_name) VALUES ('P1','一厂(机加工)'), ('P2','二厂(装配/发货)');
INSERT INTO party(party_type, party_code, party_name, tax_no, address_phone, bank_account, payment_days) VALUES
 ('customer','SELF','苏州示例精密机械有限公司(示例)','91320500EXAMPLE001X',NULL,NULL,0),
 ('customer','CUST01','示例自动化设备有限公司','91310000EXAMPLE002Y','上海市示例路1号 021-00000000','示例银行 6222000000000001',30),
 ('supplier','SUP-STEEL','示例钢材贸易有限公司','91320000EXAMPLE003Z',NULL,NULL,30),
 ('supplier','SUP-BRG','示例轴承经销部','91320000EXAMPLE004A',NULL,NULL,30),
 ('subcontractor','SUB-HT','示例热处理厂','91320000EXAMPLE005B',NULL,NULL,30),
 ('subcontractor','SUB-PL','示例电镀厂','91320000EXAMPLE006C',NULL,NULL,30);
INSERT INTO warehouse(plant_id, wh_code, wh_name, wh_type, supplier_id) VALUES
 (plant_of('P1'),'RAW1','一厂原材料仓','raw',NULL), (plant_of('P1'),'WIP1','一厂半成品仓','wip',NULL),
 (plant_of('P1'),'FG1','一厂成品仓','fg',NULL), (plant_of('P1'),'REM1','一厂余料仓','remnant',NULL),
 (plant_of('P1'),'REJ1','一厂不良品仓','reject',NULL),
 (plant_of('P1'),'SUB-HT','热处理厂(外协仓)','subcontract',pty('SUB-HT')), (plant_of('P1'),'SUB-PL','电镀厂(外协仓)','subcontract',pty('SUB-PL')),
 (plant_of('P1'),'TRANSIT','厂间在途','transit',NULL), (plant_of('P2'),'FG2','二厂成品仓','fg',NULL);
INSERT INTO employee(emp_code, emp_name, plant_id, pay_mode, base_monthly) VALUES
 ('E001','张师傅(下料/粗车)',plant_of('P1'),'piece',0), ('E002','李师傅(精车)',plant_of('P1'),'piece',0),
 ('E003','王师傅(装配)',plant_of('P1'),'piece',0), ('E004','赵工(返工)',plant_of('P1'),'piece',0);

INSERT INTO workstation(plant_id, ws_code, ws_name, rate_param_key) VALUES
 (plant_of('P1'),'SAW','锯床下料','rate_lathe_conventional'), (plant_of('P1'),'CNC1','数控车床1','rate_cnc_lathe'),
 (plant_of('P1'),'CNC2','数控车床2','rate_cnc_lathe'), (plant_of('P1'),'BENCH','钳工装配台','rate_fitter');

INSERT INTO item(item_code, item_name, item_kind, stock_uom, material_param_key, density_param_key, std_cost, is_batch_tracked) VALUES
 ('RAW-45-D40','45号钢圆钢 Φ40','raw','kg','mat_45_kg','density_45_steel',NULL,true),
 ('BRG-6205','深沟球轴承 6205','purchased','pcs',NULL,NULL,p('ex_bearing_6205_price'),false),
 ('SHAFT-SEMI','精密轴(镀铬) Φ38h6','semi','pcs',NULL,NULL,NULL,false),
 ('SHAFT-ASSY','精密轴组件(含2只轴承)','finished','pcs',NULL,NULL,NULL,false);
INSERT INTO param_template(name, unit) VALUES ('直径','mm'), ('长度','mm'), ('材质',NULL), ('表面处理',NULL), ('热处理',NULL);
INSERT INTO item_param(item_id, template_id, value_num, value_text)
SELECT it('SHAFT-SEMI'), t.id, v.n, v.t FROM param_template t JOIN (VALUES ('直径',38::numeric,NULL),('长度',195,NULL),('材质',NULL,'45#'),
  ('表面处理',NULL,'镀铬 10-20μm'),('热处理',NULL,'调质 HB220-250')) v(name,n,t) ON v.name=t.name;

INSERT INTO drawing_revision(item_id, revision, file_uri, change_note) VALUES
 (it('SHAFT-SEMI'),'A','s3://drawings/SHAFT-SEMI-A.pdf','初版'), (it('SHAFT-ASSY'),'A','s3://drawings/SHAFT-ASSY-A.pdf','初版');
SELECT fn_release_drawing(id) FROM drawing_revision WHERE revision='A';

-- 多层 BOM：组件 = 精密轴×1 + 轴承×2；精密轴 = 45#圆钢 毛重(由参数计算)
INSERT INTO bom(item_id, drawing_id) VALUES (it('SHAFT-ASSY'), (SELECT current_drawing_id FROM item WHERE id=it('SHAFT-ASSY'))),
                                            (it('SHAFT-SEMI'), (SELECT current_drawing_id FROM item WHERE id=it('SHAFT-SEMI')));
INSERT INTO bom_item(bom_id, component_id, qty_per, issue_at_seq) VALUES
 ((SELECT id FROM bom WHERE item_id=it('SHAFT-ASSY')), it('SHAFT-SEMI'), 1, 10),
 ((SELECT id FROM bom WHERE item_id=it('SHAFT-ASSY')), it('BRG-6205'), 2, 10);
INSERT INTO bom_item(bom_id, component_id, qty_per, net_qty_per, issue_at_seq) VALUES
 ((SELECT id FROM bom WHERE item_id=it('SHAFT-SEMI')), it('RAW-45-D40'),
  fn_bar_weight_kg(p('ex_shaft_stock_dia_mm'), p('ex_shaft_stock_len_mm'), p('density_45_steel')), p('ex_shaft_finished_kg'), 10);

-- 工艺路线：下料→粗车→外协调质→精车→外协镀铬 ；组件：装配
INSERT INTO routing(item_id, routing_name) VALUES (it('SHAFT-SEMI'),'精密轴标准工艺'), (it('SHAFT-ASSY'),'组件装配');
INSERT INTO routing_operation(routing_id, seq, op_name, workstation_id, std_hours, is_subcontracted, subcon_price_key, subcon_basis, subcon_basis_per_unit, piece_rate, qc_required)
SELECT r.id, v.seq, v.op, (SELECT id FROM workstation WHERE ws_code=v.ws AND tenant_id=app_tid()), coalesce(p(v.hk),0), v.sub, v.pk, v.basis,
       CASE v.basis WHEN 'kg' THEN p('ex_shaft_finished_kg') WHEN 'dm2' THEN p('ex_shaft_chrome_area_dm2') END,
       coalesce(p(v.rk),0), v.qc
FROM routing r, (VALUES
  (10,'下料','SAW','ex_hours_cut',false,NULL,NULL,'ex_piece_rate_cut',false),
  (20,'粗车','CNC1','ex_hours_rough_turn',false,NULL,NULL,'ex_piece_rate_rough',false),
  (30,'调质(外协)',NULL,NULL,true,'ht_quench_temper_electric','kg',NULL,true),
  (40,'精车','CNC2','ex_hours_finish_turn',false,NULL,NULL,'ex_piece_rate_finish',true),
  (50,'镀铬(外协)',NULL,NULL,true,'surface_chrome_cu_ni_cr','dm2',NULL,true)
) v(seq,op,ws,hk,sub,pk,basis,rk,qc)
WHERE r.item_id=it('SHAFT-SEMI');
INSERT INTO routing_operation(routing_id, seq, op_name, workstation_id, std_hours, piece_rate)
SELECT r.id, 10, '装配', (SELECT id FROM workstation WHERE ws_code='BENCH' AND tenant_id=app_tid()), p('ex_hours_assembly'), p('ex_piece_rate_assembly')
FROM routing r WHERE r.item_id=it('SHAFT-ASSY');

DO $$ BEGIN
  PERFORM assert_eq('精密轴坯料毛重(kg)=π·20²·200·7.85/1e6', (SELECT qty_per FROM bom_item WHERE component_id=it('RAW-45-D40')), 1.9729, 0.0001);
  PERFORM assert_eq('精密轴工序数', (SELECT count(*) FROM routing_operation ro JOIN routing r ON r.id=ro.routing_id WHERE r.item_id=it('SHAFT-SEMI')), 5);
  PERFORM assert_true('每个物料最多一个生效图纸', NOT EXISTS (SELECT item_id FROM drawing_revision WHERE status='released' GROUP BY item_id HAVING count(*)>1));
  PERFORM assert_true('所有参数均有来源记录', NOT EXISTS (SELECT 1 FROM ref_param r WHERE NOT EXISTS (SELECT 1 FROM ref_param_source s WHERE s.param_key=r.param_key)));
END $$;
