ALTER TABLE crm.supplier_goods_entry
    ADD COLUMN website_badges JSONB NOT NULL DEFAULT '[]'::jsonb;

CREATE FUNCTION crm.valid_goods_website_badges(value JSONB) RETURNS BOOLEAN
LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN jsonb_typeof(value) <> 'array' THEN FALSE
        WHEN jsonb_array_length(value) > 8 THEN FALSE
        ELSE (SELECT COALESCE(bool_and(
            COALESCE(jsonb_typeof(badge) = 'object', FALSE)
            AND COALESCE(jsonb_typeof(badge->'text') = 'string', FALSE)
            AND COALESCE(length(badge->>'text') BETWEEN 1 AND 48, FALSE)
            AND COALESCE(badge->>'text' !~ '^[[:space:]]|[[:space:]]$', FALSE)
            AND COALESCE(badge->>'tone' IN ('NEUTRAL','BRAND','SUCCESS','INFO','WARNING','ACCENT'), FALSE)), TRUE)
            AND count(*) = count(DISTINCT lower(badge->>'text'))
            FROM jsonb_array_elements(value) badge) END;
$$;

ALTER TABLE crm.supplier_goods_entry ADD CONSTRAINT supplier_goods_website_badges_valid
    CHECK (crm.valid_goods_website_badges(website_badges));

COMMENT ON COLUMN crm.supplier_goods_entry.border_tariff_subcategory_id IS
    'Shared CRM goods classification. Optional descriptive classification for MINI; FULL uses it for future materialization quotes. Existing calculation snapshots are immutable.';
COMMENT ON COLUMN crm.supplier_goods_entry.website_badges IS
    'Ordered descriptive website labels shared by all goods variants. Separate from physical warehouse label identity.';

CREATE TABLE crm.website_catalog_revision (
    project_id UUID NOT NULL REFERENCES crm.project(id) ON DELETE CASCADE,
    transaction_id BIGINT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(project_id, transaction_id)
);
CREATE INDEX website_catalog_revision_compaction ON crm.website_catalog_revision(occurred_at,project_id,transaction_id);
CREATE TABLE crm.website_catalog_revision_checkpoint (
    project_id UUID PRIMARY KEY REFERENCES crm.project(id) ON DELETE CASCADE,
    transaction_count BIGINT NOT NULL,
    transaction_sum NUMERIC(38,0) NOT NULL
);

CREATE FUNCTION crm.touch_website_catalog_revision() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    row_data JSONB;
    affected_project UUID;
BEGIN
    IF TG_TABLE_NAME IN ('border_tariff_category','border_tariff_subcategory') THEN
        INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
            SELECT id,txid_current() FROM crm.project
            ON CONFLICT(project_id,transaction_id) DO NOTHING;
        RETURN NULL;
    END IF;
    row_data := CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
    IF TG_TABLE_NAME='cargo_item_financial_entry' AND row_data->>'entry_type'<>'ONLINE_STORE_PRICE' THEN
        RETURN NULL;
    END IF;
    IF TG_OP='UPDATE' THEN
        IF TG_TABLE_NAME='supplier_goods_entry' AND (
            SELECT bool_and(row_data->key IS NOT DISTINCT FROM to_jsonb(OLD)->key)
            FROM unnest(ARRAY['name','description','border_tariff_subcategory_id','website_badges','cover_photo_id','deleted_at']) key
        ) THEN RETURN NULL; END IF;
        IF TG_TABLE_NAME='cargo_item' AND (
            SELECT bool_and(row_data->key IS NOT DISTINCT FROM to_jsonb(OLD)->key)
            FROM unnest(ARRAY['supplier_goods_variant_id','status_code','customer_profile_id','customer_account_id']) key
        ) THEN RETURN NULL; END IF;
        IF TG_TABLE_NAME='customer_order_line' AND (
            SELECT bool_and(row_data->key IS NOT DISTINCT FROM to_jsonb(OLD)->key)
            FROM unnest(ARRAY['cargo_item_id','status_code']) key
        ) THEN RETURN NULL; END IF;
    END IF;
    affected_project := (row_data->>'project_id')::UUID;
    IF affected_project IS NULL AND TG_TABLE_NAME='supplier_goods_variant' THEN
        SELECT project_id INTO affected_project FROM crm.supplier_goods_entry
            WHERE id=(row_data->>'supplier_goods_entry_id')::UUID;
    ELSIF affected_project IS NULL AND TG_TABLE_NAME='cargo_item_financial_entry' THEN
        SELECT project_id INTO affected_project FROM crm.cargo_item WHERE id=(row_data->>'cargo_item_id')::UUID;
    ELSIF affected_project IS NULL AND TG_TABLE_NAME='cargo_item_photo_object' THEN
        SELECT project_id INTO affected_project FROM crm.cargo_item_photo WHERE id=(row_data->>'photo_id')::UUID;
    END IF;
    IF affected_project IS NOT NULL THEN
        INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
            SELECT id,txid_current() FROM crm.project WHERE id=affected_project
            ON CONFLICT(project_id,transaction_id) DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$;

DO $$
DECLARE target TEXT;
BEGIN
    FOREACH target IN ARRAY ARRAY['supplier_goods_entry','supplier_goods_variant','cargo_item',
        'cargo_item_financial_entry','customer_order_line','cargo_item_photo','cargo_item_photo_object',
        'border_tariff_category','border_tariff_subcategory'] LOOP
        EXECUTE format('CREATE TRIGGER website_catalog_changed AFTER INSERT OR UPDATE OR DELETE ON crm.%I FOR EACH ROW EXECUTE FUNCTION crm.touch_website_catalog_revision()',target);
    END LOOP;
END;
$$;

-- The previous independent retail taxonomy is retained as history; new code does not use it.
