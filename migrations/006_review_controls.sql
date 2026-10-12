-- Additive review remediation. Released migrations 001-005 are immutable.
SET LOCAL ROLE serk_owner;

-- A remote attacker must not consume another source's account quota.
DROP FUNCTION security.consume_login_attempt(text,text);
CREATE FUNCTION security.consume_login_attempt(p_slug text,p_email text,p_source text) RETURNS boolean
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE n integer; stamp timestamptz:=clock_timestamp();
 BEGIN
 IF p_source IS NULL OR length(p_source) NOT BETWEEN 1 AND 64 OR length(p_slug)>63 OR length(p_email)>254 THEN RETURN false; END IF;
 -- Bounded cleanup work on the indexed age column; no identities or IPs stored.
 DELETE FROM security.login_windows WHERE key_hash IN
 (SELECT key_hash FROM security.login_windows WHERE window_start<stamp-interval '1 hour' ORDER BY window_start LIMIT 100);
 INSERT INTO security.login_windows VALUES
 (encode(sha256(convert_to(jsonb_build_array(p_slug,lower(btrim(p_email)),p_source)::text,'UTF8')),'hex'),stamp,1)
 ON CONFLICT(key_hash) DO UPDATE SET
 attempts=CASE WHEN login_windows.window_start<stamp-interval '1 minute' THEN 1 ELSE least(login_windows.attempts+1,1000) END,
 window_start=CASE WHEN login_windows.window_start<stamp-interval '1 minute' THEN stamp ELSE login_windows.window_start END
 RETURNING attempts INTO n;
 RETURN n<=10;
 END $$;
CREATE FUNCTION security.reset_login_attempts(p_slug text,p_email text,p_source text) RETURNS void
 LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DELETE FROM security.login_windows WHERE key_hash=encode(sha256(convert_to(jsonb_build_array(p_slug,lower(btrim(p_email)),p_source)::text,'UTF8')),'hex')
 $$;
GRANT EXECUTE ON FUNCTION security.consume_login_attempt(text,text,text),security.reset_login_attempts(text,text,text) TO serk_auth;

-- A close requires company-wide ledger visibility so branch RLS cannot hide work.
CREATE FUNCTION ledger.guard_pending_period() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 BEGIN
 IF OLD.state IN ('OPEN','SOFT_CLOSED') AND NEW.state<>OLD.state THEN
  PERFORM security.require('ledger.read');
  IF EXISTS(SELECT FROM ledger.journals WHERE period_id=OLD.id AND state IN ('DRAFT','SUBMITTED','APPROVED')) THEN
   RAISE EXCEPTION 'period_has_unfinished_journals' USING ERRCODE='55000';
  END IF;
 END IF;
 RETURN NEW;
 END $$;
CREATE TRIGGER aa_pending_period BEFORE UPDATE ON ledger.periods FOR EACH ROW EXECUTE FUNCTION ledger.guard_pending_period();
CREATE INDEX journal_period_unfinished ON ledger.journals(period_id,state) WHERE state IN ('DRAFT','SUBMITTED','APPROVED');
CREATE FUNCTION ledger.period_close_preview(p_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE p ledger.periods; counts jsonb; n bigint;
 BEGIN
 PERFORM security.require('period.close'); PERFORM security.require('ledger.read');
 SELECT * INTO p FROM ledger.periods WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 SELECT count(*),jsonb_build_object('draft',count(*) FILTER(WHERE state='DRAFT'),'submitted',count(*) FILTER(WHERE state='SUBMITTED'),
 'approved',count(*) FILTER(WHERE state='APPROVED')) INTO n,counts FROM ledger.journals WHERE period_id=p_id AND state IN ('DRAFT','SUBMITTED','APPROVED');
 RETURN jsonb_build_object('period_id',p_id,'version',p.version,'state',p.state,'unfinished',counts,'can_close',n=0 AND p.state IN ('OPEN','SOFT_CLOSED'));
 END $$;
GRANT EXECUTE ON FUNCTION ledger.period_close_preview(uuid) TO serk_api;

-- Privileged configuration is explicit, reasoned, and append-only audited.
CREATE TABLE security.configuration_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL,company_id uuid NOT NULL,
 actor_login text NOT NULL DEFAULT session_user,action text NOT NULL,reason text NOT NULL CHECK(length(btrim(reason)) BETWEEN 3 AND 1000),
 previous_state jsonb,new_state jsonb NOT NULL,recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id)
);
CREATE TRIGGER immutable_configuration_events BEFORE UPDATE OR DELETE ON security.configuration_events
 FOR EACH ROW EXECUTE FUNCTION ledger.block_mutation();
