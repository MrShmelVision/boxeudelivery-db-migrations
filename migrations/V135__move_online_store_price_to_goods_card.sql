-- A card owns one independent retail price for every variant, existing unit and future replenishment.
ALTER TABLE crm.supplier_goods_entry
    ADD COLUMN online_store_amount NUMERIC(19,4),
    ADD COLUMN online_store_currency_code VARCHAR(3) REFERENCES crm.currency_definition(code) ON DELETE RESTRICT,
    ADD COLUMN online_store_price_revision INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN online_store_price_needs_review BOOLEAN NOT NULL DEFAULT FALSE,
    ADD CONSTRAINT ck_goods_online_store_price CHECK (
        (online_store_amount IS NULL AND online_store_currency_code IS NULL)
        OR (online_store_amount IS NOT NULL AND online_store_amount >= 0 AND online_store_currency_code IS NOT NULL)
    ),
    ADD CONSTRAINT ck_goods_online_store_price_revision CHECK (online_store_price_revision >= 0),
    ADD CONSTRAINT ck_goods_online_store_price_review CHECK (
        NOT online_store_price_needs_review OR online_store_amount IS NULL
    );

CREATE TABLE crm.supplier_goods_online_store_price_revision (
    id UUID PRIMARY KEY,
    supplier_goods_entry_id UUID NOT NULL REFERENCES crm.supplier_goods_entry(id) ON DELETE RESTRICT,
    revision_number INTEGER NOT NULL CHECK (revision_number > 0),
    action_code VARCHAR(16) NOT NULL CHECK (action_code IN ('CREATED','CORRECTED','DELETED')),
    amount NUMERIC(19,4),
    currency_code VARCHAR(3) REFERENCES crm.currency_definition(code) ON DELETE RESTRICT,
    actor_subject VARCHAR(255) NOT NULL,
    reason VARCHAR(500),
    occurred_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT uq_goods_online_store_price_revision UNIQUE (supplier_goods_entry_id, revision_number),
    CONSTRAINT ck_goods_online_store_price_revision_value CHECK (
        (action_code = 'DELETED' AND amount IS NULL AND currency_code IS NULL)
        OR (action_code <> 'DELETED' AND amount IS NOT NULL AND amount >= 0 AND currency_code IS NOT NULL)
    ),
    CONSTRAINT ck_goods_online_store_price_revision_reason CHECK (
        action_code = 'CREATED' OR (reason IS NOT NULL AND length(btrim(reason)) > 0)
    )
);

-- Only unanimous historical prices can be carried forward automatically.
-- Conflicting amounts/currencies stay intact in the old financial ledger and require employee review.
WITH legacy AS (
    SELECT i.supplier_goods_entry_id AS goods_id,
           count(DISTINCT (f.amount, f.currency_code)) AS prices,
           min(f.amount) AS amount, min(f.currency_code) AS currency
    FROM crm.cargo_item_financial_entry f
    JOIN crm.cargo_item i ON i.id = f.cargo_item_id
    WHERE f.entry_type = 'ONLINE_STORE_PRICE' AND f.active
    GROUP BY i.supplier_goods_entry_id
)
UPDATE crm.supplier_goods_entry g
SET online_store_amount = CASE WHEN legacy.prices = 1 THEN legacy.amount END,
    online_store_currency_code = CASE WHEN legacy.prices = 1 THEN legacy.currency END,
    online_store_price_revision = CASE WHEN legacy.prices = 1 THEN 1 ELSE 0 END,
    online_store_price_needs_review = legacy.prices > 1,
    updated_by_subject = 'migration:V135', updated_at = CURRENT_TIMESTAMP, version = g.version + 1
FROM legacy WHERE g.id = legacy.goods_id;

INSERT INTO crm.supplier_goods_online_store_price_revision
    (id, supplier_goods_entry_id, revision_number, action_code, amount, currency_code, actor_subject, reason, occurred_at)
SELECT gen_random_uuid(), id, 1, 'CREATED', online_store_amount, online_store_currency_code,
       'migration:V135', 'Transferred unanimous legacy item prices; original entries and revisions retained', CURRENT_TIMESTAMP
FROM crm.supplier_goods_entry WHERE online_store_price_revision = 1;

COMMENT ON COLUMN crm.supplier_goods_entry.online_store_amount IS
    'Independent public store price shared by all variants and units. Never derived from customer, procurement or settlement prices.';
COMMENT ON COLUMN crm.supplier_goods_entry.online_store_price_needs_review IS
    'Legacy per-item prices disagreed; no public price until an authorized employee sets a shared price or clears the conflict.';
COMMENT ON TABLE crm.supplier_goods_online_store_price_revision IS
    'Employee-managed card price history. Legacy ONLINE_STORE_PRICE item ledger rows remain historical only.';

-- Card prices changed ownership; force a new catalogue snapshot even if only conflicting legacy prices existed.
INSERT INTO crm.website_catalog_revision(project_id, transaction_id)
SELECT DISTINCT project_id, txid_current() FROM crm.supplier_goods_entry
ON CONFLICT (project_id, transaction_id) DO NOTHING;

-- Preserve transaction-scoped catalogue invalidation for shared price changes.
CREATE OR REPLACE FUNCTION crm.touch_website_catalog_revision() RETURNS TRIGGER
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
            FROM unnest(ARRAY['name','description','border_tariff_subcategory_id','website_badges','cover_photo_id','deleted_at','online_store_amount','online_store_currency_code']) key
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
    ELSIF affected_project IS NULL AND TG_TABLE_NAME='cargo_item_photo' THEN
        SELECT project_id INTO affected_project FROM crm.supplier_goods_entry
            WHERE id=(row_data->>'supplier_goods_entry_id')::UUID;
    ELSIF affected_project IS NULL AND TG_TABLE_NAME='cargo_item_photo_object' THEN
        SELECT goods.project_id INTO affected_project
            FROM crm.cargo_item_photo photo
            JOIN crm.supplier_goods_entry goods ON goods.id=photo.supplier_goods_entry_id
            WHERE photo.id=(row_data->>'photo_id')::UUID;
    END IF;
    IF affected_project IS NOT NULL THEN
        INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
            SELECT id,txid_current() FROM crm.project WHERE id=affected_project
            ON CONFLICT(project_id,transaction_id) DO NOTHING;
    END IF;
    RETURN NULL;
END;
$$;
