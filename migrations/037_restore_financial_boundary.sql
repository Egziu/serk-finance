-- Forward-only repair: retain migrations 001-036 byte-identical.
-- Normalize ownership left by legacy scripts that omitted SET ROLE.
RESET ROLE;
DO $$ DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY['invoicing.invoice_lines','invoicing.bill_lines','core.exchange_rates'] LOOP
  EXECUTE format('ALTER TABLE %s OWNER TO serk_owner',t);
 END LOOP;
END $$;
SET LOCAL ROLE serk_owner;

DROP POLICY migration_owner ON ledger.accounts;
DROP POLICY migration_owner ON ledger.journals;
DROP POLICY migration_owner ON ledger.lines;
ALTER POLICY account_permission ON ledger.accounts USING(security.has('ledger.read'));
ALTER POLICY branch_scope ON ledger.journals USING(security.visible_branch(branch_id));
ALTER TABLE ledger.journals DROP CONSTRAINT journals_source_type_check;
ALTER TABLE ledger.journals ADD CONSTRAINT journals_source_type_check CHECK(source_type IN('MANUAL','REVERSAL','SYSTEM'));
REVOKE INSERT, UPDATE, DELETE ON ledger.journals, ledger.lines, ledger.line_dimensions FROM serk_api;
CREATE OR REPLACE FUNCTION ledger.guard_journal() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE amount numeric;
 BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'journal_delete_forbidden' USING ERRCODE='55000'; END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.state<>'DRAFT' OR NEW.created_by IS DISTINCT FROM security.actor() OR NEW.version<>1 THEN RAISE EXCEPTION 'invalid_initial_state' USING ERRCODE='23514'; END IF;
  RETURN NEW;
 END IF;
 IF OLD.state IN ('POSTED','VOIDED') THEN RAISE EXCEPTION 'journal_immutable' USING ERRCODE='55000'; END IF;
 IF (to_jsonb(NEW)-ARRAY['state','version','submitted_by','approved_by','posted_by','posted_at','reason']) IS DISTINCT FROM
    (to_jsonb(OLD)-ARRAY['state','version','submitted_by','approved_by','posted_by','posted_at','reason'])
 THEN RAISE EXCEPTION 'journal_content_immutable' USING ERRCODE='55000'; END IF;
 IF NEW.version<>OLD.version+1 OR length(btrim(NEW.reason))<3 THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='23514'; END IF;
 IF OLD.state='DRAFT' AND NEW.state='SUBMITTED' THEN
  PERFORM security.require('journal.submit',OLD.branch_id); PERFORM ledger.validate(OLD.id);
  NEW.submitted_by:=security.actor(); NEW.approved_by:=NULL; NEW.posted_by:=NULL; NEW.posted_at:=NULL;
 ELSIF OLD.state='SUBMITTED' AND NEW.state='APPROVED' THEN
  SELECT sum(functional_debit_minor) INTO amount FROM ledger.lines WHERE journal_id=OLD.id;
  PERFORM security.require('journal.approve',OLD.branch_id,amount); PERFORM ledger.validate(OLD.id);
  IF OLD.created_by=security.actor() OR OLD.submitted_by=security.actor() THEN RAISE EXCEPTION 'segregation_of_duties' USING ERRCODE='42501'; END IF;
  NEW.approved_by:=security.actor(); NEW.submitted_by:=OLD.submitted_by;NEW.posted_by:=NULL;NEW.posted_at:=NULL;
 ELSIF OLD.state='APPROVED' AND NEW.state='POSTED' THEN
  PERFORM security.require('journal.post',OLD.branch_id); PERFORM ledger.validate(OLD.id,true);
  NEW.approved_by:=OLD.approved_by;NEW.submitted_by:=OLD.submitted_by;NEW.posted_by:=security.actor();NEW.posted_at:=clock_timestamp();
 ELSIF NEW.state='VOIDED' THEN
  PERFORM security.require('journal.void',OLD.branch_id);
  NEW.approved_by:=OLD.approved_by;NEW.submitted_by:=OLD.submitted_by;NEW.posted_by:=NULL;NEW.posted_at:=NULL;
 ELSE RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
 RETURN NEW;
 END $$;
