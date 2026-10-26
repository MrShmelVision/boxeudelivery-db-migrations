\set ON_ERROR_STOP on
DO $$ BEGIN
    IF current_database()<>'boxeudelivery_validation' THEN RAISE EXCEPTION 'Disposable database required'; END IF;
END $$;
CREATE FUNCTION pg_temp.verify(passed BOOLEAN, scenario TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF passed IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'FAIL %', scenario; END IF;
    RAISE NOTICE 'PASS %', scenario;
END $$;
BEGIN;
CREATE FUNCTION pg_temp.stock_revision(expected INT, scenario TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.verify((SELECT count(*)=expected AND count(*) FILTER (
        WHERE project_id<>'11111111-1111-4111-8111-111111111111')=0
        FROM crm.website_catalog_revision WHERE transaction_id=txid_current()), scenario);
END $$;
CREATE FUNCTION pg_temp.clear_stock_revision() RETURNS VOID LANGUAGE sql AS $$
    DELETE FROM crm.website_catalog_revision WHERE transaction_id=txid_current();
$$;

INSERT INTO crm.warehouse(id,name,location_description,created_by_subject,updated_by_subject)
VALUES('15100000-0000-4000-8000-000000000001','Stock destination','Verification','verification','verification');
INSERT INTO crm.project_warehouse(project_id,warehouse_id,assigned_by_subject)
VALUES('11111111-1111-4111-8111-111111111111','15100000-0000-4000-8000-000000000001','verification');
INSERT INTO crm.cargo_item(id,project_id,supplier_goods_entry_id,supplier_goods_variant_id,supplier_id,
    origin_code,status_code,created_by_subject,updated_by_subject,label_code,label_source_code,label_symbology_code,
    current_warehouse_id,accepted_by_account_id,accepted_at)
SELECT id,'11111111-1111-4111-8111-111111111111','33333333-3333-4333-8333-333333333333',
    '44444444-4444-4444-8444-444444444444','22222222-2222-4222-8222-222222222222','SUPPLIER','AVAILABLE',
    'verification','verification','STOCK-'||id::TEXT,'EXTERNAL_SCAN','QR_CODE',
    '18181818-1818-4818-8818-181818181818','77777777-7777-4777-8777-777777777777',now()
FROM (VALUES('15100000-0000-4000-8000-000000000002'::UUID),('15100000-0000-4000-8000-000000000003'::UUID)) AS items(id);
SELECT pg_temp.clear_stock_revision();

INSERT INTO crm.mini_supplier_intake(id,project_id,supplier_id,supplier_goods_entry_id,created_by_account_id,created_by_subject)
VALUES('15100000-0000-4000-8000-000000000004','11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222','33333333-3333-4333-8333-333333333333',
    '77777777-7777-4777-8777-777777777777','verification');
SELECT pg_temp.stock_revision(1,'intake creation invalidates its project');
SELECT pg_temp.clear_stock_revision();
INSERT INTO crm.mini_supplier_intake_item(intake_id,cargo_item_id,project_id,supplier_id)
VALUES('15100000-0000-4000-8000-000000000004','15100000-0000-4000-8000-000000000002',
    '11111111-1111-4111-8111-111111111111','22222222-2222-4222-8222-222222222222');
SELECT pg_temp.stock_revision(1,'intake membership insert invalidates without a unit status change');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.mini_supplier_intake_item SET cargo_item_id='15100000-0000-4000-8000-000000000003'
WHERE intake_id='15100000-0000-4000-8000-000000000004';
SELECT pg_temp.stock_revision(1,'intake membership update invalidates');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.mini_supplier_intake_item SET cargo_item_id=cargo_item_id WHERE intake_id='15100000-0000-4000-8000-000000000004';
SELECT pg_temp.stock_revision(0,'unchanged intake membership is quiet');
UPDATE crm.mini_supplier_intake SET completed_at=now(),completed_by_account_id='77777777-7777-4777-8777-777777777777',
    completed_by_subject='verification' WHERE id='15100000-0000-4000-8000-000000000004';
SELECT pg_temp.stock_revision(1,'intake completion invalidates without an item status change');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.mini_supplier_intake SET completed_at=completed_at WHERE id='15100000-0000-4000-8000-000000000004';
SELECT pg_temp.stock_revision(0,'unchanged intake completion is quiet');
DELETE FROM crm.mini_supplier_intake_item WHERE intake_id='15100000-0000-4000-8000-000000000004';
SELECT pg_temp.stock_revision(1,'intake membership deletion invalidates');
SELECT pg_temp.clear_stock_revision();
DELETE FROM crm.mini_supplier_intake WHERE id='15100000-0000-4000-8000-000000000004';
SELECT pg_temp.stock_revision(1,'intake deletion invalidates');
SELECT pg_temp.clear_stock_revision();

INSERT INTO crm.warehouse_relocation(id,client_request_id,relocation_number,project_id,source_warehouse_id,
    destination_warehouse_id,status_code,created_by_account_id,created_by_subject,updated_by_subject)
VALUES('15100000-0000-4000-8000-000000000005',gen_random_uuid(),'REL-2026-888888',
    '11111111-1111-4111-8111-111111111111','18181818-1818-4818-8818-181818181818',
    '15100000-0000-4000-8000-000000000001','DRAFT','77777777-7777-4777-8777-777777777777','verification','verification');
SELECT pg_temp.stock_revision(1,'relocation creation invalidates');
SELECT pg_temp.clear_stock_revision();
INSERT INTO crm.warehouse_relocation_item(relocation_id,cargo_item_id,project_id,source_warehouse_id,
    destination_warehouse_id,label_code_snapshot,sequence_number)
VALUES('15100000-0000-4000-8000-000000000005','15100000-0000-4000-8000-000000000002',
    '11111111-1111-4111-8111-111111111111','18181818-1818-4818-8818-181818181818',
    '15100000-0000-4000-8000-000000000001','STOCK-15100000-0000-4000-8000-000000000002',1);
SELECT pg_temp.stock_revision(1,'draft relocation reserves stock before dispatch');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.warehouse_relocation_item SET cargo_item_id='15100000-0000-4000-8000-000000000003'
WHERE relocation_id='15100000-0000-4000-8000-000000000005';
SELECT pg_temp.stock_revision(1,'relocation membership update invalidates');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.warehouse_relocation_item SET cargo_item_id=cargo_item_id
WHERE relocation_id='15100000-0000-4000-8000-000000000005';
SELECT pg_temp.stock_revision(0,'unchanged relocation membership is quiet');
UPDATE crm.warehouse_relocation SET status_code='CANCELLED',cancelled_at=now(),
    cancelled_by_account_id='77777777-7777-4777-8777-777777777777',cancelled_by_subject='verification',
    cancellation_reason='Verification' WHERE id='15100000-0000-4000-8000-000000000005';
SELECT pg_temp.stock_revision(1,'relocation cancellation releases stock without a unit status change');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.warehouse_relocation SET status_code=status_code WHERE id='15100000-0000-4000-8000-000000000005';
SELECT pg_temp.stock_revision(0,'unchanged relocation status is quiet');
DELETE FROM crm.warehouse_relocation_item WHERE relocation_id='15100000-0000-4000-8000-000000000005';
SELECT pg_temp.stock_revision(1,'relocation membership deletion invalidates');
SELECT pg_temp.clear_stock_revision();
DELETE FROM crm.warehouse_relocation WHERE id='15100000-0000-4000-8000-000000000005';
SELECT pg_temp.stock_revision(1,'relocation deletion invalidates');
SELECT pg_temp.clear_stock_revision();

INSERT INTO crm.conversation(id,project_id,kind_code)
VALUES('15100000-0000-4000-8000-000000000006','11111111-1111-4111-8111-111111111111','INBOUND_DELIVERY');
INSERT INTO crm.inbound_delivery(id,project_id,supplier_id,target_warehouse_id,status_code,
    created_by_subject,updated_by_subject,delivery_number,conversation_id,courier_distribution_mode,transport_mode)
VALUES('15100000-0000-4000-8000-000000000007','11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222','18181818-1818-4818-8818-181818181818','DRAFT',
    'verification','verification','IN-2026-888888','15100000-0000-4000-8000-000000000006','OPEN_POOL','DIRECT_TO_WAREHOUSE');
SELECT pg_temp.stock_revision(1,'inbound delivery creation invalidates');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.inbound_delivery SET status_code='CANCELLED' WHERE id='15100000-0000-4000-8000-000000000007';
SELECT pg_temp.stock_revision(1,'inbound cancellation invalidates');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.inbound_delivery SET status_code=status_code WHERE id='15100000-0000-4000-8000-000000000007';
SELECT pg_temp.stock_revision(0,'unchanged inbound status is quiet');
DELETE FROM crm.inbound_delivery WHERE id='15100000-0000-4000-8000-000000000007';
SELECT pg_temp.stock_revision(1,'inbound deletion invalidates');
SELECT pg_temp.clear_stock_revision();

UPDATE crm.cargo_item SET current_warehouse_id='15100000-0000-4000-8000-000000000001'
WHERE id='15100000-0000-4000-8000-000000000002';
SELECT pg_temp.stock_revision(1,'warehouse custody changes invalidate');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.cargo_item SET accepted_at=accepted_at+interval '1 second' WHERE id='15100000-0000-4000-8000-000000000002';
SELECT pg_temp.stock_revision(1,'receipt attribution changes invalidate');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.cargo_item SET current_warehouse_id=current_warehouse_id,accepted_at=accepted_at
WHERE id='15100000-0000-4000-8000-000000000002';
SELECT pg_temp.stock_revision(0,'unchanged warehouse and receipt facts are quiet');
UPDATE crm.cargo_item SET inbound_delivery_id='20202020-2020-4020-8020-202020202020',
    inbound_delivery_line_id='21212121-2121-4121-8121-212121212121' WHERE id='15100000-0000-4000-8000-000000000002';
SELECT pg_temp.stock_revision(1,'delivery association invalidates without changing item status');
SELECT pg_temp.clear_stock_revision();
UPDATE crm.cargo_item SET inbound_delivery_id=NULL,inbound_delivery_line_id=NULL
WHERE id='15100000-0000-4000-8000-000000000002';
SELECT pg_temp.stock_revision(1,'delivery release invalidates without changing item status');
ROLLBACK;
SELECT pg_temp.verify(NOT EXISTS(SELECT 1 FROM crm.cargo_item WHERE id='15100000-0000-4000-8000-000000000002'),
    'stock invalidation verification rolls back every business row');
