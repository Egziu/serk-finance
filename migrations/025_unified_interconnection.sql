CREATE TABLE invoicing.invoice_lines (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    invoice_id uuid NOT NULL,
    item_id uuid NOT NULL,
    description text,
    quantity numeric NOT NULL DEFAULT 1,
    unit_price ledger.minor NOT NULL DEFAULT 0,
    tax_rate_id uuid,
    line_total ledger.minor NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    FOREIGN KEY (tenant_id, company_id, invoice_id) REFERENCES invoicing.invoices(tenant_id, company_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, company_id, item_id) REFERENCES inventory.items(tenant_id, company_id, id),
    FOREIGN KEY (tenant_id, company_id, tax_rate_id) REFERENCES taxes.tax_rates(tenant_id, company_id, id),
    UNIQUE (tenant_id, company_id, id)
);

CREATE TABLE invoicing.bill_lines (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    bill_id uuid NOT NULL,
    item_id uuid NOT NULL,
    description text,
    quantity numeric NOT NULL DEFAULT 1,
    unit_price ledger.minor NOT NULL DEFAULT 0,
    tax_rate_id uuid,
    line_total ledger.minor NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    FOREIGN KEY (tenant_id, company_id, bill_id) REFERENCES invoicing.bills(tenant_id, company_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, company_id, item_id) REFERENCES inventory.items(tenant_id, company_id, id),
    FOREIGN KEY (tenant_id, company_id, tax_rate_id) REFERENCES taxes.tax_rates(tenant_id, company_id, id),
    UNIQUE (tenant_id, company_id, id)
);

ALTER TABLE invoicing.invoice_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.bill_lines ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON invoicing.invoice_lines USING (tenant_id = (SELECT security.tenant()));
CREATE POLICY tenant_isolation ON invoicing.bill_lines USING (tenant_id = (SELECT security.tenant()));

GRANT SELECT, INSERT, UPDATE, DELETE ON invoicing.invoice_lines TO serk_api;
GRANT SELECT, INSERT, UPDATE, DELETE ON invoicing.bill_lines TO serk_api;

-- Add tax_rate_id to payruns
ALTER TABLE payroll.payruns ADD COLUMN tax_rate_id uuid;
ALTER TABLE payroll.payruns ADD FOREIGN KEY (tenant_id, company_id, tax_rate_id) REFERENCES taxes.tax_rates(tenant_id, company_id, id);

-- Ensure inventory.items has valid account references
-- (Since ledger accounts is in another schema and accounts use strings for IDs, we can't do a direct foreign key if the types don't match, but we can verify it at the application layer or write a function. For now, we rely on application layer validation since account IDs are strings).
