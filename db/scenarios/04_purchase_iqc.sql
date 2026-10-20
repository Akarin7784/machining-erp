-- 剧本 04：按 MRP 生成采购 → 到货 → 来料检(轴承有 4 只不合格退回) → 补货 → 入库(不含税计价) → 进项专票
SELECT use_tenant('DEMO');
DO $$
DECLARE plan bigint := (SELECT max(id) FROM production_plan); po_s bigint; po_b bigint; pr bigint; pr2 bigint; extra numeric := 3; -- 下料余量 3kg（示例）
  steel_kg numeric; steel_price numeric := p('mat_45_kg'); brg_price numeric := p('ex_bearing_6205_price'); inv bigint;
BEGIN
  steel_kg := (SELECT net_qty FROM mrp_line WHERE production_plan_id=plan AND item_id=it('RAW-45-D40')) + extra;
  po_s := fn_po_create(pty('SUP-STEEL'), plant_of('P1'), jsonb_build_array(jsonb_build_object('item',it('RAW-45-D40'),'qty',steel_kg,'price',steel_price,
          'mrp_line',(SELECT id FROM mrp_line WHERE production_plan_id=plan AND item_id=it('RAW-45-D40')))));
  po_b := fn_po_create(pty('SUP-BRG'), plant_of('P1'), jsonb_build_array(jsonb_build_object('item',it('BRG-6205'),'qty',200,'price',brg_price,
          'mrp_line',(SELECT id FROM mrp_line WHERE production_plan_id=plan AND item_id=it('BRG-6205')))));
  -- 钢材到货，全部合格
  pr := fn_po_receive(po_s, wh('RAW1'), jsonb_build_array(jsonb_build_object('po_item',(SELECT id FROM purchase_order_item WHERE purchase_order_id=po_s),'qty',steel_kg,'batch','HG-2610-001')));
  PERFORM fn_incoming_inspection((SELECT id FROM purchase_receipt_item WHERE purchase_receipt_id=pr), steel_kg, 0, '材质证明书齐全');
  PERFORM fn_receipt_post(pr);
  PERFORM assert_eq('钢材入库数量', stock_qty('RAW-45-D40','RAW1'), steel_kg);
  PERFORM assert_eq('钢材入库金额=数量×含税价/1.13', stock_value('RAW-45-D40','RAW1'), steel_kg*round(steel_price/1.13,6), 0.01);
  PERFORM assert_raises('未检验不能过账', format('SELECT fn_receipt_post(fn_po_receive(%s,%s,%L::jsonb))', po_b, wh('RAW1'),
     jsonb_build_array(jsonb_build_object('po_item',(SELECT id FROM purchase_order_item WHERE purchase_order_id=po_b),'qty',1))::text), '未检验');
  -- 轴承到货 200，来料检 4 只不合格退回
  pr := fn_po_receive(po_b, wh('RAW1'), jsonb_build_array(jsonb_build_object('po_item',(SELECT id FROM purchase_order_item WHERE purchase_order_id=po_b),'qty',200)));
  PERFORM fn_incoming_inspection((SELECT id FROM purchase_receipt_item WHERE purchase_receipt_id=pr), 196, 4, '4 只游隙超差');
  PERFORM fn_receipt_post(pr);
  PERFORM assert_true('部分到货：采购单=部分收货', (SELECT status FROM purchase_order WHERE id=po_b)='partially_received');
  pr2 := fn_po_receive(po_b, wh('RAW1'), jsonb_build_array(jsonb_build_object('po_item',(SELECT id FROM purchase_order_item WHERE purchase_order_id=po_b),'qty',4)));
  PERFORM fn_incoming_inspection((SELECT id FROM purchase_receipt_item WHERE purchase_receipt_id=pr2), 4, 0);
  PERFORM fn_receipt_post(pr2);
  PERFORM assert_true('补货后采购单=已收货', (SELECT status FROM purchase_order WHERE id=po_b)='received');
  PERFORM assert_eq('轴承库存', stock_qty('BRG-6205','RAW1'), 200);
  -- 进项专票
  inv := fn_purchase_invoice('purchase_receipt', (SELECT min(id) FROM purchase_receipt WHERE purchase_order_id=po_s), 'JX-0001');
  PERFORM assert_eq('进项发票价税合计≈数量×含税价', (SELECT total_amount FROM invoice WHERE id=inv), steel_kg*steel_price, 0.05);
  PERFORM fn_purchase_invoice('purchase_receipt', pr, 'JX-0002');
  PERFORM fn_purchase_invoice('purchase_receipt', pr2, 'JX-0003');
  PERFORM assert_eq('应付暂估已全部冲平', (SELECT sum(g.credit-g.debit) FROM gl_entry g WHERE g.account_id=fn_acct('220201')), 0);
  PERFORM assert_true('进项专票税率=13%', NOT EXISTS (SELECT 1 FROM invoice_item ii JOIN invoice i ON i.id=ii.invoice_id WHERE i.direction='purchase' AND ii.tax_rate<>0.13));
END $$;
