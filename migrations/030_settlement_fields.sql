-- 030_settlement_fields.sql
SET LOCAL ROLE serk_owner;

ALTER TABLE invoicing.invoices ADD COLUMN IF NOT EXISTS settlement_type text NOT NULL DEFAULT 'CREDIT' CHECK (settlement_type IN ('CREDIT', 'DIRECT'));
ALTER TABLE invoicing.invoices ADD COLUMN IF NOT EXISTS payment_account_id uuid;
ALTER TABLE invoicing.invoices ADD COLUMN IF NOT EXISTS payment_journal_id uuid;
ALTER TABLE invoicing.invoices ADD COLUMN IF NOT EXISTS paid_at timestamptz;

ALTER TABLE invoicing.bills ADD COLUMN IF NOT EXISTS settlement_type text NOT NULL DEFAULT 'CREDIT' CHECK (settlement_type IN ('CREDIT', 'DIRECT'));
ALTER TABLE invoicing.bills ADD COLUMN IF NOT EXISTS payment_account_id uuid;
ALTER TABLE invoicing.bills ADD COLUMN IF NOT EXISTS payment_journal_id uuid;
ALTER TABLE invoicing.bills ADD COLUMN IF NOT EXISTS paid_at timestamptz;