CREATE OR REPLACE FUNCTION ledger.guard_line() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,pg_temp AS $$
 DECLARE j ledger.journals;
 BEGIN
 SELECT * INTO j FROM ledger.journals WHERE id=CASE WHEN TG_OP='DELETE' THEN OLD.journal_id ELSE NEW.journal_id END FOR UPDATE;
 IF NOT FOUND OR j.state<>'DRAFT' THEN RAISE EXCEPTION 'journal_lines_immutable' USING ERRCODE='55000'; END IF;
 IF TG_OP='UPDATE' AND (NEW.journal_id,NEW.tenant_id,NEW.company_id) IS DISTINCT FROM (OLD.journal_id,OLD.tenant_id,OLD.company_id) THEN
 RAISE EXCEPTION 'journal_identity_immutable' USING ERRCODE='55000'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
 END $$;
CREATE FUNCTION ledger.integrity_status_base() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,audit,integration,security,pg_temp AS $$
 DECLARE imbalanced bigint; audit_errors bigint; missing_events bigint; missing_heads bigint;
  version_errors bigint; posted bigint; entries bigint; last_seq bigint; head_hash text;
 BEGIN
 PERFORM security.require('audit.read'); PERFORM security.require('ledger.read');
 SELECT count(*) INTO posted FROM ledger.journals WHERE state='POSTED';
 SELECT count(*) INTO imbalanced FROM (
  SELECT j.id FROM ledger.journals j LEFT JOIN ledger.lines l ON l.journal_id=j.id WHERE j.state='POSTED'
  GROUP BY j.id HAVING count(l.line_no) FILTER(WHERE NOT l.is_rounding) NOT BETWEEN 2 AND 500
   OR count(l.line_no) FILTER(WHERE l.is_rounding)>1
   OR coalesce(sum(l.debit_minor),0)<=0 OR coalesce(sum(l.functional_debit_minor),0)<=0
   OR coalesce(sum(l.debit_minor-l.credit_minor),0)<>0
   OR coalesce(sum(l.functional_debit_minor-l.functional_credit_minor),0)<>0
 ) bad;
 WITH chain AS (
  SELECT e.*,row_number() OVER(ORDER BY sequence_no) AS expected_sequence,
   coalesce(lag(event_hash) OVER(ORDER BY sequence_no),'') AS expected_previous FROM audit.events e
 ) SELECT count(*) INTO audit_errors FROM chain e WHERE sequence_no<>expected_sequence OR previous_hash<>expected_previous
  OR event_hash<>encode(sha256(convert_to(previous_hash||canonical_payload,'UTF8')),'hex')
  OR (canonical_payload::jsonb->>'at')::timestamptz IS DISTINCT FROM recorded_at
  OR (canonical_payload::jsonb-'at') IS DISTINCT FROM jsonb_build_object('id',id,'tenant_id',tenant_id,'company_id',company_id,
   'sequence',sequence_no,'actor',actor_id,'action',action,'entity',entity_id,
   'before',previous_state,'after',new_state,'context',request_context);
 SELECT count(*), coalesce(max(sequence_no),0) INTO entries, last_seq FROM audit.events;
 SELECT event_hash INTO head_hash FROM audit.events ORDER BY sequence_no DESC LIMIT 1;
 SELECT count(*) INTO missing_heads FROM (
   SELECT 1 WHERE (entries>0 AND NOT EXISTS(SELECT FROM audit.heads WHERE company_id=security.company()
     AND last_sequence=last_seq AND last_hash=head_hash)) OR
    (entries=0 AND EXISTS(SELECT FROM audit.heads WHERE company_id=security.company() AND (last_sequence<>0 OR last_hash<>'')))
 ) m;
 SELECT count(*) INTO missing_events FROM audit.events e FULL JOIN integration.outbox o ON o.id=e.id
  WHERE e.id IS NULL OR o.id IS NULL OR e.entity_id IS DISTINCT FROM o.aggregate_id
  OR e.tenant_id IS DISTINCT FROM o.tenant_id OR e.company_id IS DISTINCT FROM o.company_id
  OR e.action IS DISTINCT FROM o.event_type 
  OR coalesce(e.new_state->>'version', o.aggregate_version::text) IS DISTINCT FROM o.aggregate_version::text
  OR o.payload IS DISTINCT FROM jsonb_build_object('schema_version',1,'id',e.id,'tenant_id',e.tenant_id,
   'company_id',e.company_id,'aggregate_id',e.entity_id,'version',o.aggregate_version,'state',coalesce(e.new_state->>'state', e.new_state->>'status', 'updated'),'audit_hash',e.event_hash);
 SELECT count(*) INTO version_errors FROM (
  SELECT j.id,j.version FROM ledger.journals j LEFT JOIN integration.outbox o ON o.aggregate_id=j.id
  GROUP BY j.id,j.version HAVING count(o.id)<>j.version OR coalesce(min(o.aggregate_version),0)<>1 OR coalesce(max(o.aggregate_version),0)<>j.version
 ) bad;
 RETURN jsonb_build_object('checked_at',statement_timestamp(),'company_id',security.company(),
  'scope','company_wide','posted_journals',posted,'audit_events',entries,'audit_head',coalesce(head_hash,''),
  'unbalanced_posted_journals',imbalanced,'audit_chain_errors',audit_errors,'audit_head_errors',missing_heads,
  'outbox_mismatches',missing_events,'journal_event_version_errors',version_errors,
  'ok',imbalanced=0 AND audit_errors=0 AND missing_heads=0 AND missing_events=0 AND version_errors=0,
  'limitations','Checks local ledger balances, audit linkage and outbox records; not external delivery, statutory compliance, or proof against a privileged database administrator.');
 END $$;