CREATE TABLE ledger.fx_rounding_settings (
 tenant_id uuid NOT NULL,company_id uuid PRIMARY KEY,account_id uuid NOT NULL,
 max_difference_minor integer NOT NULL CHECK(max_difference_minor BETWEEN 1 AND 250),
 FOREIGN KEY(tenant_id,company_id,account_id) REFERENCES ledger.accounts(tenant_id,company_id,id)
);
-- No runtime role may read or mutate this private operator configuration directly.
CREATE FUNCTION ledger.configure_fx_rounding(p_company uuid,p_account uuid,p_max integer,p_reason text) RETURNS void
 LANGUAGE plpgsql SET search_path=pg_catalog,ledger,security,organization,pg_temp AS $$
 DECLARE tid uuid; prior jsonb; next jsonb;
 BEGIN
 IF p_max IS NULL OR p_max NOT BETWEEN 1 AND 250 OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN
 RAISE EXCEPTION 'invalid_rounding_configuration' USING ERRCODE='22023'; END IF;
 SELECT tenant_id INTO STRICT tid FROM organization.companies WHERE id=p_company FOR UPDATE;
 PERFORM 1 FROM ledger.accounts WHERE id=p_account AND company_id=p_company AND active AND posting_allowed AND NOT control_account
 AND type IN ('OTHER_EXPENSE','OTHER_INCOME') AND NOT EXISTS(SELECT FROM ledger.accounts c WHERE c.parent_id=p_account) FOR SHARE;
 IF NOT FOUND THEN RAISE EXCEPTION 'invalid_rounding_account' USING ERRCODE='23514'; END IF;
 SELECT to_jsonb(s) INTO prior FROM ledger.fx_rounding_settings s WHERE company_id=p_company;
 INSERT INTO ledger.fx_rounding_settings VALUES(tid,p_company,p_account,p_max)
 ON CONFLICT(company_id) DO UPDATE SET account_id=p_account,max_difference_minor=p_max
 RETURNING to_jsonb(fx_rounding_settings) INTO next;
 INSERT INTO security.configuration_events(tenant_id,company_id,action,reason,previous_state,new_state)
 VALUES(tid,p_company,'configure_fx_rounding',p_reason,prior,next);
 END $$;

-- At most one system-created functional-only rounding line, after 2..500 source lines.
ALTER TABLE ledger.lines ADD COLUMN is_rounding boolean NOT NULL DEFAULT false;
ALTER TABLE ledger.lines DROP CONSTRAINT lines_check;
ALTER TABLE ledger.lines DROP CONSTRAINT lines_line_no_check;
ALTER TABLE ledger.lines ADD CONSTRAINT lines_line_no_check CHECK(line_no BETWEEN 1 AND 501);
ALTER TABLE ledger.lines ADD CONSTRAINT lines_amount_sides CHECK(
 (NOT is_rounding AND ((debit_minor>0 AND credit_minor=0) OR (credit_minor>0 AND debit_minor=0))) OR
 (is_rounding AND debit_minor=0 AND credit_minor=0 AND ((functional_debit_minor>0 AND functional_credit_minor=0) OR (functional_credit_minor>0 AND functional_debit_minor=0))));
CREATE UNIQUE INDEX one_rounding_line ON ledger.lines(journal_id) WHERE is_rounding;

