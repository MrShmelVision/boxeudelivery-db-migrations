CREATE TABLE crm.border_tariff_category_group (
    id UUID PRIMARY KEY,
    category_id UUID NOT NULL REFERENCES crm.border_tariff_category(id) ON DELETE RESTRICT,
    code VARCHAR(64) NOT NULL CHECK (code ~ '^[A-Z][A-Z0-9_]{1,63}$'),
    display_name VARCHAR(150) NOT NULL CHECK (BTRIM(display_name) <> ''),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    display_order INTEGER NOT NULL DEFAULT 0 CHECK (display_order >= 0),
    created_by_subject VARCHAR(255) NOT NULL CHECK (BTRIM(created_by_subject) <> ''),
    updated_by_subject VARCHAR(255) NOT NULL CHECK (BTRIM(updated_by_subject) <> ''),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
    CONSTRAINT uq_border_tariff_group_code UNIQUE (category_id, code),
    CONSTRAINT uq_border_tariff_group_name UNIQUE (category_id, display_name),
    CONSTRAINT uq_border_tariff_group_category UNIQUE (id, category_id),
    CONSTRAINT ck_border_tariff_group_timestamps CHECK (updated_at >= created_at)
);

CREATE INDEX ix_border_tariff_group_category
    ON crm.border_tariff_category_group(category_id, active, display_order, display_name, id);

ALTER TABLE crm.border_tariff_subcategory
    ADD COLUMN group_id UUID,
    ADD COLUMN website_slug VARCHAR(224),
    ADD CONSTRAINT fk_border_tariff_subcategory_group
        FOREIGN KEY (group_id, category_id)
        REFERENCES crm.border_tariff_category_group(id, category_id) ON DELETE RESTRICT,
    ADD CONSTRAINT ck_border_tariff_subcategory_website_slug
        CHECK (website_slug IS NULL OR website_slug ~ '^subcategory-[a-z][a-z0-9-]*$');

DROP INDEX crm.uq_border_tariff_subcategory_code;
DROP INDEX crm.uq_border_tariff_subcategory_name;
CREATE UNIQUE INDEX uq_border_tariff_subcategory_code
    ON crm.border_tariff_subcategory(group_id, code) NULLS NOT DISTINCT
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uq_border_tariff_subcategory_name
    ON crm.border_tariff_subcategory(category_id, group_id, display_name) NULLS NOT DISTINCT
    WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uq_border_tariff_subcategory_website_slug
    ON crm.border_tariff_subcategory(COALESCE(website_slug, 'subcategory-' || lower(replace(code, '_', '-'))))
    WHERE deleted_at IS NULL;
CREATE INDEX ix_border_tariff_subcategory_group
    ON crm.border_tariff_subcategory(group_id, active, display_order, display_name, id)
    WHERE deleted_at IS NULL;

-- Existing terminal identities, commercial policies and public URLs stay intact.
INSERT INTO crm.border_tariff_category_group
    (id, category_id, code, display_name, display_order, created_by_subject, updated_by_subject)
SELECT md5('catalogue-legacy-group:' || c.id::text)::uuid, c.id, 'LEGACY',
       'Ранее созданные категории', 100000, 'catalogue-hierarchy', 'catalogue-hierarchy'
FROM crm.border_tariff_category c
WHERE EXISTS (SELECT 1 FROM crm.border_tariff_subcategory s WHERE s.category_id = c.id);

UPDATE crm.border_tariff_subcategory s
SET group_id = g.id, updated_by_subject = 'catalogue-hierarchy',
    updated_at = CURRENT_TIMESTAMP, version = s.version + 1
FROM crm.border_tariff_category_group g
WHERE g.category_id = s.category_id AND g.code = 'LEGACY';

CREATE FUNCTION crm.touch_website_catalog_group_revision() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO crm.website_catalog_revision(project_id, transaction_id)
        SELECT id, txid_current() FROM crm.project
        ON CONFLICT(project_id, transaction_id) DO NOTHING;
    RETURN NULL;
END;
$$;

CREATE TRIGGER website_catalog_changed
AFTER INSERT OR UPDATE OR DELETE ON crm.border_tariff_category_group
FOR EACH ROW EXECUTE FUNCTION crm.touch_website_catalog_group_revision();

COMMENT ON TABLE crm.border_tariff_category_group IS
    'Second-level navigation only. Tariffs and goods assignments belong to terminal subcategories.';
COMMENT ON COLUMN crm.border_tariff_subcategory.group_id IS
    'Navigation parent in the same root category. Nullable for compatibility with an older writer during rollout.';
COMMENT ON COLUMN crm.border_tariff_subcategory.website_slug IS
    'Stable public terminal URL key. Null preserves the historical code-based URL.';
