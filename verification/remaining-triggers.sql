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
    'cargo_item:trg_cargo_item_supplier_provenance',
    'cargo_item:website_catalog_changed',
    'cargo_item:website_stock_eligibility_changed',
    'cargo_item_financial_entry:website_catalog_changed',
    'cargo_item_photo:trg_cargo_photo_owner',
    'cargo_item_photo:website_catalog_changed',
    'cargo_item_photo_object:website_catalog_changed',
    'customer_order_line:website_catalog_changed',
    'inbound_delivery:website_stock_eligibility_changed',
    'inbound_delivery_line:trg_inbound_delivery_line_legacy_attributes',
    'mini_supplier_intake:website_stock_eligibility_changed',
    'mini_supplier_intake_item:website_stock_eligibility_changed',
    'product_brand:website_catalog_brand_changed',
    'supplier_goods_entry:supplier_goods_article_number',
    'supplier_goods_entry:website_catalog_brand_changed',
    'supplier_goods_entry:website_catalog_changed',
    'supplier_goods_variant:trg_supplier_goods_variant_legacy_attributes',
    'supplier_goods_variant:website_catalog_changed',
    'task:trg_task_subcategory_usage',
    'warehouse_relocation:website_stock_eligibility_changed',
    'warehouse_relocation_item:website_stock_eligibility_changed',
    'website_catalog_revision:website_catalog_notify'], 'all active CRM triggers have scenarios');

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
    PERFORM pg_temp.verify(article ~ ('^' || source.task_prefix || '-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{7}$'),
        'goods article uses project prefix and seven random characters');
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
