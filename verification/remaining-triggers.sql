\set ON_ERROR_STOP on
DO $$ BEGIN
    IF current_database() <> 'boxeudelivery_validation' THEN
        RAISE EXCEPTION 'Disposable verification database required';
    END IF;
END $$;

CREATE FUNCTION pg_temp.verify(passed BOOLEAN, scenario TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF passed IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'FAIL %', scenario; END IF;
    RAISE NOTICE 'PASS %', scenario;
END $$;

-- Inventory is deliberate: adding a trigger requires adding an execution scenario.
SELECT pg_temp.verify((SELECT array_agg(c.relname || ':' || t.tgname ORDER BY c.relname,t.tgname)
    FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace WHERE NOT t.tgisinternal AND n.nspname='crm') = ARRAY[
    'border_tariff_category:website_catalog_changed',
    'border_tariff_category_group:website_catalog_changed',
    'border_tariff_subcategory:website_catalog_changed',
    'cargo_item:sales_stock_exclusive',
    'cargo_item:trg_cargo_item_supplier_provenance',
    'cargo_item:website_catalog_changed',
    'cargo_item:website_stock_eligibility_changed',
    'cargo_item_financial_entry:website_catalog_changed',
    'cargo_item_photo:trg_cargo_photo_owner',
    'cargo_item_photo:website_catalog_changed',
    'cargo_item_photo_object:website_catalog_changed',
    'catalogue_publication:catalogue_publication_immutable',
    'customer_order_line:sales_stock_exclusive',
    'customer_order_line:website_catalog_changed',
    'inbound_delivery:website_stock_eligibility_changed',
    'inbound_delivery_line:trg_inbound_delivery_line_legacy_attributes',
    'mini_supplier_intake:website_stock_eligibility_changed',
    'mini_supplier_intake_item:website_stock_eligibility_changed',
    'parcel_expense:parcel_expense_immutable',
    'parcel_expense:parcel_expense_total',
    'parcel_expense_allocation:parcel_expense_allocation_immutable',
    'parcel_expense_allocation:parcel_expense_allocation_total',
    'product_brand:website_catalog_brand_changed',
    'sales_request_line:sales_paid_composition_guard',
    'settlement_money_operation:sales_prepayment_retention',
    'supplier_goods_entry:supplier_goods_article_number',
    'supplier_goods_entry:website_catalog_brand_changed',
    'supplier_goods_entry:website_catalog_changed',
    'supplier_goods_variant:trg_supplier_goods_variant_legacy_attributes',
    'supplier_goods_variant:website_catalog_changed',
    'task:trg_task_subcategory_usage',
    'warehouse_relocation:website_stock_eligibility_changed',
    'warehouse_relocation_item:sales_stock_exclusive',
    'warehouse_relocation_item:website_stock_eligibility_changed',
    'website_catalog_revision:website_catalog_notify',
    'website_store_settings:website_store_settings_changed'], 'all active CRM triggers have scenarios');

BEGIN;
SELECT txid_current() AS store_settings_transaction \gset
INSERT INTO crm.website_store_settings(project_id,version,pickup_enabled,city,address,opening_hours,pickup_fee,updated_at)
VALUES('11111111-1111-4111-8111-111111111111',1,true,'Test city','Test address','Daily',0,now());
SELECT pg_temp.verify(EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE project_id='11111111-1111-4111-8111-111111111111' AND transaction_id=txid_current()), 'pickup settings insertion publishes a project revision');
UPDATE crm.website_store_settings SET pickup_fee=250,version=2 WHERE project_id='11111111-1111-4111-8111-111111111111';
SELECT pg_temp.verify((SELECT count(*)=1 FROM crm.website_catalog_revision WHERE project_id='11111111-1111-4111-8111-111111111111' AND transaction_id=txid_current()), 'pickup changes coalesce within the transaction');
DO $$ BEGIN
    BEGIN
        UPDATE crm.website_store_settings SET address=NULL WHERE project_id='11111111-1111-4111-8111-111111111111';
        RAISE EXCEPTION 'Enabled pickup accepted a missing address';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END $$;
ROLLBACK;
SELECT pg_temp.verify(NOT EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE transaction_id=:'store_settings_transaction'::BIGINT), 'rolled back pickup settings do not publish');
SELECT pg_temp.verify(NOT EXISTS(SELECT 1 FROM crm.website_store_settings), 'pickup settings rollback preserves the initial state');