CREATE OR REPLACE FUNCTION ledger.integrity_status() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,audit,security,pg_temp AS $$
DECLARE result jsonb; mismatches bigint;
BEGIN
 result:=ledger.integrity_status_base();
 SELECT count(*) INTO mismatches FROM ledger.journals j
 WHERE j.state='POSTED' AND NOT EXISTS(
  SELECT FROM audit.events e WHERE e.entity_id=j.id AND e.action='journals.posted'
  AND e.new_state->>'version'=j.version::text
  AND coalesce(nullif(e.new_state->'lines','null'::jsonb),'[]'::jsonb)=coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no) FROM ledger.lines l WHERE l.journal_id=j.id),'[]'::jsonb)
  AND coalesce(nullif(e.new_state->'dimensions','null'::jsonb),'[]'::jsonb)=coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.line_no,d.kind) FROM ledger.line_dimensions d WHERE d.journal_id=j.id),'[]'::jsonb));
 RETURN result||jsonb_build_object('posted_snapshot_mismatches',mismatches,'ok',(result->>'ok')::boolean AND mismatches=0);
END $$;
REVOKE ALL ON FUNCTION ledger.integrity_status_base() FROM PUBLIC,serk_api,serk_auth;
GRANT EXECUTE ON FUNCTION ledger.integrity_status() TO serk_api;

-- Self-service factor changes must go through reauthentication on the separate auth connection.
REVOKE EXECUTE ON FUNCTION security.self_enroll_mfa(text,bigint),security.self_disable_mfa() FROM PUBLIC,serk_api,serk_auth;

CREATE FUNCTION ledger.guard_used_postability() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,ledger,pg_temp AS $$ BEGIN
 IF OLD.posting_allowed AND NOT NEW.posting_allowed AND EXISTS(SELECT FROM ledger.lines WHERE account_id=OLD.id)
 THEN RAISE EXCEPTION 'account_definition_in_use' USING ERRCODE='55000'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER used_postability BEFORE UPDATE ON ledger.accounts FOR EACH ROW EXECUTE FUNCTION ledger.guard_used_postability();
