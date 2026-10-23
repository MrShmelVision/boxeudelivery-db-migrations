CREATE TABLE crm.product_brand (
    id UUID PRIMARY KEY,
    name VARCHAR(120) NOT NULL CHECK (name = btrim(name) AND length(name) > 0),
    created_by_subject VARCHAR(255) NOT NULL,
    updated_by_subject VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0)
);
CREATE UNIQUE INDEX uq_product_brand_name ON crm.product_brand (lower(name));

ALTER TABLE crm.supplier_goods_entry ADD COLUMN brand_id UUID
    CONSTRAINT fk_supplier_goods_brand REFERENCES crm.product_brand(id) ON DELETE RESTRICT;
CREATE INDEX ix_supplier_goods_brand ON crm.supplier_goods_entry(brand_id) WHERE brand_id IS NOT NULL;

CREATE TABLE crm.product_brand_audit_event (
    id UUID PRIMARY KEY,
    brand_id UUID NOT NULL,
    action_code VARCHAR(10) NOT NULL CHECK (action_code IN ('CREATED','UPDATED','DELETED')),
    old_name VARCHAR(120),
    new_name VARCHAR(120),
    actor_subject VARCHAR(255) NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX ix_product_brand_audit ON crm.product_brand_audit_event(brand_id,occurred_at);

CREATE FUNCTION crm.touch_website_catalog_brand_revision() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'product_brand' THEN
        IF NEW.name IS NOT DISTINCT FROM OLD.name THEN RETURN NULL; END IF;
        INSERT INTO crm.website_catalog_revision(project_id, transaction_id)
            SELECT DISTINCT project_id, txid_current() FROM crm.supplier_goods_entry
            WHERE brand_id = NEW.id AND deleted_at IS NULL
            ORDER BY project_id
            ON CONFLICT(project_id,transaction_id) DO NOTHING;
    ELSE
        IF NEW.brand_id IS NOT DISTINCT FROM OLD.brand_id THEN RETURN NULL; END IF;
        INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
            VALUES (NEW.project_id,txid_current())
            ON CONFLICT(project_id,transaction_id) DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$;
CREATE TRIGGER website_catalog_brand_changed AFTER UPDATE OF name ON crm.product_brand
    FOR EACH ROW EXECUTE FUNCTION crm.touch_website_catalog_brand_revision();
CREATE TRIGGER website_catalog_brand_changed AFTER UPDATE OF brand_id ON crm.supplier_goods_entry
    FOR EACH ROW EXECUTE FUNCTION crm.touch_website_catalog_brand_revision();

COMMENT ON TABLE crm.product_brand IS 'Global administrator-managed brands. No automatic or seeded product assignments.';
COMMENT ON TABLE crm.product_brand_audit_event IS 'Retained brand history, including deletion of an unused brand.';
