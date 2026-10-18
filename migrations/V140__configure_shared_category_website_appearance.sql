ALTER TABLE crm.border_tariff_category
    ADD COLUMN website_illustration varchar(20) NOT NULL DEFAULT 'generic',
    ADD COLUMN website_menu_icon varchar(20) NOT NULL DEFAULT 'grid',
    ADD COLUMN website_image_revision uuid,
    ADD COLUMN website_image_object_key varchar(512),
    ADD CONSTRAINT border_tariff_category_website_image_shape CHECK (
        (website_image_revision IS NULL) = (website_image_object_key IS NULL)
    ),
    ADD CONSTRAINT border_tariff_category_website_illustration_check CHECK (
        website_illustration IN ('electronics', 'autoparts', 'furniture', 'clothing', 'home', 'sport', 'children', 'generic')
    ),
    ADD CONSTRAINT border_tariff_category_website_menu_icon_check CHECK (
        website_menu_icon IN ('grid', 'monitor', 'car', 'armchair', 'shirt', 'house', 'dumbbell', 'baby', 'sparkles', 'heart')
    );

CREATE TABLE crm.border_tariff_category_website_history (
    id uuid PRIMARY KEY,
    category_id uuid NOT NULL REFERENCES crm.border_tariff_category(id),
    previous_appearance jsonb NOT NULL,
    appearance jsonb NOT NULL,
    actor_subject varchar(255) NOT NULL,
    created_at timestamptz NOT NULL
);
CREATE INDEX border_tariff_category_website_history_category_idx
    ON crm.border_tariff_category_website_history(category_id, created_at DESC, id);