BEGIN;
DO $$
DECLARE previous JSONB; preset INTEGER;
BEGIN
    SELECT to_jsonb(g) INTO STRICT previous FROM crm.supplier_goods_entry g
        WHERE id='33333333-3333-4333-8333-333333333333';
    PERFORM pg_temp.verify(previous->>'website_delivery_days' IS NULL, 'existing goods have no invented delivery promise');
    FOREACH preset IN ARRAY ARRAY[7,14,21] LOOP
        UPDATE crm.supplier_goods_entry SET website_delivery_days=preset
            WHERE id='33333333-3333-4333-8333-333333333333';
        PERFORM pg_temp.verify((SELECT website_delivery_days=preset AND to_jsonb(g)-'website_delivery_days'=previous-'website_delivery_days'
            FROM crm.supplier_goods_entry g WHERE id='33333333-3333-4333-8333-333333333333'),
            'delivery preset preserves every independent goods fact');
    END LOOP;
    BEGIN
        UPDATE crm.supplier_goods_entry SET website_delivery_days=8 WHERE id='33333333-3333-4333-8333-333333333333';
        RAISE EXCEPTION 'Unsupported delivery preset must fail';
    EXCEPTION WHEN check_violation THEN NULL; END;
    UPDATE crm.supplier_goods_entry SET website_delivery_days=NULL WHERE id='33333333-3333-4333-8333-333333333333';
    PERFORM pg_temp.verify(NOT EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE transaction_id=txid_current()),
        'CRM-only delivery setting does not invalidate website publication');
END $$;
ROLLBACK;

BEGIN;
DO $$
DECLARE
    previous JSONB;
    percentage INTEGER;
BEGIN
    SELECT to_jsonb(g) INTO STRICT previous FROM crm.supplier_goods_entry g
        WHERE id='33333333-3333-4333-8333-333333333333';
    PERFORM pg_temp.verify(previous->>'website_prepayment_percent' IS NULL,
        'existing goods have no invented prepayment');
    FOREACH percentage IN ARRAY ARRAY[0,1,25,50,99,100] LOOP
        UPDATE crm.supplier_goods_entry SET website_prepayment_percent=percentage
            WHERE id='33333333-3333-4333-8333-333333333333';
        PERFORM pg_temp.verify((SELECT website_prepayment_percent=percentage
            AND to_jsonb(g)-'website_prepayment_percent'=previous-'website_prepayment_percent'
            FROM crm.supplier_goods_entry g WHERE id='33333333-3333-4333-8333-333333333333'),
            'prepayment preserves independent goods facts including price and delivery');
    END LOOP;
    FOREACH percentage IN ARRAY ARRAY[-1,101] LOOP
        BEGIN
            UPDATE crm.supplier_goods_entry SET website_prepayment_percent=percentage
                WHERE id='33333333-3333-4333-8333-333333333333';
            RAISE EXCEPTION 'Out-of-range prepayment must fail';
        EXCEPTION WHEN check_violation THEN NULL;
        END;
    END LOOP;
    UPDATE crm.supplier_goods_entry SET website_prepayment_percent=NULL
        WHERE id='33333333-3333-4333-8333-333333333333';
    PERFORM pg_temp.verify(NOT EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE transaction_id=txid_current()),
        'CRM-only prepayment does not invalidate website publication');
END $$;
ROLLBACK;

BEGIN;
DO $$
DECLARE
    goods UUID := gen_random_uuid();
    source RECORD;
    article TEXT;
    second_article TEXT;
BEGIN
    SELECT g.*,p.task_prefix INTO STRICT source FROM crm.supplier_goods_entry g
        JOIN crm.project p ON p.id=g.project_id WHERE g.id='33333333-3333-4333-8333-333333333333';
    PERFORM pg_temp.verify(NOT EXISTS(SELECT 1 FROM crm.supplier_goods_entry g
        LEFT JOIN crm.supplier_goods_article_number n USING(article_number)
        WHERE g.article_number IS NULL OR n.article_number IS NULL),'all current and historical goods have reserved articles');
    INSERT INTO crm.supplier_goods_entry(id,project_id,supplier_id,name,created_by_subject,updated_by_subject)
        VALUES(goods,source.project_id,source.supplier_id,'Article verification','verification','verification')
        RETURNING article_number INTO article;
    PERFORM pg_temp.verify(article ~ ('^' || source.task_prefix || '-[1-9][0-9]{5}$'),
        'goods article uses project task prefix and six random digits');
    UPDATE crm.supplier_goods_entry SET article_number=article_number,name='Renamed article verification' WHERE id=goods;
    PERFORM pg_temp.verify((SELECT article_number=article FROM crm.supplier_goods_entry WHERE id=goods),
        'ordinary edits and no-op article updates preserve the number');
    BEGIN
        UPDATE crm.supplier_goods_entry SET article_number=source.article_number WHERE id=goods;
        RAISE EXCEPTION 'Manual article change must fail';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        UPDATE crm.supplier_goods_entry SET article_number=NULL WHERE id=goods;
        RAISE EXCEPTION 'Clearing article must fail';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        INSERT INTO crm.supplier_goods_entry(id,project_id,supplier_id,name,created_by_subject,updated_by_subject,article_number)
            VALUES(gen_random_uuid(),source.project_id,source.supplier_id,'Manual article','verification','verification',article);
        RAISE EXCEPTION 'Caller supplied article must fail';
    EXCEPTION WHEN check_violation THEN NULL; END;
    UPDATE crm.project SET task_prefix='ART150' WHERE id=source.project_id;
    INSERT INTO crm.supplier_goods_entry(id,project_id,supplier_id,name,created_by_subject,updated_by_subject)
        VALUES(gen_random_uuid(),source.project_id,source.supplier_id,'New prefix article','verification','verification')
        RETURNING article_number INTO second_article;
    PERFORM pg_temp.verify(second_article LIKE 'ART150-%'
        AND (SELECT article_number=article FROM crm.supplier_goods_entry WHERE id=goods),
        'a changed project prefix applies only to new cards');
    DELETE FROM crm.supplier_goods_entry WHERE id=goods;
    PERFORM pg_temp.verify(EXISTS(SELECT 1 FROM crm.supplier_goods_article_number WHERE article_number=article),
        'deleted goods article remains reserved');
