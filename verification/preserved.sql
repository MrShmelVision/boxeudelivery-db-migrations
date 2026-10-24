\set ON_ERROR_STOP on
DO $$
DECLARE changed INT;
BEGIN
    WITH actual AS (
        SELECT 'photo' AS family,p.id::TEXT AS identity,to_jsonb(p)-'project_id'-'supplier_id'-'gallery_id' AS value FROM crm.cargo_item_photo p
        UNION ALL SELECT 'photo-object',p.photo_id::TEXT||':'||p.variant_code,to_jsonb(p) FROM crm.cargo_item_photo_object p
        UNION ALL SELECT 'finance',e.id::TEXT,to_jsonb(e) FROM crm.cargo_item_financial_entry e
    ) SELECT count(*) INTO changed FROM verification.retained r
      LEFT JOIN actual a ON a.family=r.family AND a.identity=r.identity WHERE a.value IS DISTINCT FROM r.value;
    IF changed<>0 OR (SELECT count(*) FROM verification.retained)<>6 THEN
        RAISE EXCEPTION 'Historical media or prices changed: %',changed;
    END IF;
    IF (SELECT website_badges FROM crm.supplier_goods_entry WHERE id='30000000-0000-4000-8000-000000000003')<>'[]'::JSONB THEN
        RAISE EXCEPTION 'New presentation fields did not retain compatible defaults';
    END IF;
    RAISE NOTICE 'PASS retained original, previews, independent prices and presentation defaults survive upgrade';
END $$;
