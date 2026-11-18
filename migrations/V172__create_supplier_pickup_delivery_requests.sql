CREATE TABLE crm.supplier_pickup_delivery_request (
    project_id UUID NOT NULL REFERENCES crm.project(id) ON DELETE RESTRICT,
    created_by_account_id UUID NOT NULL REFERENCES crm.account(id) ON DELETE RESTRICT,
    request_reference UUID NOT NULL,
    supplier_id UUID NOT NULL,
    request_digest VARCHAR(64) NOT NULL CHECK (request_digest ~ '^[a-f0-9]{64}$'),
    inbound_delivery_id UUID NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (project_id, created_by_account_id, request_reference),
    FOREIGN KEY (project_id, supplier_id) REFERENCES crm.project_supplier(project_id, supplier_id) ON DELETE RESTRICT,
    FOREIGN KEY (inbound_delivery_id, project_id, supplier_id)
        REFERENCES crm.inbound_delivery(id, project_id, supplier_id) ON DELETE RESTRICT
);

CREATE TABLE crm.supplier_pickup_delivery_request_product (
    project_id UUID NOT NULL,
    created_by_account_id UUID NOT NULL,
    request_reference UUID NOT NULL,
    position INTEGER NOT NULL CHECK (position BETWEEN 0 AND 99),
    supplier_goods_entry_id UUID NOT NULL UNIQUE,
    PRIMARY KEY (project_id, created_by_account_id, request_reference, position),
    FOREIGN KEY (project_id, created_by_account_id, request_reference)
        REFERENCES crm.supplier_pickup_delivery_request(project_id, created_by_account_id, request_reference)
        ON DELETE RESTRICT,
    FOREIGN KEY (supplier_goods_entry_id, project_id)
        REFERENCES crm.supplier_goods_entry(id, project_id) ON DELETE RESTRICT
);