ALTER TABLE invoicing.customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.customers FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON invoicing.customers;
CREATE POLICY repaired_scope ON invoicing.customers USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON invoicing.customers AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('sales.read')));
CREATE POLICY repaired_insert ON invoicing.customers AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('sales.manage')));
CREATE POLICY repaired_update ON invoicing.customers AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('sales.manage'))) WITH CHECK ((SELECT security.has('sales.manage')));
CREATE POLICY repaired_delete ON invoicing.customers AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE invoicing.vendors ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.vendors FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON invoicing.vendors;
CREATE POLICY repaired_scope ON invoicing.vendors USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON invoicing.vendors AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('purchases.read')));
CREATE POLICY repaired_insert ON invoicing.vendors AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('purchases.manage')));
CREATE POLICY repaired_update ON invoicing.vendors AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('purchases.manage'))) WITH CHECK ((SELECT security.has('purchases.manage')));
CREATE POLICY repaired_delete ON invoicing.vendors AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE invoicing.invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.invoices FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON invoicing.invoices;
CREATE POLICY repaired_scope ON invoicing.invoices USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON invoicing.invoices AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('sales.read')));
CREATE POLICY repaired_insert ON invoicing.invoices AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('sales.manage')));
CREATE POLICY repaired_update ON invoicing.invoices AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('sales.manage'))) WITH CHECK ((SELECT security.has('sales.manage')));
CREATE POLICY repaired_delete ON invoicing.invoices AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE invoicing.invoice_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.invoice_lines FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON invoicing.invoice_lines;
CREATE POLICY repaired_scope ON invoicing.invoice_lines USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON invoicing.invoice_lines AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('sales.read')));
CREATE POLICY repaired_insert ON invoicing.invoice_lines AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('sales.manage')));
CREATE POLICY repaired_update ON invoicing.invoice_lines AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('sales.manage'))) WITH CHECK ((SELECT security.has('sales.manage')));
CREATE POLICY repaired_delete ON invoicing.invoice_lines AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE invoicing.bills ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.bills FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON invoicing.bills;
CREATE POLICY repaired_scope ON invoicing.bills USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON invoicing.bills AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('purchases.read')));
CREATE POLICY repaired_insert ON invoicing.bills AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('purchases.manage')));
CREATE POLICY repaired_update ON invoicing.bills AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('purchases.manage'))) WITH CHECK ((SELECT security.has('purchases.manage')));
CREATE POLICY repaired_delete ON invoicing.bills AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE invoicing.bill_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoicing.bill_lines FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON invoicing.bill_lines;
CREATE POLICY repaired_scope ON invoicing.bill_lines USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON invoicing.bill_lines AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('purchases.read')));
CREATE POLICY repaired_insert ON invoicing.bill_lines AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('purchases.manage')));
CREATE POLICY repaired_update ON invoicing.bill_lines AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('purchases.manage'))) WITH CHECK ((SELECT security.has('purchases.manage')));
CREATE POLICY repaired_delete ON invoicing.bill_lines AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE payroll.employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE payroll.employees FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON payroll.employees;
CREATE POLICY repaired_scope ON payroll.employees USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON payroll.employees AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('payroll.read')));
CREATE POLICY repaired_insert ON payroll.employees AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('payroll.manage')));
CREATE POLICY repaired_update ON payroll.employees AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('payroll.manage'))) WITH CHECK ((SELECT security.has('payroll.manage')));
CREATE POLICY repaired_delete ON payroll.employees AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE payroll.payruns ENABLE ROW LEVEL SECURITY;
ALTER TABLE payroll.payruns FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON payroll.payruns;
CREATE POLICY repaired_scope ON payroll.payruns USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON payroll.payruns AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('payroll.read')));
CREATE POLICY repaired_insert ON payroll.payruns AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('payroll.manage')));
CREATE POLICY repaired_update ON payroll.payruns AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('payroll.manage'))) WITH CHECK ((SELECT security.has('payroll.manage')));
CREATE POLICY repaired_delete ON payroll.payruns AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE payroll.pay_slips ENABLE ROW LEVEL SECURITY;
ALTER TABLE payroll.pay_slips FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON payroll.pay_slips;
CREATE POLICY repaired_scope ON payroll.pay_slips USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON payroll.pay_slips AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('payroll.read')));
CREATE POLICY repaired_insert ON payroll.pay_slips AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('payroll.manage')));
CREATE POLICY repaired_update ON payroll.pay_slips AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('payroll.manage'))) WITH CHECK ((SELECT security.has('payroll.manage')));
CREATE POLICY repaired_delete ON payroll.pay_slips AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE inventory.items ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory.items FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON inventory.items;
CREATE POLICY repaired_scope ON inventory.items USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON inventory.items AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('inventory.read')));
CREATE POLICY repaired_insert ON inventory.items AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('inventory.manage')));
CREATE POLICY repaired_update ON inventory.items AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('inventory.manage'))) WITH CHECK ((SELECT security.has('inventory.manage')));
CREATE POLICY repaired_delete ON inventory.items AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE inventory.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory.transactions FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON inventory.transactions;
CREATE POLICY repaired_scope ON inventory.transactions USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON inventory.transactions AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('inventory.read')));
CREATE POLICY repaired_insert ON inventory.transactions AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('inventory.manage')));
CREATE POLICY repaired_update ON inventory.transactions AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('inventory.manage'))) WITH CHECK ((SELECT security.has('inventory.manage')));
CREATE POLICY repaired_delete ON inventory.transactions AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE taxes.tax_agencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE taxes.tax_agencies FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON taxes.tax_agencies;
CREATE POLICY repaired_scope ON taxes.tax_agencies USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON taxes.tax_agencies AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('taxes.read')));
CREATE POLICY repaired_insert ON taxes.tax_agencies AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('taxes.manage')));
CREATE POLICY repaired_update ON taxes.tax_agencies AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('taxes.manage'))) WITH CHECK ((SELECT security.has('taxes.manage')));
CREATE POLICY repaired_delete ON taxes.tax_agencies AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE taxes.tax_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE taxes.tax_rates FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON taxes.tax_rates;
CREATE POLICY repaired_scope ON taxes.tax_rates USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON taxes.tax_rates AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('taxes.read')));
CREATE POLICY repaired_insert ON taxes.tax_rates AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('taxes.manage')));
CREATE POLICY repaired_update ON taxes.tax_rates AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('taxes.manage'))) WITH CHECK ((SELECT security.has('taxes.manage')));
CREATE POLICY repaired_delete ON taxes.tax_rates AS RESTRICTIVE FOR DELETE USING (false);
ALTER TABLE core.exchange_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.exchange_rates FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_isolation ON core.exchange_rates;
CREATE POLICY repaired_scope ON core.exchange_rates USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON core.exchange_rates AS RESTRICTIVE FOR SELECT USING ((SELECT security.has('configuration.manage')));
CREATE POLICY repaired_insert ON core.exchange_rates AS RESTRICTIVE FOR INSERT WITH CHECK ((SELECT security.has('configuration.manage')));
CREATE POLICY repaired_update ON core.exchange_rates AS RESTRICTIVE FOR UPDATE USING ((SELECT security.has('configuration.manage'))) WITH CHECK ((SELECT security.has('configuration.manage')));
CREATE POLICY repaired_delete ON core.exchange_rates AS RESTRICTIVE FOR DELETE USING (false);

