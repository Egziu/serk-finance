CREATE SCHEMA IF NOT EXISTS core AUTHORIZATION serk_owner;
SET LOCAL ROLE serk_owner;

CREATE TABLE core.currencies (
    code text PRIMARY KEY, -- e.g. USD, EUR, ETB
    name text NOT NULL,
    symbol text NOT NULL,
    active boolean NOT NULL DEFAULT true
);

INSERT INTO core.currencies (code, name, symbol) VALUES 
('USD', 'US Dollar', '$'),
('EUR', 'Euro', '€'),
('GBP', 'British Pound', '£'),
('ETB', 'Ethiopian Birr', 'Br')
ON CONFLICT (code) DO NOTHING;

CREATE TABLE core.exchange_rates (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    company_id uuid NOT NULL,
    date date NOT NULL,
    base_currency text NOT NULL REFERENCES core.currencies(code),
    foreign_currency text NOT NULL REFERENCES core.currencies(code),
    exchange_rate numeric(19,4) NOT NULL, -- How much of base_currency = 1 foreign_currency
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (tenant_id, company_id) REFERENCES organization.companies(tenant_id, id),
    UNIQUE (tenant_id, company_id, date, base_currency, foreign_currency)
);

-- Need to add a Base Currency setting to the Company table
ALTER TABLE organization.companies 
ADD COLUMN IF NOT EXISTS base_currency text REFERENCES core.currencies(code) DEFAULT 'USD';

-- Link the schema to our audit trigger
CREATE TRIGGER audit_exchange_rates
AFTER INSERT OR UPDATE ON core.exchange_rates
FOR EACH ROW EXECUTE FUNCTION audit.record_change();
