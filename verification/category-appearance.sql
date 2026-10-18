\set ON_ERROR_STOP on
DO $$ BEGIN IF current_database() <> 'boxeudelivery_validation' THEN RAISE EXCEPTION 'Owned database only'; END IF; END $$;
BEGIN;
DO $$
DECLARE
    category_id uuid := 'd1400000-0000-4000-8000-000000000001';
BEGIN
    INSERT INTO crm.border_tariff_category(id, code, display_name, active, display_order, created_by_subject, updated_by_subject)
    VALUES (category_id, 'VERIFY_WEBSITE_APPEARANCE', 'Verification category', true, 99999, 'verification', 'verification');
    ASSERT (SELECT website_illustration = 'generic' AND website_menu_icon = 'grid' AND website_image_revision IS NULL
        FROM crm.border_tariff_category WHERE id = category_id), 'new categories keep compatible presentation defaults';
    RAISE NOTICE 'PASS category appearance defaults preserve the existing common dictionary';
    DELETE FROM crm.website_catalog_revision WHERE transaction_id = txid_current();
    UPDATE crm.border_tariff_category SET website_illustration = 'electronics', website_menu_icon = 'monitor'
        WHERE id = category_id;
    ASSERT EXISTS (SELECT 1 FROM crm.website_catalog_revision WHERE transaction_id = txid_current()), 'appearance update must invalidate the public catalogue';
    RAISE NOTICE 'PASS category appearance changes execute the full-schema catalogue invalidation trigger';
    BEGIN
        UPDATE crm.border_tariff_category SET website_illustration = '../outside' WHERE id = category_id;
        RAISE EXCEPTION 'invalid illustration was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE crm.border_tariff_category SET website_menu_icon = '<svg>' WHERE id = category_id;
        RAISE EXCEPTION 'arbitrary SVG was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        UPDATE crm.border_tariff_category SET website_image_revision = gen_random_uuid() WHERE id = category_id;
        RAISE EXCEPTION 'image without an object was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RAISE NOTICE 'PASS category image and icon constraints reject malformed presentation values';
END $$;
ROLLBACK;
