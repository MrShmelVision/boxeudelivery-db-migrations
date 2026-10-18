ALTER TABLE crm.border_tariff_category
    DROP CONSTRAINT border_tariff_category_website_menu_icon_check,
    ADD CONSTRAINT border_tariff_category_website_menu_icon_check CHECK (
        website_menu_icon IN (
            'grid', 'shopping-bag', 'gift', 'package', 'tags', 'star', 'heart', 'sparkles',
            'monitor', 'smartphone', 'laptop', 'headphones', 'camera', 'watch', 'gamepad', 'keyboard',
            'printer', 'television', 'radio', 'car', 'truck', 'bike', 'plane', 'ship',
            'wrench', 'settings', 'hammer', 'drill', 'armchair', 'house', 'sofa', 'bed',
            'lamp', 'utensils', 'coffee', 'refrigerator', 'washing-machine', 'cooking-pot', 'bath', 'shirt',
            'footprints', 'briefcase', 'backpack', 'glasses', 'gem', 'scissors', 'dumbbell', 'tent',
            'compass', 'trophy', 'volleyball', 'leaf', 'flower', 'trees', 'sprout', 'paw',
            'fish', 'bird', 'baby', 'book', 'graduation-cap', 'palette', 'paintbrush', 'music',
            'guitar', 'puzzle', 'party-popper', 'stethoscope', 'pill', 'activity', 'shield', 'wallet'
        )
    );
