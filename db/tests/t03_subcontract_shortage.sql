-- 剧本 3：外协回料短少且带不良，超定额扣款进应付
BEGIN;
SELECT plan(7);
SELECT use_tenant('DEMO');
SELECT is((SELECT shortage_qty FROM subcontract_settlement s JOIN subcontract_order o ON o.id=s.subcontract_order_id WHERE o.supplier_id=pty('SUB-PL')), 2::numeric, '电镀短少 2 件');
SELECT is((SELECT defect_qty FROM subcontract_settlement s JOIN subcontract_order o ON o.id=s.subcontract_order_id WHERE o.supplier_id=pty('SUB-PL')), 2::numeric, '电镀不良 2 件');
SELECT ok((SELECT deduction > 0 AND payable_amount = processing_fee - deduction FROM subcontract_settlement s JOIN subcontract_order o ON o.id=s.subcontract_order_id WHERE o.supplier_id=pty('SUB-PL')), '超定额扣款已从应付中扣除');
SELECT is((SELECT deduction FROM subcontract_settlement s JOIN subcontract_order o ON o.id=s.subcontract_order_id WHERE o.supplier_id=pty('SUB-HT')), 0::numeric, '调质无短少无扣款');
SELECT is((SELECT count(*) FROM subcontract_movement WHERE movement_type='receive'), 3::bigint, '回料流水 3 条');
SELECT throws_like($$UPDATE subcontract_movement SET good_qty=0$$, '%只增不改%', '发料/回料流水不可改');
SELECT ok((SELECT count(*) FROM ai_subcon_check_line WHERE verdict='mismatch') >= 3, 'AI 对账核对标出差异');
SELECT * FROM finish();
ROLLBACK;
