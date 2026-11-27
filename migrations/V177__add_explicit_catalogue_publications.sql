CREATE TABLE crm.catalogue_supplier_card (
    supplier_goods_entry_id UUID PRIMARY KEY,
    card_id UUID NOT NULL,
    project_id UUID NOT NULL,
    supplier_id UUID NOT NULL,
    created_by_subject VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    UNIQUE(supplier_goods_entry_id,card_id,project_id),
    FOREIGN KEY(supplier_goods_entry_id,project_id,supplier_id)
        REFERENCES crm.supplier_goods_entry(id,project_id,supplier_id),
    FOREIGN KEY(card_id,project_id) REFERENCES crm.catalogue_card(id,project_id)
);
CREATE TABLE crm.catalogue_supplier_variant (
    supplier_variant_id UUID PRIMARY KEY,
    supplier_goods_entry_id UUID NOT NULL,
    card_id UUID NOT NULL,
    project_id UUID NOT NULL,
    variant_id UUID NOT NULL,
    supplier_id UUID NOT NULL,
    created_by_subject VARCHAR(255) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    FOREIGN KEY(supplier_variant_id,supplier_goods_entry_id,project_id,supplier_id)
        REFERENCES crm.supplier_goods_variant(id,supplier_goods_entry_id,project_id,supplier_id),
    FOREIGN KEY(supplier_goods_entry_id,card_id,project_id)
        REFERENCES crm.catalogue_supplier_card(supplier_goods_entry_id,card_id,project_id),
    FOREIGN KEY(variant_id,project_id) REFERENCES crm.catalogue_variant(id,project_id)
);
CREATE INDEX ix_catalogue_supplier_variant_card ON crm.catalogue_supplier_variant(card_id,variant_id);

