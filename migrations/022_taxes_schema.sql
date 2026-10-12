CREATE SCHEMA taxes AUTHORIZATION serk_owner;
SET LOCAL ROLE serk_owner;

CREATE TABLE taxes.tax_agencies (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    code text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    UNIQUE (tenant_id, company_id, id),
    UNIQUE (company_id, code)
);

CREATE TABLE taxes.tax_rates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    agency_id uuid NOT NULL,
    name text NOT NULL,
    code text NOT NULL,
    rate_percent numeric NOT NULL DEFAULT 0,
    active boolean NOT NULL DEFAULT true,
    effective_from date NOT NULL DEFAULT CURRENT_DATE,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    FOREIGN KEY (tenant_id, company_id, agency_id) REFERENCES taxes.tax_agencies(tenant_id, company_id, id),
    UNIQUE (tenant_id, company_id, id),
    UNIQUE (company_id, code)
);

CREATE TABLE taxes.tax_entries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    tax_rate_id uuid NOT NULL,
    journal_id uuid, -- Reference to the ledger journal that posted this
    taxable_amount ledger.minor NOT NULL DEFAULT 0,
    tax_amount ledger.minor NOT NULL DEFAULT 0,
    transaction_type text NOT NULL CHECK (transaction_type IN ('SALE', 'PURCHASE')),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    FOREIGN KEY (tenant_id, company_id, tax_rate_id) REFERENCES taxes.tax_rates(tenant_id, company_id, id),
    UNIQUE (tenant_id, company_id, id)
);

ALTER TABLE taxes.tax_agencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE taxes.tax_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE taxes.tax_entries ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON taxes.tax_agencies USING (tenant_id = (SELECT security.tenant()));
CREATE POLICY tenant_isolation ON taxes.tax_rates USING (tenant_id = (SELECT security.tenant()));
CREATE POLICY tenant_isolation ON taxes.tax_entries USING (tenant_id = (SELECT security.tenant()));

GRANT USAGE ON SCHEMA taxes TO serk_api;
GRANT SELECT, INSERT, UPDATE ON taxes.tax_agencies TO serk_api;
GRANT SELECT, INSERT, UPDATE ON taxes.tax_rates TO serk_api;
GRANT SELECT, INSERT, UPDATE ON taxes.tax_entries TO serk_api;

INSERT INTO security.permissions(code, label, category, sort_order) VALUES
  ('taxes.read', 'View tax agencies and rates', 'Taxes', 70),
  ('taxes.manage', 'Create and edit tax agencies and rates', 'Taxes', 71);

INSERT INTO security.role_permissions (tenant_id, role_id, permission)
SELECT tenant_id, role_id, unnest(ARRAY['taxes.read', 'taxes.manage'])
FROM security.role_permissions
WHERE permission = 'role.manage'
ON CONFLICT DO NOTHING;
