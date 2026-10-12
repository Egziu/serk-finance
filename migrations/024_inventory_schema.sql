CREATE SCHEMA inventory AUTHORIZATION serk_owner;
SET LOCAL ROLE serk_owner;

CREATE TABLE inventory.items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    type text NOT NULL CHECK (type IN ('PRODUCT', 'SERVICE')),
    name text NOT NULL,
    sku text,
    description text,
    unit_price ledger.minor NOT NULL DEFAULT 0,
    cost_price ledger.minor NOT NULL DEFAULT 0,
    income_account_id text,
    expense_account_id text,
    asset_account_id text,
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    UNIQUE (tenant_id, company_id, id)
);

CREATE TABLE inventory.transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    item_id uuid NOT NULL,
    transaction_date timestamptz NOT NULL DEFAULT now(),
    quantity numeric NOT NULL,
    reference_type text, -- e.g., 'INVOICE', 'BILL', 'ADJUSTMENT'
    reference_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    FOREIGN KEY (tenant_id, company_id, item_id) REFERENCES inventory.items(tenant_id, company_id, id),
    UNIQUE (tenant_id, company_id, id)
);

ALTER TABLE inventory.items ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory.transactions ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON inventory.items USING (tenant_id = (SELECT security.tenant()));
CREATE POLICY tenant_isolation ON inventory.transactions USING (tenant_id = (SELECT security.tenant()));

GRANT USAGE ON SCHEMA inventory TO serk_api;
GRANT SELECT, INSERT, UPDATE ON inventory.items TO serk_api;
GRANT SELECT, INSERT ON inventory.transactions TO serk_api;

INSERT INTO security.permissions(code, label, category, sort_order) VALUES
  ('inventory.read', 'View inventory items', 'Inventory', 90),
  ('inventory.manage', 'Create and edit items and adjustments', 'Inventory', 91);

INSERT INTO security.role_permissions (tenant_id, role_id, permission)
SELECT tenant_id, role_id, unnest(ARRAY['inventory.read', 'inventory.manage'])
FROM security.role_permissions
WHERE permission = 'role.manage'
ON CONFLICT DO NOTHING;
