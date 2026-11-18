CREATE TABLE crm.catalogue_card (
    id UUID PRIMARY KEY,
    project_id UUID NOT NULL REFERENCES crm.project(id) ON DELETE RESTRICT,
    merged_into_id UUID,
    public_anchor_variant_id UUID,
    name VARCHAR(150) NOT NULL CHECK (length(btrim(name)) > 0),
    description VARCHAR(2000),
    article_number VARCHAR(17) NOT NULL UNIQUE REFERENCES crm.supplier_goods_article_number(article_number),
    manufacturer_article VARCHAR(100),
    border_tariff_subcategory_id UUID REFERENCES crm.border_tariff_subcategory(id),
    brand_id UUID REFERENCES crm.product_brand(id),
    website_badges JSONB NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(website_badges) = 'array'),
    website_delivery_days INTEGER CHECK (website_delivery_days IN (7,14,21)),
    website_prepayment_percent INTEGER CHECK (website_prepayment_percent BETWEEN 0 AND 100),
    gallery_entry_id UUID REFERENCES crm.supplier_goods_entry(id),
    online_store_amount NUMERIC(19,4),
    online_store_currency_code VARCHAR(3) REFERENCES crm.currency_definition(code),
    online_store_discount_percent INTEGER NOT NULL DEFAULT 0 CHECK (online_store_discount_percent BETWEEN 0 AND 99),
    online_store_discounted_amount NUMERIC(19,4),
    online_store_price_needs_review BOOLEAN NOT NULL DEFAULT FALSE,
    price_revision INTEGER NOT NULL DEFAULT 0 CHECK (price_revision >= 0),
    created_by_subject VARCHAR(255) NOT NULL,
    updated_by_subject VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    deleted_at TIMESTAMPTZ,
    version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
    UNIQUE(id,project_id),
    FOREIGN KEY(merged_into_id,project_id) REFERENCES crm.catalogue_card(id,project_id),
    CHECK (merged_into_id IS NULL OR merged_into_id <> id),
    CHECK ((online_store_amount IS NULL AND online_store_currency_code IS NULL)
        OR (online_store_amount IS NOT NULL AND online_store_amount >= 0 AND online_store_currency_code IS NOT NULL)),
    CHECK ((online_store_discount_percent = 0 AND online_store_discounted_amount IS NULL)
        OR (online_store_discount_percent > 0 AND online_store_amount IS NOT NULL AND online_store_amount > 0
            AND online_store_discounted_amount IS NOT NULL AND online_store_discounted_amount > 0 AND online_store_discounted_amount < online_store_amount))
);

INSERT INTO crm.catalogue_card (
    id,project_id,name,description,article_number,manufacturer_article,border_tariff_subcategory_id,
    brand_id,website_badges,website_delivery_days,website_prepayment_percent,gallery_entry_id,
    online_store_amount,online_store_currency_code,online_store_discount_percent,
    online_store_discounted_amount,online_store_price_needs_review,price_revision,
    created_by_subject,updated_by_subject,created_at,updated_at,deleted_at,version
)
SELECT id,project_id,name,description,article_number,manufacturer_article,border_tariff_subcategory_id,
    brand_id,website_badges,website_delivery_days,website_prepayment_percent,id,
    online_store_amount,online_store_currency_code,online_store_discount_percent,
    online_store_discounted_amount,online_store_price_needs_review,online_store_price_revision,
    created_by_subject,updated_by_subject,created_at,updated_at,deleted_at,version
FROM crm.supplier_goods_entry;

