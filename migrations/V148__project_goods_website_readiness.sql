CREATE VIEW crm.supplier_goods_website_readiness AS
SELECT supplier_goods_entry_id, category_ready, brand_ready,
       category_ready AND brand_ready AS ready
FROM (
    SELECT goods.id AS supplier_goods_entry_id,
           coalesce(subcategory.active AND subcategory.deleted_at IS NULL
                    AND category.active
                    AND (subcategory.group_id IS NULL OR category_group.active), false) AS category_ready,
           goods.brand_id IS NOT NULL AS brand_ready
    FROM crm.supplier_goods_entry goods
    LEFT JOIN crm.border_tariff_subcategory subcategory ON subcategory.id = goods.border_tariff_subcategory_id
    LEFT JOIN crm.border_tariff_category category ON category.id = subcategory.category_id
    LEFT JOIN crm.border_tariff_category_group category_group
           ON category_group.id = subcategory.group_id AND category_group.category_id = category.id
    WHERE goods.deleted_at IS NULL
) classification;

COMMENT ON VIEW crm.supplier_goods_website_readiness IS
    'Read contract for catalogue eligibility and CRM completion filters. A visible card requires a brand and an active terminal classification with active ancestors. This does not grant project access or create a publication flag.';
