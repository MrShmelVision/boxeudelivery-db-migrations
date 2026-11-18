CREATE TABLE crm.product_code_scan_session (
    id UUID PRIMARY KEY,
    project_id UUID NOT NULL REFERENCES crm.project(id) ON DELETE RESTRICT,
    supplier_id UUID,
    catalogue_variant_id UUID,
    created_by_account_id UUID NOT NULL REFERENCES crm.account(id) ON DELETE RESTRICT,
    client_reference UUID NOT NULL,
    status_code VARCHAR(16) NOT NULL,
    product_code VARCHAR(14),
    activated_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    FOREIGN KEY(project_id, supplier_id) REFERENCES crm.project_supplier(project_id, supplier_id) ON DELETE RESTRICT,
    FOREIGN KEY(catalogue_variant_id, project_id) REFERENCES crm.catalogue_variant(id, project_id) ON DELETE RESTRICT,
    CONSTRAINT ck_product_code_scan_session_scope CHECK (num_nonnulls(supplier_id, catalogue_variant_id) = 1),
    CONSTRAINT ck_product_code_scan_session_code CHECK (product_code IS NULL OR crm.valid_product_gtin(product_code)),
    CONSTRAINT ck_product_code_scan_session_expiry CHECK (expires_at > created_at AND expires_at <= created_at + INTERVAL '10 minutes'),
    CONSTRAINT ck_product_code_scan_session_version CHECK (version >= 0 AND updated_at >= created_at),
    CONSTRAINT ck_product_code_scan_session_lifecycle CHECK (
        (status_code = 'WAITING' AND product_code IS NULL AND activated_at IS NULL AND completed_at IS NULL AND cancelled_at IS NULL)
        OR (status_code = 'ACTIVE' AND product_code IS NULL AND activated_at IS NOT NULL AND completed_at IS NULL AND cancelled_at IS NULL)
        OR (status_code = 'COMPLETED' AND product_code IS NOT NULL AND activated_at IS NOT NULL AND completed_at IS NOT NULL AND cancelled_at IS NULL)
        OR (status_code = 'CANCELLED' AND product_code IS NULL AND completed_at IS NULL AND cancelled_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX uq_product_code_scan_session_open_client
    ON crm.product_code_scan_session(project_id, created_by_account_id, client_reference)
    WHERE status_code IN ('WAITING', 'ACTIVE');

CREATE INDEX ix_product_code_scan_session_expiry
    ON crm.product_code_scan_session(expires_at, id);

ALTER TABLE crm.cargo_audit_event
    DROP CONSTRAINT ck_cargo_audit_event_aggregate_type,
    ADD CONSTRAINT ck_cargo_audit_event_aggregate_type CHECK (aggregate_type IN (
        'SUPPLIER_GOODS', 'INBOUND_DELIVERY', 'INBOUND_PACKAGE', 'COURIER_TRIP',
        'COURIER_ASSIGNMENT', 'COURIER_COMPENSATION_PROPOSAL', 'CARGO_ITEM', 'CARGO_PHOTO',
        'CARGO_PHOTO_CAPTURE_SESSION', 'CARGO_PRODUCT_CODE_SCAN_SESSION', 'CARGO_FINANCIAL_ENTRY',
        'CARGO_PURCHASE_RATE', 'CARGO_CUSTOMER_FX_QUOTE', 'CARGO_USER_DAILY_RATE',
        'CUSTOMER_ORDER', 'CUSTOMER_ORDER_LINE', 'PICKING_SESSION', 'OUTBOUND_PACKAGE',
        'OUTBOUND_DELIVERY', 'WAREHOUSE_RELOCATION'
    ));
