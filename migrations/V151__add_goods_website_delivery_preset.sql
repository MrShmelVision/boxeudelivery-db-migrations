ALTER TABLE crm.supplier_goods_entry
    ADD COLUMN website_delivery_days INTEGER,
    ADD CONSTRAINT ck_supplier_goods_website_delivery_days
        CHECK (website_delivery_days IS NULL OR website_delivery_days IN (7, 14, 21));

COMMENT ON COLUMN crm.supplier_goods_entry.website_delivery_days IS
    'Optional calendar-day delivery preset for out-of-stock goods. Shared by all card variants. Managed in CRM without changing website publication or physical delivery deadlines.';
