-- Completed receipts/intakes retain their supplier even after an administrative ownership correction.
CREATE TABLE crm.cargo_item_supplier_provenance (
    cargo_item_id UUID NOT NULL,
    project_id UUID NOT NULL,
    supplier_id UUID NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (cargo_item_id, project_id, supplier_id),
    CONSTRAINT fk_cargo_item_supplier_provenance_item
        FOREIGN KEY (cargo_item_id, project_id) REFERENCES crm.cargo_item (id, project_id)
        ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_cargo_item_supplier_provenance_supplier
        FOREIGN KEY (project_id, supplier_id) REFERENCES crm.project_supplier (project_id, supplier_id)
        ON DELETE RESTRICT
);

INSERT INTO crm.cargo_item_supplier_provenance(cargo_item_id, project_id, supplier_id)
SELECT id, project_id, supplier_id FROM crm.cargo_item;

ALTER TABLE crm.mini_supplier_intake_item
    DROP CONSTRAINT fk_mini_supplier_intake_item_cargo,
    ADD CONSTRAINT fk_mini_supplier_intake_item_cargo
        FOREIGN KEY (cargo_item_id, project_id, supplier_id)
        REFERENCES crm.cargo_item_supplier_provenance (cargo_item_id, project_id, supplier_id) ON DELETE RESTRICT;
ALTER TABLE crm.mini_supplier_warehouse_receipt_item
    DROP CONSTRAINT fk_mini_supplier_warehouse_receipt_item_cargo,
    ADD CONSTRAINT fk_mini_supplier_warehouse_receipt_item_cargo
        FOREIGN KEY (cargo_item_id, project_id, supplier_id)
        REFERENCES crm.cargo_item_supplier_provenance (cargo_item_id, project_id, supplier_id) ON DELETE RESTRICT;

-- Delivery ownership is a declaration snapshot, independent of the current stock owner.
ALTER TABLE crm.cargo_item ADD COLUMN inbound_supplier_id UUID;
UPDATE crm.cargo_item SET inbound_supplier_id = supplier_id WHERE inbound_delivery_id IS NOT NULL;
ALTER TABLE crm.cargo_item
    DROP CONSTRAINT fk_cargo_item_delivery_supplier,
    ADD CONSTRAINT fk_cargo_item_delivery_supplier
        FOREIGN KEY (inbound_delivery_id, project_id, inbound_supplier_id)
        REFERENCES crm.inbound_delivery (id, project_id, supplier_id) ON DELETE RESTRICT,
    ADD CONSTRAINT ck_cargo_item_inbound_supplier CHECK (
        (inbound_delivery_id IS NULL) = (inbound_supplier_id IS NULL)
    );

CREATE FUNCTION crm.record_cargo_item_supplier_provenance() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.supplier_id IS DISTINCT FROM OLD.supplier_id THEN
        INSERT INTO crm.cargo_item_supplier_provenance(cargo_item_id, project_id, supplier_id)
        VALUES(NEW.id, NEW.project_id, NEW.supplier_id) ON CONFLICT DO NOTHING;
    END IF;
    IF TG_OP = 'INSERT' OR NEW.inbound_delivery_id IS DISTINCT FROM OLD.inbound_delivery_id THEN
        NEW.inbound_supplier_id := NULL;
        IF NEW.inbound_delivery_id IS NOT NULL THEN
            SELECT supplier_id INTO NEW.inbound_supplier_id FROM crm.inbound_delivery
            WHERE id = NEW.inbound_delivery_id AND project_id = NEW.project_id;
            IF NEW.inbound_supplier_id IS DISTINCT FROM NEW.supplier_id THEN
                RAISE EXCEPTION 'Delivery and current item supplier must match on assignment'
                    USING ERRCODE = '23514', CONSTRAINT = 'ck_cargo_item_inbound_supplier';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_cargo_item_supplier_provenance
    BEFORE INSERT OR UPDATE OF supplier_id, inbound_delivery_id ON crm.cargo_item
    FOR EACH ROW EXECUTE FUNCTION crm.record_cargo_item_supplier_provenance();

-- A shared gallery owns its card; its upload-source unit is retained as historical provenance.
ALTER TABLE crm.cargo_item_photo
    ADD COLUMN project_id UUID,
    ADD COLUMN supplier_id UUID;

UPDATE crm.cargo_item_photo photo
SET project_id = item.project_id, supplier_id = item.supplier_id
FROM crm.cargo_item item WHERE item.id = photo.cargo_item_id;

ALTER TABLE crm.cargo_item_photo
    ALTER COLUMN project_id SET NOT NULL,
    ALTER COLUMN supplier_id SET NOT NULL,
    DROP CONSTRAINT fk_cargo_item_photo_source_item_goods,
    ADD CONSTRAINT fk_cargo_item_photo_source_item_owner
        FOREIGN KEY (cargo_item_id, project_id, supplier_id)
        REFERENCES crm.cargo_item_supplier_provenance (cargo_item_id, project_id, supplier_id) ON DELETE RESTRICT,
    ADD CONSTRAINT fk_cargo_item_photo_gallery_goods_owner
        FOREIGN KEY (supplier_goods_entry_id, project_id, supplier_id)
        REFERENCES crm.supplier_goods_entry (id, project_id, supplier_id) ON DELETE RESTRICT;

CREATE INDEX ix_cargo_item_photo_source_owner ON crm.cargo_item_photo(cargo_item_id, project_id, supplier_id);

-- Existing application images need not supply the new ownership columns during rollout.
CREATE FUNCTION crm.bind_cargo_photo_owner() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    SELECT project_id, supplier_id INTO NEW.project_id, NEW.supplier_id
    FROM crm.supplier_goods_entry WHERE id = NEW.supplier_goods_entry_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cargo_photo_owner
    BEFORE INSERT OR UPDATE OF cargo_item_id, supplier_goods_entry_id ON crm.cargo_item_photo
    FOR EACH ROW EXECUTE FUNCTION crm.bind_cargo_photo_owner();

COMMENT ON COLUMN crm.cargo_item_photo.supplier_goods_entry_id IS
    'Owner of a shared gallery; current goods card for exact-unit evidence. Upload-source unit identity remains unchanged by a card correction.';
COMMENT ON COLUMN crm.cargo_item.supplier_id IS
    'Current supplier-group owner. Administrative card transfers retain prior owners in cargo_item_supplier_provenance and immutable receipt, delivery and settlement facts.';
