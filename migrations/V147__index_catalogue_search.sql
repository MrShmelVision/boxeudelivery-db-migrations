CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

CREATE INDEX ix_goods_catalogue_category ON crm.supplier_goods_entry(project_id,border_tariff_subcategory_id,id)
    WHERE deleted_at IS NULL;
CREATE INDEX ix_goods_catalogue_name_search ON crm.supplier_goods_entry USING gin(lower(name) public.gin_trgm_ops)
    WHERE deleted_at IS NULL;
CREATE INDEX ix_goods_variant_value_search ON crm.supplier_goods_variant USING gin(lower(value_text) public.gin_trgm_ops);
CREATE INDEX ix_product_brand_name_search ON crm.product_brand USING gin(lower(name) public.gin_trgm_ops);
CREATE INDEX ix_goods_category_name_search ON crm.border_tariff_category USING gin(lower(display_name) public.gin_trgm_ops);
CREATE INDEX ix_goods_group_name_search ON crm.border_tariff_category_group USING gin(lower(display_name) public.gin_trgm_ops);
CREATE INDEX ix_goods_subcategory_name_search ON crm.border_tariff_subcategory USING gin(lower(display_name) public.gin_trgm_ops)
    WHERE deleted_at IS NULL;
