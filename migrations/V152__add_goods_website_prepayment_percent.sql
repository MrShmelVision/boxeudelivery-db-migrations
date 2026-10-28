ALTER TABLE crm.supplier_goods_entry
    ADD COLUMN website_prepayment_percent INTEGER,
    ADD CONSTRAINT ck_supplier_goods_website_prepayment_percent
        CHECK (website_prepayment_percent IS NULL OR website_prepayment_percent BETWEEN 0 AND 100);
