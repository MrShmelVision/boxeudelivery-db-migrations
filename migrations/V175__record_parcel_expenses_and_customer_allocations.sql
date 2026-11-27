CREATE TABLE crm.parcel_expense (
    id uuid PRIMARY KEY,
    project_id uuid NOT NULL REFERENCES crm.project(id) ON DELETE RESTRICT,
    supplier_id uuid NOT NULL REFERENCES crm.supplier(id) ON DELETE RESTRICT,
    inbound_delivery_id uuid NOT NULL REFERENCES crm.inbound_delivery(id) ON DELETE RESTRICT,
    package_id uuid NOT NULL REFERENCES crm.inbound_package(id) ON DELETE RESTRICT,
    package_number varchar(48) NOT NULL,
    amount numeric(19,4) NOT NULL CHECK (amount > 0),
    currency_code varchar(3) NOT NULL REFERENCES crm.currency_definition(code) ON DELETE RESTRICT,
    reason varchar(500) NOT NULL CHECK (length(btrim(reason)) > 0),
    paid_by varchar(16) NOT NULL CHECK (paid_by IN ('COMPANY','SUPPLIER','CUSTOMER')),
    paid_by_customer_profile_id uuid REFERENCES crm.customer_profile(id) ON DELETE RESTRICT,
    paid_by_customer_name varchar(200),
    request_hash varchar(64) NOT NULL,
    created_by_subject varchar(255) NOT NULL,
    created_at timestamptz NOT NULL,
    CONSTRAINT ck_parcel_expense_payer CHECK (
        (paid_by = 'CUSTOMER' AND paid_by_customer_profile_id IS NOT NULL AND paid_by_customer_name IS NOT NULL)
        OR (paid_by <> 'CUSTOMER' AND paid_by_customer_profile_id IS NULL AND paid_by_customer_name IS NULL)
    )
);
CREATE INDEX ix_parcel_expense_delivery ON crm.parcel_expense(inbound_delivery_id,created_at DESC,id DESC);
CREATE INDEX ix_parcel_expense_package ON crm.parcel_expense(package_id);
CREATE TABLE crm.parcel_expense_allocation (
    id uuid PRIMARY KEY,
    expense_id uuid NOT NULL REFERENCES crm.parcel_expense(id) ON DELETE RESTRICT,
    customer_profile_id uuid NOT NULL REFERENCES crm.customer_profile(id) ON DELETE RESTRICT,
    customer_name varchar(200) NOT NULL,
    amount numeric(19,4) NOT NULL CHECK (amount > 0),
    CONSTRAINT uq_parcel_expense_customer UNIQUE (expense_id,customer_profile_id)
);
CREATE INDEX ix_parcel_expense_allocation_customer ON crm.parcel_expense_allocation(customer_profile_id,expense_id);

CREATE FUNCTION crm.check_parcel_expense_allocation() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    expense_uuid uuid;
    expense crm.parcel_expense%ROWTYPE;
    allocated numeric;
BEGIN
    IF TG_TABLE_NAME = 'parcel_expense' THEN
        expense_uuid := NEW.id;
    ELSE
        expense_uuid := NEW.expense_id;
    END IF;
    SELECT * INTO STRICT expense FROM crm.parcel_expense WHERE id = expense_uuid;
    SELECT SUM(amount) INTO allocated FROM crm.parcel_expense_allocation WHERE expense_id = expense_uuid;
    IF allocated IS DISTINCT FROM expense.amount THEN
        RAISE EXCEPTION 'Customer allocations must equal the single parcel expense total'
            USING ERRCODE='23514', CONSTRAINT='ck_parcel_expense_total';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM crm.inbound_package parcel
        JOIN crm.inbound_delivery delivery ON delivery.id=parcel.inbound_delivery_id
        WHERE parcel.id=expense.package_id AND delivery.id=expense.inbound_delivery_id
          AND delivery.project_id=expense.project_id AND parcel.project_id=expense.project_id
          AND delivery.supplier_id=expense.supplier_id) THEN
        RAISE EXCEPTION 'Parcel expense scope does not match its package'
            USING ERRCODE='23514', CONSTRAINT='ck_parcel_expense_scope';
    END IF;
    IF EXISTS (SELECT 1 FROM crm.parcel_expense_allocation part
        JOIN crm.customer_profile customer ON customer.id=part.customer_profile_id
        WHERE part.expense_id=expense_uuid
          AND (customer.project_id<>expense.project_id OR customer.supplier_id<>expense.supplier_id)) THEN
        RAISE EXCEPTION 'Expense customers must belong to the same supplier scope'
            USING ERRCODE='23514', CONSTRAINT='ck_parcel_expense_customer_scope';
    END IF;
    IF expense.paid_by='CUSTOMER' AND NOT EXISTS (SELECT 1 FROM crm.parcel_expense_allocation
        WHERE expense_id=expense_uuid AND customer_profile_id=expense.paid_by_customer_profile_id) THEN
        RAISE EXCEPTION 'The paying customer must be included in the expense allocation'
            USING ERRCODE='23514', CONSTRAINT='ck_parcel_expense_paying_customer';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER parcel_expense_total AFTER INSERT ON crm.parcel_expense
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION crm.check_parcel_expense_allocation();
CREATE CONSTRAINT TRIGGER parcel_expense_allocation_total AFTER INSERT ON crm.parcel_expense_allocation
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION crm.check_parcel_expense_allocation();
CREATE FUNCTION crm.reject_parcel_expense_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Recorded parcel expenses and allocations are immutable' USING ERRCODE='23514';
END;
$$;
CREATE TRIGGER parcel_expense_immutable BEFORE UPDATE OR DELETE ON crm.parcel_expense
    FOR EACH ROW EXECUTE FUNCTION crm.reject_parcel_expense_change();
