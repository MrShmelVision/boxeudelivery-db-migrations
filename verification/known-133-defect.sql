\set ON_ERROR_STOP on
-- Negative control: the regression check must detect the actual pre-fix trigger failure.
BEGIN;
DO $$
BEGIN
    BEGIN
        UPDATE crm.cargo_item_photo_object SET size_bytes=size_bytes+1
        WHERE photo_id='30000000-0000-4000-8000-000000000007' AND variant_code='ORIGINAL';
        RAISE EXCEPTION 'Negative control failed: V133 unexpectedly accepted the broken photo-object trigger';
    EXCEPTION WHEN undefined_column THEN
        IF SQLERRM NOT LIKE '%project_id%' THEN RAISE; END IF;
        RAISE NOTICE 'PASS negative control: V133 reproduces the missing photo project_id failure';
    END;
END $$;
ROLLBACK;
