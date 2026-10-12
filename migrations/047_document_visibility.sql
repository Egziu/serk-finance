SET LOCAL ROLE serk_owner;
CREATE POLICY module_read ON finance.documents AS RESTRICTIVE FOR SELECT
USING(security.has(finance.permission(kind)||'.read'));
CREATE POLICY payslip_branch ON payroll.pay_slips AS RESTRICTIVE FOR SELECT USING(
 EXISTS(SELECT FROM payroll.payruns r WHERE r.id=payrun_id AND
  ((r.document_id IS NULL AND security.can('payroll.read') AND security.can('ledger.read'))
   OR EXISTS(SELECT FROM finance.documents d WHERE d.id=r.document_id AND security.visible_branch(d.branch_id)))));
CREATE POLICY payrun_branch ON payroll.payruns AS RESTRICTIVE FOR SELECT USING(
 (document_id IS NULL AND security.can('payroll.read') AND security.can('ledger.read'))
 OR EXISTS(SELECT FROM finance.documents d WHERE d.id=document_id AND security.visible_branch(d.branch_id)));
CREATE INDEX audit_posted_snapshot_lookup ON audit.events(entity_id,(new_state->>'version')) WHERE action='journals.posted';
CREATE INDEX payroll_source_link ON payroll.pay_slips(payrun_id,employee_id);

GRANT EXECUTE ON FUNCTION finance.permission(text) TO serk_api;

-- Publish the runtime marker only after every repair migration is present.
CREATE OR REPLACE FUNCTION security.release_version() RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT '0.2.1-rc1'::text $$;
