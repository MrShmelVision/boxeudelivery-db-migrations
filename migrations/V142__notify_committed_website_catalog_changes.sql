CREATE FUNCTION crm.notify_website_catalog_change() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    -- PostgreSQL delivers the signal only after the journal transaction commits.
    PERFORM pg_notify('website_catalog_changes', NEW.project_id::text);
    RETURN NULL;
END;
$$;

CREATE TRIGGER website_catalog_notify
AFTER INSERT ON crm.website_catalog_revision
FOR EACH ROW EXECUTE FUNCTION crm.notify_website_catalog_change();