CREATE TABLE crm.catalogue_variant (
    id UUID PRIMARY KEY,
    project_id UUID NOT NULL,
    card_id UUID NOT NULL,
    canonical_variant_id UUID,
    attributes JSONB NOT NULL CHECK (jsonb_typeof(attributes) = 'array'),
    attribute_signature VARCHAR(1024) NOT NULL,
    packaging VARCHAR(200) NOT NULL DEFAULT '',
    online_store_amount NUMERIC(19,4),
    online_store_currency_code VARCHAR(3) REFERENCES crm.currency_definition(code),
    online_store_discount_percent INTEGER NOT NULL DEFAULT 0 CHECK (online_store_discount_percent BETWEEN 0 AND 99),
    online_store_discounted_amount NUMERIC(19,4),
    price_revision INTEGER NOT NULL DEFAULT 0 CHECK (price_revision >= 0),
    created_by_subject VARCHAR(255) NOT NULL,
    updated_by_subject VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
    UNIQUE(id,project_id),
    UNIQUE(card_id,attribute_signature,packaging),
    FOREIGN KEY(card_id,project_id) REFERENCES crm.catalogue_card(id,project_id),
    FOREIGN KEY(canonical_variant_id,project_id) REFERENCES crm.catalogue_variant(id,project_id),
    CHECK (canonical_variant_id IS NULL OR canonical_variant_id <> id),
    CHECK ((online_store_amount IS NULL AND online_store_currency_code IS NULL)
        OR (online_store_amount IS NOT NULL AND online_store_amount >= 0 AND online_store_currency_code IS NOT NULL)),
    CHECK ((online_store_discount_percent = 0 AND online_store_discounted_amount IS NULL)
        OR (online_store_discount_percent > 0 AND online_store_amount IS NOT NULL AND online_store_amount > 0
            AND online_store_discounted_amount IS NOT NULL AND online_store_discounted_amount > 0 AND online_store_discounted_amount < online_store_amount))
);

INSERT INTO crm.catalogue_variant (
    id,project_id,card_id,attributes,attribute_signature,created_by_subject,updated_by_subject,created_at,updated_at
)
SELECT id,project_id,supplier_goods_entry_id,attributes,attribute_signature,
    created_by_subject,created_by_subject,created_at,created_at
FROM crm.supplier_goods_variant;

UPDATE crm.catalogue_card card SET public_anchor_variant_id=(
    SELECT variant.id FROM crm.catalogue_variant variant WHERE variant.card_id=card.id
    ORDER BY variant.created_at,variant.id LIMIT 1);
ALTER TABLE crm.catalogue_card ADD FOREIGN KEY(public_anchor_variant_id,project_id)
    REFERENCES crm.catalogue_variant(id,project_id);

CREATE FUNCTION crm.valid_product_gtin(value TEXT) RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE total INTEGER := 0;
DECLARE position INTEGER;
DECLARE multiplier INTEGER := 3;
BEGIN
    IF value !~ '^([0-9]{8}|[0-9]{12}|[0-9]{13}|[0-9]{14})$' THEN
        RETURN FALSE;
    END IF;
    FOR position IN REVERSE length(value)-1..1 LOOP
        total := total + substring(value,position,1)::INTEGER * multiplier;
        multiplier := 4-multiplier;
    END LOOP;
    RETURN (10-total%10)%10 = right(value,1)::INTEGER;
END;
$$;

CREATE TABLE crm.catalogue_product_code (
    id UUID PRIMARY KEY,
    project_id UUID NOT NULL,
    variant_id UUID NOT NULL,
    entered_code VARCHAR(14) NOT NULL CHECK (crm.valid_product_gtin(entered_code)),
    normalized_code VARCHAR(14) GENERATED ALWAYS AS (lpad(entered_code,14,'0')) STORED,
    created_by_subject VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT uq_catalogue_product_code UNIQUE(project_id,normalized_code),
    FOREIGN KEY(variant_id,project_id) REFERENCES crm.catalogue_variant(id,project_id)
);

CREATE TABLE crm.catalogue_price_revision (
    id UUID PRIMARY KEY,
    project_id UUID NOT NULL REFERENCES crm.project(id),
    card_id UUID REFERENCES crm.catalogue_card(id),
    variant_id UUID REFERENCES crm.catalogue_variant(id),
    revision_number INTEGER NOT NULL CHECK (revision_number > 0),
    amount NUMERIC(19,4),
    currency_code VARCHAR(3) REFERENCES crm.currency_definition(code),
    discount_percent INTEGER NOT NULL CHECK (discount_percent BETWEEN 0 AND 99),
    discounted_amount NUMERIC(19,4),
    actor_subject VARCHAR(255) NOT NULL,
    reason VARCHAR(500),
    occurred_at TIMESTAMPTZ NOT NULL,
    CHECK (num_nonnulls(card_id,variant_id) = 1),
    CHECK ((amount IS NULL AND currency_code IS NULL) OR (amount IS NOT NULL AND amount >= 0 AND currency_code IS NOT NULL)),
    UNIQUE(card_id,revision_number),
    UNIQUE(variant_id,revision_number)
);