END $$;
ROLLBACK;

DO $$
DECLARE brand UUID := 'b146b146-b146-4146-8146-b146b146b146';
BEGIN
    INSERT INTO crm.product_brand(id,name,created_by_subject,updated_by_subject,created_at,updated_at)
    VALUES(brand,'Verification brand','verification','verification',now(),now());
    PERFORM pg_temp.verify(NOT EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE transaction_id=txid_current()),'unused brand does not invalidate catalogue');
    UPDATE crm.supplier_goods_entry SET brand_id=brand WHERE id='33333333-3333-4333-8333-333333333333';
    PERFORM pg_temp.verify((SELECT count(*)=1 AND bool_and(project_id='11111111-1111-4111-8111-111111111111'::uuid)
        FROM crm.website_catalog_revision WHERE transaction_id=txid_current()),'brand assignment invalidates only its project');
    BEGIN
        DELETE FROM crm.product_brand WHERE id=brand;
        RAISE EXCEPTION 'Used brand deletion must fail';
    EXCEPTION WHEN foreign_key_violation THEN NULL; END;
    BEGIN
        INSERT INTO crm.product_brand(id,name,created_by_subject,updated_by_subject,created_at,updated_at)
        VALUES(gen_random_uuid(),'verification BRAND','verification','verification',now(),now());
        RAISE EXCEPTION 'Case-insensitive duplicate brand must fail';
    EXCEPTION WHEN unique_violation THEN NULL; END;
END $$;
DO $$ BEGIN
    UPDATE crm.product_brand SET name='Renamed verification brand' WHERE id='b146b146-b146-4146-8146-b146b146b146';
    PERFORM pg_temp.verify((SELECT count(*)=1 AND bool_and(project_id='11111111-1111-4111-8111-111111111111'::uuid)
        FROM crm.website_catalog_revision WHERE transaction_id=txid_current()),'brand rename invalidates only referenced projects');
END $$;
DO $$ BEGIN
    UPDATE crm.product_brand SET name=name WHERE id='b146b146-b146-4146-8146-b146b146b146';
    UPDATE crm.supplier_goods_entry SET brand_id=brand_id WHERE id='33333333-3333-4333-8333-333333333333';
    PERFORM pg_temp.verify(NOT EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE transaction_id=txid_current()),'no-op brand changes do not invalidate');
END $$;
BEGIN;
UPDATE crm.supplier_goods_entry SET brand_id=NULL WHERE id='33333333-3333-4333-8333-333333333333';
SELECT pg_temp.verify(EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE transaction_id=txid_current()),'brand removal invalidates before rollback');
ROLLBACK;
DO $$ BEGIN
    PERFORM pg_temp.verify((SELECT brand_id IS NOT NULL FROM crm.supplier_goods_entry WHERE id='33333333-3333-4333-8333-333333333333'),'brand rollback restores assignment');
    UPDATE crm.supplier_goods_entry SET brand_id=NULL WHERE id='33333333-3333-4333-8333-333333333333';
    PERFORM pg_temp.verify(EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE transaction_id=txid_current()),'brand removal invalidates catalogue');
    DELETE FROM crm.product_brand WHERE id='b146b146-b146-4146-8146-b146b146b146';
END $$;

