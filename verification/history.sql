\set ON_ERROR_STOP on
-- Representative retained media and commercial facts at the pre-catalogue history.
DO $$ BEGIN
    IF current_database()<>'boxeudelivery_validation' THEN RAISE EXCEPTION 'Disposable database required'; END IF;
END $$;
INSERT INTO crm.project(id,name,task_prefix,created_by_subject,updated_by_subject)
VALUES('30000000-0000-4000-8000-000000000001','Historical verification project','HIST','verification','verification');
INSERT INTO crm.supplier(id,display_name,status_code,created_by_subject,updated_by_subject)
VALUES('30000000-0000-4000-8000-000000000002','Historical verification supplier','ACTIVE','verification','verification');
INSERT INTO crm.project_supplier(project_id,supplier_id,status_code,operating_mode,created_by_subject,updated_by_subject)
VALUES('30000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','ACTIVE','MINI','verification','verification');
INSERT INTO crm.supplier_goods_entry(id,project_id,supplier_id,name,created_by_subject,updated_by_subject)
VALUES('30000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000002','Retained product','verification','verification');
INSERT INTO crm.supplier_goods_variant(id,supplier_goods_entry_id,project_id,supplier_id,value_text,unit_code,created_by_subject)
VALUES('30000000-0000-4000-8000-000000000004','30000000-0000-4000-8000-000000000003',
    '30000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000002','XL','SIZE','verification');
INSERT INTO crm.account(id,first_name,last_name,email,created_by_subject,updated_by_subject)
VALUES('30000000-0000-4000-8000-000000000005','Historical','Verification','historical@example.invalid','verification','verification');
INSERT INTO crm.cargo_item(id,project_id,supplier_goods_entry_id,supplier_goods_variant_id,supplier_id,
    origin_code,status_code,created_by_subject,updated_by_subject)
VALUES('30000000-0000-4000-8000-000000000006','30000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000004',
    '30000000-0000-4000-8000-000000000002','SUPPLIER','IN_TRANSIT_TO_WAREHOUSE','verification','verification');
INSERT INTO crm.cargo_item_photo(id,cargo_item_id,supplier_goods_entry_id,uploader_account_id,status_code,
    position,original_filename,declared_content_type,declared_size_bytes,declared_checksum_sha256,
    original_object_key,upload_expires_at,upload_completed_at,ready_at,gallery_scope_code)
VALUES('30000000-0000-4000-8000-000000000007','30000000-0000-4000-8000-000000000006',
    '30000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000005','READY',0,
    'retained.jpg','image/jpeg',4,repeat('a',44),'verification/retained/original',now()+interval '1 hour',now(),now(),'SUPPLIER_GOODS');
INSERT INTO crm.cargo_item_photo_object(photo_id,variant_code,object_key,content_type,size_bytes,checksum_sha256)
SELECT '30000000-0000-4000-8000-000000000007',code,'verification/retained/'||code,'image/jpeg',4,repeat('a',44)
FROM (VALUES('ORIGINAL'),('PREVIEW'),('CARD')) AS variants(code);
INSERT INTO crm.cargo_item_financial_entry(id,cargo_item_id,project_id,entry_type,amount,currency_code,created_by_subject,updated_by_subject)
VALUES('30000000-0000-4000-8000-000000000008','30000000-0000-4000-8000-000000000006',
    '30000000-0000-4000-8000-000000000001','CUSTOMER_ITEM_PRICE',123,'RUB','verification','verification'),
('30000000-0000-4000-8000-000000000009','30000000-0000-4000-8000-000000000006',
    '30000000-0000-4000-8000-000000000001','ONLINE_STORE_PRICE',456,'RUB','verification','verification');
CREATE SCHEMA verification;
CREATE TABLE verification.retained(family TEXT, identity TEXT, value JSONB, PRIMARY KEY(family,identity));
INSERT INTO verification.retained SELECT 'photo',p.id::TEXT,to_jsonb(p) FROM crm.cargo_item_photo p;
INSERT INTO verification.retained SELECT 'photo-object',p.photo_id::TEXT||':'||p.variant_code,to_jsonb(p) FROM crm.cargo_item_photo_object p;
INSERT INTO verification.retained SELECT 'finance',e.id::TEXT,to_jsonb(e) FROM crm.cargo_item_financial_entry e;