CREATE TRIGGER parcel_expense_allocation_immutable BEFORE UPDATE OR DELETE ON crm.parcel_expense_allocation
    FOR EACH ROW EXECUTE FUNCTION crm.reject_parcel_expense_change();

ALTER TABLE crm.settlement_money_operation
    ADD COLUMN parcel_expense_id uuid REFERENCES crm.parcel_expense(id) ON DELETE RESTRICT,
    DROP CONSTRAINT ck_settlement_money_operation_type,
    DROP CONSTRAINT ck_settlement_money_operation_shape;
ALTER TABLE crm.settlement_money_operation ADD CONSTRAINT ck_settlement_money_operation_type
    CHECK (operation_type IN ('CUSTOMER_ADVANCE','CUSTOMER_ORDER_CHARGE','CUSTOMER_ORDER_RECEIPT',
        'CUSTOMER_ORDER_DELIVERY_EXPENSE','CUSTOMER_REFUND','COUNTERPARTY_ADJUSTMENT','INTERNAL_TRANSFER',
        'INTERNAL_CONVERSION','COMPANY_MONEY_IN','COMPANY_MONEY_OUT','SUPPLIER_ACCRUAL',
        'SUPPLIER_ENTITLEMENT_ADJUSTMENT','SUPPLIER_DEDUCTION','SUPPLIER_PAYOUT','SALES_ADVANCE','SALES_REFUND','SALES_PREPAYMENT_RETAINED','PARCEL_EXPENSE')),
    ADD CONSTRAINT ck_settlement_money_operation_shape CHECK (
        (parcel_expense_id IS NULL AND (
        (sales_request_id IS NULL AND (

        (
            operation_type = 'CUSTOMER_ADVANCE' AND project_id IS NOT NULL
            AND counterparty_type = 'CUSTOMER' AND customer_order_id IS NULL
            AND fulfillment_shipment_id IS NULL AND outbound_delivery_id IS NULL
            AND financial_account_id IS NOT NULL
            AND destination_financial_account_id IS NULL AND payment_method IS NOT NULL
            AND counterparty_delta = amount AND reason IS NULL
        ) OR (
            operation_type = 'CUSTOMER_ORDER_CHARGE' AND project_id IS NOT NULL
            AND counterparty_type = 'CUSTOMER' AND customer_order_id IS NOT NULL
            AND fulfillment_shipment_id IS NULL AND outbound_delivery_id IS NULL
            AND financial_account_id IS NULL
            AND destination_financial_account_id IS NULL AND payment_method IS NULL
            AND counterparty_delta = -amount AND reason IS NULL
        ) OR (
            operation_type = 'CUSTOMER_ORDER_RECEIPT' AND project_id IS NOT NULL
            AND customer_order_id IS NOT NULL AND fulfillment_shipment_id IS NULL
            AND outbound_delivery_id IS NULL AND financial_account_id IS NOT NULL
            AND destination_financial_account_id IS NULL
            AND payment_method IS NOT NULL AND counterparty_delta IS NULL AND reason IS NULL
            AND ((counterparty_type IS NULL AND customer_profile_id IS NULL)
                OR (counterparty_type = 'CUSTOMER' AND customer_profile_id IS NOT NULL))
        ) OR (
            operation_type = 'CUSTOMER_ORDER_DELIVERY_EXPENSE'
            AND project_id IS NOT NULL AND supplier_id IS NOT NULL
            AND counterparty_type IS NULL AND customer_profile_id IS NULL
            AND customer_order_id IS NOT NULL AND fulfillment_shipment_id IS NULL
            AND outbound_delivery_id IS NOT NULL AND financial_account_id IS NOT NULL
            AND destination_financial_account_id IS NULL AND payment_method IS NULL
            AND counterparty_delta IS NULL AND reason IS NULL
        ) OR (
            operation_type = 'CUSTOMER_REFUND' AND project_id IS NOT NULL
            AND counterparty_type = 'CUSTOMER' AND customer_order_id IS NULL
            AND fulfillment_shipment_id IS NULL AND outbound_delivery_id IS NULL
            AND financial_account_id IS NOT NULL
            AND destination_financial_account_id IS NULL AND payment_method IS NOT NULL
            AND counterparty_delta = -amount AND reason IS NOT NULL AND BTRIM(reason) <> ''
        ) OR (
            operation_type = 'COUNTERPARTY_ADJUSTMENT' AND project_id IS NOT NULL
            AND counterparty_type IS NOT NULL AND customer_order_id IS NULL
            AND fulfillment_shipment_id IS NULL AND outbound_delivery_id IS NULL
            AND financial_account_id IS NULL
            AND destination_financial_account_id IS NULL AND payment_method IS NULL
            AND counterparty_delta IS NOT NULL AND reason IS NOT NULL AND BTRIM(reason) <> ''
        ) OR (
            operation_type IN ('INTERNAL_TRANSFER', 'INTERNAL_CONVERSION')
            AND project_id IS NULL AND supplier_id IS NULL AND counterparty_type IS NULL
            AND customer_profile_id IS NULL AND customer_order_id IS NULL
            AND fulfillment_shipment_id IS NULL AND outbound_delivery_id IS NULL
            AND financial_account_id IS NOT NULL
            AND destination_financial_account_id IS NOT NULL
            AND financial_account_id <> destination_financial_account_id
            AND payment_method IS NULL AND counterparty_delta IS NULL
            AND reason IS NOT NULL AND BTRIM(reason) <> ''
        ) OR (
            operation_type = 'SUPPLIER_ACCRUAL' AND project_id IS NOT NULL
            AND counterparty_type = 'SUPPLIER'
            AND NUM_NONNULLS(customer_order_id, fulfillment_shipment_id) = 1
            AND outbound_delivery_id IS NULL AND financial_account_id IS NULL
            AND destination_financial_account_id IS NULL
            AND payment_method IS NULL AND counterparty_delta = amount
            AND reason IS NOT NULL AND BTRIM(reason) <> ''
        ) OR (
            operation_type = 'SUPPLIER_ENTITLEMENT_ADJUSTMENT' AND project_id IS NOT NULL
            AND counterparty_type = 'SUPPLIER'
            AND NUM_NONNULLS(customer_order_id, fulfillment_shipment_id) = 1
            AND outbound_delivery_id IS NULL AND financial_account_id IS NULL
            AND destination_financial_account_id IS NULL
            AND payment_method IS NULL AND counterparty_delta IS NOT NULL AND counterparty_delta <> 0
            AND amount = ABS(counterparty_delta) AND reason IS NOT NULL AND BTRIM(reason) <> ''
        ) OR (
            operation_type = 'SUPPLIER_DEDUCTION' AND project_id IS NOT NULL
            AND counterparty_type = 'SUPPLIER' AND customer_order_id IS NULL
            AND fulfillment_shipment_id IS NULL AND outbound_delivery_id IS NULL
            AND financial_account_id IS NULL
            AND destination_financial_account_id IS NULL AND payment_method IS NULL
            AND counterparty_delta = -amount AND reason IS NOT NULL AND BTRIM(reason) <> ''
        ) OR (
            operation_type = 'SUPPLIER_PAYOUT' AND project_id IS NOT NULL
            AND counterparty_type = 'SUPPLIER' AND customer_order_id IS NULL
            AND fulfillment_shipment_id IS NULL AND outbound_delivery_id IS NULL
            AND financial_account_id IS NOT NULL
            AND destination_financial_account_id IS NULL AND payment_method IS NOT NULL
            AND (counterparty_delta IS NULL OR counterparty_delta = -amount) AND reason IS NULL
        )
        OR (
            operation_type IN ('COMPANY_MONEY_IN', 'COMPANY_MONEY_OUT')
            AND project_id IS NULL AND supplier_id IS NULL
            AND counterparty_type IS NULL AND customer_profile_id IS NULL
            AND customer_order_id IS NULL AND fulfillment_shipment_id IS NULL
            AND outbound_delivery_id IS NULL
            AND financial_account_id IS NOT NULL
            AND destination_financial_account_id IS NULL
            AND payment_method IS NULL AND counterparty_delta IS NULL
            AND reason IS NOT NULL AND BTRIM(reason) <> ''
        )
            )) OR (
            operation_type IN ('SALES_ADVANCE','SALES_REFUND') AND sales_request_id IS NOT NULL
            AND project_id IS NOT NULL AND supplier_id IS NULL AND customer_profile_id IS NULL
            AND counterparty_type IS NULL AND customer_order_id IS NULL AND fulfillment_shipment_id IS NULL
            AND outbound_delivery_id IS NULL AND financial_account_id IS NOT NULL
            AND destination_financial_account_id IS NULL AND payment_method IS NOT NULL
            AND counterparty_delta IS NULL
            AND (operation_type <> 'SALES_REFUND' OR (reason IS NOT NULL AND length(btrim(reason)) > 0))
        )
        OR (
            operation_type = 'SALES_PREPAYMENT_RETAINED'
            AND sales_request_id IS NOT NULL AND project_id IS NOT NULL
            AND supplier_id IS NULL AND customer_profile_id IS NULL AND counterparty_type IS NULL
            AND customer_order_id IS NULL AND fulfillment_shipment_id IS NULL AND outbound_delivery_id IS NULL
            AND financial_account_id IS NULL AND destination_financial_account_id IS NULL
            AND payment_method IS NULL AND counterparty_delta IS NULL
            AND reason IS NOT NULL AND length(btrim(reason)) > 0
        ))) OR (
            operation_type='PARCEL_EXPENSE' AND parcel_expense_id IS NOT NULL
            AND project_id IS NOT NULL AND supplier_id IS NOT NULL AND sales_request_id IS NULL
            AND customer_order_id IS NULL AND fulfillment_shipment_id IS NULL AND outbound_delivery_id IS NULL
            AND financial_account_id IS NULL AND destination_financial_account_id IS NULL AND payment_method IS NULL
            AND counterparty_delta IS NOT NULL AND counterparty_delta<>0 AND amount=ABS(counterparty_delta)
            AND reason IS NOT NULL AND length(btrim(reason))>0
            AND ((counterparty_type='CUSTOMER' AND customer_profile_id IS NOT NULL)
                OR (counterparty_type='SUPPLIER' AND customer_profile_id IS NULL AND counterparty_delta=amount))
        )
    );
