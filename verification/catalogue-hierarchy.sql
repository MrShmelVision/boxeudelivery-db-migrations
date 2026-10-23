\set ON_ERROR_STOP on
DO $$
DECLARE category UUID; parent UUID; terminal UUID; project UUID; revision_count BIGINT;
BEGIN
    ASSERT current_database() = 'boxeudelivery_validation';
    ASSERT (SELECT count(*) FROM crm.border_tariff_category_group WHERE created_by_subject='catalogue-20261023') = 86;
    ASSERT (SELECT count(*) FROM crm.border_tariff_subcategory s JOIN crm.border_tariff_category_group g ON g.id=s.group_id
            WHERE g.created_by_subject='catalogue-20261023' AND s.deleted_at IS NULL) = 808;
    ASSERT (SELECT count(*) FROM crm.border_tariff_subcategory WHERE code='GIRLS_CLOTHING' AND deleted_at IS NULL) = 2;
    ASSERT (SELECT count(*) FROM crm.border_tariff_policy_minimum m JOIN crm.border_tariff_subcategory s ON s.id=m.subcategory_id
            WHERE s.created_by_subject='catalogue-20261023') = 0;
    IF EXISTS (SELECT 1 FROM crm.border_tariff_subcategory WHERE id='a1450000-0000-4000-8000-000000000002') THEN
        ASSERT (SELECT border_tariff_subcategory_id='a1450000-0000-4000-8000-000000000002'::uuid
                FROM crm.supplier_goods_entry WHERE id='30000000-0000-4000-8000-000000000003');
        ASSERT (SELECT g.code='COMPUTERS_COMPONENTS' AND s.website_slug IS NULL
                FROM crm.border_tariff_subcategory s JOIN crm.border_tariff_category_group g ON g.id=s.group_id
                WHERE s.id='a1450000-0000-4000-8000-000000000002');
        ASSERT (SELECT minimum_usd=11.25 AND actual_cost_usd=4.75 FROM crm.border_tariff_policy_minimum
                WHERE subcategory_id='a1450000-0000-4000-8000-000000000002');
    END IF;
    SELECT id INTO category FROM crm.border_tariff_category WHERE code='ELECTRONICS';
    SELECT id INTO project FROM crm.project ORDER BY id LIMIT 1;
    parent:=gen_random_uuid();
    terminal:=gen_random_uuid();
    DELETE FROM crm.website_catalog_revision WHERE project_id=project AND transaction_id=txid_current();
    SELECT count(*) INTO revision_count FROM crm.website_catalog_revision WHERE project_id=project;
    INSERT INTO crm.border_tariff_category_group(id,category_id,code,display_name,created_by_subject,updated_by_subject)
    VALUES(parent,category,'VERIFY_GROUP','Verification group','verification','verification');
    ASSERT (SELECT count(*) FROM crm.website_catalog_revision WHERE project_id=project)=revision_count+1;
    DELETE FROM crm.website_catalog_revision WHERE project_id=project AND transaction_id=txid_current();
    UPDATE crm.border_tariff_category_group SET display_name='Changed verification group' WHERE id=parent;
    ASSERT EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE project_id=project AND transaction_id=txid_current());
    BEGIN
        INSERT INTO crm.border_tariff_subcategory(id,category_id,group_id,code,display_name,created_by_subject,updated_by_subject)
        SELECT terminal,c.id,parent,'VERIFY_TERMINAL','Wrong root','verification','verification'
        FROM crm.border_tariff_category c WHERE c.id<>category ORDER BY c.id LIMIT 1;
        RAISE EXCEPTION 'Cross-root category assignment must fail';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    DELETE FROM crm.website_catalog_revision WHERE project_id=project AND transaction_id=txid_current();
    DELETE FROM crm.border_tariff_category_group WHERE id=parent;
    ASSERT EXISTS(SELECT 1 FROM crm.website_catalog_revision WHERE project_id=project AND transaction_id=txid_current());
    RAISE NOTICE 'PASS three catalogue levels, scoped duplicate codes, preservation, tariff separation and all group trigger operations';
END $$;
