\set ON_ERROR_STOP on
DO $$ BEGIN IF current_database()<>'boxeudelivery_validation' THEN RAISE EXCEPTION 'Owned database required'; END IF; END $$;
BEGIN;
DO $$
DECLARE
    project UUID := '11111111-1111-4111-8111-111111111111';
    goods UUID := '33333333-3333-4333-8333-333333333333';
    variant UUID := '44444444-4444-4444-8444-444444444444';
    publication UUID := 'ea34aa50-a6e6-4bfd-805b-09741c826001';
    saved_name TEXT;
    unit_count BIGINT;
BEGIN
    INSERT INTO crm.catalogue_card(id,project_id,name,description,article_number,created_by_subject,updated_by_subject,created_at,updated_at)
        SELECT id,project_id,name,description,article_number,'verification','verification',now(),now()
        FROM crm.supplier_goods_entry WHERE id=goods ON CONFLICT(id) DO NOTHING;
    INSERT INTO crm.catalogue_variant(id,project_id,card_id,attributes,attribute_signature,packaging,created_by_subject,updated_by_subject,created_at,updated_at)
        SELECT id,project_id,goods,attributes,attribute_signature,'','verification','verification',now(),now()
        FROM crm.supplier_goods_variant WHERE id=variant ON CONFLICT(id) DO NOTHING;
    UPDATE crm.catalogue_card SET public_anchor_variant_id=variant WHERE id=goods AND public_anchor_variant_id IS NULL;
    SELECT name INTO STRICT saved_name FROM crm.catalogue_card WHERE id=goods;
    IF EXISTS(SELECT 1 FROM crm.catalogue_public_card WHERE id=goods) THEN RAISE EXCEPTION 'Legacy card was silently published'; END IF;
    INSERT INTO crm.catalogue_supplier_card
        SELECT goods,goods,project,supplier_id,'verification',now() FROM crm.supplier_goods_entry WHERE id=goods;
    INSERT INTO crm.catalogue_supplier_variant
        SELECT variant,goods,goods,project,variant,supplier_id,'verification',now() FROM crm.supplier_goods_entry WHERE id=goods;
    INSERT INTO crm.catalogue_publication(id,card_id,project_id,draft_version,snapshot,published_by_subject,published_at)
        SELECT publication,goods,project,card.version,jsonb_build_object('card',to_jsonb(card),
            'variants',(SELECT jsonb_agg(to_jsonb(v)) FROM crm.catalogue_resolved_variant v WHERE v.supplier_goods_entry_id=goods),
            'sources',(SELECT jsonb_agg(to_jsonb(s)) FROM crm.catalogue_supplier_variant s WHERE s.card_id=goods)),
            'verification',now() FROM crm.catalogue_card card WHERE card.id=goods;
    UPDATE crm.catalogue_card SET published_revision_id=publication WHERE id=goods;
    UPDATE crm.catalogue_card SET name='Unpublished change',website_delivery_days=21 WHERE id=goods;
    IF (SELECT name FROM crm.catalogue_public_card WHERE id=goods) IS DISTINCT FROM saved_name THEN RAISE EXCEPTION 'Draft leaked into published content'; END IF;
    DELETE FROM crm.catalogue_supplier_variant WHERE supplier_variant_id=variant;
    IF NOT EXISTS(SELECT 1 FROM crm.catalogue_public_source WHERE supplier_variant_id=variant) THEN RAISE EXCEPTION 'Unpublished unlink changed live stock mapping'; END IF;
    BEGIN
        UPDATE crm.catalogue_publication SET snapshot='{}' WHERE id=publication;
        RAISE EXCEPTION 'Immutable update was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM<>'Published catalogue revisions are immutable' THEN RAISE; END IF;
    END;
    BEGIN
        DELETE FROM crm.catalogue_publication WHERE id=publication;
        RAISE EXCEPTION 'Immutable deletion was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM<>'Published catalogue revisions are immutable' THEN RAISE; END IF;
    END;
    SELECT count(*) INTO unit_count FROM crm.cargo_item;
    INSERT INTO crm.cargo_item_photo(id,cargo_item_id,supplier_goods_entry_id,uploader_account_id,status_code,position,
        original_filename,declared_content_type,declared_size_bytes,declared_checksum_sha256,original_object_key,upload_expires_at,gallery_scope_code)
    VALUES('ea34aa50-a6e6-4bfd-805b-09741c826002',NULL,goods,'77777777-7777-4777-8777-777777777777','PENDING_UPLOAD',9,
        'empty-card.jpg','image/jpeg',4,repeat('a',44),'verification/empty-card',now()+interval '1 hour','SUPPLIER_GOODS');
    IF (SELECT count(*) FROM crm.cargo_item)<>unit_count THEN RAISE EXCEPTION 'Shared card photo created stock'; END IF;
    BEGIN
        UPDATE crm.cargo_item_photo SET gallery_scope_code='CARGO_ITEM' WHERE id='ea34aa50-a6e6-4bfd-805b-09741c826002';
        RAISE EXCEPTION 'Exact-unit evidence accepted no unit';
    EXCEPTION WHEN check_violation THEN NULL; END;
    UPDATE crm.catalogue_card SET published_revision_id=NULL WHERE id=goods;
    IF EXISTS(SELECT 1 FROM crm.catalogue_public_card WHERE id=goods) THEN RAISE EXCEPTION 'Withdrawal did not remove publication'; END IF;
END $$;
ROLLBACK;
