\set ON_ERROR_STOP on
DO $$ BEGIN
    IF current_database() <> 'boxeudelivery_validation' THEN RAISE EXCEPTION 'Disposable database required'; END IF;
END $$;
BEGIN;
CREATE FUNCTION pg_temp.verify(passed BOOLEAN, scenario TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF passed IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'FAIL %', scenario; END IF;
    RAISE NOTICE 'PASS %', scenario;
END $$;

DO $$
DECLARE
    project UUID := '11111111-1111-4111-8111-111111111111';
    supplier UUID := '22222222-2222-4222-8222-222222222222';
    goods UUID := '33333333-3333-4333-8333-333333333333';
    variant UUID := '44444444-4444-4444-8444-444444444444';
    actor UUID := '77777777-7777-4777-8777-777777777777';
    warehouse UUID := '18181818-1818-4818-8818-181818181818';
    next_supplier UUID := gen_random_uuid(); next_goods UUID := gen_random_uuid(); next_variant UUID := gen_random_uuid();
    item UUID := gen_random_uuid(); shared_photo UUID := gen_random_uuid(); unit_photo UUID := gen_random_uuid();
    intake UUID := gen_random_uuid(); receipt UUID := gen_random_uuid(); money UUID := gen_random_uuid();
    original_money JSONB; original_receipt JSONB; original_intake JSONB; original_item JSONB;
    blocked BOOLEAN; discarded UUID := gen_random_uuid(); order_line UUID := gen_random_uuid(); original_order_line JSONB;
BEGIN
    INSERT INTO crm.supplier(id,display_name,status_code,created_by_subject,updated_by_subject)
    VALUES(next_supplier,'Transfer destination','ACTIVE','verification','verification');
    INSERT INTO crm.project_supplier(project_id,supplier_id,status_code,operating_mode,created_by_subject,updated_by_subject)
    VALUES(project,next_supplier,'ACTIVE','MINI','verification','verification');
    INSERT INTO crm.supplier_goods_entry(id,project_id,supplier_id,name,created_by_subject,updated_by_subject)
    VALUES(next_goods,project,next_supplier,'Destination card','verification','verification');
    INSERT INTO crm.supplier_goods_variant(id,supplier_goods_entry_id,project_id,supplier_id,unit_code,
        attributes,attribute_signature,created_by_subject)
    VALUES(next_variant,next_goods,project,next_supplier,'UNSPECIFIED','[]','','verification');
    INSERT INTO crm.cargo_item(id,project_id,supplier_goods_entry_id,supplier_goods_variant_id,supplier_id,
        origin_code,status_code,created_by_subject,updated_by_subject,label_code,label_source_code,label_symbology_code,
        current_warehouse_id,accepted_by_account_id,accepted_at)
    VALUES(item,project,goods,variant,supplier,'SUPPLIER','AVAILABLE','verification','verification',
        'TRANSFER-'||item::TEXT,'EXTERNAL_SCAN','QR_CODE',warehouse,actor,now());
    PERFORM pg_temp.verify((SELECT count(*)=1 FROM crm.cargo_item_supplier_provenance WHERE cargo_item_id=item),
        'item insert records supplier provenance for old application images');
    INSERT INTO crm.cargo_item_photo(id,cargo_item_id,supplier_goods_entry_id,uploader_account_id,status_code,position,
        original_filename,declared_content_type,declared_size_bytes,declared_checksum_sha256,original_object_key,
        upload_expires_at,upload_completed_at,ready_at,gallery_scope_code)
    VALUES(shared_photo,item,goods,actor,'READY',9,'shared.jpg','image/jpeg',4,repeat('a',44),
        'verification/shared/'||shared_photo::TEXT,now()+interval '1 hour',now(),now(),'SUPPLIER_GOODS'),
        (unit_photo,item,goods,actor,'READY',0,'unit.jpg','image/jpeg',4,repeat('a',44),
        'verification/unit/'||unit_photo::TEXT,now()+interval '1 hour',now(),now(),'CARGO_ITEM');
    PERFORM pg_temp.verify((SELECT bool_and(project_id=project AND supplier_id=supplier)
        FROM crm.cargo_item_photo WHERE id IN (shared_photo,unit_photo)), 'photo insert derives gallery ownership');
    INSERT INTO crm.mini_supplier_intake(id,project_id,supplier_id,supplier_goods_entry_id,created_by_account_id,
        created_by_subject,completed_by_account_id,completed_by_subject,completed_at)
    VALUES(intake,project,supplier,goods,actor,'verification',actor,'verification',now());
    INSERT INTO crm.mini_supplier_intake_item(intake_id,cargo_item_id,project_id,supplier_id)
    VALUES(intake,item,project,supplier);
    INSERT INTO crm.mini_supplier_warehouse_receipt(id,project_id,supplier_id,supplier_goods_entry_id,
        supplier_goods_variant_id,warehouse_id,received_by_account_id,received_by_subject)
    VALUES(receipt,project,supplier,goods,variant,warehouse,actor,'verification');
    INSERT INTO crm.mini_supplier_warehouse_receipt_item(warehouse_receipt_id,cargo_item_id,project_id,supplier_id)
    VALUES(receipt,item,project,supplier);
    INSERT INTO crm.cargo_item_financial_entry(id,cargo_item_id,project_id,entry_type,amount,currency_code,
        created_by_subject,updated_by_subject)
    VALUES(money,item,project,'SUPPLIER_CONSIGNMENT_PRICE',123,'RUB','verification','verification');
    SELECT to_jsonb(m) INTO original_money FROM crm.cargo_item_financial_entry m WHERE id=money;
    SELECT to_jsonb(r) INTO original_receipt FROM crm.mini_supplier_warehouse_receipt_item r WHERE cargo_item_id=item;
    SELECT to_jsonb(i) INTO original_intake FROM crm.mini_supplier_intake_item i WHERE cargo_item_id=item;
    SELECT to_jsonb(i) - ARRAY['supplier_id','supplier_goods_entry_id','supplier_goods_variant_id']
        INTO original_item FROM crm.cargo_item i WHERE id=item;

    INSERT INTO crm.customer_order_line(id,customer_order_id,project_id,cargo_item_id,sequence_number,status_code,
        unit_price,currency_code,price_source_code,created_by_subject,updated_by_subject,
        removed_by_subject,removed_at,removal_reason)
    VALUES(order_line,'14141414-1414-4414-8414-141414141414',project,item,1,'REMOVED',10,'RUB','ORDER_ENTRY',
        'verification','verification','verification',now(),'Cancelled before transfer');
    SELECT to_jsonb(l) INTO original_order_line FROM crm.customer_order_line l WHERE id=order_line;
    UPDATE crm.customer_order_line l SET removed_goods_entry_id=goods,removed_goods_name=g.name,
        removed_supplier_sku=g.supplier_sku,removed_ean=g.ean,removed_manufacturer_article=g.manufacturer_article,
        removed_serial_number=i.serial_number,removed_label_code=i.label_code,removed_warehouse_id=i.current_warehouse_id
    FROM crm.cargo_item i JOIN crm.supplier_goods_entry g ON g.id=i.supplier_goods_entry_id
    WHERE l.id=order_line AND i.id=item;

    UPDATE crm.cargo_item SET supplier_id=next_supplier,supplier_goods_entry_id=next_goods,
        supplier_goods_variant_id=next_variant WHERE id=item;
    UPDATE crm.cargo_item_photo SET supplier_goods_entry_id=next_goods WHERE id=unit_photo;
    PERFORM pg_temp.verify((SELECT count(*)=2 FROM crm.cargo_item_supplier_provenance WHERE cargo_item_id=item),
        'supplier update appends new provenance without replacing old ownership');
    PERFORM pg_temp.verify((SELECT supplier_goods_entry_id=goods AND supplier_id=supplier AND cargo_item_id=item
        FROM crm.cargo_item_photo WHERE id=shared_photo), 'shared gallery retains its owner and upload-source identity');
    PERFORM pg_temp.verify((SELECT supplier_goods_entry_id=next_goods AND supplier_id=next_supplier AND cargo_item_id=item
        AND original_object_key='verification/unit/'||unit_photo::TEXT FROM crm.cargo_item_photo WHERE id=unit_photo),
        'exact-unit photo follows the unit without replacing its file');
    PERFORM pg_temp.verify((SELECT to_jsonb(i)-ARRAY['supplier_id','supplier_goods_entry_id','supplier_goods_variant_id']=original_item
        FROM crm.cargo_item i WHERE id=item), 'QR, warehouse custody and physical-unit identity survive transfer');
    PERFORM pg_temp.verify((SELECT to_jsonb(m)=original_money FROM crm.cargo_item_financial_entry m WHERE id=money)
        AND (SELECT to_jsonb(r)=original_receipt FROM crm.mini_supplier_warehouse_receipt_item r WHERE cargo_item_id=item)
        AND (SELECT to_jsonb(i)=original_intake FROM crm.mini_supplier_intake_item i WHERE cargo_item_id=item),
        'financial, receipt and intake history remains byte-for-byte unchanged');
    PERFORM pg_temp.verify((SELECT removed_goods_entry_id=goods AND removed_warehouse_id=warehouse
        AND (to_jsonb(l)-ARRAY['removed_goods_entry_id','removed_goods_name','removed_supplier_sku','removed_ean',
            'removed_manufacturer_article','removed_serial_number','removed_label_code','removed_warehouse_id'])
        = (original_order_line-ARRAY['removed_goods_entry_id','removed_goods_name','removed_supplier_sku','removed_ean',
            'removed_manufacturer_article','removed_serial_number','removed_label_code','removed_warehouse_id'])
        FROM crm.customer_order_line l WHERE id=order_line), 'removed order keeps original card, money, revisions and timestamps');
    blocked := FALSE;
    BEGIN UPDATE crm.customer_order_line SET removed_goods_entry_id=NULL WHERE id=order_line;
    EXCEPTION WHEN check_violation THEN blocked := TRUE; END;
    PERFORM pg_temp.verify(blocked, 'incomplete removed-line snapshots are rejected');

    blocked := FALSE;
    BEGIN
        UPDATE crm.cargo_item_photo SET project_id='11111111-1111-4111-8111-222222222222' WHERE id=unit_photo;
    EXCEPTION WHEN foreign_key_violation THEN blocked := TRUE; END;
    PERFORM pg_temp.verify(blocked, 'photo project spoofing remains constrained');
    blocked := FALSE;
    BEGIN DELETE FROM crm.cargo_item_supplier_provenance WHERE cargo_item_id=item AND supplier_id=supplier;
    EXCEPTION WHEN foreign_key_violation THEN blocked := TRUE; END;
    PERFORM pg_temp.verify(blocked, 'historical receipt and gallery prevent provenance removal');
    blocked := FALSE;
    BEGIN
        UPDATE crm.cargo_item SET inbound_delivery_id='20202020-2020-4020-8020-202020202020',
            inbound_delivery_line_id='21212121-2121-4121-8121-212121212121' WHERE id=item;
    EXCEPTION WHEN check_violation THEN blocked := TRUE; END;
    PERFORM pg_temp.verify(blocked, 'assigning a new delivery still requires its current supplier');

    UPDATE crm.cargo_item SET supplier_id=supplier,supplier_goods_entry_id=goods,supplier_goods_variant_id=variant WHERE id=item;
    UPDATE crm.cargo_item SET inbound_delivery_id='20202020-2020-4020-8020-202020202020',
        inbound_delivery_line_id='21212121-2121-4121-8121-212121212121' WHERE id=item;
    UPDATE crm.cargo_item SET supplier_id=next_supplier,supplier_goods_entry_id=next_goods,
        supplier_goods_variant_id=next_variant WHERE id=item;
    PERFORM pg_temp.verify((SELECT inbound_supplier_id=supplier FROM crm.cargo_item WHERE id=item),
        'current ownership correction retains original inbound delivery supplier');
    UPDATE crm.cargo_item SET inbound_delivery_id=NULL,inbound_delivery_line_id=NULL WHERE id=item;
    PERFORM pg_temp.verify((SELECT inbound_supplier_id IS NULL FROM crm.cargo_item WHERE id=item),
        'ordinary delivery release clears its supplier snapshot');
    PERFORM pg_temp.verify((SELECT count(*)=2 FROM crm.cargo_item_supplier_provenance WHERE cargo_item_id=item),
        'returning to an earlier owner does not duplicate provenance');
    INSERT INTO crm.cargo_item(id,project_id,supplier_goods_entry_id,supplier_goods_variant_id,supplier_id,
        origin_code,status_code,created_by_subject,updated_by_subject)
    VALUES(discarded,project,goods,variant,supplier,'SUPPLIER','IN_TRANSIT_TO_WAREHOUSE','verification','verification');
    DELETE FROM crm.cargo_item WHERE id=discarded;
    PERFORM pg_temp.verify(NOT EXISTS(SELECT 1 FROM crm.cargo_item_supplier_provenance WHERE cargo_item_id=discarded),
        'discarding an untouched provisional unit removes only its unused provenance');
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
ROLLBACK;
