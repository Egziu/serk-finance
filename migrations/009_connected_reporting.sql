-- SERK-native reporting: no ERPNext DDL or controller code copied.
SET LOCAL ROLE serk_owner;

CREATE FUNCTION ledger.general_ledger(p_account uuid,p_from date,p_as_of date,p_limit integer DEFAULT 100,
 p_after_date date DEFAULT NULL,p_after_id uuid DEFAULT NULL,p_after_line integer DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 DECLARE a ledger.accounts; result jsonb;
 BEGIN
 IF NOT security.has('ledger.read') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 IF p_from IS NULL OR p_as_of IS NULL OR NOT isfinite(p_from) OR NOT isfinite(p_as_of) OR p_from>p_as_of THEN
  RAISE EXCEPTION 'invalid_dates' USING ERRCODE='22023';
 END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
  OR num_nonnulls(p_after_date,p_after_id,p_after_line) NOT IN (0,3)
  OR (p_after_date IS NOT NULL AND (p_after_date NOT BETWEEN p_from AND p_as_of OR p_after_line NOT BETWEEN 1 AND 501)) THEN
  RAISE EXCEPTION 'invalid_pagination' USING ERRCODE='22023';
 END IF;
 SELECT * INTO a FROM ledger.accounts WHERE id=p_account;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 WITH visible AS MATERIALIZED (
  SELECT j.accounting_date,j.id AS journal_id,j.number,j.description AS journal_description,j.currency,j.fx_rate::text AS fx_rate,
   j.branch_id,j.reversed_from,l.line_no,l.description,l.is_rounding,l.debit_minor,l.credit_minor,
   l.functional_debit_minor,l.functional_credit_minor
  FROM ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id
  WHERE l.account_id=p_account AND j.state='POSTED' AND j.accounting_date<=p_as_of
 ), totals AS (
  SELECT coalesce(sum(functional_debit_minor-functional_credit_minor) FILTER(WHERE accounting_date<p_from),0) AS opening,
   coalesce(sum(functional_debit_minor) FILTER(WHERE accounting_date>=p_from),0) AS debit,
   coalesce(sum(functional_credit_minor) FILTER(WHERE accounting_date>=p_from),0) AS credit FROM visible
 ), movements AS (
  SELECT v.*,t.opening+sum(v.functional_debit_minor-v.functional_credit_minor)
   OVER(ORDER BY accounting_date,journal_id,line_no ROWS UNBOUNDED PRECEDING) AS running
  FROM visible v CROSS JOIN totals t WHERE accounting_date>=p_from
 ), candidates AS MATERIALIZED (
  SELECT * FROM movements WHERE p_after_date IS NULL OR (accounting_date,journal_id,line_no)>(p_after_date,p_after_id,p_after_line)
  ORDER BY accounting_date,journal_id,line_no LIMIT p_limit+1
 ), page AS MATERIALIZED (
  SELECT * FROM candidates ORDER BY accounting_date,journal_id,line_no LIMIT p_limit
 )
 SELECT jsonb_build_object('account',jsonb_build_object('id',a.id,'code',a.code,'name',a.name,'type',a.type),
  'from',p_from,'as_of',p_as_of,'generated_at',statement_timestamp(),
  'currency',(SELECT functional_currency FROM organization.companies WHERE id=security.company()),
  'company_wide',security.can('ledger.read'),'balance_convention','debit_minus_credit',
  'opening_minor',t.opening::text,'debit_minor',t.debit::text,'credit_minor',t.credit::text,
  'closing_minor',(t.opening+t.debit-t.credit)::text,
  'rows',coalesce((SELECT jsonb_agg(jsonb_build_object(
   'accounting_date',p.accounting_date,'journal_id',p.journal_id,'number',p.number,'line_no',p.line_no,
   'description',p.description,'journal_description',p.journal_description,'branch_id',p.branch_id,
   'transaction_currency',p.currency,'fx_rate',p.fx_rate,'reversed_from',p.reversed_from,'is_rounding',p.is_rounding,
   'transaction_debit_minor',p.debit_minor::text,'transaction_credit_minor',p.credit_minor::text,
   'debit_minor',p.functional_debit_minor::text,'credit_minor',p.functional_credit_minor::text,
   'running_minor',p.running::text) ORDER BY p.accounting_date,p.journal_id,p.line_no) FROM page p),'[]'::jsonb),
  'has_more',(SELECT count(*)>p_limit FROM candidates),
  'next_cursor',CASE WHEN (SELECT count(*)>p_limit FROM candidates) THEN
   (SELECT jsonb_build_object('after_date',accounting_date,'after_id',journal_id,'after_line',line_no)
    FROM page ORDER BY accounting_date DESC,journal_id DESC,line_no DESC LIMIT 1) ELSE NULL END)
 INTO result FROM totals t;
 RETURN result;
 END $$;
GRANT EXECUTE ON FUNCTION ledger.general_ledger(uuid,date,date,integer,date,uuid,integer) TO serk_api;

-- A bounded-by-statement-timeout, read-only reconciliation. Company-wide audit
-- and ledger access are both required; a partial branch view is not a proof.
CREATE FUNCTION ledger.integrity_status() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
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
 SELECT count(*),coalesce(max(sequence_no),0) INTO entries,last_seq FROM audit.events;
 SELECT event_hash INTO head_hash FROM audit.events ORDER BY sequence_no DESC LIMIT 1;
 SELECT count(*) INTO missing_heads WHERE (entries>0 AND NOT EXISTS(SELECT FROM audit.heads WHERE company_id=security.company()
   AND last_sequence=last_seq AND last_hash=head_hash)) OR
  (entries=0 AND EXISTS(SELECT FROM audit.heads WHERE company_id=security.company() AND (last_sequence<>0 OR last_hash<>'')));
 SELECT count(*) INTO missing_events FROM audit.events e FULL JOIN integration.outbox o ON o.id=e.id
  WHERE e.id IS NULL OR o.id IS NULL OR e.entity_id IS DISTINCT FROM o.aggregate_id
  OR e.tenant_id IS DISTINCT FROM o.tenant_id OR e.company_id IS DISTINCT FROM o.company_id
  OR e.action IS DISTINCT FROM o.event_type OR e.new_state->>'version' IS DISTINCT FROM o.aggregate_version::text
  OR o.payload IS DISTINCT FROM jsonb_build_object('schema_version',1,'id',e.id,'tenant_id',e.tenant_id,
   'company_id',e.company_id,'aggregate_id',e.entity_id,'version',o.aggregate_version,'state',e.new_state->>'state','audit_hash',e.event_hash);
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
GRANT EXECUTE ON FUNCTION ledger.integrity_status() TO serk_api;
CREATE OR REPLACE FUNCTION security.release_version() RETURNS text LANGUAGE sql IMMUTABLE
 SET search_path=pg_catalog,pg_temp AS $$ SELECT '0.2.0-rc3'::text $$;
