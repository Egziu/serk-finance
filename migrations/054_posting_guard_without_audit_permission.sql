-- 0.3.0-rc1: posting no longer requires the preparer to hold audit.read.
--
-- Module, adjustment and year-end commands refuse to post while the company's ledger integrity
-- fails (finance.assert_clean). That check ran ledger.integrity_status(), which requires the
-- caller to hold audit.read and only sees the rows the caller's row-level security allows, so
-- preparers without audit rights (payroll officers, sales clerks) could never submit.
--
-- The integrity computation now runs as a dedicated, login-less role that can read the
-- ledger, audit and outbox tables of the CURRENT company only (every query filters on
-- security.company()). It returns counts, never row data, and is callable only by serk_owner
-- functions. The integrity report itself still requires audit.read.
RESET ROLE;
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='serk_integrity') THEN
  CREATE ROLE serk_integrity NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE BYPASSRLS;
 END IF;
END $$;
GRANT USAGE ON SCHEMA ledger,audit,integration,security TO serk_integrity;
GRANT SELECT ON ledger.journals,ledger.lines,ledger.line_dimensions,audit.events,audit.heads,integration.outbox TO serk_integrity;
GRANT EXECUTE ON FUNCTION security.company() TO serk_integrity;

CREATE FUNCTION ledger.integrity_status_core() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,audit,integration,security,pg_temp AS $$
DECLARE c uuid:=security.company(); imbalanced bigint; audit_errors bigint; missing_events bigint; missing_heads bigint;
 version_errors bigint; posted bigint; entries bigint; last_seq bigint; head_hash text;
BEGIN
 IF c IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 SELECT count(*) INTO posted FROM ledger.journals WHERE company_id=c AND state='POSTED';
 SELECT count(*) INTO imbalanced FROM (
  SELECT j.id FROM ledger.journals j LEFT JOIN ledger.lines l ON l.journal_id=j.id WHERE j.company_id=c AND j.state='POSTED'
  GROUP BY j.id HAVING count(l.line_no) FILTER(WHERE NOT l.is_rounding) NOT BETWEEN 2 AND 500
   OR count(l.line_no) FILTER(WHERE l.is_rounding)>1
   OR coalesce(sum(l.debit_minor),0)<=0 OR coalesce(sum(l.functional_debit_minor),0)<=0
   OR coalesce(sum(l.debit_minor-l.credit_minor),0)<>0
   OR coalesce(sum(l.functional_debit_minor-l.functional_credit_minor),0)<>0
 ) bad;
 WITH chain AS (
  SELECT e.*,row_number() OVER(ORDER BY sequence_no) AS expected_sequence,
   coalesce(lag(event_hash) OVER(ORDER BY sequence_no),'') AS expected_previous FROM audit.events e WHERE e.company_id=c
 ) SELECT count(*) INTO audit_errors FROM chain e WHERE sequence_no<>expected_sequence OR previous_hash<>expected_previous
  OR event_hash<>encode(sha256(convert_to(previous_hash||canonical_payload,'UTF8')),'hex')
  OR (canonical_payload::jsonb->>'at')::timestamptz IS DISTINCT FROM recorded_at
  OR (canonical_payload::jsonb-'at') IS DISTINCT FROM jsonb_build_object('id',id,'tenant_id',tenant_id,'company_id',company_id,
   'sequence',sequence_no,'actor',actor_id,'action',action,'entity',entity_id,
   'before',previous_state,'after',new_state,'context',request_context);
 SELECT count(*),coalesce(max(sequence_no),0) INTO entries,last_seq FROM audit.events WHERE company_id=c;
 SELECT event_hash INTO head_hash FROM audit.events WHERE company_id=c ORDER BY sequence_no DESC LIMIT 1;
 SELECT count(*) INTO missing_heads FROM (
   SELECT 1 WHERE (entries>0 AND NOT EXISTS(SELECT FROM audit.heads WHERE company_id=c AND last_sequence=last_seq AND last_hash=head_hash)) OR
    (entries=0 AND EXISTS(SELECT FROM audit.heads WHERE company_id=c AND (last_sequence<>0 OR last_hash<>'')))
 ) m;
 SELECT count(*) INTO missing_events FROM (SELECT * FROM audit.events WHERE company_id=c) e
  FULL JOIN (SELECT * FROM integration.outbox WHERE company_id=c) o ON o.id=e.id
  WHERE e.id IS NULL OR o.id IS NULL OR e.entity_id IS DISTINCT FROM o.aggregate_id
  OR e.tenant_id IS DISTINCT FROM o.tenant_id OR e.company_id IS DISTINCT FROM o.company_id
  OR e.action IS DISTINCT FROM o.event_type
  OR coalesce(e.new_state->>'version',o.aggregate_version::text) IS DISTINCT FROM o.aggregate_version::text
  OR o.payload IS DISTINCT FROM jsonb_build_object('schema_version',1,'id',e.id,'tenant_id',e.tenant_id,
   'company_id',e.company_id,'aggregate_id',e.entity_id,'version',o.aggregate_version,'state',coalesce(e.new_state->>'state',e.new_state->>'status','updated'),'audit_hash',e.event_hash);
 SELECT count(*) INTO version_errors FROM (
  SELECT j.id,j.version FROM ledger.journals j LEFT JOIN integration.outbox o ON o.aggregate_id=j.id AND o.company_id=c
  WHERE j.company_id=c
  GROUP BY j.id,j.version HAVING count(o.id)<>j.version OR coalesce(min(o.aggregate_version),0)<>1 OR coalesce(max(o.aggregate_version),0)<>j.version
 ) bad;
 RETURN jsonb_build_object('checked_at',statement_timestamp(),'company_id',c,
  'scope','company_wide','posted_journals',posted,'audit_events',entries,'audit_head',coalesce(head_hash,''),
  'unbalanced_posted_journals',imbalanced,'audit_chain_errors',audit_errors,'audit_head_errors',missing_heads,
  'outbox_mismatches',missing_events,'journal_event_version_errors',version_errors,
  'ok',imbalanced=0 AND audit_errors=0 AND missing_heads=0 AND missing_events=0 AND version_errors=0,
  'limitations','Checks local ledger balances, audit linkage and outbox records; not external delivery, statutory compliance, or proof against a privileged database administrator.');
