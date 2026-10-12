CREATE SCHEMA invoicing AUTHORIZATION serk_owner;
SET LOCAL ROLE serk_owner;

CREATE TABLE invoicing.customers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    email text,
    phone text,
    address text,
    tax_id text,
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    UNIQUE (tenant_id, company_id, id)
);

CREATE TABLE invoicing.vendors (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    name text NOT NULL,
    email text,
    phone text,
    address text,
    tax_id text,
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    UNIQUE (tenant_id, company_id, id)
);

CREATE TABLE invoicing.invoices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    customer_id uuid NOT NULL,
    invoice_number text NOT NULL,
    issue_date date NOT NULL,
    due_date date NOT NULL,
    currency text NOT NULL DEFAULT 'USD',
    subtotal ledger.minor NOT NULL DEFAULT 0,
    tax_total ledger.minor NOT NULL DEFAULT 0,
    total_amount ledger.minor NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'APPROVED', 'PAID', 'VOID')),
    journal_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    FOREIGN KEY (tenant_id, company_id, customer_id) REFERENCES invoicing.customers(tenant_id, company_id, id),
    UNIQUE (tenant_id, company_id, id),
    UNIQUE (company_id, invoice_number)
);

CREATE TABLE invoicing.bills (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    vendor_id uuid NOT NULL,
    bill_number text NOT NULL,
    issue_date date NOT NULL,
    due_date date NOT NULL,
    currency text NOT NULL DEFAULT 'USD',
    subtotal ledger.minor NOT NULL DEFAULT 0,
    tax_total ledger.minor NOT NULL DEFAULT 0,
    total_amount ledger.minor NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'APPROVED', 'PAID', 'VOID')),
    journal_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    FOREIGN KEY (tenant_id, company_id, vendor_id) REFERENCES invoicing.vendors(tenant_id, company_id, id),
    UNIQUE (tenant_id, company_id, id),
    UNIQUE (company_id, bill_number)
);

ALTER TABLE invoicing.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.vendors ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.bills ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON invoicing.customers USING (tenant_id = (SELECT security.tenant()));
CREATE POLICY tenant_isolation ON invoicing.vendors USING (tenant_id = (SELECT security.tenant()));
CREATE POLICY tenant_isolation ON invoicing.invoices USING (tenant_id = (SELECT security.tenant()));
CREATE POLICY tenant_isolation ON invoicing.bills USING (tenant_id = (SELECT security.tenant()));

GRANT USAGE ON SCHEMA invoicing TO serk_api;
GRANT SELECT, INSERT, UPDATE ON invoicing.customers TO serk_api;
GRANT SELECT, INSERT, UPDATE ON invoicing.vendors TO serk_api;
GRANT SELECT, INSERT, UPDATE ON invoicing.invoices TO serk_api;
GRANT SELECT, INSERT, UPDATE ON invoicing.bills TO serk_api;