DO $$
DECLARE sample RECORD; variant UUID; actual JSONB; signature TEXT;
BEGIN
    FOR sample IN SELECT * FROM (VALUES
        ('SIZE','SIZE'),('MILLILITER','VOLUME'),('LITER','VOLUME'),('GRAM','WEIGHT'),
        ('KILOGRAM','WEIGHT'),('MILLIMETER','LENGTH'),('CENTIMETER','LENGTH'),('METER','LENGTH')
    ) AS cases(unit_code,attribute_type) LOOP
        variant := gen_random_uuid();
        INSERT INTO crm.supplier_goods_variant(id,supplier_goods_entry_id,project_id,supplier_id,
            value_text,unit_code,created_by_subject)
        VALUES(variant,'33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111',
            '22222222-2222-4222-8222-222222222222',' 12 ',sample.unit_code,'verification');
        SELECT attributes,attribute_signature INTO actual,signature FROM crm.supplier_goods_variant WHERE id=variant;
        PERFORM pg_temp.verify(actual->0->>'type'=sample.attribute_type
            AND actual->0->>'value'=' 12 '
            AND actual->0->>'unit' IS NOT DISTINCT FROM CASE WHEN sample.unit_code='SIZE' THEN NULL ELSE sample.unit_code END
            AND signature=sample.attribute_type || '|MTI=|' || CASE WHEN sample.unit_code='SIZE' THEN '' ELSE sample.unit_code END,
            'legacy variant insert '||sample.unit_code);
        DELETE FROM crm.supplier_goods_variant WHERE id=variant;
    END LOOP;
END $$;

INSERT INTO crm.warehouse(id,name,location_description,created_by_subject,updated_by_subject)
VALUES('18181818-1818-4818-8818-181818181818','Verification warehouse','Isolated fixture','verification','verification');
INSERT INTO crm.project_warehouse(project_id,warehouse_id,assigned_by_subject)
VALUES('11111111-1111-4111-8111-111111111111','18181818-1818-4818-8818-181818181818','verification');
INSERT INTO crm.conversation(id,project_id,kind_code)
VALUES('19191919-1919-4919-8919-191919191919','11111111-1111-4111-8111-111111111111','INBOUND_DELIVERY');
INSERT INTO crm.inbound_delivery(id,project_id,supplier_id,target_warehouse_id,status_code,
    created_by_subject,updated_by_subject,delivery_number,conversation_id,courier_distribution_mode,transport_mode)
VALUES('20202020-2020-4020-8020-202020202020','11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222','18181818-1818-4818-8818-181818181818','DRAFT',
    'verification','verification','IN-2026-999999','19191919-1919-4919-8919-191919191919','OPEN_POOL','DIRECT_TO_WAREHOUSE');
INSERT INTO crm.inbound_delivery_line(id,inbound_delivery_id,name,declared_quantity,created_by_subject,
    updated_by_subject,supplier_goods_entry_id,project_id,supplier_id,supplier_goods_variant_id,variant_unit_code,variant_value_text)
VALUES('21212121-2121-4121-8121-212121212121','20202020-2020-4020-8020-202020202020','Legacy line',1,
    'verification','verification','33333333-3333-4333-8333-333333333333','11111111-1111-4111-8111-111111111111',
    '22222222-2222-4222-8222-222222222222','44444444-4444-4444-8444-444444444444','SIZE','XL');
SELECT pg_temp.verify((SELECT variant_attributes='[{"type":"SIZE","value":"XL","unit":null}]'::jsonb
    FROM crm.inbound_delivery_line WHERE id='21212121-2121-4121-8121-212121212121'), 'legacy inbound line insert fills attributes');

INSERT INTO crm.task_category(id,country_code,name,created_by_subject,updated_by_subject,created_at,updated_at)
VALUES('23232323-2323-4323-8323-232323232323','PL','Verification category','verification','verification',now(),now());
INSERT INTO crm.task_subcategory(id,category_id,country_code,name,created_by_subject,updated_by_subject,created_at,updated_at)
VALUES('24242424-2424-4424-8424-242424242424','23232323-2323-4323-8323-232323232323','PL',
    'First subcategory','verification','verification',now(),now()),
('25252525-2525-4525-8525-252525252525','23232323-2323-4323-8323-232323232323','PL',
    'Second subcategory','verification','verification',now(),now());
INSERT INTO crm.conversation(id,project_id,kind_code)
VALUES('26262626-2626-4626-8626-262626262626','11111111-1111-4111-8111-111111111111','TASK');
INSERT INTO crm.task(id,project_id,conversation_id,task_key,sequence_number,title,deadline_at,deadline_zone_id,
    created_by_account_id,updated_by_account_id,task_category_id,task_subcategory_id)
