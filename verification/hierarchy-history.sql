\set ON_ERROR_STOP on
DO $$ BEGIN
    ASSERT current_database() = 'boxeudelivery_validation';
END $$;
INSERT INTO crm.border_tariff_category(id,code,display_name,created_by_subject,updated_by_subject)
VALUES('a1450000-0000-4000-8000-000000000001','ELECTRONICS','Электроника','verification','verification');
INSERT INTO crm.border_tariff_subcategory(id,category_id,code,display_name,created_by_subject,updated_by_subject)
VALUES('a1450000-0000-4000-8000-000000000002','a1450000-0000-4000-8000-000000000001','MONITORS','Мониторы','verification','verification');
UPDATE crm.supplier_goods_entry SET border_tariff_subcategory_id='a1450000-0000-4000-8000-000000000002'
WHERE id='30000000-0000-4000-8000-000000000003';
INSERT INTO crm.border_tariff_policy_minimum(policy_id,subcategory_id,minimum_usd,actual_cost_usd)
SELECT id,'a1450000-0000-4000-8000-000000000002',11.25,4.75 FROM crm.border_tariff_policy WHERE status_code='DRAFT';