CREATE TABLE crm.catalogue_photo (
    card_id UUID NOT NULL REFERENCES crm.catalogue_card(id),
    photo_id UUID NOT NULL REFERENCES crm.cargo_item_photo(id) ON DELETE CASCADE,
    position INTEGER NOT NULL CHECK (position BETWEEN 0 AND 9),
    approved_by_subject VARCHAR(255) NOT NULL,
    approved_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY(card_id,photo_id),
    UNIQUE(card_id,position)
);

INSERT INTO crm.catalogue_photo(card_id,photo_id,position,approved_by_subject,approved_at)
SELECT card.id,photo.id,(row_number() OVER(PARTITION BY card.id ORDER BY
    CASE WHEN photo.id=declaration.cover_photo_id THEN 0 ELSE 1 END,photo.position,photo.id)-1)::INTEGER,
    'migration:V169',CURRENT_TIMESTAMP
FROM crm.catalogue_card card
JOIN crm.supplier_goods_entry declaration ON declaration.id=card.gallery_entry_id
JOIN crm.cargo_item_photo photo ON photo.supplier_goods_entry_id=declaration.id
WHERE photo.gallery_scope_code='SUPPLIER_GOODS';

CREATE TABLE crm.catalogue_merge_review (
    id UUID PRIMARY KEY,
    project_id UUID NOT NULL REFERENCES crm.project(id),
    source_id UUID NOT NULL,
    destination_id UUID NOT NULL,
    source_version BIGINT NOT NULL,
    destination_version BIGINT NOT NULL,
    reviewed_choices JSONB NOT NULL CHECK (jsonb_typeof(reviewed_choices) = 'object'),
    created_by_subject VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    committed_at TIMESTAMPTZ,
    FOREIGN KEY(source_id,project_id) REFERENCES crm.catalogue_card(id,project_id),
    FOREIGN KEY(destination_id,project_id) REFERENCES crm.catalogue_card(id,project_id),
    CHECK (source_id <> destination_id)
);

ALTER TABLE crm.supplier_goods_entry
    ALTER COLUMN ean TYPE VARCHAR(14),
    DROP CONSTRAINT ck_supplier_goods_entry_ean,
    ADD CONSTRAINT ck_supplier_goods_entry_ean CHECK (ean IS NULL OR ean ~ '^([0-9]{8}|[0-9]{12}|[0-9]{13}|[0-9]{14})$'),
    ADD COLUMN catalogue_card_id UUID,
    ADD COLUMN transport_classification_confirmed_by VARCHAR(255),
    ADD COLUMN transport_classification_confirmed_at TIMESTAMPTZ,
    ADD FOREIGN KEY(catalogue_card_id,project_id) REFERENCES crm.catalogue_card(id,project_id);

UPDATE crm.supplier_goods_entry
SET catalogue_card_id = id,
    transport_classification_confirmed_by = CASE WHEN border_tariff_subcategory_id IS NOT NULL THEN updated_by_subject END,
    transport_classification_confirmed_at = CASE WHEN border_tariff_subcategory_id IS NOT NULL THEN updated_at END;

ALTER TABLE crm.inbound_delivery_line
    ALTER COLUMN ean TYPE VARCHAR(14),
    DROP CONSTRAINT ck_inbound_delivery_line_ean,
    ADD CONSTRAINT ck_inbound_delivery_line_ean CHECK (ean IS NULL OR ean ~ '^([0-9]{8}|[0-9]{12}|[0-9]{13}|[0-9]{14})$');
ALTER TABLE crm.customer_order_line ALTER COLUMN removed_ean TYPE VARCHAR(14);

ALTER TABLE crm.cargo_item
    ADD COLUMN catalogue_variant_id UUID,
    ADD COLUMN declared_product_code VARCHAR(14),
    ADD COLUMN declared_catalogue_variant_id UUID,
    ADD COLUMN supplier_declaration_snapshot JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(supplier_declaration_snapshot)='object'),
    ADD COLUMN product_code VARCHAR(14),
    ADD COLUMN product_identification_code VARCHAR(24) NOT NULL DEFAULT 'PENDING',
    ADD COLUMN product_review_reason VARCHAR(500),
    ADD FOREIGN KEY(catalogue_variant_id,project_id) REFERENCES crm.catalogue_variant(id,project_id),
    ADD FOREIGN KEY(declared_catalogue_variant_id,project_id) REFERENCES crm.catalogue_variant(id,project_id),
    ADD CONSTRAINT ck_cargo_product_identification CHECK (
        product_identification_code IN ('LEGACY','PENDING','CONFIRMED','UNRESOLVED','CUSTOMER_REVIEW')),
    ADD CONSTRAINT ck_cargo_product_code CHECK (product_code IS NULL OR crm.valid_product_gtin(product_code));

