CREATE TABLE crm.retail_catalog_category (
    id UUID PRIMARY KEY,
    project_id UUID NOT NULL REFERENCES crm.project(id) ON DELETE RESTRICT,
    slug VARCHAR(60) NOT NULL CHECK (slug ~ '^[a-z][a-z0-9]*(-[a-z0-9]+)*$'),
    name VARCHAR(100) NOT NULL CHECK (BTRIM(name) <> ''),
    description VARCHAR(200),
    illustration VARCHAR(20) NOT NULL CHECK (illustration IN ('electronics','autoparts','furniture','clothing','home','sport','children','generic')),
    position INTEGER NOT NULL CHECK (position BETWEEN 0 AND 10000),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_retail_category_project_slug UNIQUE (project_id, slug),
    CONSTRAINT uq_retail_category_id_project UNIQUE (id, project_id)
);

ALTER TABLE crm.supplier_goods_entry ADD CONSTRAINT uq_supplier_goods_entry_id_project UNIQUE (id, project_id);
CREATE TABLE crm.retail_catalog_assignment (
    goods_entry_id UUID PRIMARY KEY,
    project_id UUID NOT NULL,
    category_id UUID,
    version BIGINT NOT NULL DEFAULT 0 CHECK (version >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (goods_entry_id, project_id) REFERENCES crm.supplier_goods_entry(id, project_id) ON DELETE RESTRICT,
    FOREIGN KEY (category_id, project_id) REFERENCES crm.retail_catalog_category(id, project_id) ON DELETE RESTRICT
);
CREATE INDEX ix_retail_assignment_category ON crm.retail_catalog_assignment(project_id, category_id, goods_entry_id);
CREATE TABLE crm.retail_catalog_audit (
    id UUID PRIMARY KEY,
    project_id UUID NOT NULL REFERENCES crm.project(id) ON DELETE RESTRICT,
    actor_account_id UUID NOT NULL REFERENCES crm.account(id) ON DELETE RESTRICT,
    category_id UUID REFERENCES crm.retail_catalog_category(id) ON DELETE RESTRICT,
    goods_entry_id UUID REFERENCES crm.supplier_goods_entry(id) ON DELETE RESTRICT,
    action VARCHAR(30) NOT NULL CHECK (action IN ('CATEGORY_CREATED','CATEGORY_UPDATED','GOODS_ASSIGNED','GOODS_UNASSIGNED')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX ix_retail_audit_project_created ON crm.retail_catalog_audit(project_id, created_at DESC, id);
