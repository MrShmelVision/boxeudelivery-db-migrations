CREATE TABLE crm.supplier_goods_creation_receipt (
    project_id UUID NOT NULL REFERENCES crm.project(id),
    request_reference UUID NOT NULL,
    actor_subject VARCHAR(255) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    supplier_goods_entry_id UUID NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY(project_id,request_reference),
    FOREIGN KEY(supplier_goods_entry_id,project_id) REFERENCES crm.supplier_goods_entry(id,project_id)
);
CREATE TABLE crm.supplier_pickup_draft (
    id UUID PRIMARY KEY,
    project_id UUID NOT NULL,
    supplier_id UUID NOT NULL,
    owner_account_id UUID NOT NULL REFERENCES crm.account(id),
    payload JSONB NOT NULL CHECK(jsonb_typeof(payload)='object' AND octet_length(payload::text)<=524288),
    version BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL,
    FOREIGN KEY(project_id,supplier_id) REFERENCES crm.project_supplier(project_id,supplier_id)
);
CREATE INDEX ix_supplier_pickup_draft_owner ON crm.supplier_pickup_draft(owner_account_id,updated_at DESC,id);