UPDATE crm.cargo_item SET catalogue_variant_id=supplier_goods_variant_id,product_identification_code='LEGACY';

UPDATE crm.cargo_item item SET supplier_declaration_snapshot=jsonb_build_object(
    'name',goods.name,'description',coalesce(goods.description,''))
FROM crm.supplier_goods_entry goods WHERE goods.id=item.supplier_goods_entry_id;

ALTER TABLE crm.sales_request_line DROP CONSTRAINT fk_sales_request_line_variant,
    ADD CONSTRAINT fk_sales_request_line_catalogue_variant FOREIGN KEY(supplier_goods_variant_id,project_id)
        REFERENCES crm.catalogue_variant(id,project_id) ON DELETE RESTRICT;

ALTER TABLE crm.cargo_item DROP CONSTRAINT ck_cargo_item_status,
    ADD CONSTRAINT ck_cargo_item_status CHECK (status_code IN (
        'EXPECTED_AT_SUPPLIER','AT_SUPPLIER','RESERVED_FOR_DELIVERY','IN_TRANSIT_TO_PICKUP_POINT',
        'PRICE_MODERATION','READY_FOR_COURIER_PICKUP','IN_TRANSIT_TO_WAREHOUSE','AVAILABLE',
        'IN_RELOCATION','PICKED_FOR_ORDER','PACKED_FOR_CUSTOMER','DELIVERED_TO_CUSTOMER',
        'MISSING','DAMAGED','REJECTED','CANCELLED','AWAITING_IDENTIFICATION'));

ALTER TABLE crm.cargo_item DROP CONSTRAINT ck_cargo_item_availability_state,
    ADD CONSTRAINT ck_cargo_item_availability_state CHECK (
        (status_code IN ('AVAILABLE','PICKED_FOR_ORDER','PACKED_FOR_CUSTOMER','DAMAGED','REJECTED','AWAITING_IDENTIFICATION')
            AND label_code IS NOT NULL AND current_warehouse_id IS NOT NULL
            AND accepted_by_account_id IS NOT NULL AND accepted_at IS NOT NULL)
        OR (status_code IN ('IN_RELOCATION','DELIVERED_TO_CUSTOMER') AND label_code IS NOT NULL
            AND current_warehouse_id IS NULL AND accepted_by_account_id IS NOT NULL AND accepted_at IS NOT NULL)
        OR (status_code NOT IN ('AVAILABLE','IN_RELOCATION','PICKED_FOR_ORDER','PACKED_FOR_CUSTOMER',
                'DELIVERED_TO_CUSTOMER','AWAITING_IDENTIFICATION')
            AND label_code IS NULL AND current_warehouse_id IS NULL
            AND accepted_by_account_id IS NULL AND accepted_at IS NULL));

ALTER TABLE crm.cargo_item DROP CONSTRAINT ck_cargo_item_delivery_assignment,
    ADD CONSTRAINT ck_cargo_item_delivery_assignment CHECK (
        (inbound_delivery_id IS NULL AND inbound_delivery_line_id IS NULL
            AND status_code IN ('EXPECTED_AT_SUPPLIER','AT_SUPPLIER','IN_TRANSIT_TO_WAREHOUSE','AVAILABLE',
                'IN_RELOCATION','PICKED_FOR_ORDER','PACKED_FOR_CUSTOMER','DELIVERED_TO_CUSTOMER',
                'MISSING','DAMAGED','REJECTED','CANCELLED','AWAITING_IDENTIFICATION'))
        OR (inbound_delivery_id IS NOT NULL AND inbound_delivery_line_id IS NOT NULL
            AND status_code IN ('RESERVED_FOR_DELIVERY','IN_TRANSIT_TO_PICKUP_POINT','PRICE_MODERATION',
                'READY_FOR_COURIER_PICKUP','IN_TRANSIT_TO_WAREHOUSE','AVAILABLE','IN_RELOCATION',
                'PICKED_FOR_ORDER','PACKED_FOR_CUSTOMER','DELIVERED_TO_CUSTOMER','MISSING','DAMAGED',
                'REJECTED','AWAITING_IDENTIFICATION')));

ALTER TABLE crm.warehouse_receipt_item DROP CONSTRAINT ck_warehouse_receipt_item_outcome,
    ADD CONSTRAINT ck_warehouse_receipt_item_outcome CHECK (
        outcome_code IN ('ACCEPTED','SURPLUS_ACCEPTED','MISSING','DAMAGED','REJECTED','AWAITING_IDENTIFICATION'));
