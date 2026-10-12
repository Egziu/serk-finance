CREATE SCHEMA payroll AUTHORIZATION serk_owner;
SET LOCAL ROLE serk_owner;

CREATE TABLE payroll.employees (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    first_name text NOT NULL,
    last_name text NOT NULL,
    email text,
    department text,
    salary_amount ledger.minor NOT NULL DEFAULT 0,
    pay_frequency text NOT NULL CHECK (pay_frequency IN ('WEEKLY', 'BIWEEKLY', 'MONTHLY')),
    active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    UNIQUE (tenant_id, company_id, id)
);

CREATE TABLE payroll.payruns (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    pay_period_start date NOT NULL,
    pay_period_end date NOT NULL,
    payment_date date NOT NULL,
    status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'APPROVED', 'PAID')),
    journal_id uuid, -- Reference to ledger journal
    total_gross ledger.minor NOT NULL DEFAULT 0,
    total_net ledger.minor NOT NULL DEFAULT 0,
    total_taxes ledger.minor NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    UNIQUE (tenant_id, company_id, id)
);

CREATE TABLE payroll.pay_slips (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    payrun_id uuid NOT NULL,
    employee_id uuid NOT NULL,
    gross_pay ledger.minor NOT NULL DEFAULT 0,
    net_pay ledger.minor NOT NULL DEFAULT 0,
    taxes_withheld ledger.minor NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    FOREIGN KEY (tenant_id, company_id, payrun_id) REFERENCES payroll.payruns(tenant_id, company_id, id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, company_id, employee_id) REFERENCES payroll.employees(tenant_id, company_id, id),
    UNIQUE (tenant_id, company_id, id)
);

ALTER TABLE payroll.employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE payroll.payruns ENABLE ROW LEVEL SECURITY;
ALTER TABLE payroll.pay_slips ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON payroll.employees USING (tenant_id = (SELECT security.tenant()));
CREATE POLICY tenant_isolation ON payroll.payruns USING (tenant_id = (SELECT security.tenant()));
CREATE POLICY tenant_isolation ON payroll.pay_slips USING (tenant_id = (SELECT security.tenant()));

GRANT USAGE ON SCHEMA payroll TO serk_api;
GRANT SELECT, INSERT, UPDATE ON payroll.employees TO serk_api;
GRANT SELECT, INSERT, UPDATE ON payroll.payruns TO serk_api;
GRANT SELECT, INSERT, UPDATE ON payroll.pay_slips TO serk_api;

INSERT INTO security.permissions(code, label, category, sort_order) VALUES
  ('payroll.read', 'View employees and payruns', 'Payroll', 80),
  ('payroll.manage', 'Create and edit employees and run payroll', 'Payroll', 81);

INSERT INTO security.role_permissions (tenant_id, role_id, permission)
SELECT tenant_id, role_id, unnest(ARRAY['payroll.read', 'payroll.manage'])
FROM security.role_permissions
WHERE permission = 'role.manage'
ON CONFLICT DO NOTHING;
