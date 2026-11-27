CREATE OR REPLACE VIEW crm.supplier_goods_website_readiness AS
SELECT declaration.id AS supplier_goods_entry_id,
    coalesce(readiness.ready,FALSE) AS category_ready,
    card.brand_id IS NOT NULL AS brand_ready,
    coalesce(readiness.ready,FALSE) AS ready,
    EXISTS(SELECT 1 FROM crm.catalogue_public_variant variant
        JOIN crm.catalogue_public_price price ON price.variant_id=variant.id
        WHERE variant.supplier_goods_entry_id=card.id AND variant.canonical
            AND price.amount IS NOT NULL AND price.currency_code IS NOT NULL AND NOT price.needs_review) AS price_ready,
    card.website_delivery_days IS NOT NULL AS delivery_ready
FROM crm.supplier_goods_entry declaration
LEFT JOIN (SELECT DISTINCT supplier_goods_entry_id,card_id FROM crm.catalogue_public_source) published
    ON published.supplier_goods_entry_id=declaration.id
LEFT JOIN crm.catalogue_public_card card ON card.id=published.card_id
LEFT JOIN crm.catalogue_public_ready readiness ON readiness.supplier_goods_entry_id=card.id
WHERE declaration.deleted_at IS NULL;