CREATE TABLE crm.catalogue_draft_seo (
    card_id UUID PRIMARY KEY REFERENCES crm.catalogue_card(id),
    slug VARCHAR(120),
    title VARCHAR(200),
    description VARCHAR(500),
    heading VARCHAR(200),
    image_position INTEGER CHECK(image_position BETWEEN 0 AND 9),
    excluded BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK(slug IS NULL OR slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);
CREATE TABLE crm.catalogue_publication (
    id UUID PRIMARY KEY,
    card_id UUID NOT NULL,
    project_id UUID NOT NULL,
    draft_version BIGINT NOT NULL,
    snapshot JSONB NOT NULL CHECK(jsonb_typeof(snapshot)='object'),
    published_by_subject VARCHAR(255) NOT NULL,
    published_at TIMESTAMPTZ NOT NULL,
    UNIQUE(id,card_id,project_id),
    FOREIGN KEY(card_id,project_id) REFERENCES crm.catalogue_card(id,project_id)
);
ALTER TABLE crm.catalogue_card ADD COLUMN published_revision_id UUID,
    ADD FOREIGN KEY(published_revision_id,id,project_id) REFERENCES crm.catalogue_publication(id,card_id,project_id);
CREATE FUNCTION crm.protect_catalogue_publication() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Published catalogue revisions are immutable'; END;
$$;
CREATE TRIGGER catalogue_publication_immutable BEFORE UPDATE OR DELETE ON crm.catalogue_publication
    FOR EACH ROW EXECUTE FUNCTION crm.protect_catalogue_publication();

-- No automatic publication or source approval: existing cards await an administrator's review.
CREATE VIEW crm.catalogue_public_revision AS
SELECT publication.* FROM crm.catalogue_card current
JOIN crm.catalogue_publication publication ON publication.id=current.published_revision_id;
CREATE VIEW crm.catalogue_public_card AS
SELECT saved.* FROM crm.catalogue_public_revision publication
CROSS JOIN LATERAL jsonb_populate_record(NULL::crm.catalogue_card,publication.snapshot->'card') saved;
CREATE VIEW crm.catalogue_public_variant AS
SELECT saved.* FROM crm.catalogue_public_revision publication
CROSS JOIN LATERAL jsonb_populate_recordset(NULL::crm.catalogue_resolved_variant,publication.snapshot->'variants') saved;
CREATE VIEW crm.catalogue_public_code AS
SELECT saved.* FROM crm.catalogue_public_revision publication
CROSS JOIN LATERAL jsonb_populate_recordset(NULL::crm.catalogue_product_code,publication.snapshot->'codes') saved;
CREATE VIEW crm.catalogue_public_price AS
SELECT saved.* FROM crm.catalogue_public_revision publication
CROSS JOIN LATERAL jsonb_populate_recordset(NULL::crm.catalogue_effective_price,publication.snapshot->'prices') saved;
CREATE VIEW crm.catalogue_public_photo AS
SELECT saved.* FROM crm.catalogue_public_revision publication
CROSS JOIN LATERAL jsonb_populate_recordset(NULL::crm.catalogue_photo,publication.snapshot->'photos') saved;
CREATE VIEW crm.catalogue_public_source AS
SELECT saved.* FROM crm.catalogue_public_revision publication
CROSS JOIN LATERAL jsonb_populate_recordset(NULL::crm.catalogue_supplier_variant,publication.snapshot->'sources') saved;
CREATE VIEW crm.catalogue_public_seo AS
SELECT publication.card_id, publication.id AS revision_id, publication.snapshot->'seo' AS seo
FROM crm.catalogue_public_revision publication;

CREATE VIEW crm.catalogue_public_stock AS
SELECT variant.id AS variant_id,variant.supplier_goods_entry_id,variant.project_id,variant.created_at,
    card.public_anchor_variant_id AS canonical_variant_id,coalesce(stock.quantity,0)::INTEGER AS available_quantity,
    variant.canonical
FROM crm.catalogue_public_variant variant
JOIN crm.catalogue_public_card card ON card.id=variant.supplier_goods_entry_id
LEFT JOIN (
    SELECT source.variant_id,count(*) AS quantity
    FROM crm.cargo_item item
    JOIN crm.catalogue_public_source source ON source.supplier_variant_id=item.supplier_goods_variant_id
        AND source.project_id=item.project_id AND source.supplier_id=item.supplier_id
    WHERE item.status_code='AVAILABLE' AND item.current_warehouse_id IS NOT NULL AND item.accepted_at IS NOT NULL
        AND item.product_identification_code IN ('LEGACY','CONFIRMED')
        AND item.sales_request_line_id IS NULL AND item.customer_profile_id IS NULL AND item.customer_account_id IS NULL
        AND NOT EXISTS (SELECT 1 FROM crm.customer_order_line line WHERE line.cargo_item_id=item.id AND line.status_code<>'REMOVED')
        AND NOT EXISTS (SELECT 1 FROM crm.warehouse_relocation_item link
            JOIN crm.warehouse_relocation relocation ON relocation.id=link.relocation_id
            WHERE link.cargo_item_id=item.id AND relocation.status_code NOT IN ('COMPLETED','CANCELLED'))
        AND NOT EXISTS (SELECT 1 FROM crm.mini_supplier_intake_item link
            JOIN crm.mini_supplier_intake intake ON intake.id=link.intake_id WHERE link.cargo_item_id=item.id AND intake.completed_at IS NULL)
        AND NOT EXISTS (SELECT 1 FROM crm.inbound_delivery delivery WHERE delivery.id=item.inbound_delivery_id
            AND delivery.status_code NOT IN ('COMPLETED','CANCELLED'))
    GROUP BY source.variant_id
) stock ON stock.variant_id=variant.canonical_id;
CREATE VIEW crm.catalogue_public_ready AS
SELECT card.id AS supplier_goods_entry_id, TRUE AS ready
FROM crm.catalogue_public_card card
JOIN crm.border_tariff_subcategory subcategory ON subcategory.id=card.border_tariff_subcategory_id
JOIN crm.border_tariff_category category ON category.id=subcategory.category_id
LEFT JOIN crm.border_tariff_category_group category_group ON category_group.id=subcategory.group_id
WHERE card.website_delivery_days IS NOT NULL AND subcategory.active AND subcategory.deleted_at IS NULL
    AND category.active AND (subcategory.group_id IS NULL OR category_group.active);

DROP TRIGGER website_stock_eligibility_changed ON crm.cargo_item;
CREATE TRIGGER website_stock_eligibility_changed
AFTER UPDATE OF current_warehouse_id,accepted_at,inbound_delivery_id,project_id,sales_request_line_id,
    supplier_goods_variant_id,supplier_id,catalogue_variant_id,product_identification_code ON crm.cargo_item
FOR EACH ROW EXECUTE FUNCTION crm.touch_website_stock_eligibility_revision();
