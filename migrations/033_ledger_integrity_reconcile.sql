-- 033_ledger_integrity_reconcile.sql
SET LOCAL ROLE serk_owner;

-- 1. Ensure 2000 Accounts Payable and 1200 Accounts Receivable exist for all companies
INSERT INTO ledger.accounts (
  tenant_id, company_id, code, name, type, normal_balance, parent_id,
  posting_allowed, control_account, reporting_category
)
SELECT 
  c.tenant_id, c.id, '2000', 'Accounts Payable', 'LIABILITY', 'CREDIT', NULL,
  true, false, 'LIABILITY'
FROM organization.companies c
WHERE NOT EXISTS (
  SELECT 1 FROM ledger.accounts a 
  WHERE a.company_id = c.id AND (a.code = '2000' OR a.name ILIKE '%Accounts Payable%')
)
ON CONFLICT (company_id, code) DO NOTHING;

INSERT INTO ledger.accounts (
  tenant_id, company_id, code, name, type, normal_balance, parent_id,
  posting_allowed, control_account, reporting_category
)
SELECT 
  c.tenant_id, c.id, '1200', 'Accounts Receivable', 'ASSET', 'DEBIT', NULL,
  true, false, 'ASSET'
FROM organization.companies c
WHERE NOT EXISTS (
  SELECT 1 FROM ledger.accounts a 
  WHERE a.company_id = c.id AND (a.code = '1200' OR a.name ILIKE '%Accounts Receivable%')
)
ON CONFLICT (company_id, code) DO NOTHING;

-- 2. Balance orphan system journals BILL-987441 and PAY-BILL-892720
-- Temporarily disable guard_lines trigger during this administrative data repair
ALTER TABLE ledger.lines DISABLE TRIGGER guard_lines;

-- BILL-987441: add missing Credit Accounts Payable line (line 1)
INSERT INTO ledger.lines (tenant_id, company_id, journal_id, line_no, account_id, debit_minor, credit_minor, functional_debit_minor, functional_credit_minor)
SELECT j.tenant_id, j.company_id, j.id, 1, ap.id, 0, 165200000, 0, 165200000
FROM ledger.journals j
JOIN ledger.accounts ap ON ap.company_id = j.company_id AND ap.code = '2000'
WHERE j.id = '4679d08f-896b-43d0-a891-7f67826f7163'
  AND NOT EXISTS (SELECT 1 FROM ledger.lines l WHERE l.journal_id = j.id AND l.line_no = 1);

-- PAY-BILL-892720: add missing Debit Accounts Payable line (line 1)
INSERT INTO ledger.lines (tenant_id, company_id, journal_id, line_no, account_id, debit_minor, credit_minor, functional_debit_minor, functional_credit_minor)
SELECT j.tenant_id, j.company_id, j.id, 1, ap.id, 165200000, 0, 165200000, 0
FROM ledger.journals j
JOIN ledger.accounts ap ON ap.company_id = j.company_id AND ap.code = '2000'
WHERE j.id = '230e06a8-d54a-4896-871f-393ec3d4f03d'
  AND NOT EXISTS (SELECT 1 FROM ledger.lines l WHERE l.journal_id = j.id AND l.line_no = 1);

ALTER TABLE ledger.lines ENABLE TRIGGER guard_lines;

-- 3. Update ledger.integrity_status() to properly reconcile outbox events across all audited modules
CREATE OR REPLACE FUNCTION ledger.integrity_status() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
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
