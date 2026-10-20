-- 剧本 06：外协镀铬 回料短少且带不良 → 损耗定额 → 超定额扣款进应付 → AI 核对外协对账单
SELECT use_tenant('DEMO');
DO $$
DECLARE wo work_order; sc subcontract_order; scid bigint; s subcontract_settlement; rid bigint; fee numeric; over numeric; inv bigint;
BEGIN
  SELECT * INTO wo FROM work_order WHERE item_id=it('SHAFT-SEMI') AND parent_work_order_id IS NOT NULL;
  scid := fn_subcon_create(wo.id, 50, pty('SUB-PL'), wh('SUB-PL'));
  SELECT * INTO sc FROM subcontract_order WHERE id=scid;
  PERFORM assert_eq('损耗定额取参数', sc.loss_allowance, p('subcontract_loss_allowance'));
  PERFORM assert_eq('镀铬单价取参数', sc.unit_price, p('surface_chrome_cu_ni_cr'));
  PERFORM assert_raises('发出数量不能超过本工序可投入数', format('SELECT fn_subcon_send(%s, 100)', sc.id), '超过本工序可发数量');
  PERFORM fn_subcon_send(sc.id, 99, 'FH-PL-001');
  -- 分两次回料：先回 60 合格；再回 35 合格 + 2 不良（起皮）；另 2 件短少
  PERFORM fn_subcon_receive(sc.id, 60, 0, 'PL-SH-001');
  PERFORM fn_subcon_receive(sc.id, 35, 2, 'PL-SH-002 起皮2件');
  s := fn_subcon_settle(sc.id);
  fee := 95 * p('ex_shaft_chrome_area_dm2') * p('surface_chrome_cu_ni_cr');
  over := (2 + 2) - 99*p('subcontract_loss_allowance');
  PERFORM assert_eq('短少数=发出-合格-不良', s.shortage_qty, 2);
  PERFORM assert_eq('损耗定额件数=发出×1%', s.allowance_qty, 99*p('subcontract_loss_allowance'));
  PERFORM assert_eq('超定额件数', s.over_loss_qty, over);
  PERFORM assert_eq('加工费=合格数×面积×单价', s.processing_fee, round(fee,2));
  PERFORM assert_eq('扣款=超定额件数×在制品单件成本', s.deduction, round(over*sc.part_value,2));
  PERFORM assert_eq('应付=加工费-扣款', s.payable_amount, round(fee,2) - round(over*sc.part_value,2));
  PERFORM assert_true('外协单已结算', (SELECT status FROM subcontract_order WHERE id=sc.id)='settled');
  PERFORM assert_eq('镀铬工序完工=95，报废=4', (SELECT completed_qty*1000+scrap_qty FROM wo_operation WHERE work_order_id=wo.id AND seq=50), 95004);
  inv := fn_purchase_invoice('subcontract_settlement', s.id, 'JX-PL-01');
  PERFORM assert_eq('电镀厂应付余额=扣款后金额(发票价税合计)', (SELECT balance FROM v_party_balance WHERE party_id=pty('SUB-PL') AND ledger_type='payable'),
                    (SELECT total_amount FROM invoice WHERE id=inv));
  PERFORM assert_eq('发票价税合计与结算应付差额不超过 1 分', (SELECT total_amount FROM invoice WHERE id=inv), s.payable_amount, 0.011);

  -- AI 识别电镀厂对账单照片（假数据）：对方按 97 件合格、无不良、未扣款开账
  rid := fn_ai_check_subcon_statement(pty('SUB-PL'), jsonb_build_object('period', to_char(current_date,'YYYY-MM'), 'lines', jsonb_build_array(
           jsonb_build_object('order_no', sc.doc_no, 'sent_qty', 99, 'good_qty', 97, 'defect_qty', 0,
                              'amount', round(97*p('ex_shaft_chrome_area_dm2')*p('surface_chrome_cu_ni_cr'),2)),
           jsonb_build_object('order_no', 'SC-99999', 'amount', 120))));
  PERFORM assert_eq('AI 核对：差异字段数(合格数/不良数/金额)', (SELECT count(*) FROM ai_subcon_check_line WHERE ai_request_id=rid AND verdict='mismatch'), 3);
  PERFORM assert_eq('AI 核对：对方多出系统没有的单据', (SELECT count(*) FROM ai_subcon_check_line WHERE ai_request_id=rid AND verdict='missing_in_system'), 1);
  PERFORM assert_eq('AI 核对：金额差异=对方金额-系统应付', (SELECT diff FROM ai_subcon_check_line WHERE ai_request_id=rid AND field='amount'),
                    round(97*p('ex_shaft_chrome_area_dm2')*p('surface_chrome_cu_ni_cr'),2) - s.payable_amount);
END $$;