CREATE UNIQUE INDEX uq_parcel_expense_posting ON crm.settlement_money_operation
    (parcel_expense_id,counterparty_type,COALESCE(customer_profile_id,'00000000-0000-0000-0000-000000000000'::uuid))
    WHERE parcel_expense_id IS NOT NULL;
ALTER TABLE crm.settlement_supplier_entitlement
    ADD COLUMN parcel_expense_id uuid REFERENCES crm.parcel_expense(id) ON DELETE RESTRICT,
    DROP CONSTRAINT ck_settlement_supplier_entitlement_source,
    ADD CONSTRAINT ck_settlement_supplier_entitlement_source CHECK (
        (parcel_expense_id IS NULL AND (
            (customer_order_id IS NOT NULL AND customer_order_line_id IS NOT NULL AND cargo_item_id IS NOT NULL
                AND fulfillment_shipment_id IS NULL AND supplier_money_collection_id IS NULL)
            OR (customer_order_id IS NULL AND customer_order_line_id IS NULL AND cargo_item_id IS NULL
                AND fulfillment_shipment_id IS NOT NULL AND supplier_money_collection_id IS NULL)
            OR (customer_order_id IS NULL AND customer_order_line_id IS NULL AND cargo_item_id IS NULL
                AND fulfillment_shipment_id IS NULL AND supplier_money_collection_id IS NOT NULL)
        )) OR (parcel_expense_id IS NOT NULL AND customer_order_id IS NULL AND customer_order_line_id IS NULL
            AND cargo_item_id IS NULL AND fulfillment_shipment_id IS NULL AND supplier_money_collection_id IS NULL)
    );
CREATE UNIQUE INDEX uq_supplier_entitlement_parcel_expense ON crm.settlement_supplier_entitlement(parcel_expense_id)
    WHERE parcel_expense_id IS NOT NULL;
