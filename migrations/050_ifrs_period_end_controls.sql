-- 0.2.2-rc1: IFRS period-end and reporting controls from the independent accounting review.
--
--  A1 (IAS 1)  Year-end close: a dual-controlled CLOSING journal transfers the year's profit or
--              loss to a configured retained-earnings account. Profit-or-loss reports exclude
--              CLOSING entries; the statement of financial position shows retained earnings
--              separately from the profit of the open (unclosed) period.
--  A2 (IAS 1)  Current / non-current presentation uses each account's explicit statement_class
--              (049) instead of matching words in the reporting category.
--  A3 (IAS 10) Dual-controlled period reopen for adjusting events, refused once the year is closed.
--  A4 (IAS 21) Foreign-currency manual journals must use a recorded rate for the accounting date
--              within the company tolerance (default 2 %); companies.base_currency follows the
--              functional currency.
--  A5          VAT reporting by date range treats reversal entries as negative amounts of the
--              original type; tax rates that are in use cannot be re-priced or back-dated.
--  A6 (IAS 19) Payroll is accrued on the last day of the pay period it belongs to.
--  A7 (IAS 2)  A purchase return cannot be posted once the item's stock has moved after the bill
--              (it would distort weighted-average cost); use an inventory adjustment instead.

-- Data alignment runs as the operator (FORCE ROW LEVEL SECURITY hides rows from serk_owner).
RESET ROLE;
UPDATE organization.companies SET base_currency=functional_currency WHERE base_currency IS DISTINCT FROM functional_currency;
ALTER TABLE organization.companies ALTER COLUMN base_currency DROP DEFAULT;
ALTER TABLE organization.companies ADD CONSTRAINT companies_base_is_functional CHECK(base_currency IS NULL OR base_currency=functional_currency);
SET LOCAL ROLE serk_owner;

ALTER TABLE ledger.journals DROP CONSTRAINT journals_source_type_check;
ALTER TABLE ledger.journals ADD CONSTRAINT journals_source_type_check CHECK(source_type IN('MANUAL','REVERSAL','SYSTEM','CLOSING'));

------------------------------------------------------------------------------------------
-- Validation: control accounts may be used by SYSTEM, CLOSING and reversals of SYSTEM journals.
------------------------------------------------------------------------------------------
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
 AND (NOT a.active OR NOT a.posting_allowed OR (a.control_account AND NOT (j.source_type IN('SYSTEM','CLOSING') OR (j.source_type='REVERSAL' AND EXISTS(SELECT FROM ledger.journals original WHERE original.id=j.reversed_from AND original.source_type='SYSTEM')))) OR EXISTS(SELECT FROM ledger.accounts child WHERE child.parent_id=a.id)))
 THEN RAISE EXCEPTION 'invalid_posting_account' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT FROM ledger.line_dimensions d JOIN ledger.dimensions v ON v.id=d.dimension_id WHERE d.journal_id=p_id AND NOT v.active)
 THEN RAISE EXCEPTION 'inactive_dimension' USING ERRCODE='23514'; END IF;
 IF p_posting THEN
  IF p.state<>'OPEN' OR j.accounting_date NOT BETWEEN p.start_date AND p.end_date
  THEN RAISE EXCEPTION 'period_not_open' USING ERRCODE='55000'; END IF;
  PERFORM 1 FROM organization.branches WHERE id=j.branch_id AND active FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'inactive_branch' USING ERRCODE='23514'; END IF;
  -- Nothing may be posted into a fiscal year after its closing entry.
  IF j.source_type<>'CLOSING' AND EXISTS(SELECT FROM ledger.year_closings y WHERE y.fiscal_year_id=p.fiscal_year_id AND y.state='POSTED')
  THEN RAISE EXCEPTION 'fiscal_year_closed' USING ERRCODE='55000'; END IF;
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

------------------------------------------------------------------------------------------
-- A1: year-end close.
------------------------------------------------------------------------------------------
CREATE TABLE ledger.year_closings(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,fiscal_year_id uuid NOT NULL,
 state text NOT NULL DEFAULT 'SUBMITTED' CHECK(state IN('SUBMITTED','POSTED','VOIDED')),
 retained_earnings_account_id uuid NOT NULL,journal_ids uuid[] NOT NULL DEFAULT '{}',net_result_minor numeric NOT NULL,
 requested_by uuid NOT NULL,approved_by uuid,reason text NOT NULL,version bigint NOT NULL DEFAULT 1,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,company_id,fiscal_year_id) REFERENCES ledger.fiscal_years(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,company_id,retained_earnings_account_id) REFERENCES ledger.accounts(tenant_id,company_id,id),
 CHECK(approved_by IS NULL OR approved_by<>requested_by));