CREATE OR REPLACE FUNCTION ledger.create_journal(p jsonb,p_original uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 DECLARE jid uuid:=gen_random_uuid(); cid uuid:=security.company(); tid uuid:=security.tenant();
 b uuid:=(p->>'branch_id')::uuid;dt date:=(p->>'accounting_date')::date;per ledger.periods; original ledger.journals;
 fyname text; sn bigint;pref text;curr text;fc text;rate numeric;te integer;fe integer;item jsonb;dim jsonb;ln integer:=0; delta numeric; rounding ledger.fx_rounding_settings;
 BEGIN
 PERFORM security.require('journal.create',b);
 IF length(btrim(coalesce(p->>'description','')))<1 OR length(btrim(coalesce(p->>'reason','')))<3 THEN RAISE EXCEPTION 'description_and_reason_required' USING ERRCODE='22023'; END IF;
 SELECT * INTO STRICT per FROM ledger.periods WHERE company_id=cid AND dt BETWEEN start_date AND end_date FOR SHARE;
 IF per.state<>'OPEN' THEN RAISE EXCEPTION 'period_not_open' USING ERRCODE='55000'; END IF;
 SELECT name INTO fyname FROM ledger.fiscal_years WHERE id=per.fiscal_year_id;
 INSERT INTO ledger.numbering(tenant_id,company_id,fiscal_year_id,document_type) VALUES(tid,cid,per.fiscal_year_id,'JOURNAL') ON CONFLICT DO NOTHING;
 UPDATE ledger.numbering SET next_value=next_value+1 WHERE company_id=cid AND fiscal_year_id=per.fiscal_year_id AND document_type='JOURNAL'
 RETURNING next_value-1,prefix INTO sn,pref;
 SELECT functional_currency INTO fc FROM organization.companies WHERE id=cid FOR SHARE;
 curr:=p->>'currency';rate:=(p->>'fx_rate')::numeric;
 IF p_original IS NOT NULL THEN
  SELECT * INTO STRICT original FROM ledger.journals WHERE id=p_original FOR UPDATE;
  IF original.state<>'POSTED' THEN RAISE EXCEPTION 'only_posted_can_reverse' USING ERRCODE='55000'; END IF;
  IF dt<original.accounting_date THEN RAISE EXCEPTION 'reversal_date_before_original' USING ERRCODE='23514'; END IF;
  b:=original.branch_id;curr:=original.currency;rate:=original.fx_rate;fc:=original.functional_currency;
 END IF;
 SELECT minor_units INTO STRICT te FROM organization.currencies WHERE code=curr FOR SHARE;
 SELECT minor_units INTO STRICT fe FROM organization.currencies WHERE code=fc FOR SHARE;
 INSERT INTO ledger.journals(id,tenant_id,company_id,branch_id,period_id,accounting_date,number,sequence_no,description,currency,functional_currency,
 fx_rate,created_by,reversed_from,reason,source_type) VALUES(jid,tid,cid,b,per.id,dt,
 pref||'-'||fyname||'-'||lpad(sn::text,greatest(6,length(sn::text)),'0'),sn,p->>'description',curr,fc,rate,security.actor(),p_original,p->>'reason',
 CASE WHEN p_original IS NULL THEN 'MANUAL' ELSE 'REVERSAL' END);
 IF p_original IS NOT NULL THEN
  INSERT INTO ledger.lines SELECT tid,cid,jid,line_no,account_id,description,credit_minor,debit_minor,functional_credit_minor,functional_debit_minor,is_rounding
   FROM ledger.lines WHERE journal_id=p_original;
  INSERT INTO ledger.line_dimensions SELECT tid,cid,jid,line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=p_original;
 ELSE
  IF jsonb_typeof(p->'lines')<>'array' OR jsonb_array_length(p->'lines') NOT BETWEEN 2 AND 500 THEN RAISE EXCEPTION 'invalid_lines' USING ERRCODE='22023'; END IF;
  FOR item IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
   ln:=ln+1;
   INSERT INTO ledger.lines VALUES(tid,cid,jid,ln,(item->>'account_id')::uuid,coalesce(item->>'description',''),
    (item->>'debit_minor')::numeric,(item->>'credit_minor')::numeric,
    round((item->>'debit_minor')::numeric*rate*power(10::numeric,fe-te)),round((item->>'credit_minor')::numeric*rate*power(10::numeric,fe-te)),false);
   FOR dim IN SELECT * FROM jsonb_array_elements(coalesce(item->'dimensions','[]'::jsonb)) LOOP
    INSERT INTO ledger.line_dimensions VALUES(tid,cid,jid,ln,dim->>'kind',(dim->>'dimension_id')::uuid);
   END LOOP;
  END LOOP;
  SELECT sum(functional_debit_minor-functional_credit_minor) INTO delta FROM ledger.lines WHERE journal_id=jid;
  IF delta<>0 THEN
   SELECT * INTO rounding FROM ledger.fx_rounding_settings WHERE company_id=cid FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION 'fx_rounding_not_configured' USING ERRCODE='23514'; END IF;
   IF abs(delta)>rounding.max_difference_minor OR abs(delta)>floor(ln::numeric/2) THEN
    RAISE EXCEPTION 'fx_rounding_limit_exceeded' USING ERRCODE='23514'; END IF;
   INSERT INTO ledger.lines VALUES(tid,cid,jid,ln+1,rounding.account_id,'FX conversion rounding',0,0,greatest(-delta,0),greatest(delta,0),true);
  END IF;
 END IF;
 PERFORM ledger.validate(jid);
 RETURN jid;
 EXCEPTION WHEN NO_DATA_FOUND THEN RAISE EXCEPTION 'invalid_reference_or_period' USING ERRCODE='22023';
 END $$;

CREATE OR REPLACE FUNCTION ledger.validate(p_id uuid,p_posting boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 DECLARE j ledger.journals;p ledger.periods; n integer;td numeric;tc numeric;fd numeric;fc numeric; te integer;fe integer; nr integer; delta numeric; r ledger.lines;
 BEGIN
 SELECT * INTO STRICT j FROM ledger.journals WHERE id=p_id;
 IF p_posting THEN
  SELECT * INTO STRICT p FROM ledger.periods WHERE id=j.period_id FOR SHARE;
  PERFORM 1 FROM ledger.accounts WHERE id IN(SELECT account_id FROM ledger.lines WHERE journal_id=p_id) ORDER BY id FOR SHARE;
 END IF;
 SELECT count(*),sum(debit_minor),sum(credit_minor),sum(functional_debit_minor),sum(functional_credit_minor)
 INTO n,td,tc,fd,fc FROM ledger.lines WHERE journal_id=p_id;
 SELECT count(*) INTO nr FROM ledger.lines WHERE journal_id=p_id AND is_rounding;
 IF n-nr<2 OR n-nr>500 OR nr>1 OR td IS DISTINCT FROM tc OR fd IS DISTINCT FROM fc OR coalesce(td,0)<=0 OR coalesce(fd,0)<=0
 THEN RAISE EXCEPTION 'journal_unbalanced' USING ERRCODE='23514'; END IF;
 SELECT minor_units INTO te FROM organization.currencies WHERE code=j.currency;
 SELECT minor_units INTO fe FROM organization.currencies WHERE code=j.functional_currency;
 IF EXISTS(SELECT FROM ledger.lines l WHERE l.journal_id=p_id AND NOT l.is_rounding AND
 (l.functional_debit_minor<>round(l.debit_minor*j.fx_rate*power(10::numeric,fe-te)) OR
 l.functional_credit_minor<>round(l.credit_minor*j.fx_rate*power(10::numeric,fe-te)))) THEN
 RAISE EXCEPTION 'invalid_currency_conversion' USING ERRCODE='23514'; END IF;
 IF nr=1 THEN
  SELECT * INTO STRICT r FROM ledger.lines WHERE journal_id=p_id AND is_rounding;
  SELECT sum(functional_debit_minor-functional_credit_minor) INTO delta FROM ledger.lines WHERE journal_id=p_id AND NOT is_rounding;
  IF j.currency=j.functional_currency OR delta=0 OR abs(delta)>floor((n-nr)::numeric/2)
   OR r.functional_debit_minor<>greatest(-delta,0) OR r.functional_credit_minor<>greatest(delta,0)
   OR r.line_no<>(SELECT max(line_no)+1 FROM ledger.lines WHERE journal_id=p_id AND NOT is_rounding)
   OR EXISTS(SELECT FROM ledger.line_dimensions WHERE journal_id=p_id AND line_no=r.line_no)
  THEN RAISE EXCEPTION 'invalid_rounding_line' USING ERRCODE='23514'; END IF;
 END IF;
 IF j.currency=j.functional_currency AND j.fx_rate<>1 THEN RAISE EXCEPTION 'invalid_exchange_rate' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT FROM ledger.lines l JOIN ledger.accounts a ON a.id=l.account_id WHERE l.journal_id=p_id
 AND (NOT a.active OR NOT a.posting_allowed OR a.control_account OR EXISTS(SELECT FROM ledger.accounts child WHERE child.parent_id=a.id)))
 THEN RAISE EXCEPTION 'invalid_posting_account' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT FROM ledger.line_dimensions d JOIN ledger.dimensions v ON v.id=d.dimension_id WHERE d.journal_id=p_id AND NOT v.active)
 THEN RAISE EXCEPTION 'inactive_dimension' USING ERRCODE='23514'; END IF;
 IF p_posting THEN
  IF p.state<>'OPEN' OR j.accounting_date NOT BETWEEN p.start_date AND p.end_date
  THEN RAISE EXCEPTION 'period_not_open' USING ERRCODE='55000'; END IF;
  PERFORM 1 FROM organization.branches WHERE id=j.branch_id AND active FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'inactive_branch' USING ERRCODE='23514'; END IF;
 END IF;
 IF j.reversed_from IS NOT NULL THEN
  IF NOT EXISTS(SELECT FROM ledger.journals WHERE id=j.reversed_from AND state='POSTED' AND accounting_date<=j.accounting_date) THEN RAISE EXCEPTION 'invalid_reversal' USING ERRCODE='23514'; END IF;
  IF EXISTS((SELECT line_no,account_id,debit_minor,credit_minor,functional_debit_minor,functional_credit_minor,is_rounding FROM ledger.lines WHERE journal_id=p_id
   EXCEPT SELECT line_no,account_id,credit_minor,debit_minor,functional_credit_minor,functional_debit_minor,is_rounding FROM ledger.lines WHERE journal_id=j.reversed_from)
   UNION ALL (SELECT line_no,account_id,credit_minor,debit_minor,functional_credit_minor,functional_debit_minor,is_rounding FROM ledger.lines WHERE journal_id=j.reversed_from
   EXCEPT SELECT line_no,account_id,debit_minor,credit_minor,functional_debit_minor,functional_credit_minor,is_rounding FROM ledger.lines WHERE journal_id=p_id)) THEN
   RAISE EXCEPTION 'reversal_mismatch' USING ERRCODE='23514'; END IF;
  IF EXISTS((SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=p_id EXCEPT SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=j.reversed_from)
   UNION ALL (SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=j.reversed_from EXCEPT SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=p_id)) THEN
   RAISE EXCEPTION 'reversal_dimensions_mismatch' USING ERRCODE='23514'; END IF;
 END IF;
 END $$;

