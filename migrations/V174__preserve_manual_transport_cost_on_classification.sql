-- A tariff can have a cost even when staff already recorded the exact item's cost.
ALTER TABLE crm.cargo_item_border_tariff_calculation
    DROP CONSTRAINT ck_cargo_item_border_tariff_calculation_actual_cost,
    ADD CONSTRAINT ck_cargo_item_border_tariff_calculation_actual_cost CHECK (
        (policy_actual_cost_usd IS NULL OR policy_actual_cost_usd >= 0)
        AND (generated_actual_cost_entry_id IS NULL OR policy_actual_cost_usd IS NOT NULL)
    );
