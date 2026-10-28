-- Keep issued numbers reserved even if a goods card is physically removed later.
CREATE TABLE crm.supplier_goods_article_number (
    article_number VARCHAR(16) PRIMARY KEY,
    issued_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT supplier_goods_article_number_format
        CHECK (article_number ~ '^[A-Z][A-Z0-9]{1,7}-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{7}$')
);

CREATE FUNCTION crm.issue_supplier_goods_article_number(prefix TEXT) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    alphabet CONSTANT TEXT := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
    candidate TEXT;
    random_bytes BYTEA;
    issued TEXT;
BEGIN
    IF prefix IS NULL OR prefix !~ '^[A-Z][A-Z0-9]{1,7}$' THEN
        RAISE EXCEPTION 'A valid project prefix is required' USING ERRCODE='23514';
    END IF;
    FOR attempt IN 1..100 LOOP
        random_bytes := uuid_send(gen_random_uuid());
        candidate := prefix || '-';
        -- Bytes 9..15 contain no fixed UUID version or variant bits.
        FOR position IN 9..15 LOOP
            candidate := candidate || substr(alphabet, (get_byte(random_bytes, position) & 31) + 1, 1);
        END LOOP;
        INSERT INTO crm.supplier_goods_article_number(article_number) VALUES(candidate)
            ON CONFLICT DO NOTHING RETURNING article_number INTO issued;
        IF issued IS NOT NULL THEN RETURN issued; END IF;
    END LOOP;
    RAISE EXCEPTION 'Unable to issue a unique goods article number';
END;
$$;

ALTER TABLE crm.supplier_goods_entry ADD COLUMN article_number VARCHAR(16);

UPDATE crm.supplier_goods_entry goods
SET article_number=crm.issue_supplier_goods_article_number(project.task_prefix)
FROM crm.project project WHERE project.id=goods.project_id;

ALTER TABLE crm.supplier_goods_entry
    ALTER COLUMN article_number SET NOT NULL,
    ADD CONSTRAINT uq_supplier_goods_entry_article_number UNIQUE(article_number),
    ADD CONSTRAINT fk_supplier_goods_entry_article_number FOREIGN KEY(article_number)
        REFERENCES crm.supplier_goods_article_number(article_number) ON DELETE RESTRICT;

CREATE FUNCTION crm.assign_supplier_goods_article_number() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE prefix TEXT;
BEGIN
    IF TG_OP='INSERT' THEN
        IF NEW.article_number IS NOT NULL THEN
            RAISE EXCEPTION 'Goods article number is assigned automatically' USING ERRCODE='23514';
        END IF;
        SELECT task_prefix INTO STRICT prefix FROM crm.project WHERE id=NEW.project_id;
        NEW.article_number := crm.issue_supplier_goods_article_number(prefix);
    ELSIF NEW.article_number IS DISTINCT FROM OLD.article_number THEN
        RAISE EXCEPTION 'Goods article number is immutable' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER supplier_goods_article_number
BEFORE INSERT OR UPDATE OF article_number ON crm.supplier_goods_entry
FOR EACH ROW EXECUTE FUNCTION crm.assign_supplier_goods_article_number();

CREATE INDEX ix_goods_catalogue_article_search ON crm.supplier_goods_entry
    USING gin(lower(article_number) public.gin_trgm_ops) WHERE deleted_at IS NULL;

-- Publish one committed catalogue signal per project after assigning existing cards.
INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
    SELECT DISTINCT project_id,txid_current() FROM crm.supplier_goods_entry
    ON CONFLICT(project_id,transaction_id) DO NOTHING;

COMMENT ON COLUMN crm.supplier_goods_entry.article_number IS
    'Immutable goods article: project prefix at creation and seven random base32 characters. Shared by variants. Independent of supplier SKU, manufacturer article and physical labels.';
