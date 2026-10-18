-- A removed order line must not start describing another supplier's current stock.
-- The transfer command captures its existing presentation once, before moving the unit.
ALTER TABLE crm.customer_order_line
    ADD COLUMN removed_goods_entry_id UUID,
    ADD COLUMN removed_goods_name VARCHAR(150),
    ADD COLUMN removed_supplier_sku VARCHAR(100),
    ADD COLUMN removed_ean VARCHAR(13),
    ADD COLUMN removed_manufacturer_article VARCHAR(100),
    ADD COLUMN removed_serial_number VARCHAR(150),
    ADD COLUMN removed_label_code VARCHAR(128),
    ADD COLUMN removed_warehouse_id UUID,
    ADD CONSTRAINT fk_customer_order_line_removed_goods
        FOREIGN KEY (removed_goods_entry_id, project_id)
        REFERENCES crm.supplier_goods_entry (id, project_id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_customer_order_line_removed_warehouse
        FOREIGN KEY (removed_warehouse_id) REFERENCES crm.warehouse (id) ON DELETE RESTRICT,
    ADD CONSTRAINT ck_customer_order_line_removed_goods_snapshot CHECK (
        (
            removed_goods_entry_id IS NULL AND removed_goods_name IS NULL
            AND removed_supplier_sku IS NULL AND removed_ean IS NULL
            AND removed_manufacturer_article IS NULL AND removed_serial_number IS NULL
            AND removed_label_code IS NULL AND removed_warehouse_id IS NULL
        ) OR (
            status_code = 'REMOVED' AND removed_goods_entry_id IS NOT NULL
            AND removed_goods_name IS NOT NULL AND BTRIM(removed_goods_name) <> ''
        )
    );

CREATE INDEX ix_customer_order_line_removed_goods ON crm.customer_order_line(removed_goods_entry_id)
    WHERE removed_goods_entry_id IS NOT NULL;

COMMENT ON COLUMN crm.customer_order_line.removed_goods_entry_id IS
    'Descriptive snapshot of a removed line, captured once before a goods-card transfer. Monetary fields, revisions and timestamps are unchanged.';
