CREATE FUNCTION crm.touch_website_stock_eligibility_revision() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    previous_project UUID;
    current_project UUID;
    relevant_columns TEXT[];
BEGIN
    IF TG_OP='UPDATE' THEN
        relevant_columns := CASE TG_TABLE_NAME
            WHEN 'cargo_item' THEN ARRAY['current_warehouse_id','accepted_at','inbound_delivery_id','project_id']
            WHEN 'inbound_delivery' THEN ARRAY['status_code','project_id']
            WHEN 'mini_supplier_intake' THEN ARRAY['completed_at','project_id']
            WHEN 'mini_supplier_intake_item' THEN ARRAY['intake_id','cargo_item_id','project_id']
            WHEN 'warehouse_relocation' THEN ARRAY['status_code','project_id']
            WHEN 'warehouse_relocation_item' THEN ARRAY['relocation_id','cargo_item_id','project_id']
        END;
        IF (SELECT bool_and(to_jsonb(NEW)->column_name IS NOT DISTINCT FROM to_jsonb(OLD)->column_name)
            FROM unnest(relevant_columns) column_name) THEN
            RETURN NULL;
        END IF;
    END IF;
    IF TG_OP<>'INSERT' THEN previous_project := (to_jsonb(OLD)->>'project_id')::UUID; END IF;
    IF TG_OP<>'DELETE' THEN current_project := (to_jsonb(NEW)->>'project_id')::UUID; END IF;
    INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
        SELECT id,txid_current() FROM crm.project WHERE id IN (previous_project,current_project)
        ON CONFLICT(project_id,transaction_id) DO NOTHING;
    RETURN NULL;
END;
$$;

CREATE TRIGGER website_stock_eligibility_changed
AFTER UPDATE OF current_warehouse_id,accepted_at,inbound_delivery_id,project_id ON crm.cargo_item
FOR EACH ROW EXECUTE FUNCTION crm.touch_website_stock_eligibility_revision();

CREATE TRIGGER website_stock_eligibility_changed
AFTER INSERT OR UPDATE OF status_code,project_id OR DELETE ON crm.inbound_delivery
FOR EACH ROW EXECUTE FUNCTION crm.touch_website_stock_eligibility_revision();

CREATE TRIGGER website_stock_eligibility_changed
AFTER INSERT OR UPDATE OF completed_at,project_id OR DELETE ON crm.mini_supplier_intake
FOR EACH ROW EXECUTE FUNCTION crm.touch_website_stock_eligibility_revision();

CREATE TRIGGER website_stock_eligibility_changed
AFTER INSERT OR UPDATE OF intake_id,cargo_item_id,project_id OR DELETE ON crm.mini_supplier_intake_item
FOR EACH ROW EXECUTE FUNCTION crm.touch_website_stock_eligibility_revision();

CREATE TRIGGER website_stock_eligibility_changed
AFTER INSERT OR UPDATE OF status_code,project_id OR DELETE ON crm.warehouse_relocation
FOR EACH ROW EXECUTE FUNCTION crm.touch_website_stock_eligibility_revision();

CREATE TRIGGER website_stock_eligibility_changed
AFTER INSERT OR UPDATE OF relocation_id,cargo_item_id,project_id OR DELETE ON crm.warehouse_relocation_item
FOR EACH ROW EXECUTE FUNCTION crm.touch_website_stock_eligibility_revision();

INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
    SELECT id,txid_current() FROM crm.project
    ON CONFLICT(project_id,transaction_id) DO NOTHING;