ALTER TABLE crm.mini_supplier_warehouse_receipt_item DROP CONSTRAINT ck_mini_supplier_warehouse_receipt_item_outcome,
    ADD CONSTRAINT ck_mini_supplier_warehouse_receipt_item_outcome CHECK (
        outcome_code IN ('ACCEPTED','MISSING','DAMAGED','REJECTED','AWAITING_IDENTIFICATION'));

CREATE INDEX ix_catalogue_card_project ON crm.catalogue_card(project_id,updated_at DESC,id)
    WHERE deleted_at IS NULL AND merged_into_id IS NULL;
CREATE INDEX ix_catalogue_card_search ON crm.catalogue_card USING gin(lower(name || ' ' || article_number) public.gin_trgm_ops);
CREATE INDEX ix_catalogue_variant_card ON crm.catalogue_variant(card_id,id);
CREATE INDEX ix_catalogue_variant_canonical ON crm.catalogue_variant(canonical_variant_id);
CREATE INDEX ix_cargo_item_catalogue ON crm.cargo_item(project_id,catalogue_variant_id,status_code);
CREATE INDEX ix_catalogue_code_variant ON crm.catalogue_product_code(variant_id);

CREATE VIEW crm.catalogue_resolved_variant AS
SELECT alias.id,actual.id AS canonical_id,coalesce(card.merged_into_id,card.id) AS supplier_goods_entry_id,
    actual.project_id,actual.attributes,actual.packaging,actual.created_at,
    NULL::VARCHAR(50) AS value_text,
    alias.canonical_variant_id IS NULL AS canonical,
    actual.online_store_amount,actual.online_store_currency_code,
    actual.online_store_discount_percent,actual.online_store_discounted_amount
FROM crm.catalogue_variant alias
JOIN crm.catalogue_variant actual ON actual.id=coalesce(alias.canonical_variant_id,alias.id)
JOIN crm.catalogue_card card ON card.id=actual.card_id;

CREATE VIEW crm.catalogue_website_variant AS
SELECT variant.id AS variant_id,variant.supplier_goods_entry_id,variant.project_id,variant.created_at,
    card.public_anchor_variant_id AS canonical_variant_id,coalesce(stock.quantity,0)::integer AS available_quantity
FROM crm.catalogue_resolved_variant variant
JOIN crm.catalogue_card card ON card.id=variant.supplier_goods_entry_id
LEFT JOIN (
    SELECT resolved.canonical_id,count(*) AS quantity
    FROM crm.cargo_item item
    JOIN crm.catalogue_resolved_variant resolved ON resolved.id=item.catalogue_variant_id
    WHERE item.status_code='AVAILABLE' AND item.current_warehouse_id IS NOT NULL AND item.accepted_at IS NOT NULL
        AND item.product_identification_code IN ('LEGACY','CONFIRMED')
        AND item.sales_request_line_id IS NULL AND item.customer_profile_id IS NULL AND item.customer_account_id IS NULL
        AND NOT EXISTS (SELECT 1 FROM crm.customer_order_line line WHERE line.cargo_item_id=item.id AND line.status_code<>'REMOVED')
        AND NOT EXISTS (SELECT 1 FROM crm.warehouse_relocation_item link
            JOIN crm.warehouse_relocation relocation ON relocation.id=link.relocation_id
            WHERE link.cargo_item_id=item.id AND relocation.status_code NOT IN ('COMPLETED','CANCELLED'))
        AND NOT EXISTS (SELECT 1 FROM crm.mini_supplier_intake_item link
            JOIN crm.mini_supplier_intake intake ON intake.id=link.intake_id
            WHERE link.cargo_item_id=item.id AND intake.completed_at IS NULL)
        AND NOT EXISTS (SELECT 1 FROM crm.inbound_delivery delivery
            WHERE delivery.id=item.inbound_delivery_id AND delivery.status_code NOT IN ('COMPLETED','CANCELLED'))
    GROUP BY resolved.canonical_id
) stock ON stock.canonical_id=variant.canonical_id;

