-- Both scopes retain ten unique slots; a permutation may reuse them within one transaction.
ALTER TABLE crm.cargo_item_photo
    ADD COLUMN gallery_id UUID GENERATED ALWAYS AS (
        CASE WHEN gallery_scope_code = 'SUPPLIER_GOODS'
            THEN supplier_goods_entry_id ELSE cargo_item_id END
    ) STORED;

DROP INDEX crm.uq_cargo_item_photo_goods_position;
DROP INDEX crm.uq_cargo_item_photo_unit_position;

ALTER TABLE crm.cargo_item_photo
    ADD CONSTRAINT uq_cargo_photo_gallery_position
        UNIQUE (gallery_scope_code, gallery_id, position) DEFERRABLE INITIALLY IMMEDIATE;
