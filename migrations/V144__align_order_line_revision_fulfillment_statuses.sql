ALTER TABLE crm.customer_order_line_revision
    DROP CONSTRAINT ck_customer_order_line_revision_status,
    ADD CONSTRAINT ck_customer_order_line_revision_status
        CHECK (status_code IN ('DRAFT', 'CONFIRMED', 'PICKED', 'PACKED', 'DELIVERED', 'REMOVED'));

COMMENT ON COLUMN crm.customer_order_line_revision.status_code IS
    'Exact order-line lifecycle snapshot at the revision. Application commands still forbid repricing delivered or removed lines.';