CREATE OR REPLACE FUNCTION ledger.get_journal(p_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE j ledger.journals; result jsonb;
 BEGIN
 SELECT * INTO j FROM ledger.journals WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 PERFORM security.require('ledger.read',j.branch_id);
 SELECT to_jsonb(j)||jsonb_build_object('effective_state',CASE WHEN EXISTS(SELECT FROM ledger.journals r WHERE r.reversed_from=j.id AND r.state='POSTED') THEN 'REVERSED' ELSE j.state END,
 'fx_rate',j.fx_rate::text,'lines',coalesce((SELECT jsonb_agg(jsonb_build_object('line_no',l.line_no,'is_rounding',l.is_rounding,'account_id',l.account_id,
 'account_code',a.code,'account_name',a.name,'description',l.description,'debit_minor',l.debit_minor::text,'credit_minor',l.credit_minor::text,
 'functional_debit_minor',l.functional_debit_minor::text,'functional_credit_minor',l.functional_credit_minor::text,
 'dimensions',coalesce((SELECT jsonb_agg(jsonb_build_object('kind',d.kind,'dimension_id',d.dimension_id)) FROM ledger.line_dimensions d
 WHERE d.journal_id=l.journal_id AND d.line_no=l.line_no),'[]'::jsonb)) ORDER BY l.line_no)
 FROM ledger.lines l JOIN ledger.accounts a ON a.id=l.account_id WHERE l.journal_id=j.id),'[]'::jsonb),
 'permissions',jsonb_build_object('submit',security.can('journal.submit',j.branch_id),'approve',
 security.can('journal.approve',j.branch_id,(SELECT sum(functional_debit_minor) FROM ledger.lines WHERE journal_id=j.id)) AND
 security.actor()<>j.created_by AND security.actor() IS DISTINCT FROM j.submitted_by,
 'post',security.can('journal.post',j.branch_id),'reverse',security.can('journal.reverse',j.branch_id),'void',security.can('journal.void',j.branch_id))) INTO result;
 RETURN result;
 END $$;


CREATE OR REPLACE FUNCTION ledger.reference_data() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 BEGIN
 IF NOT security.has('ledger.read') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('accounts',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY code) FROM ledger.accounts a),'[]'::jsonb),
 'branches',coalesce((SELECT jsonb_agg(to_jsonb(b) ORDER BY code) FROM organization.branches b),'[]'::jsonb),
 'periods',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY start_date) FROM ledger.periods p),'[]'::jsonb),
 'dimensions',coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY kind,code) FROM ledger.dimensions d),'[]'::jsonb),
 'currencies',(SELECT jsonb_agg(to_jsonb(c) ORDER BY code) FROM organization.currencies c),
 'permissions',jsonb_build_object('create',security.has('journal.create'),'audit',security.has('audit.read'),'close',security.can('period.close') AND security.can('ledger.read')));
 END $$;
