-- 032_invoicing_grants.sql
SET LOCAL ROLE serk_owner;

-- Allow reading functional_currency from organization.companies for invoices and bills
GRANT SELECT ON organization.companies TO serk_api;

-- Allow recording journals and lines for approved invoices, bills, and payments
GRANT INSERT, UPDATE ON ledger.journals TO serk_api;
GRANT INSERT, UPDATE ON ledger.lines TO serk_api;

-- Allow system-generated journals to have matching created_by and approved_by (automated workflows)
ALTER TABLE ledger.journals DROP CONSTRAINT IF EXISTS journals_check;
ALTER TABLE ledger.journals ADD CONSTRAINT journals_check 
    CHECK (approved_by IS NULL OR approved_by <> created_by OR source_type = 'SYSTEM');

-- Allow inserting lines for system-generated journals
CREATE OR REPLACE FUNCTION ledger.guard_line() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE j ledger.journals;
 BEGIN
 SELECT * INTO j FROM ledger.journals WHERE id=CASE WHEN TG_OP='DELETE' THEN OLD.journal_id ELSE NEW.journal_id END FOR UPDATE;
 IF NOT FOUND OR (j.state<>'DRAFT' AND j.source_type<>'SYSTEM') THEN RAISE EXCEPTION 'journal_lines_immutable' USING ERRCODE='55000'; END IF;
 IF TG_OP='UPDATE' AND (NEW.journal_id,NEW.tenant_id,NEW.company_id) IS DISTINCT FROM (OLD.journal_id,OLD.tenant_id,OLD.company_id) THEN
 RAISE EXCEPTION 'journal_identity_immutable' USING ERRCODE='55000'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
 END $$;