CREATE VIEW crm.catalogue_effective_price AS
SELECT variant.id AS variant_id,
    coalesce(variant.online_store_amount,card.online_store_amount) AS amount,
    coalesce(variant.online_store_currency_code,card.online_store_currency_code) AS currency_code,
    CASE WHEN variant.online_store_amount IS NULL THEN card.online_store_discount_percent
        ELSE variant.online_store_discount_percent END AS discount_percent,
    CASE WHEN variant.online_store_amount IS NULL THEN card.online_store_discounted_amount
        ELSE variant.online_store_discounted_amount END AS discounted_amount,
    variant.online_store_amount IS NULL AS inherited,
    variant.online_store_amount IS NULL AND card.online_store_price_needs_review AS needs_review
FROM crm.catalogue_resolved_variant variant
JOIN crm.catalogue_card card ON card.id=variant.supplier_goods_entry_id;

CREATE VIEW crm.catalogue_website_readiness AS
SELECT card.id AS supplier_goods_entry_id,
    coalesce(subcategory.active AND subcategory.deleted_at IS NULL AND category.active
        AND (subcategory.group_id IS NULL OR category_group.active),false) AS category_ready,
    card.brand_id IS NOT NULL AS brand_ready,
    EXISTS (SELECT 1 FROM crm.catalogue_resolved_variant variant
        JOIN crm.catalogue_effective_price price ON price.variant_id=variant.id
        WHERE variant.supplier_goods_entry_id=card.id AND variant.canonical
            AND price.amount IS NOT NULL AND price.currency_code IS NOT NULL AND NOT price.needs_review) AS price_ready,
    card.website_delivery_days IS NOT NULL OR EXISTS (
        SELECT 1 FROM crm.catalogue_website_variant stock
        WHERE stock.supplier_goods_entry_id=card.id AND stock.available_quantity>0) AS delivery_ready
FROM crm.catalogue_card card
LEFT JOIN crm.border_tariff_subcategory subcategory ON subcategory.id=card.border_tariff_subcategory_id
LEFT JOIN crm.border_tariff_category category ON category.id=subcategory.category_id
LEFT JOIN crm.border_tariff_category_group category_group ON category_group.id=subcategory.group_id
WHERE card.deleted_at IS NULL AND card.merged_into_id IS NULL;

CREATE VIEW crm.catalogue_website_catalog_variant AS
SELECT stock.*,resolved.canonical FROM crm.catalogue_website_variant stock
JOIN crm.catalogue_resolved_variant resolved ON resolved.id=stock.variant_id
JOIN crm.catalogue_effective_price price ON price.variant_id=stock.variant_id
JOIN crm.catalogue_card card ON card.id=stock.supplier_goods_entry_id
WHERE price.amount IS NOT NULL AND price.currency_code IS NOT NULL AND NOT price.needs_review
    AND (stock.available_quantity>0 OR card.website_delivery_days IS NOT NULL);

CREATE VIEW crm.catalogue_website_ready AS
SELECT readiness.*,readiness.category_ready AND readiness.brand_ready AND EXISTS (
    SELECT 1 FROM crm.catalogue_website_catalog_variant variant
    WHERE variant.supplier_goods_entry_id=readiness.supplier_goods_entry_id AND variant.canonical
) AS ready FROM crm.catalogue_website_readiness readiness;

CREATE OR REPLACE VIEW crm.supplier_goods_website_readiness AS
SELECT declaration.id AS supplier_goods_entry_id,
    coalesce(readiness.category_ready,false) AS category_ready,
    coalesce(readiness.brand_ready,false) AS brand_ready,
    coalesce(readiness.ready,false) AS ready,
    coalesce(readiness.price_ready,false) AS price_ready,
    coalesce(readiness.delivery_ready,false) AS delivery_ready
FROM crm.supplier_goods_entry declaration
LEFT JOIN crm.catalogue_card original ON original.id=declaration.catalogue_card_id
LEFT JOIN crm.catalogue_website_ready readiness
    ON readiness.supplier_goods_entry_id=coalesce(original.merged_into_id,original.id)
WHERE declaration.deleted_at IS NULL;

DROP TRIGGER website_stock_eligibility_changed ON crm.cargo_item;
CREATE TRIGGER website_stock_eligibility_changed
AFTER UPDATE OF current_warehouse_id,accepted_at,inbound_delivery_id,project_id,sales_request_line_id,
    catalogue_variant_id,product_identification_code ON crm.cargo_item
FOR EACH ROW EXECUTE FUNCTION crm.touch_website_stock_eligibility_revision();

INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
SELECT DISTINCT project_id,txid_current() FROM crm.catalogue_card ON CONFLICT DO NOTHING;
