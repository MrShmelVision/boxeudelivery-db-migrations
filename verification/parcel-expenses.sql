\set ON_ERROR_STOP on
DO $$ BEGIN
    IF current_database() <> 'boxeudelivery_validation' THEN
        RAISE EXCEPTION 'Disposable verification database required';
    END IF;
END $$;

BEGIN;
DO $$
DECLARE
    project_uuid UUID := '11111111-1111-4111-8111-111111111111';
    supplier_uuid UUID := '22222222-2222-4222-8222-222222222222';
    warehouse_uuid UUID := gen_random_uuid();
    conversation_uuid UUID := gen_random_uuid();
    delivery_uuid UUID := gen_random_uuid();
    package_uuid UUID := gen_random_uuid();
    customer_uuid UUID := gen_random_uuid();
    second_customer_uuid UUID := gen_random_uuid();
    other_supplier_uuid UUID := gen_random_uuid();
    other_customer_uuid UUID := gen_random_uuid();
    valid_expense_uuid UUID := gen_random_uuid();
    valid_allocation_uuid UUID := gen_random_uuid();
    probe_expense_uuid UUID;
    failure_constraint TEXT;
BEGIN
    INSERT INTO crm.warehouse(id,name,location_description,created_by_subject,updated_by_subject)
    VALUES(warehouse_uuid,'Parcel expense verification','Disposable fixture','verification','verification');
    INSERT INTO crm.project_warehouse(project_id,warehouse_id,assigned_by_subject)
    VALUES(project_uuid,warehouse_uuid,'verification');
    INSERT INTO crm.conversation(id,project_id,kind_code)
    VALUES(conversation_uuid,project_uuid,'INBOUND_DELIVERY');
    INSERT INTO crm.inbound_delivery(id,project_id,supplier_id,target_warehouse_id,status_code,
        created_by_subject,updated_by_subject,delivery_number,conversation_id,courier_distribution_mode,transport_mode)
    VALUES(delivery_uuid,project_uuid,supplier_uuid,warehouse_uuid,'DRAFT','verification','verification',
        'IN-2099-900001',conversation_uuid,'OPEN_POOL','DIRECT_TO_WAREHOUSE');
    INSERT INTO crm.inbound_package(id,inbound_delivery_id,project_id,sequence_number,package_number,
        created_by_subject,updated_by_subject)
    VALUES(package_uuid,delivery_uuid,project_uuid,1,'IN-2099-900001-P001','verification','verification');
    INSERT INTO crm.customer_profile(id,project_id,supplier_id,display_name,created_by_subject,updated_by_subject)
    VALUES(customer_uuid,project_uuid,supplier_uuid,'First expense customer','verification','verification'),
        (second_customer_uuid,project_uuid,supplier_uuid,'Second expense customer','verification','verification');
    INSERT INTO crm.supplier(id,display_name,status_code,created_by_subject,updated_by_subject)
    VALUES(other_supplier_uuid,'Other expense supplier','ACTIVE','verification','verification');
    INSERT INTO crm.project_supplier(project_id,supplier_id,status_code,operating_mode,created_by_subject,updated_by_subject)
    VALUES(project_uuid,other_supplier_uuid,'ACTIVE','MINI','verification','verification');
    INSERT INTO crm.customer_profile(id,project_id,supplier_id,display_name,created_by_subject,updated_by_subject)
    VALUES(other_customer_uuid,project_uuid,other_supplier_uuid,'Foreign expense customer','verification','verification');

    INSERT INTO crm.parcel_expense(id,project_id,supplier_id,inbound_delivery_id,package_id,package_number,
        amount,currency_code,reason,paid_by,request_hash,created_by_subject,created_at)
    VALUES(valid_expense_uuid,project_uuid,supplier_uuid,delivery_uuid,package_uuid,'IN-2099-900001-P001',
        10,'USD','Verified company expense','COMPANY',repeat('a',64),'verification',now());
    INSERT INTO crm.parcel_expense_allocation(id,expense_id,customer_profile_id,customer_name,amount)
    VALUES(valid_allocation_uuid,valid_expense_uuid,customer_uuid,'First expense customer',4),
        (gen_random_uuid(),valid_expense_uuid,second_customer_uuid,'Second expense customer',6);
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'PASS parcel header and allocation deferred triggers accept an exact scoped total';
    SET CONSTRAINTS ALL DEFERRED;

    BEGIN
        probe_expense_uuid := gen_random_uuid();
        INSERT INTO crm.parcel_expense(id,project_id,supplier_id,inbound_delivery_id,package_id,package_number,
            amount,currency_code,reason,paid_by,request_hash,created_by_subject,created_at)
        VALUES(probe_expense_uuid,project_uuid,supplier_uuid,delivery_uuid,package_uuid,'IN-2099-900001-P001',
            10,'USD','Incorrect total','COMPANY',repeat('b',64),'verification',now());
        INSERT INTO crm.parcel_expense_allocation(id,expense_id,customer_profile_id,customer_name,amount)
        VALUES(gen_random_uuid(),probe_expense_uuid,customer_uuid,'First expense customer',9);
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Incomplete expense allocation was accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS failure_constraint = CONSTRAINT_NAME;
        IF failure_constraint <> 'ck_parcel_expense_total' THEN RAISE; END IF;
        RAISE NOTICE 'PASS deferred expense total rejects a partial customer allocation';
    END;

    BEGIN
        probe_expense_uuid := gen_random_uuid();
        INSERT INTO crm.parcel_expense(id,project_id,supplier_id,inbound_delivery_id,package_id,package_number,
            amount,currency_code,reason,paid_by,request_hash,created_by_subject,created_at)
        VALUES(probe_expense_uuid,project_uuid,supplier_uuid,delivery_uuid,package_uuid,'IN-2099-900001-P001',
            10,'USD','Foreign customer','COMPANY',repeat('c',64),'verification',now());
        INSERT INTO crm.parcel_expense_allocation(id,expense_id,customer_profile_id,customer_name,amount)
        VALUES(gen_random_uuid(),probe_expense_uuid,other_customer_uuid,'Foreign expense customer',10);
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Foreign supplier customer was accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS failure_constraint = CONSTRAINT_NAME;
        IF failure_constraint <> 'ck_parcel_expense_customer_scope' THEN RAISE; END IF;
        RAISE NOTICE 'PASS expense allocations reject another supplier customer';
    END;

    BEGIN
        probe_expense_uuid := gen_random_uuid();
        INSERT INTO crm.parcel_expense(id,project_id,supplier_id,inbound_delivery_id,package_id,package_number,
            amount,currency_code,reason,paid_by,request_hash,created_by_subject,created_at)
        VALUES(probe_expense_uuid,project_uuid,other_supplier_uuid,delivery_uuid,package_uuid,'IN-2099-900001-P001',
            10,'USD','Foreign package scope','COMPANY',repeat('d',64),'verification',now());
        INSERT INTO crm.parcel_expense_allocation(id,expense_id,customer_profile_id,customer_name,amount)
        VALUES(gen_random_uuid(),probe_expense_uuid,other_customer_uuid,'Foreign expense customer',10);
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Mismatched package supplier was accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS failure_constraint = CONSTRAINT_NAME;
        IF failure_constraint <> 'ck_parcel_expense_scope' THEN RAISE; END IF;
        RAISE NOTICE 'PASS expense header rejects another supplier package scope';
    END;

    BEGIN
        probe_expense_uuid := gen_random_uuid();
        INSERT INTO crm.parcel_expense(id,project_id,supplier_id,inbound_delivery_id,package_id,package_number,
            amount,currency_code,reason,paid_by,paid_by_customer_profile_id,paid_by_customer_name,
            request_hash,created_by_subject,created_at)
        VALUES(probe_expense_uuid,project_uuid,supplier_uuid,delivery_uuid,package_uuid,'IN-2099-900001-P001',
            10,'USD','Missing paying customer','CUSTOMER',second_customer_uuid,'Second expense customer',
            repeat('e',64),'verification',now());
        INSERT INTO crm.parcel_expense_allocation(id,expense_id,customer_profile_id,customer_name,amount)
        VALUES(gen_random_uuid(),probe_expense_uuid,customer_uuid,'First expense customer',10);
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'Absent paying customer was accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS failure_constraint = CONSTRAINT_NAME;
        IF failure_constraint <> 'ck_parcel_expense_paying_customer' THEN RAISE; END IF;
        RAISE NOTICE 'PASS paying customer must belong to the expense allocation';
    END;

    BEGIN
        UPDATE crm.parcel_expense SET amount=11 WHERE id=valid_expense_uuid;
        RAISE EXCEPTION 'Recorded expense update was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'PASS recorded expense update is rejected';
    END;
    BEGIN
        DELETE FROM crm.parcel_expense WHERE id=valid_expense_uuid;
        RAISE EXCEPTION 'Recorded expense deletion was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'PASS recorded expense deletion is rejected';
    END;
    BEGIN
        UPDATE crm.parcel_expense_allocation SET amount=5 WHERE id=valid_allocation_uuid;
        RAISE EXCEPTION 'Recorded allocation update was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'PASS recorded allocation update is rejected';
    END;
    BEGIN
        DELETE FROM crm.parcel_expense_allocation WHERE id=valid_allocation_uuid;
        RAISE EXCEPTION 'Recorded allocation deletion was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'PASS recorded allocation deletion is rejected';
    END;
END $$;
ROLLBACK;
