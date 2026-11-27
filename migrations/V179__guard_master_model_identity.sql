ALTER TABLE crm.catalogue_card
    ADD COLUMN model_identity VARCHAR(500),
    ADD COLUMN manufacturer_identity VARCHAR(500),
    ADD COLUMN identity_review_required BOOLEAN NOT NULL DEFAULT FALSE;
WITH identities AS (
    SELECT id,project_id,coalesce(brand_id::text,'')||':'||regexp_replace(lower(btrim(name)),'\s+',' ','g') AS model,
        CASE WHEN nullif(btrim(manufacturer_article),'') IS NOT NULL
            THEN coalesce(brand_id::text,'')||':'||lower(btrim(manufacturer_article)) END AS manufacturer
    FROM crm.catalogue_card WHERE deleted_at IS NULL AND merged_into_id IS NULL
), conflicts AS (
    SELECT *,count(*) OVER(PARTITION BY project_id,model) AS models,
        count(*) OVER(PARTITION BY project_id,manufacturer) AS manufacturers FROM identities
)
UPDATE crm.catalogue_card card SET model_identity=CASE WHEN conflicts.models=1 THEN conflicts.model END,
    manufacturer_identity=CASE WHEN conflicts.manufacturers=1 THEN conflicts.manufacturer END,
    identity_review_required=conflicts.models>1 OR (conflicts.manufacturer IS NOT NULL AND conflicts.manufacturers>1)
FROM conflicts WHERE conflicts.id=card.id;
CREATE UNIQUE INDEX uq_catalogue_model_identity ON crm.catalogue_card(project_id,model_identity)
    WHERE deleted_at IS NULL AND merged_into_id IS NULL AND model_identity IS NOT NULL;
CREATE UNIQUE INDEX uq_catalogue_manufacturer_identity ON crm.catalogue_card(project_id,manufacturer_identity)
    WHERE deleted_at IS NULL AND merged_into_id IS NULL AND manufacturer_identity IS NOT NULL;
