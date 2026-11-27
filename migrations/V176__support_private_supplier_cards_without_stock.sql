-- Card definitions are independent of physical batches and public catalogue identities.
ALTER TABLE crm.supplier_goods_variant
    ADD COLUMN product_code VARCHAR(14),
    ADD COLUMN active BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN code_review_required BOOLEAN NOT NULL DEFAULT FALSE,
    ADD CONSTRAINT ck_supplier_variant_product_code
        CHECK (product_code IS NULL OR crm.valid_product_gtin(product_code));

UPDATE crm.supplier_goods_variant variant SET active = FALSE
FROM crm.supplier_goods_entry card
WHERE card.id = variant.supplier_goods_entry_id AND card.deleted_at IS NOT NULL;

-- Only an unambiguous, unique declaration can establish a reusable code. Conflicts retain
-- their immutable unit declarations and are explicitly reviewed, never silently merged.
WITH declarations AS (
    SELECT variant.id, variant.project_id, variant.supplier_id,
        count(DISTINCT coalesce(lpad(item.declared_product_code,14,'0'),'')) AS code_count,
        min(item.declared_product_code) AS code
    FROM crm.supplier_goods_variant variant
    JOIN crm.cargo_item item ON item.supplier_goods_variant_id=variant.id
    WHERE variant.active
    GROUP BY variant.id
), candidates AS (
    SELECT *, count(*) OVER (PARTITION BY project_id,supplier_id,lpad(code,14,'0')) AS owners
    FROM declarations WHERE code_count=1 AND code IS NOT NULL
)
UPDATE crm.supplier_goods_variant variant
SET product_code=CASE WHEN candidate.owners=1 THEN candidate.code ELSE NULL END,
    code_review_required=candidate.owners>1
FROM candidates candidate WHERE candidate.id=variant.id;

UPDATE crm.supplier_goods_variant variant SET code_review_required=TRUE
WHERE EXISTS (
    SELECT 1 FROM crm.cargo_item item WHERE item.supplier_goods_variant_id=variant.id
    GROUP BY item.supplier_goods_variant_id
    HAVING count(DISTINCT coalesce(lpad(item.declared_product_code,14,'0'),''))>1
);

DROP INDEX crm.uq_supplier_goods_variant_attribute_signature;
CREATE UNIQUE INDEX uq_supplier_variant_definition
    ON crm.supplier_goods_variant(supplier_goods_entry_id,attribute_signature,coalesce(lpad(product_code,14,'0'),''))
    WHERE active;
CREATE UNIQUE INDEX uq_supplier_variant_owner_product_code
    ON crm.supplier_goods_variant(project_id,supplier_id,lpad(product_code,14,'0'))
    WHERE active AND product_code IS NOT NULL;

ALTER TABLE crm.cargo_item_photo
    ALTER COLUMN cargo_item_id DROP NOT NULL,
    ADD CONSTRAINT ck_cargo_photo_source_scope
        CHECK (cargo_item_id IS NOT NULL OR gallery_scope_code='SUPPLIER_GOODS');

COMMENT ON COLUMN crm.supplier_goods_variant.product_code IS
    'Optional private variant GTIN; uniqueness is scoped to its supplier and project, never a public catalogue link.';
COMMENT ON COLUMN crm.cargo_item_photo.cargo_item_id IS
    'Optional provenance for a shared card gallery; exact-unit receipt evidence always requires a physical unit.';