VALUES('27272727-2727-4727-8727-272727272727','11111111-1111-4111-8111-111111111111',
    '26262626-2626-4626-8626-262626262626','SMOKE-999999',999999,'Verification task',now()+interval '1 day','Europe/Warsaw',
    '77777777-7777-4777-8777-777777777777','77777777-7777-4777-8777-777777777777',
    '23232323-2323-4323-8323-232323232323','24242424-2424-4424-8424-242424242424');
SELECT pg_temp.verify((SELECT count(*)=1 FROM crm.task_subcategory_usage WHERE task_id='27272727-2727-4727-8727-272727272727'), 'task insert records subcategory usage');
UPDATE crm.task SET task_subcategory_id=task_subcategory_id WHERE id='27272727-2727-4727-8727-272727272727';
SELECT pg_temp.verify((SELECT count(*)=1 FROM crm.task_subcategory_usage WHERE task_id='27272727-2727-4727-8727-272727272727'), 'repeated task classification is idempotent');
UPDATE crm.task SET task_subcategory_id='25252525-2525-4525-8525-252525252525' WHERE id='27272727-2727-4727-8727-272727272727';
UPDATE crm.task SET task_subcategory_id=NULL WHERE id='27272727-2727-4727-8727-272727272727';
SELECT pg_temp.verify((SELECT count(*)=2 FROM crm.task_subcategory_usage WHERE task_id='27272727-2727-4727-8727-272727272727'), 'task classification keeps immutable usage history');
DELETE FROM crm.task WHERE id='27272727-2727-4727-8727-272727272727';
SELECT pg_temp.verify((SELECT count(*)=2 FROM crm.task_subcategory_usage WHERE task_id='27272727-2727-4727-8727-272727272727'), 'task removal preserves usage evidence');

DO $$
DECLARE invalid JSONB; valid JSONB;
BEGIN
    FOR invalid IN SELECT value FROM (VALUES
        ('{}'::jsonb),('false'),('1'),('"text"'),('[null]'),('[{}]'),
        ('[{"text":"bad","tone":"UNKNOWN"}]'),('[{"text":"bad","tone":"BRAND","icon":"UNKNOWN"}]'),
        ('[{"text":"bad","tone":"BRAND","style":"UNKNOWN"}]'),('[{"text":"bad","tone":"BRAND","size":"UNKNOWN"}]'),
        ('[{"text":" duplicate ","tone":"BRAND"}]'),('[{"text":"DUP","tone":"BRAND"},{"text":"dup","tone":"INFO"}]')
    ) AS samples(value) LOOP
        PERFORM pg_temp.verify(crm.valid_goods_website_badges(invalid)=FALSE,'invalid label value rejected: '||invalid::text);
    END LOOP;
    FOREACH valid IN ARRAY ARRAY['[]'::jsonb,'[{"text":"Legacy","tone":"BRAND"}]'::jsonb,
        '[{"text":"New","tone":"INFO","icon":"NONE","style":"OUTLINE","size":"LARGE"}]'::jsonb] LOOP
        PERFORM pg_temp.verify(crm.valid_goods_website_badges(valid),'compatible label value accepted');
    END LOOP;
END $$;

BEGIN;
DO $$
DECLARE
    request_id UUID := gen_random_uuid();
    first_line UUID := gen_random_uuid();
    second_line UUID := gen_random_uuid();
    stock UUID := gen_random_uuid();
    expected UUID := gen_random_uuid();
    stock_unit UUID := gen_random_uuid();
    expected_unit UUID := gen_random_uuid();
    assignment_id UUID := gen_random_uuid();
    order_id UUID := gen_random_uuid();
    order_line_id UUID := gen_random_uuid();
    destination UUID := gen_random_uuid();
    relocation_id UUID := gen_random_uuid();
    project UUID := '11111111-1111-4111-8111-111111111111';
    supplier UUID := '22222222-2222-4222-8222-222222222222';
    actor UUID := '77777777-7777-4777-8777-777777777777';
    warehouse UUID := '18181818-1818-4818-8818-181818181818';
