-- 剧本 12：多工厂调拨：一厂成品仓 → 在途 → 二厂成品仓（金额随货转移）
SELECT use_tenant('DEMO');
DO $$
DECLARE tr bigint; v numeric := stock_value('SHAFT-ASSY','FG1'); q numeric := stock_qty('SHAFT-ASSY','FG1');
BEGIN
  INSERT INTO stock_transfer(from_warehouse_id, transit_warehouse_id, to_warehouse_id, item_id, qty)
  VALUES (wh('FG1'), wh('TRANSIT'), wh('FG2'), it('SHAFT-ASSY'), q) RETURNING id INTO tr;
  PERFORM fn_transfer_ship(tr);
  PERFORM assert_eq('发出后在途数量', stock_qty('SHAFT-ASSY','TRANSIT'), q);
  PERFORM assert_raises('未发出不能重复收货的状态迁移校验', format('UPDATE stock_transfer SET status=%L WHERE id=%s', 'draft', tr), '不允许的状态迁移');
  PERFORM fn_transfer_receive(tr);
  PERFORM assert_eq('二厂收货数量', stock_qty('SHAFT-ASSY','FG2'), q);
  PERFORM assert_eq('调拨金额不变', stock_value('SHAFT-ASSY','FG2'), v, 0.01);
  PERFORM assert_eq('在途清零', stock_qty('SHAFT-ASSY','TRANSIT'), 0);
  PERFORM assert_eq('在途科目清零', (SELECT coalesce(sum(debit-credit),0) FROM gl_entry WHERE account_id=fn_acct('1411')), 0);
END $$;