REVOKE INSERT,UPDATE,DELETE ON invoicing.invoices,invoicing.bills,invoicing.invoice_lines,invoicing.bill_lines,
 payroll.payruns,payroll.pay_slips,inventory.transactions FROM serk_api;

-- Validate item account references as scoped UUID foreign keys.
ALTER TABLE inventory.items ALTER COLUMN income_account_id TYPE uuid USING nullif(income_account_id,'')::uuid;
ALTER TABLE inventory.items ALTER COLUMN expense_account_id TYPE uuid USING nullif(expense_account_id,'')::uuid;
ALTER TABLE inventory.items ALTER COLUMN asset_account_id TYPE uuid USING nullif(asset_account_id,'')::uuid;
ALTER TABLE inventory.items ADD FOREIGN KEY(tenant_id,company_id,income_account_id) REFERENCES ledger.accounts(tenant_id,company_id,id);
ALTER TABLE inventory.items ADD FOREIGN KEY(tenant_id,company_id,expense_account_id) REFERENCES ledger.accounts(tenant_id,company_id,id);
ALTER TABLE inventory.items ADD FOREIGN KEY(tenant_id,company_id,asset_account_id) REFERENCES ledger.accounts(tenant_id,company_id,id);
ALTER TABLE payroll.employees ADD CHECK(salary_amount>0);
ALTER TABLE taxes.tax_rates ADD CHECK(rate_percent>=0 AND rate_percent<=100 AND scale(rate_percent)<=6);

ALTER TABLE taxes.tax_entries FORCE ROW LEVEL SECURITY;
DROP POLICY tenant_isolation ON taxes.tax_entries;
CREATE POLICY repaired_scope ON taxes.tax_entries USING(tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY repaired_read ON taxes.tax_entries AS RESTRICTIVE FOR SELECT USING((SELECT security.has('taxes.read')));
REVOKE INSERT,UPDATE,DELETE ON taxes.tax_entries FROM serk_api;