BEGIN
    INSERT INTO crm.sales_request(id,request_number,project_id,client_request_id,intake_fingerprint,customer_name,customer_phone,
        receipt_preference,status_code,manager_account_id,agreed_terms,terms_agreed_at,created_by_subject,updated_by_subject,created_at,updated_at)
    VALUES(request_id,'SALE-VERIFY',project,gen_random_uuid(),repeat('a',64),'Synthetic customer','+79990000000',
        'TOGETHER','AWAITING_PREPAYMENT',actor,'Agreed',now(),'verification','verification',now(),now());
    INSERT INTO crm.sales_request_line(id,sales_request_id,project_id,sequence_number,product_name,quantity,attributes,unit_price,currency_code,required_prepayment)
    VALUES(first_line,request_id,project,1,'Ready unit',1,'[]',100,'RUB',50),
        (second_line,request_id,project,2,'Expected unit',1,'[]',100,'RUB',50);
    INSERT INTO crm.cargo_item(id,project_id,supplier_goods_entry_id,supplier_goods_variant_id,supplier_id,origin_code,status_code,
        created_by_subject,updated_by_subject,label_code,label_source_code,label_symbology_code,current_warehouse_id,accepted_by_account_id,accepted_at)
    VALUES(stock,project,'33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444',supplier,'SUPPLIER','AVAILABLE',
        'verification','verification','SALE-'||stock::text,'EXTERNAL_SCAN','QR_CODE',warehouse,actor,now());
    BEGIN
        UPDATE crm.cargo_item SET sales_request_line_id=first_line WHERE id=stock;
        RAISE EXCEPTION 'Unpaid reservation accepted';
    EXCEPTION WHEN check_violation THEN NULL; END;
    INSERT INTO crm.sales_request_line(id,sales_request_id,project_id,sequence_number,product_name,quantity,attributes)
    VALUES(gen_random_uuid(),request_id,project,3,'Draft edit verification',1,'[]');
    UPDATE crm.sales_request_line SET product_name='Revised before payment' WHERE sales_request_id=request_id AND sequence_number=3;
    DELETE FROM crm.sales_request_line WHERE sales_request_id=request_id AND sequence_number=3;
    BEGIN
        UPDATE crm.sales_request_line SET id=gen_random_uuid() WHERE id=first_line;
        RAISE EXCEPTION 'Sales line identity was changed';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        UPDATE crm.sales_request_line SET sales_request_id=gen_random_uuid() WHERE id=first_line;
        RAISE EXCEPTION 'Sales line was moved between requests';
    EXCEPTION WHEN check_violation THEN NULL; END;
    UPDATE crm.sales_request SET status_code='PAID',payment_confirmed_at=now() WHERE id=request_id;
    BEGIN
        UPDATE crm.sales_request_line SET quantity=quantity+1 WHERE id=first_line;
        RAISE EXCEPTION 'Paid composition update was accepted';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        DELETE FROM crm.sales_request_line WHERE id=first_line;
        RAISE EXCEPTION 'Paid composition delete was accepted';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN
        INSERT INTO crm.sales_request_line(id,sales_request_id,project_id,sequence_number,product_name,quantity,attributes)
        VALUES(gen_random_uuid(),request_id,project,3,'Forbidden paid addition',1,'[]');
        RAISE EXCEPTION 'Paid composition insertion was accepted';
    EXCEPTION WHEN check_violation THEN NULL; END;
    PERFORM pg_temp.verify(TRUE,'composition insert/update/delete allowed before payment and rejected after confirmation');

    UPDATE crm.cargo_item SET sales_request_line_id=first_line WHERE id=stock;
    INSERT INTO crm.cargo_sales_unit(id,project_id,sales_request_id,sales_request_line_id,cargo_item_id,unit_number,
        unit_price,currency_code,prepayment_amount,product_confirmation,reserved_at,received_at,received_warehouse_id)
    VALUES(stock_unit,project,request_id,first_line,stock,1,100,'RUB',50,'Confirmed',now(),now(),warehouse);
    PERFORM pg_temp.verify(EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE project_id=project AND transaction_id=txid_current()),'sales reservation invalidates the public free-stock revision');
    BEGIN
        INSERT INTO crm.customer_order_line(id,customer_order_id,project_id,cargo_item_id,sequence_number,status_code,
            unit_price,currency_code,price_source_code,created_by_subject,updated_by_subject)
        VALUES(gen_random_uuid(),'14141414-1414-4414-8414-141414141414',project,stock,991,'DRAFT',100,'RUB','ORDER_ENTRY','verification','verification');
        RAISE EXCEPTION 'Ordinary order stole sales stock';
    EXCEPTION WHEN check_violation THEN NULL; END;
    INSERT INTO crm.warehouse(id,name,location_description,created_by_subject,updated_by_subject)
    VALUES(destination,'Sales verification destination','Synthetic','verification','verification');
    INSERT INTO crm.project_warehouse(project_id,warehouse_id,assigned_by_subject) VALUES(project,destination,'verification');
    INSERT INTO crm.warehouse_relocation(id,client_request_id,relocation_number,project_id,source_warehouse_id,
        destination_warehouse_id,status_code,created_by_account_id,created_by_subject,updated_by_subject)
    VALUES(relocation_id,gen_random_uuid(),'REL-2026-888887',project,warehouse,destination,'DRAFT',actor,'verification','verification');
    BEGIN
        INSERT INTO crm.warehouse_relocation_item(relocation_id,cargo_item_id,project_id,source_warehouse_id,destination_warehouse_id,label_code_snapshot,sequence_number)
        VALUES(relocation_id,stock,project,warehouse,destination,'SALE-'||stock::text,1);
        RAISE EXCEPTION 'Relocation stole sales stock';
    EXCEPTION WHEN check_violation THEN NULL; END;
    INSERT INTO crm.sales_sourcing_assignment(id,project_id,sales_request_id,sales_request_line_id,quantity,supplier_id,warehouse_id,
        supplier_terms,supplier_unit_amount,supplier_currency_code,deadline_at,status_code,created_by_subject,updated_by_subject,created_at,updated_at)
    VALUES(assignment_id,project,request_id,second_line,1,supplier,warehouse,'Supplier terms',20,'RUB',now()+interval '1 day','ACCEPTED','verification','verification',now(),now());
    INSERT INTO crm.cargo_item(id,project_id,supplier_goods_entry_id,supplier_goods_variant_id,supplier_id,origin_code,status_code,
        created_by_subject,updated_by_subject,sales_request_line_id)
    VALUES(expected,project,'33333333-3333-4333-8333-333333333333','44444444-4444-4444-8444-444444444444',supplier,'SUPPLIER','IN_TRANSIT_TO_WAREHOUSE','verification','verification',second_line);
    INSERT INTO crm.cargo_sales_unit(id,project_id,sales_request_id,sales_request_line_id,cargo_item_id,unit_number,
        sourcing_assignment_id,unit_price,currency_code,prepayment_amount,product_confirmation,reserved_at)
    VALUES(expected_unit,project,request_id,second_line,expected,1,assignment_id,100,'RUB',50,'Confirmed',now());
    PERFORM pg_temp.verify(crm.sales_request_stage(request_id)='SOURCING','expected physical units never become ready stock');
    UPDATE crm.cargo_item SET status_code='AVAILABLE',current_warehouse_id=warehouse,accepted_at=now(),accepted_by_account_id=actor,
        label_code='SALE-'||expected::text,label_source_code='EXTERNAL_SCAN',label_symbology_code='QR_CODE' WHERE id=expected;
    PERFORM pg_temp.verify((SELECT received_at IS NOT NULL AND received_warehouse_id=warehouse FROM crm.cargo_sales_unit WHERE id=expected_unit),'ordinary warehouse receipt retains the sourcing evidence');
    PERFORM pg_temp.verify(crm.sales_request_stage(request_id)='READY_FOR_HANDOVER','together receipt waits until the full composition is accepted');
    INSERT INTO crm.customer_order SELECT (jsonb_populate_record(NULL::crm.customer_order,
        to_jsonb(template)||jsonb_build_object('id',order_id,'order_number','ORD-2026-888887','sales_request_id',request_id))).*
        FROM crm.customer_order template WHERE id='14141414-1414-4414-8414-141414141414';
    UPDATE crm.cargo_item SET sales_request_line_id=NULL WHERE id=stock;
    INSERT INTO crm.customer_order_line(id,customer_order_id,project_id,cargo_item_id,sequence_number,status_code,
        unit_price,currency_code,price_source_code,created_by_subject,updated_by_subject)
    VALUES(order_line_id,order_id,project,stock,1,'DRAFT',100,'RUB','ORDER_ENTRY','verification','verification');
    UPDATE crm.cargo_sales_unit SET customer_order_id=order_id,customer_order_line_id=order_line_id,supplier_amount=20,supplier_currency_code='RUB' WHERE id=stock_unit;
    PERFORM pg_temp.verify((SELECT reserved_amount=50 FROM crm.sales_prepayment_commitment WHERE sales_request_id=request_id AND currency_code='RUB'),'issuing one order preserves the minimum prepayment for the remaining goods');
    PERFORM pg_temp.verify((SELECT unit_price=20 FROM crm.supplier_order_financial_line WHERE id=order_line_id),'supplier financial projection uses the agreed supplier amount');
    PERFORM pg_temp.verify((SELECT unit_price=100 FROM crm.customer_order_line WHERE id=order_line_id),'supplier terms never overwrite the customer selling price');
    PERFORM pg_temp.verify((SELECT COUNT(*)=0 FROM crm.cargo_item item WHERE item.id=stock AND item.sales_request_line_id IS NULL
        AND NOT EXISTS(SELECT 1 FROM crm.customer_order_line line WHERE line.cargo_item_id=item.id AND line.status_code<>'REMOVED')),'order conversion retains free-stock exclusion');