END $$;

CREATE FUNCTION ledger.posted_snapshot_mismatches() RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,audit,security,pg_temp AS $$
 SELECT count(*) FROM ledger.journals j
 WHERE j.company_id=(SELECT security.company()) AND j.state='POSTED' AND NOT EXISTS(
  SELECT FROM audit.events e WHERE e.company_id=j.company_id AND e.entity_id=j.id AND e.action='journals.posted'
  AND e.new_state->>'version'=j.version::text
  AND coalesce(nullif(e.new_state->'lines','null'::jsonb),'[]'::jsonb)=coalesce((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no) FROM ledger.lines l WHERE l.journal_id=j.id),'[]'::jsonb)
  AND coalesce(nullif(e.new_state->'dimensions','null'::jsonb),'[]'::jsonb)=coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY d.line_no,d.kind) FROM ledger.line_dimensions d WHERE d.journal_id=j.id),'[]'::jsonb))
$$;

ALTER FUNCTION ledger.integrity_status_core() OWNER TO serk_integrity;
ALTER FUNCTION ledger.posted_snapshot_mismatches() OWNER TO serk_integrity;
REVOKE ALL ON FUNCTION ledger.integrity_status_core(),ledger.posted_snapshot_mismatches() FROM PUBLIC,serk_api,serk_auth;
GRANT EXECUTE ON FUNCTION ledger.integrity_status_core(),ledger.posted_snapshot_mismatches() TO serk_owner;

SET LOCAL ROLE serk_owner;
CREATE OR REPLACE FUNCTION ledger.integrity_status_base() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,audit,integration,security,pg_temp AS $$
BEGIN
 PERFORM security.require('audit.read'); PERFORM security.require('ledger.read');
 RETURN ledger.integrity_status_core();
END $$;

CREATE OR REPLACE FUNCTION ledger.integrity_status() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,audit,security,pg_temp AS $$
DECLARE result jsonb; mismatches bigint;
BEGIN
 result:=ledger.integrity_status_base();
 mismatches:=ledger.posted_snapshot_mismatches();
 RETURN result||jsonb_build_object('posted_snapshot_mismatches',mismatches,'ok',(result->>'ok')::boolean AND mismatches=0);
END $$;

-- Company-wide check that any preparer's posting relies on, independent of their read rights.
CREATE OR REPLACE FUNCTION finance.assert_clean() RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$
BEGIN
 IF NOT (ledger.integrity_status_core()->>'ok')::boolean OR ledger.posted_snapshot_mismatches()<>0
 THEN RAISE EXCEPTION 'ledger_reconciliation_required' USING ERRCODE='55000'; END IF;
END $$;