CREATE UNIQUE INDEX year_closing_active ON ledger.year_closings(fiscal_year_id) WHERE state<>'VOIDED';
ALTER TABLE ledger.year_closings ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.year_closings FORCE ROW LEVEL SECURITY;
CREATE POLICY scoped ON ledger.year_closings USING(tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY ledger_read ON ledger.year_closings AS RESTRICTIVE USING((SELECT security.has('ledger.read')));
GRANT SELECT ON ledger.year_closings TO serk_api;
CREATE TRIGGER year_closings_audit AFTER INSERT OR UPDATE ON ledger.year_closings FOR EACH ROW EXECUTE FUNCTION audit.record_change();

-- Profit-or-loss balances of a fiscal year, per branch and account (functional currency, debit positive).
CREATE FUNCTION ledger.year_result_lines(p_year uuid) RETURNS TABLE(branch_id uuid,account_id uuid,balance numeric) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 SELECT j.branch_id,l.account_id,sum(l.functional_debit_minor-l.functional_credit_minor)
 FROM ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id JOIN ledger.accounts a ON a.id=l.account_id
 JOIN ledger.fiscal_years y ON y.id=p_year
 WHERE j.state='POSTED' AND j.source_type<>'CLOSING' AND j.accounting_date BETWEEN y.start_date AND y.end_date
  AND a.type IN('REVENUE','OTHER_INCOME','COST_OF_SALES','EXPENSE','OTHER_EXPENSE')
 GROUP BY j.branch_id,l.account_id HAVING sum(l.functional_debit_minor-l.functional_credit_minor)<>0
$$;
REVOKE ALL ON FUNCTION ledger.year_result_lines(uuid) FROM PUBLIC;

CREATE FUNCTION ledger.year_close_preview(p_year uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$
DECLARE y ledger.fiscal_years; last ledger.periods; net numeric; blockers jsonb:='[]';
BEGIN
 PERFORM security.require('ledger.read');PERFORM security.require('period.close');
 SELECT * INTO y FROM ledger.fiscal_years WHERE id=p_year;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 SELECT * INTO last FROM ledger.periods WHERE fiscal_year_id=y.id ORDER BY end_date DESC LIMIT 1;
 IF last.id IS NULL THEN blockers:=blockers||'"no_periods"'; ELSIF last.state<>'OPEN' THEN blockers:=blockers||'"final_period_not_open"'; END IF;
 IF EXISTS(SELECT FROM ledger.periods WHERE fiscal_year_id=y.id AND id<>last.id AND state NOT IN('CLOSED','LOCKED')) THEN blockers:=blockers||'"earlier_periods_open"'; END IF;
 IF EXISTS(SELECT FROM ledger.journals j JOIN ledger.periods p ON p.id=j.period_id WHERE p.fiscal_year_id=y.id AND j.state IN('DRAFT','SUBMITTED','APPROVED'))
 THEN blockers:=blockers||'"unfinished_journals"'; END IF;
 IF EXISTS(SELECT FROM ledger.year_closings WHERE fiscal_year_id=y.id AND state<>'VOIDED') THEN blockers:=blockers||'"close_already_requested"'; END IF;
 SELECT coalesce(sum(balance),0) INTO net FROM ledger.year_result_lines(y.id);
 RETURN jsonb_build_object('fiscal_year',to_jsonb(y),'final_period',to_jsonb(last),
  -- Profit is credit-positive: a negative debit balance across profit-or-loss accounts.
  'profit_minor',(-net)::text,'blockers',blockers,'ready',jsonb_array_length(blockers)=0,
  'accounts',coalesce((SELECT jsonb_agg(jsonb_build_object('account_id',a.id,'code',a.code,'name',a.name,'type',a.type,'balance_minor',(-s.balance)::text) ORDER BY a.code)
    FROM (SELECT account_id,sum(balance) balance FROM ledger.year_result_lines(y.id) GROUP BY account_id) s JOIN ledger.accounts a ON a.id=s.account_id),'[]'),
  'closing',(SELECT to_jsonb(c)||jsonb_build_object('net_result_minor',c.net_result_minor::text) FROM ledger.year_closings c WHERE c.fiscal_year_id=y.id AND c.state<>'VOIDED'));
END $$;

CREATE FUNCTION ledger.year_close_command(p_key text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,finance,security,pg_temp AS $$
DECLARE h text; prior finance.receipts; c ledger.year_closings; y ledger.fiscal_years; last ledger.periods; preview jsonb;
 re uuid; br record; ln record; lines jsonb; jid uuid; sn bigint; pref text; fc text; ids uuid[]:='{}'; net numeric; brnet numeric;
 jn jsonb; v bigint; result jsonb;
BEGIN
 IF p_action NOT IN('request','approve','void') OR jsonb_typeof(p)<>'object' THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM security.require('period.close');PERFORM security.require('ledger.read');
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'idempotency_key_required' USING ERRCODE='22023'; END IF;
 IF length(btrim(coalesce(p->>'reason',''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'invalid_reason' USING ERRCODE='22023'; END IF;
 h:=encode(sha256(convert_to(jsonb_build_object('kind','YEAR_CLOSE','action',p_action,'payload',p)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(security.company()::text||security.actor()::text||p_key,0));
 SELECT * INTO prior FROM finance.receipts WHERE company_id=security.company() AND user_id=security.actor() AND key=p_key;
 IF FOUND THEN
  IF prior.request_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='22000'; END IF;
  RETURN prior.response;
 END IF;
 -- One close at a time per company.
 PERFORM pg_advisory_xact_lock(hashtextextended('year-close:'||security.company()::text,0));
 IF p_action='request' THEN
  SELECT * INTO y FROM ledger.fiscal_years WHERE id=(p->>'fiscal_year_id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  preview:=ledger.year_close_preview(y.id);
  IF NOT (preview->>'ready')::boolean THEN RAISE EXCEPTION 'year_close_blocked' USING ERRCODE='55000'; END IF;
  re:=finance.account((p->>'retained_earnings_account_id')::uuid,ARRAY['EQUITY']);
  SELECT * INTO STRICT last FROM ledger.periods WHERE fiscal_year_id=y.id ORDER BY end_date DESC LIMIT 1 FOR UPDATE;
  SELECT functional_currency INTO fc FROM organization.companies WHERE id=security.company();
  SELECT coalesce(sum(balance),0) INTO net FROM ledger.year_result_lines(y.id);
  FOR br IN SELECT DISTINCT branch_id FROM ledger.year_result_lines(y.id) ORDER BY branch_id LOOP
   IF (SELECT count(*) FROM ledger.year_result_lines(y.id) WHERE branch_id=br.branch_id)>499 THEN RAISE EXCEPTION 'too_many_accounts_to_close' USING ERRCODE='54000'; END IF;
   PERFORM security.require('journal.create',br.branch_id);
   INSERT INTO ledger.numbering(tenant_id,company_id,fiscal_year_id,document_type) VALUES(security.tenant(),security.company(),y.id,'JOURNAL') ON CONFLICT DO NOTHING;
   UPDATE ledger.numbering SET next_value=next_value+1 WHERE company_id=security.company() AND fiscal_year_id=y.id AND document_type='JOURNAL' RETURNING next_value-1,prefix INTO sn,pref;
   jid:=gen_random_uuid();
   INSERT INTO ledger.journals(id,tenant_id,company_id,branch_id,period_id,accounting_date,number,sequence_no,description,currency,functional_currency,fx_rate,created_by,reason,source_type)
   VALUES(jid,security.tenant(),security.company(),br.branch_id,last.id,y.end_date,pref||'-'||y.name||'-'||lpad(sn::text,greatest(6,length(sn::text)),'0'),sn,
    'Year-end close '||y.name||': transfer of profit or loss to retained earnings',fc,fc,1,security.actor(),p->>'reason','CLOSING');
   brnet:=0;
   FOR ln IN SELECT row_number() OVER(ORDER BY a.code) AS n,r.account_id,r.balance FROM ledger.year_result_lines(y.id) r JOIN ledger.accounts a ON a.id=r.account_id WHERE r.branch_id=br.branch_id LOOP
    INSERT INTO ledger.lines VALUES(security.tenant(),security.company(),jid,ln.n,ln.account_id,'Year-end close',
     greatest(-ln.balance,0),greatest(ln.balance,0),greatest(-ln.balance,0),greatest(ln.balance,0),false);
    brnet:=brnet+ln.balance;sn:=ln.n;
   END LOOP;
   IF brnet<>0 THEN
    INSERT INTO ledger.lines VALUES(security.tenant(),security.company(),jid,sn+1,re,'Retained earnings',
     greatest(brnet,0),greatest(-brnet,0),greatest(brnet,0),greatest(-brnet,0),false);
   END IF;
   PERFORM ledger.validate(jid);
   SELECT version INTO v FROM ledger.journals WHERE id=jid;
   jn:=ledger.module_command('year-close:'||jid||':submit','submit',jsonb_build_object('id',jid,'expected_version',v,'reason',p->>'reason'));
   ids:=ids||jid;
  END LOOP;
  INSERT INTO ledger.year_closings(tenant_id,company_id,fiscal_year_id,retained_earnings_account_id,journal_ids,net_result_minor,requested_by,reason)
  VALUES(security.tenant(),security.company(),y.id,re,ids,-net,security.actor(),p->>'reason') RETURNING * INTO c;
 ELSE
  SELECT * INTO c FROM ledger.year_closings WHERE id=(p->>'id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  IF c.version IS DISTINCT FROM (p->>'expected_version')::bigint THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
  IF c.state<>'SUBMITTED' THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
  IF p_action='approve' THEN
   IF c.requested_by=security.actor() THEN RAISE EXCEPTION 'segregation_of_duties' USING ERRCODE='42501'; END IF;
   PERFORM finance.assert_clean();
   -- Anything posted into the year after the request makes the closing entry stale.
   IF EXISTS(SELECT FROM ledger.journals j JOIN ledger.fiscal_years fy ON fy.id=c.fiscal_year_id
     WHERE j.state='POSTED' AND j.source_type<>'CLOSING' AND j.accounting_date BETWEEN fy.start_date AND fy.end_date AND j.posted_at>c.created_at)
    OR (SELECT coalesce(sum(balance),0) FROM ledger.year_result_lines(c.fiscal_year_id))<>-c.net_result_minor
   THEN RAISE EXCEPTION 'year_close_stale_void_and_request_again' USING ERRCODE='55000'; END IF;
   FOREACH jid IN ARRAY c.journal_ids LOOP
    SELECT version INTO v FROM ledger.journals WHERE id=jid;
    jn:=ledger.module_command('year-close:'||jid||':approve','approve',jsonb_build_object('id',jid,'expected_version',v,'reason',p->>'reason'));
    jn:=ledger.module_command('year-close:'||jid||':post','post',jsonb_build_object('id',jid,'expected_version',jn->>'version','reason',p->>'reason'));
   END LOOP;
   UPDATE ledger.year_closings SET state='POSTED',approved_by=security.actor(),version=version+1,reason=p->>'reason' WHERE id=c.id RETURNING * INTO c;
   -- The final period closes with the year; nothing further can be posted into it.
   SELECT * INTO STRICT last FROM ledger.periods WHERE fiscal_year_id=c.fiscal_year_id ORDER BY end_date DESC LIMIT 1;
   PERFORM ledger.close_period(last.id,last.version,p->>'reason');
  ELSE
   IF c.requested_by<>security.actor() THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   FOREACH jid IN ARRAY c.journal_ids LOOP
    SELECT version INTO v FROM ledger.journals WHERE id=jid;
    jn:=ledger.module_command('year-close:'||jid||':void','void',jsonb_build_object('id',jid,'expected_version',v,'reason',p->>'reason'));
   END LOOP;
   UPDATE ledger.year_closings SET state='VOIDED',version=version+1,reason=p->>'reason' WHERE id=c.id RETURNING * INTO c;
  END IF;
 END IF;
 result:=to_jsonb(c)||jsonb_build_object('net_result_minor',c.net_result_minor::text);
 INSERT INTO finance.receipts VALUES(security.tenant(),security.company(),security.actor(),p_key,h,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION ledger.year_close_preview(uuid),ledger.year_close_command(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.year_close_preview(uuid),ledger.year_close_command(text,text,jsonb) TO serk_api;

------------------------------------------------------------------------------------------
-- A3: dual-controlled period reopen.
------------------------------------------------------------------------------------------
CREATE TABLE ledger.period_reopenings(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,period_id uuid NOT NULL,
 state text NOT NULL DEFAULT 'SUBMITTED' CHECK(state IN('SUBMITTED','APPROVED','VOIDED')),
 requested_by uuid NOT NULL,approved_by uuid,reason text NOT NULL,version bigint NOT NULL DEFAULT 1,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,company_id,period_id) REFERENCES ledger.periods(tenant_id,company_id,id),
 CHECK(approved_by IS NULL OR approved_by<>requested_by));
CREATE UNIQUE INDEX period_reopening_pending ON ledger.period_reopenings(period_id) WHERE state='SUBMITTED';
ALTER TABLE ledger.period_reopenings ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.period_reopenings FORCE ROW LEVEL SECURITY;
CREATE POLICY scoped ON ledger.period_reopenings USING(tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY ledger_read ON ledger.period_reopenings AS RESTRICTIVE USING((SELECT security.has('ledger.read')));
GRANT SELECT ON ledger.period_reopenings TO serk_api;
CREATE TRIGGER period_reopenings_audit AFTER INSERT OR UPDATE ON ledger.period_reopenings FOR EACH ROW EXECUTE FUNCTION audit.record_change();

CREATE OR REPLACE FUNCTION ledger.guard_period() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE fy ledger.fiscal_years;
 BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'period_delete_forbidden' USING ERRCODE='55000'; END IF;
 IF TG_OP='UPDATE' THEN
  IF (to_jsonb(OLD)-ARRAY['state','version']) IS DISTINCT FROM (to_jsonb(NEW)-ARRAY['state','version'])
   OR NOT ((OLD.state='OPEN' AND NEW.state IN ('SOFT_CLOSED','CLOSED')) OR (OLD.state='SOFT_CLOSED' AND NEW.state='CLOSED') OR (OLD.state='CLOSED' AND NEW.state='LOCKED')
    -- Reopen only through an approved reopening (the setting is transaction-local and only
    -- ledger.period_reopen_command sets it; the API role cannot update periods directly).
    OR (OLD.state='CLOSED' AND NEW.state='OPEN' AND current_setting('serk.period_reopen',true)=OLD.id::text))
   OR NEW.version<>OLD.version+1 THEN RAISE EXCEPTION 'invalid_period_transition' USING ERRCODE='55000'; END IF;
  PERFORM security.require('period.close');
 ELSE
  PERFORM 1 FROM organization.companies WHERE id=NEW.company_id FOR UPDATE;
  SELECT * INTO STRICT fy FROM ledger.fiscal_years WHERE id=NEW.fiscal_year_id FOR UPDATE;
  IF NEW.start_date<fy.start_date OR NEW.end_date>fy.end_date OR EXISTS(SELECT FROM ledger.periods WHERE company_id=NEW.company_id
   AND daterange(start_date,end_date,'[]') && daterange(NEW.start_date,NEW.end_date,'[]')) THEN
   RAISE EXCEPTION 'invalid_period_range' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
 END $$;

CREATE FUNCTION ledger.period_reopen_command(p_key text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,finance,security,pg_temp AS $$
DECLARE h text; prior finance.receipts; r ledger.period_reopenings; per ledger.periods; result jsonb;
BEGIN
 IF p_action NOT IN('request','approve','void') OR jsonb_typeof(p)<>'object' THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM security.require('period.close');PERFORM security.require('ledger.read');
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'idempotency_key_required' USING ERRCODE='22023'; END IF;
 IF length(btrim(coalesce(p->>'reason',''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'invalid_reason' USING ERRCODE='22023'; END IF;
 h:=encode(sha256(convert_to(jsonb_build_object('kind','PERIOD_REOPEN','action',p_action,'payload',p)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(security.company()::text||security.actor()::text||p_key,0));
 SELECT * INTO prior FROM finance.receipts WHERE company_id=security.company() AND user_id=security.actor() AND key=p_key;
 IF FOUND THEN
  IF prior.request_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='22000'; END IF;
  RETURN prior.response;
 END IF;
 IF p_action='request' THEN
  SELECT * INTO per FROM ledger.periods WHERE id=(p->>'period_id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  IF per.state<>'CLOSED' THEN RAISE EXCEPTION 'period_not_closed' USING ERRCODE='55000'; END IF;
  IF EXISTS(SELECT FROM ledger.year_closings WHERE fiscal_year_id=per.fiscal_year_id AND state<>'VOIDED') THEN RAISE EXCEPTION 'fiscal_year_closed' USING ERRCODE='55000'; END IF;
  INSERT INTO ledger.period_reopenings(tenant_id,company_id,period_id,requested_by,reason)
  VALUES(security.tenant(),security.company(),per.id,security.actor(),p->>'reason') RETURNING * INTO r;
 ELSE
  SELECT * INTO r FROM ledger.period_reopenings WHERE id=(p->>'id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  IF r.version IS DISTINCT FROM (p->>'expected_version')::bigint THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
  IF r.state<>'SUBMITTED' THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
  IF p_action='approve' THEN
   IF r.requested_by=security.actor() THEN RAISE EXCEPTION 'segregation_of_duties' USING ERRCODE='42501'; END IF;
   SELECT * INTO STRICT per FROM ledger.periods WHERE id=r.period_id FOR UPDATE;
   IF per.state<>'CLOSED' THEN RAISE EXCEPTION 'period_not_closed' USING ERRCODE='55000'; END IF;
   IF EXISTS(SELECT FROM ledger.year_closings WHERE fiscal_year_id=per.fiscal_year_id AND state<>'VOIDED') THEN RAISE EXCEPTION 'fiscal_year_closed' USING ERRCODE='55000'; END IF;
   PERFORM set_config('serk.period_reopen',per.id::text,true);
   PERFORM set_config('serk.request_context',(coalesce(nullif(current_setting('serk.request_context',true),'')::jsonb,'{}'::jsonb)||jsonb_build_object('reason',p->>'reason'))::text,true);
   UPDATE ledger.periods SET state='OPEN',version=version+1 WHERE id=per.id;
   PERFORM set_config('serk.period_reopen','',true);
   UPDATE ledger.period_reopenings SET state='APPROVED',approved_by=security.actor(),version=version+1,reason=p->>'reason' WHERE id=r.id RETURNING * INTO r;
  ELSE
   IF r.requested_by<>security.actor() THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   UPDATE ledger.period_reopenings SET state='VOIDED',version=version+1,reason=p->>'reason' WHERE id=r.id RETURNING * INTO r;
  END IF;
 END IF;
 result:=to_jsonb(r);
 INSERT INTO finance.receipts VALUES(security.tenant(),security.company(),security.actor(),p_key,h,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION ledger.period_reopen_command(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.period_reopen_command(text,text,jsonb) TO serk_api;

------------------------------------------------------------------------------------------
-- A2 + A1: statements.
------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ledger.balance_sheet(p_as_of date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
DECLARE v_currency text; v_result jsonb; v_net_income numeric:=0;
BEGIN
 IF NOT security.can('ledger.read') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 IF p_as_of IS NULL THEN RAISE EXCEPTION 'as_of_required' USING ERRCODE='22023'; END IF;
 SELECT functional_currency INTO v_currency FROM organization.companies WHERE id=security.company();
 -- Profit or loss not yet transferred by a posted year-end close (CLOSING entries included,
 -- so closed years net to zero here and appear in retained earnings instead).
 SELECT coalesce(sum(l.functional_credit_minor-l.functional_debit_minor),0) INTO v_net_income
 FROM ledger.accounts a JOIN ledger.lines l ON l.account_id=a.id
 JOIN ledger.journals j ON l.journal_id=j.id AND j.state='POSTED' AND j.accounting_date<=p_as_of
 WHERE a.tenant_id=security.tenant() AND a.company_id=security.company()
  AND a.type IN('REVENUE','OTHER_INCOME','COST_OF_SALES','EXPENSE','OTHER_EXPENSE');
 WITH acct AS (
  SELECT a.id,a.code,a.name,a.type,a.reporting_category,a.statement_class,
   coalesce(sum(CASE WHEN a.type='ASSET' THEN l.functional_debit_minor-l.functional_credit_minor ELSE l.functional_credit_minor-l.functional_debit_minor END),0) AS balance_minor,
   coalesce(sum(l.functional_debit_minor),0) AS dr_minor,coalesce(sum(l.functional_credit_minor),0) AS cr_minor
  FROM ledger.accounts a
  LEFT JOIN (ledger.lines l JOIN ledger.journals j ON l.journal_id=j.id AND j.state='POSTED' AND j.accounting_date<=p_as_of) ON l.account_id=a.id
  WHERE a.tenant_id=security.tenant() AND a.company_id=security.company() AND a.type IN('ASSET','LIABILITY','EQUITY')
  GROUP BY a.id,a.code,a.name,a.type,a.reporting_category,a.statement_class),
 sect AS (
  SELECT s.k,coalesce(jsonb_agg(jsonb_build_object('id',a.id,'code',a.code,'name',a.name,'reporting_category',a.reporting_category,
    'statement_class',a.statement_class,'balance_minor',a.balance_minor::text,'dr_minor',a.dr_minor::text,'cr_minor',a.cr_minor::text) ORDER BY a.code)
    FILTER(WHERE a.id IS NOT NULL),'[]'::jsonb) AS rows,coalesce(sum(a.balance_minor),0) AS total
  FROM (VALUES('CA'),('NCA'),('CL'),('NCL'),('EQ')) s(k)
  LEFT JOIN acct a ON s.k=CASE WHEN a.type='ASSET' AND a.statement_class='NON_CURRENT' THEN 'NCA' WHEN a.type='ASSET' THEN 'CA'
   WHEN a.type='LIABILITY' AND a.statement_class='NON_CURRENT' THEN 'NCL' WHEN a.type='LIABILITY' THEN 'CL' ELSE 'EQ' END
  GROUP BY s.k)
 SELECT jsonb_build_object('as_of',p_as_of,'currency',v_currency,
  'assets',jsonb_build_object(
   'current_assets',(SELECT rows FROM sect WHERE k='CA'),'current_assets_total_minor',(SELECT total::text FROM sect WHERE k='CA'),
   'non_current_assets',(SELECT rows FROM sect WHERE k='NCA'),'non_current_assets_total_minor',(SELECT total::text FROM sect WHERE k='NCA'),
   'total_assets_minor',((SELECT total FROM sect WHERE k='CA')+(SELECT total FROM sect WHERE k='NCA'))::text),
  'liabilities',jsonb_build_object(
   'current_liabilities',(SELECT rows FROM sect WHERE k='CL'),'current_liabilities_total_minor',(SELECT total::text FROM sect WHERE k='CL'),
   'non_current_liabilities',(SELECT rows FROM sect WHERE k='NCL'),'non_current_liabilities_total_minor',(SELECT total::text FROM sect WHERE k='NCL'),
   'total_liabilities_minor',((SELECT total FROM sect WHERE k='CL')+(SELECT total FROM sect WHERE k='NCL'))::text),
  'equity',jsonb_build_object(
   'equity_accounts',(SELECT rows FROM sect WHERE k='EQ'),'equity_accounts_total_minor',(SELECT total::text FROM sect WHERE k='EQ'),
   'net_income_minor',v_net_income::text,'net_income_label','Profit for the open period (not yet closed to retained earnings)',
   'total_equity_minor',((SELECT total FROM sect WHERE k='EQ')+v_net_income)::text),
  'total_liabilities_and_equity_minor',((SELECT total FROM sect WHERE k='CL')+(SELECT total FROM sect WHERE k='NCL')+(SELECT total FROM sect WHERE k='EQ')+v_net_income)::text,
  'is_balanced',((SELECT total FROM sect WHERE k='CA')+(SELECT total FROM sect WHERE k='NCA'))=((SELECT total FROM sect WHERE k='CL')+(SELECT total FROM sect WHERE k='NCL')+(SELECT total FROM sect WHERE k='EQ')+v_net_income)
 ) INTO v_result;
 RETURN v_result;
END $$;

CREATE OR REPLACE FUNCTION ledger.income_statement(p_from date,p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
DECLARE v_currency text; v_result jsonb;
BEGIN
 IF NOT security.can('ledger.read') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 IF p_to IS NULL THEN RAISE EXCEPTION 'to_date_required' USING ERRCODE='22023'; END IF;
 SELECT functional_currency INTO v_currency FROM organization.companies WHERE id=security.company();
 WITH act AS (
  SELECT a.id,a.code,a.name,a.type,a.reporting_category,
   coalesce(sum(CASE WHEN a.type IN('REVENUE','OTHER_INCOME') THEN l.functional_credit_minor-l.functional_debit_minor ELSE l.functional_debit_minor-l.functional_credit_minor END),0) AS balance_minor
  FROM ledger.accounts a
  LEFT JOIN (ledger.lines l JOIN ledger.journals j ON l.journal_id=j.id AND j.state='POSTED' AND j.source_type<>'CLOSING'
    AND j.accounting_date<=p_to AND (p_from IS NULL OR j.accounting_date>=p_from)) ON l.account_id=a.id
  WHERE a.tenant_id=security.tenant() AND a.company_id=security.company() AND a.type IN('REVENUE','COST_OF_SALES','EXPENSE','OTHER_INCOME','OTHER_EXPENSE')
  GROUP BY a.id,a.code,a.name,a.type,a.reporting_category),
 sect AS (
  SELECT s.k,coalesce(jsonb_agg(jsonb_build_object('id',a.id,'code',a.code,'name',a.name,'reporting_category',a.reporting_category,'amount_minor',a.balance_minor::text) ORDER BY a.code)
   FILTER(WHERE a.id IS NOT NULL),'[]'::jsonb) AS rows,coalesce(sum(a.balance_minor),0) AS total
  FROM (VALUES('REVENUE'),('COST_OF_SALES'),('EXPENSE'),('OTHER_INCOME'),('OTHER_EXPENSE')) s(k) LEFT JOIN act a ON a.type=s.k GROUP BY s.k)
 SELECT jsonb_build_object('from',p_from,'to',p_to,'currency',v_currency,
  'revenue',(SELECT rows FROM sect WHERE k='REVENUE'),'total_revenue_minor',(SELECT total::text FROM sect WHERE k='REVENUE'),
  'cost_of_sales',(SELECT rows FROM sect WHERE k='COST_OF_SALES'),'total_cost_of_sales_minor',(SELECT total::text FROM sect WHERE k='COST_OF_SALES'),
  'gross_profit_minor',((SELECT total FROM sect WHERE k='REVENUE')-(SELECT total FROM sect WHERE k='COST_OF_SALES'))::text,
  'operating_expenses',(SELECT rows FROM sect WHERE k='EXPENSE'),'total_operating_expenses_minor',(SELECT total::text FROM sect WHERE k='EXPENSE'),
  'operating_income_minor',((SELECT total FROM sect WHERE k='REVENUE')-(SELECT total FROM sect WHERE k='COST_OF_SALES')-(SELECT total FROM sect WHERE k='EXPENSE'))::text,
  'other_income',(SELECT rows FROM sect WHERE k='OTHER_INCOME'),'total_other_income_minor',(SELECT total::text FROM sect WHERE k='OTHER_INCOME'),
  'other_expenses',(SELECT rows FROM sect WHERE k='OTHER_EXPENSE'),'total_other_expenses_minor',(SELECT total::text FROM sect WHERE k='OTHER_EXPENSE'),
  'net_profit_minor',((SELECT total FROM sect WHERE k='REVENUE')-(SELECT total FROM sect WHERE k='COST_OF_SALES')-(SELECT total FROM sect WHERE k='EXPENSE')
   +(SELECT total FROM sect WHERE k='OTHER_INCOME')-(SELECT total FROM sect WHERE k='OTHER_EXPENSE'))::text
 ) INTO v_result;
 RETURN v_result;
END $$;

------------------------------------------------------------------------------------------
-- A4: exchange rates.
------------------------------------------------------------------------------------------
CREATE TABLE ledger.fx_policies(
 id uuid NOT NULL DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid PRIMARY KEY,tolerance_bps integer NOT NULL DEFAULT 200 CHECK(tolerance_bps BETWEEN 0 AND 5000),
 version bigint NOT NULL DEFAULT 1,FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id));
ALTER TABLE ledger.fx_policies ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.fx_policies FORCE ROW LEVEL SECURITY;
CREATE POLICY scoped ON ledger.fx_policies USING(tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
GRANT SELECT ON ledger.fx_policies TO serk_api;
CREATE TRIGGER fx_policies_audit AFTER INSERT OR UPDATE ON ledger.fx_policies FOR EACH ROW EXECUTE FUNCTION audit.record_change();

CREATE FUNCTION ledger.set_fx_tolerance(p_bps integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$
DECLARE r ledger.fx_policies;
BEGIN
 PERFORM security.require('configuration.manage');
 IF p_bps IS NULL OR p_bps NOT BETWEEN 0 AND 5000 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 INSERT INTO ledger.fx_policies(tenant_id,company_id,tolerance_bps) VALUES(security.tenant(),security.company(),p_bps)
 ON CONFLICT(company_id) DO UPDATE SET tolerance_bps=EXCLUDED.tolerance_bps,version=fx_policies.version+1 RETURNING * INTO r;
 RETURN to_jsonb(r);
END $$;

CREATE FUNCTION ledger.recorded_rate(p_currency text,p_date date) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,core,security,pg_temp AS $$
 SELECT exchange_rate FROM core.exchange_rates WHERE company_id=(SELECT security.company()) AND foreign_currency=p_currency
  AND date<=p_date ORDER BY date DESC,created_at DESC LIMIT 1
$$;
REVOKE ALL ON FUNCTION ledger.set_fx_tolerance(integer),ledger.recorded_rate(text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.set_fx_tolerance(integer),ledger.recorded_rate(text,date) TO serk_api;

CREATE FUNCTION ledger.guard_manual_rate() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,core,security,pg_temp AS $$
DECLARE recorded numeric; bps integer;
BEGIN
 IF NEW.source_type='MANUAL' AND NEW.currency<>NEW.functional_currency THEN
  recorded:=ledger.recorded_rate(NEW.currency,NEW.accounting_date);
  IF recorded IS NULL OR recorded<=0 THEN RAISE EXCEPTION 'exchange_rate_not_recorded' USING ERRCODE='23514'; END IF;
  SELECT tolerance_bps INTO bps FROM ledger.fx_policies WHERE company_id=NEW.company_id;
  IF abs(NEW.fx_rate-recorded)*10000>recorded*coalesce(bps,200) THEN RAISE EXCEPTION 'exchange_rate_outside_tolerance' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER ab_manual_rate BEFORE INSERT ON ledger.journals FOR EACH ROW EXECUTE FUNCTION ledger.guard_manual_rate();

-- Rates are positive and recorded against the company's functional currency.
CREATE FUNCTION core.guard_exchange_rate() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,core,organization,pg_temp AS $$
BEGIN
 IF NEW.exchange_rate IS NULL OR NEW.exchange_rate<=0 OR NEW.exchange_rate>=1e12
  OR NEW.base_currency IS DISTINCT FROM (SELECT functional_currency FROM organization.companies WHERE id=NEW.company_id)
  OR NEW.foreign_currency=NEW.base_currency OR NEW.date IS NULL OR NOT isfinite(NEW.date)
 THEN RAISE EXCEPTION 'invalid_exchange_rate' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER aa_valid_rate BEFORE INSERT OR UPDATE ON core.exchange_rates FOR EACH ROW EXECUTE FUNCTION core.guard_exchange_rate();

------------------------------------------------------------------------------------------
-- A5: VAT reporting and tax-rate versions.
------------------------------------------------------------------------------------------
-- Reversal journals carry tax entries of the opposite type (043). Reports interpret any entry
-- on a REVERSAL journal as a negative amount of the original type; stored rows are not altered.
CREATE FUNCTION finance.tax_report(p_from date,p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,taxes,ledger,organization,security,pg_temp AS $$
DECLARE result jsonb; out_acc uuid; in_acc uuid; out_bal numeric; in_bal numeric;
BEGIN
 PERFORM security.require('taxes.read');PERFORM security.require('ledger.read');
 IF p_to IS NULL OR (p_from IS NOT NULL AND p_from>p_to) THEN RAISE EXCEPTION 'invalid_report_parameters' USING ERRCODE='22023'; END IF;
 SELECT (accounts->>'output_tax')::uuid,(accounts->>'input_tax')::uuid INTO out_acc,in_acc FROM finance.settings WHERE company_id=security.company();
 SELECT coalesce(sum(CASE WHEN l.account_id=out_acc THEN l.functional_credit_minor-l.functional_debit_minor END),0),
        coalesce(sum(CASE WHEN l.account_id=in_acc THEN l.functional_debit_minor-l.functional_credit_minor END),0)
 INTO out_bal,in_bal FROM ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id
 WHERE j.state='POSTED' AND l.account_id IN(out_acc,in_acc) AND j.accounting_date<=p_to AND (p_from IS NULL OR j.accounting_date>=p_from);
 WITH e AS (
  SELECT e.tax_rate_id,
   CASE WHEN j.source_type='REVERSAL' THEN CASE e.transaction_type WHEN 'SALE' THEN 'PURCHASE' ELSE 'SALE' END ELSE e.transaction_type END AS kind,
   CASE WHEN j.source_type='REVERSAL' THEN -1 ELSE 1 END AS sign,e.taxable_amount,e.tax_amount
  FROM taxes.tax_entries e JOIN ledger.journals j ON j.id=e.journal_id AND j.state='POSTED'
  WHERE j.accounting_date<=p_to AND (p_from IS NULL OR j.accounting_date>=p_from)),
 by_rate AS (
  SELECT r.id,r.code,r.name,r.rate_percent,
   sum(CASE WHEN e.kind='SALE' THEN e.sign*e.taxable_amount ELSE 0 END) AS sales_taxable,
   sum(CASE WHEN e.kind='SALE' THEN e.sign*e.tax_amount ELSE 0 END) AS output_tax,
   sum(CASE WHEN e.kind='PURCHASE' THEN e.sign*e.taxable_amount ELSE 0 END) AS purchases_taxable,
   sum(CASE WHEN e.kind='PURCHASE' THEN e.sign*e.tax_amount ELSE 0 END) AS input_tax
  FROM e JOIN taxes.tax_rates r ON r.id=e.tax_rate_id GROUP BY r.id,r.code,r.name,r.rate_percent)
 SELECT jsonb_build_object('from',p_from,'to',p_to,'currency',(SELECT functional_currency FROM organization.companies WHERE id=security.company()),
  'rates',coalesce(jsonb_agg(jsonb_build_object('tax_rate_id',id,'code',code,'name',name,'rate_percent',rate_percent::text,
    'sales_taxable_minor',sales_taxable::text,'output_tax_minor',output_tax::text,'purchases_taxable_minor',purchases_taxable::text,'input_tax_minor',input_tax::text) ORDER BY code),'[]'),
  'output_tax_minor',coalesce(sum(output_tax),0)::text,'input_tax_minor',coalesce(sum(input_tax),0)::text,
  'net_tax_payable_minor',(coalesce(sum(output_tax),0)-coalesce(sum(input_tax),0))::text,
  -- Ledger movement on the mapped VAT accounts in the same range, including remittances and
  -- adjustments; the difference to the document totals is what still needs explaining.
  'ledger_output_tax_movement_minor',out_bal::text,'ledger_input_tax_movement_minor',in_bal::text)
 INTO result FROM by_rate;
 RETURN result;
END $$;
CREATE OR REPLACE FUNCTION finance.tax_liability() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$
DECLARE r jsonb;
BEGIN
 r:=finance.tax_report(NULL,current_date);
 RETURN jsonb_build_object('currency',r->>'currency','total_tax_liability',r->>'net_tax_payable_minor');
END $$;
REVOKE ALL ON FUNCTION finance.tax_report(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION finance.tax_report(date,date),finance.tax_liability() TO serk_api;

-- Invoker rights: the check must see every use, which a definer function under FORCE ROW LEVEL
-- SECURITY would not without a session. The runtime role has no UPDATE on tax rates.
CREATE FUNCTION taxes.guard_rate_version() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,taxes,finance,ledger,pg_temp AS $$
DECLARE last_use date;
BEGIN
 SELECT max(d) INTO last_use FROM (
  SELECT j.accounting_date AS d FROM taxes.tax_entries e JOIN ledger.journals j ON j.id=e.journal_id WHERE e.tax_rate_id=OLD.id
  UNION ALL SELECT d.accounting_date FROM finance.documents d,jsonb_array_elements(d.payload->'lines') x
   WHERE d.company_id=OLD.company_id AND d.state<>'VOIDED' AND x->>'tax_rate_id'=OLD.id::text) u;
 IF last_use IS NOT NULL AND ((NEW.rate_percent,NEW.effective_from) IS DISTINCT FROM (OLD.rate_percent,OLD.effective_from)
  OR (NEW.effective_to IS NOT NULL AND NEW.effective_to<last_use))
 THEN RAISE EXCEPTION 'tax_rate_in_use_create_new_version' USING ERRCODE='55000'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER ab_rate_version BEFORE UPDATE ON taxes.tax_rates FOR EACH ROW EXECUTE FUNCTION taxes.guard_rate_version();

------------------------------------------------------------------------------------------
-- A6: payroll accrual date.
------------------------------------------------------------------------------------------
CREATE FUNCTION finance.guard_payroll_accrual() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,pg_temp AS $$
BEGIN
 IF NEW.kind='PAYROLL' AND NEW.accounting_date<>(NEW.payload->>'pay_period_end')::date THEN
  RAISE EXCEPTION 'payroll_accounting_date_must_be_period_end' USING ERRCODE='22023'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER aa_payroll_accrual BEFORE INSERT ON finance.documents FOR EACH ROW EXECUTE FUNCTION finance.guard_payroll_accrual();

------------------------------------------------------------------------------------------
-- A7: purchase returns after stock movement.
------------------------------------------------------------------------------------------
CREATE FUNCTION inventory.guard_bill_return() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,inventory,pg_temp AS $$
DECLARE original inventory.transactions;
BEGIN
 IF NEW.reference_type='BILL_REVERSAL' THEN
  SELECT * INTO original FROM inventory.transactions WHERE reference_type='BILL' AND reference_id=NEW.reference_id AND item_id=NEW.item_id ORDER BY created_at,id LIMIT 1;
  IF FOUND AND EXISTS(SELECT FROM inventory.transactions t WHERE t.item_id=NEW.item_id AND (t.created_at,t.id)>(original.created_at,original.id)) THEN
   RAISE EXCEPTION 'stock_moved_since_bill_use_inventory_adjustment' USING ERRCODE='55000'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER aa_bill_return BEFORE INSERT ON inventory.transactions FOR EACH ROW EXECUTE FUNCTION inventory.guard_bill_return();

------------------------------------------------------------------------------------------
-- Settings: retained earnings mapping.
------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION finance.configure(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,ledger,security,pg_temp AS $$ DECLARE k text;v text;types text[];BEGIN
 PERFORM security.require('configuration.manage'); PERFORM security.require('ledger.read');
 IF jsonb_typeof(p)<>'object' THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 FOR k,v IN SELECT * FROM jsonb_each_text(p) LOOP
  IF k='cash_accounts' THEN
   IF jsonb_typeof(p->k) IS DISTINCT FROM 'array' OR jsonb_array_length(p->k) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'cash_account_configuration_required' USING ERRCODE='23514'; END IF;
   PERFORM finance.account(x::uuid,ARRAY['ASSET']) FROM jsonb_array_elements_text(p->k) x;
   IF EXISTS(SELECT FROM ledger.accounts WHERE id IN(SELECT x::uuid FROM jsonb_array_elements_text(p->k) x) AND control_account) THEN RAISE EXCEPTION 'cash_account_configuration_required' USING ERRCODE='23514'; END IF;
   IF EXISTS(SELECT FROM jsonb_array_elements_text(p->k) x WHERE x IN(p->>'receivable',p->>'input_tax')) THEN RAISE EXCEPTION 'invalid_account_mapping' USING ERRCODE='23514'; END IF;
   IF EXISTS(SELECT FROM jsonb_array_elements_text(p->k) x JOIN finance.control_accounts c ON c.account_id=x::uuid) THEN RAISE EXCEPTION 'invalid_account_mapping' USING ERRCODE='23514'; END IF;
   CONTINUE;
  END IF;
  types:=CASE k WHEN 'receivable' THEN ARRAY['ASSET'] WHEN 'payable' THEN ARRAY['LIABILITY']
   WHEN 'output_tax' THEN ARRAY['LIABILITY'] WHEN 'input_tax' THEN ARRAY['ASSET']
   WHEN 'opening_equity' THEN ARRAY['EQUITY'] WHEN 'retained_earnings' THEN ARRAY['EQUITY'] WHEN 'payroll_expense' THEN ARRAY['EXPENSE']
   WHEN 'payroll_payable' THEN ARRAY['LIABILITY'] WHEN 'payroll_tax' THEN ARRAY['LIABILITY']
   WHEN 'pension_expense' THEN ARRAY['EXPENSE'] WHEN 'pension_payable' THEN ARRAY['LIABILITY'] END;
  IF types IS NULL THEN RAISE EXCEPTION 'invalid_account_mapping' USING ERRCODE='22023'; END IF;
  PERFORM finance.account(v::uuid,types);
  IF k IN('receivable','payable','input_tax','output_tax','payroll_payable','payroll_tax','pension_payable') THEN INSERT INTO finance.control_accounts VALUES(security.tenant(),security.company(),k,v::uuid) ON CONFLICT DO NOTHING; END IF;
 END LOOP;
 INSERT INTO finance.settings(tenant_id,company_id,accounts) VALUES(security.tenant(),security.company(),p)
 ON CONFLICT(company_id) DO UPDATE SET accounts=EXCLUDED.accounts,version=finance.settings.version+1;
 RETURN jsonb_build_object('accounts',p);
END $$;