END $$;
ROLLBACK;

BEGIN;
DO $$
DECLARE
    project UUID := '11111111-1111-4111-8111-111111111111';
    request_id UUID := gen_random_uuid();
    account_id UUID := gen_random_uuid();
    advance_id UUID := gen_random_uuid();
    retention_id UUID := gen_random_uuid();
BEGIN
    INSERT INTO crm.sales_request(id,request_number,project_id,client_request_id,intake_fingerprint,
        customer_name,customer_phone,receipt_preference,status_code,payment_confirmed_at,
        created_by_subject,updated_by_subject,created_at,updated_at)
    VALUES(request_id,'SAL-2026-888886',project,gen_random_uuid(),repeat('d',64),
        'Retention verification','+10000000000','TOGETHER','PAID',now(),
        'verification','verification',now(),now());
    INSERT INTO crm.settlement_financial_account(id,account_type,display_name,currency_code,
        created_by_subject,updated_by_subject)
    VALUES(account_id,'COMPANY_BANK','Retention verification','RUB','verification','verification');
    INSERT INTO crm.settlement_money_operation(id,client_operation_id,operation_type,project_id,sales_request_id,
        financial_account_id,payment_method,amount,currency_code,occurred_at,confirmed_at,
        created_by_subject,confirmed_by_subject)
    VALUES(advance_id,gen_random_uuid(),'SALES_ADVANCE',project,request_id,account_id,'BANK_TRANSFER',600,
        'RUB',now(),now(),'verification','verification');
    INSERT INTO crm.settlement_money_account_posting(operation_id,financial_account_id,currency_code,amount_delta,occurred_at)
    VALUES(advance_id,account_id,'RUB',600,now());
    BEGIN
        INSERT INTO crm.settlement_money_operation(id,client_operation_id,operation_type,project_id,sales_request_id,
            amount,currency_code,reason,occurred_at,confirmed_at,created_by_subject,confirmed_by_subject)
        VALUES(gen_random_uuid(),gen_random_uuid(),'SALES_PREPAYMENT_RETAINED',project,request_id,
            400,'RUB','Cancellation retention',now(),now(),'verification','verification');
        RAISE EXCEPTION 'Active request accepted prepayment retention';
    EXCEPTION WHEN check_violation THEN NULL; END;
    UPDATE crm.sales_request SET status_code='CANCELLED',cancelled_at=now(),cancellation_reason='Cancellation verification'
        WHERE id=request_id;
    BEGIN
        INSERT INTO crm.settlement_money_operation(id,client_operation_id,operation_type,project_id,sales_request_id,
            amount,currency_code,reason,occurred_at,confirmed_at,created_by_subject,confirmed_by_subject)
        VALUES(gen_random_uuid(),gen_random_uuid(),'SALES_PREPAYMENT_RETAINED',project,request_id,
            601,'RUB','Excess retention',now(),now(),'verification','verification');
        RAISE EXCEPTION 'Retention exceeded received unallocated money';
    EXCEPTION WHEN check_violation THEN NULL; END;
    INSERT INTO crm.settlement_money_operation(id,client_operation_id,operation_type,project_id,sales_request_id,
        amount,currency_code,reason,occurred_at,confirmed_at,created_by_subject,confirmed_by_subject)
    VALUES(retention_id,gen_random_uuid(),'SALES_PREPAYMENT_RETAINED',project,request_id,
        400,'RUB','Agreed prepayment retained',now(),now(),'verification','verification');
    PERFORM pg_temp.verify((SELECT sum(amount_delta)=600 FROM crm.settlement_money_account_posting
        WHERE financial_account_id=account_id),'retention does not duplicate the original cash receipt');
    PERFORM pg_temp.verify((SELECT sum(CASE operation_type WHEN 'SALES_ADVANCE' THEN amount
        WHEN 'SALES_PREPAYMENT_RETAINED' THEN -amount ELSE 0 END)=200 FROM crm.settlement_money_operation
        WHERE sales_request_id=request_id),'retention preserves the excess advance for a separate refund');
    BEGIN
        INSERT INTO crm.settlement_money_operation(id,client_operation_id,operation_type,project_id,sales_request_id,
            amount,currency_code,reason,occurred_at,confirmed_at,created_by_subject,confirmed_by_subject)
        VALUES(gen_random_uuid(),gen_random_uuid(),'SALES_PREPAYMENT_RETAINED',project,request_id,
            1,'RUB','Duplicate retention',now(),now(),'verification','verification');
        RAISE EXCEPTION 'Duplicate request currency retention was accepted';
    EXCEPTION WHEN unique_violation THEN NULL; END;
    PERFORM pg_temp.verify(TRUE,'retention requires cancelled paid state, available money and one operation per currency');
END $$;
ROLLBACK;
