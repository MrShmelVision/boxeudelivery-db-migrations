-- Optional presentation fields keep older producers and stored labels compatible.
CREATE OR REPLACE FUNCTION crm.valid_goods_website_badges(value JSONB) RETURNS BOOLEAN
LANGUAGE SQL IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE WHEN jsonb_typeof(value) <> 'array' THEN FALSE
        WHEN jsonb_array_length(value) > 8 THEN FALSE
        ELSE (SELECT COALESCE(bool_and(
            COALESCE(jsonb_typeof(badge) = 'object', FALSE)
            AND COALESCE(jsonb_typeof(badge->'text') = 'string', FALSE)
            AND COALESCE(length(badge->>'text') BETWEEN 1 AND 48, FALSE)
            AND COALESCE(badge->>'text' !~ '^[[:space:]]|[[:space:]]$', FALSE)
            AND COALESCE(badge->>'tone' IN ('NEUTRAL','BRAND','SUCCESS','INFO','WARNING','ACCENT'), FALSE)
            AND COALESCE(badge->>'icon','TAG') IN ('NONE','TAG','SPARKLES','STAR','HEART','LEAF','FLAME','GIFT','SHIELD_CHECK','AWARD','GEM','TRUCK','PACKAGE','PALETTE','CHECK','HAND')
            AND COALESCE(badge->>'style','SOFT') IN ('SOFT','OUTLINE','SOLID')
            AND COALESCE(badge->>'size','MEDIUM') IN ('SMALL','MEDIUM','LARGE')), TRUE)
            AND count(*) = count(DISTINCT lower(badge->>'text'))
            FROM jsonb_array_elements(value) badge) END;
$$;

-- Revalidate durable rows after changing the function referenced by the check.
ALTER TABLE crm.supplier_goods_entry DROP CONSTRAINT supplier_goods_website_badges_valid;
ALTER TABLE crm.supplier_goods_entry ADD CONSTRAINT supplier_goods_website_badges_valid
    CHECK (crm.valid_goods_website_badges(website_badges));

COMMENT ON COLUMN crm.supplier_goods_entry.website_badges IS
    'Ordered descriptive labels shared by goods variants: unique text, closed tone, built-in SVG icon, style and size. Missing appearance fields default to TAG/SOFT/MEDIUM. Not physical warehouse labels.';
