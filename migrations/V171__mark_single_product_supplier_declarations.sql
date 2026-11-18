ALTER TABLE crm.supplier_goods_entry
    ADD COLUMN single_product_declaration BOOLEAN NOT NULL DEFAULT FALSE,
    ADD CONSTRAINT ck_supplier_goods_single_product_code
        CHECK (NOT single_product_declaration OR ean IS NULL OR crm.valid_product_gtin(ean));
