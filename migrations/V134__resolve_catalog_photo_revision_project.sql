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
