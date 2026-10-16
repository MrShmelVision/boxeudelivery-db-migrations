-- V136 was already applied locally before the owner clarified the advertised-price rounding rule.
-- Retain earlier immutable price revisions; all new commands use the confirmed rule.
COMMENT ON COLUMN crm.supplier_goods_entry.online_store_discounted_amount IS
    'Server-calculated discounted card price, rounded HALF_UP to the nearest 100 currency units; advertised whole percentage remains unchanged.';
COMMENT ON COLUMN crm.supplier_goods_online_store_price_revision.discounted_amount IS
    'Immutable advertised result at this revision. New revisions use nearest-100 HALF_UP rounding without recalculating the advertised percentage.';
