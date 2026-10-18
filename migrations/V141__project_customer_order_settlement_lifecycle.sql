CREATE INDEX ix_settlement_supplier_entitlement_order
    ON crm.settlement_supplier_entitlement(customer_order_id)
    WHERE customer_order_id IS NOT NULL;

CREATE FUNCTION crm.customer_order_lifecycle(order_id uuid) RETURNS text
LANGUAGE sql STABLE PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN customer_order.status_code = 'CANCELLED' THEN 'COMPLETED'
        WHEN customer_order.status_code <> 'FULFILLED' THEN 'ACTIVE'
        WHEN EXISTS (
            SELECT 1
            FROM crm.customer_order_line line
            WHERE line.customer_order_id = customer_order.id
              AND line.status_code <> 'REMOVED'
              AND (customer_order.order_kind_code <> 'MINI' OR line.unit_price > 0)
              AND NOT EXISTS (
                  SELECT 1
                  FROM crm.settlement_supplier_entitlement entitlement
                  WHERE entitlement.customer_order_line_id = line.id
              )
        ) OR EXISTS (
            SELECT 1
            FROM crm.settlement_supplier_entitlement entitlement
            LEFT JOIN crm.settlement_supplier_statement_entitlement statement_entitlement
              ON statement_entitlement.entitlement_id = entitlement.id
            WHERE entitlement.customer_order_id = customer_order.id
              AND entitlement.amount > COALESCE(statement_entitlement.deduction_amount, 0) + COALESCE((
                  SELECT SUM(allocation.amount)
                  FROM crm.settlement_supplier_payout_allocation allocation
                  LEFT JOIN crm.settlement_supplier_payout_leg leg
                    ON leg.payout_operation_id = allocation.payout_operation_id
                  LEFT JOIN crm.settlement_supplier_payout_document_acknowledgement document_acknowledgement
                    ON document_acknowledgement.payout_document_id = leg.payout_document_id
                  LEFT JOIN crm.settlement_supplier_payout_acknowledgement legacy_acknowledgement
                    ON legacy_acknowledgement.payout_operation_id = allocation.payout_operation_id
                  WHERE allocation.entitlement_id = entitlement.id
                    AND (
                        document_acknowledgement.decision_code = 'RECEIVED'
                        OR (
                            document_acknowledgement.payout_document_id IS NULL
                            AND legacy_acknowledgement.decision_code = 'RECEIVED'
                            AND NOT EXISTS (
                                SELECT 1
                                FROM crm.settlement_supplier_payout_leg other_leg
                                WHERE other_leg.payout_document_id = leg.payout_document_id
                                  AND other_leg.id <> leg.id
                            )
                        )
                    )
              ), 0)
        ) THEN 'SETTLEMENT_PENDING'
        ELSE 'COMPLETED'
    END
    FROM crm.customer_order
    WHERE customer_order.id = order_id
$$;

COMMENT ON FUNCTION crm.customer_order_lifecycle(uuid) IS
    'Read-only order register contract: execution, outstanding or unacknowledged supplier settlement, closed or cancelled.';
