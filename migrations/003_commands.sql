SET LOCAL ROLE serk_owner;
CREATE FUNCTION security.has(p_permission text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT EXISTS(SELECT FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=security.company() AND m.user_id=security.actor() AND rp.permission=p_permission)
$$;
GRANT EXECUTE ON FUNCTION security.has(text) TO serk_api;
CREATE POLICY account_permission ON ledger.accounts AS RESTRICTIVE USING(security.has('ledger.read'));
CREATE POLICY period_permission ON ledger.periods AS RESTRICTIVE USING(security.has('ledger.read'));
CREATE POLICY year_permission ON ledger.fiscal_years AS RESTRICTIVE USING(security.has('ledger.read'));
CREATE POLICY dimension_permission ON ledger.dimensions AS RESTRICTIVE USING(security.has('ledger.read'));

CREATE FUNCTION ledger.get_journal(p_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE j ledger.journals; result jsonb;
 BEGIN
 SELECT * INTO j FROM ledger.journals WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 PERFORM security.require('ledger.read',j.branch_id);
 SELECT to_jsonb(j)||jsonb_build_object('effective_state',CASE WHEN EXISTS(SELECT FROM ledger.journals r WHERE r.reversed_from=j.id AND r.state='POSTED') THEN 'REVERSED' ELSE j.state END,
 'fx_rate',j.fx_rate::text,'lines',coalesce((SELECT jsonb_agg(jsonb_build_object('line_no',l.line_no,'account_id',l.account_id,
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

CREATE FUNCTION ledger.create_journal(p jsonb,p_original uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 DECLARE jid uuid:=gen_random_uuid(); cid uuid:=security.company(); tid uuid:=security.tenant();
 b uuid:=(p->>'branch_id')::uuid;dt date:=(p->>'accounting_date')::date;per ledger.periods; original ledger.journals;
 fyname text; sn bigint;pref text;curr text;fc text;rate numeric;te integer;fe integer;item jsonb;dim jsonb;ln integer:=0;
 BEGIN
 PERFORM security.require('journal.create',b);
 IF length(btrim(coalesce(p->>'description','')))<1 OR length(btrim(coalesce(p->>'reason','')))<3 THEN RAISE EXCEPTION 'description_and_reason_required' USING ERRCODE='22023'; END IF;
 SELECT * INTO STRICT per FROM ledger.periods WHERE company_id=cid AND dt BETWEEN start_date AND end_date;
 IF per.state<>'OPEN' THEN RAISE EXCEPTION 'period_not_open' USING ERRCODE='55000'; END IF;
 SELECT name INTO fyname FROM ledger.fiscal_years WHERE id=per.fiscal_year_id;
 INSERT INTO ledger.numbering(tenant_id,company_id,fiscal_year_id,document_type) VALUES(tid,cid,per.fiscal_year_id,'JOURNAL') ON CONFLICT DO NOTHING;
 UPDATE ledger.numbering SET next_value=next_value+1 WHERE company_id=cid AND fiscal_year_id=per.fiscal_year_id AND document_type='JOURNAL'
 RETURNING next_value-1,prefix INTO sn,pref;
 SELECT functional_currency INTO fc FROM organization.companies WHERE id=cid;
 curr:=p->>'currency';rate:=(p->>'fx_rate')::numeric;
 IF p_original IS NOT NULL THEN
  SELECT * INTO STRICT original FROM ledger.journals WHERE id=p_original FOR UPDATE;
  IF original.state<>'POSTED' THEN RAISE EXCEPTION 'only_posted_can_reverse' USING ERRCODE='55000'; END IF;
  b:=original.branch_id;curr:=original.currency;rate:=original.fx_rate;fc:=original.functional_currency;
 END IF;
 SELECT minor_units INTO STRICT te FROM organization.currencies WHERE code=curr;
 SELECT minor_units INTO STRICT fe FROM organization.currencies WHERE code=fc;
 INSERT INTO ledger.journals(id,tenant_id,company_id,branch_id,period_id,accounting_date,number,sequence_no,description,currency,functional_currency,
 fx_rate,created_by,reversed_from,reason,source_type) VALUES(jid,tid,cid,b,per.id,dt,
 pref||'-'||fyname||'-'||lpad(sn::text,greatest(6,length(sn::text)),'0'),sn,p->>'description',curr,fc,rate,security.actor(),p_original,p->>'reason',
 CASE WHEN p_original IS NULL THEN 'MANUAL' ELSE 'REVERSAL' END);
 IF p_original IS NOT NULL THEN
  INSERT INTO ledger.lines SELECT tid,cid,jid,line_no,account_id,description,credit_minor,debit_minor,functional_credit_minor,functional_debit_minor
   FROM ledger.lines WHERE journal_id=p_original;
  INSERT INTO ledger.line_dimensions SELECT tid,cid,jid,line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=p_original;
 ELSE
  IF jsonb_typeof(p->'lines')<>'array' OR jsonb_array_length(p->'lines') NOT BETWEEN 2 AND 500 THEN RAISE EXCEPTION 'invalid_lines' USING ERRCODE='22023'; END IF;
  FOR item IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
   ln:=ln+1;
   INSERT INTO ledger.lines VALUES(tid,cid,jid,ln,(item->>'account_id')::uuid,coalesce(item->>'description',''),
    (item->>'debit_minor')::numeric,(item->>'credit_minor')::numeric,
    round((item->>'debit_minor')::numeric*rate*power(10::numeric,fe-te)),round((item->>'credit_minor')::numeric*rate*power(10::numeric,fe-te)));
   FOR dim IN SELECT * FROM jsonb_array_elements(coalesce(item->'dimensions','[]'::jsonb)) LOOP
    INSERT INTO ledger.line_dimensions VALUES(tid,cid,jid,ln,dim->>'kind',(dim->>'dimension_id')::uuid);
   END LOOP;
  END LOOP;
 END IF;
 PERFORM ledger.validate(jid);
 RETURN jid;
 EXCEPTION WHEN NO_DATA_FOUND THEN RAISE EXCEPTION 'invalid_reference_or_period' USING ERRCODE='22023';
 END $$;

CREATE FUNCTION ledger.command(p_key text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE h text; prior ledger.idempotency; jid uuid; j ledger.journals; response jsonb;newstate text;
 BEGIN
 IF security.actor() IS NULL OR security.company() IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'idempotency_key_required' USING ERRCODE='22023'; END IF;
 h:=encode(sha256(convert_to(jsonb_build_object('action',p_action,'payload',p)::text,'UTF8')),'hex');
 -- Serialized per actor/company/key; the durable receipt commits with the journal.
 PERFORM pg_advisory_xact_lock(hashtextextended(security.company()::text||security.actor()::text||p_key,0));
 SELECT * INTO prior FROM ledger.idempotency WHERE company_id=security.company() AND user_id=security.actor() AND key=p_key;
 IF FOUND THEN
  IF prior.request_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='22000'; END IF;
  PERFORM ledger.get_journal((prior.response->>'id')::uuid); -- Reauthorize replay after membership changes.
  RETURN prior.response;
 END IF;
 IF p_action='create' THEN jid:=ledger.create_journal(p);
 ELSE
  jid:=(p->>'id')::uuid;
  SELECT * INTO j FROM ledger.journals WHERE id=jid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  IF j.version IS DISTINCT FROM (p->>'expected_version')::bigint THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
  IF length(btrim(coalesce(p->>'reason','')))<3 THEN RAISE EXCEPTION 'reason_required' USING ERRCODE='22023'; END IF;
  IF p_action='reverse' THEN
   PERFORM security.require('journal.reverse',j.branch_id);
   jid:=ledger.create_journal(jsonb_build_object('branch_id',j.branch_id,'accounting_date',p->>'accounting_date',
    'description','Reversal of '||j.number||': '||(p->>'reason'),'reason',p->>'reason'),j.id);
  ELSE
   newstate:=CASE p_action WHEN 'submit' THEN 'SUBMITTED' WHEN 'approve' THEN 'APPROVED' WHEN 'post' THEN 'POSTED' WHEN 'void' THEN 'VOIDED' END;
   IF newstate IS NULL THEN RAISE EXCEPTION 'invalid_action' USING ERRCODE='22023'; END IF;
   UPDATE ledger.journals SET state=newstate,version=version+1,reason=p->>'reason' WHERE id=jid;
  END IF;
 END IF;
 response:=ledger.get_journal(jid);
 INSERT INTO ledger.idempotency(tenant_id,company_id,user_id,key,request_hash,response) VALUES(security.tenant(),security.company(),security.actor(),p_key,h,response);
 RETURN response;
 END $$;
GRANT EXECUTE ON FUNCTION ledger.command(text,text,jsonb),ledger.get_journal(uuid) TO serk_api;

CREATE FUNCTION ledger.list_journals(p_limit integer DEFAULT 50,p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL,p_state text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE result jsonb;
 BEGIN
 IF NOT security.has('ledger.read') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 IF p_limit NOT BETWEEN 1 AND 100 OR (p_before IS NULL)<>(p_before_id IS NULL) THEN RAISE EXCEPTION 'invalid_pagination' USING ERRCODE='22023'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC,s.id DESC),'[]'::jsonb) INTO result FROM (
 SELECT j.id,j.number,j.description,j.accounting_date,j.currency,j.state,j.version,j.created_at,
 CASE WHEN EXISTS(SELECT FROM ledger.journals r WHERE r.reversed_from=j.id AND r.state='POSTED') THEN 'REVERSED' ELSE j.state END effective_state,
 (SELECT sum(l.debit_minor)::text FROM ledger.lines l WHERE l.journal_id=j.id) debit_minor
 FROM ledger.journals j WHERE (p_before IS NULL OR (j.created_at,j.id)<(p_before,p_before_id)) AND (p_state IS NULL OR j.state=p_state)
 ORDER BY j.created_at DESC,j.id DESC LIMIT p_limit) s;
 RETURN result;
 END $$;
CREATE FUNCTION ledger.trial_balance(p_as_of date,p_from date DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 DECLARE result jsonb;
 BEGIN
 IF NOT security.has('ledger.read') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 IF p_as_of IS NULL OR (p_from IS NOT NULL AND p_from>p_as_of) THEN RAISE EXCEPTION 'invalid_dates' USING ERRCODE='22023'; END IF;
 SELECT jsonb_build_object('as_of',p_as_of,'from',p_from,'currency',(SELECT functional_currency FROM organization.companies WHERE id=security.company()),
 'rows',coalesce(jsonb_agg(jsonb_build_object('account_id',s.id,'code',s.code,'name',s.name,'type',s.type,'normal_balance',s.normal_balance,
 'debit_minor',s.dr::text,'credit_minor',s.cr::text,'net_debit_minor',(s.dr-s.cr)::text) ORDER BY s.code),'[]'::jsonb),
 'debit_minor',coalesce(sum(s.dr),0)::text,'credit_minor',coalesce(sum(s.cr),0)::text) INTO result FROM (
 SELECT a.id,a.code,a.name,a.type,a.normal_balance,coalesce(sum(l.functional_debit_minor),0) dr,coalesce(sum(l.functional_credit_minor),0) cr
 FROM ledger.accounts a LEFT JOIN (ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id AND j.state='POSTED'
 AND j.accounting_date<=p_as_of AND (p_from IS NULL OR j.accounting_date>=p_from)) ON l.account_id=a.id
 GROUP BY a.id,a.code,a.name,a.type,a.normal_balance) s;
 RETURN result;
 END $$;
CREATE FUNCTION ledger.reference_data() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 BEGIN
 IF NOT security.has('ledger.read') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('accounts',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY code) FROM ledger.accounts a),'[]'::jsonb),
 'branches',coalesce((SELECT jsonb_agg(to_jsonb(b) ORDER BY code) FROM organization.branches b),'[]'::jsonb),
 'periods',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY start_date) FROM ledger.periods p),'[]'::jsonb),
 'dimensions',coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY kind,code) FROM ledger.dimensions d),'[]'::jsonb),
 'currencies',(SELECT jsonb_agg(to_jsonb(c) ORDER BY code) FROM organization.currencies c),
 'permissions',jsonb_build_object('create',security.has('journal.create'),'audit',security.has('audit.read'),'close',security.can('period.close')));
 END $$;
CREATE FUNCTION audit.list_events(p_after bigint DEFAULT 0,p_limit integer DEFAULT 100) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,audit,security,pg_temp AS $$
 DECLARE result jsonb;
 BEGIN
 PERFORM security.require('audit.read');
 IF p_limit NOT BETWEEN 1 AND 100 OR p_after<0 THEN RAISE EXCEPTION 'invalid_pagination' USING ERRCODE='22023'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.sequence_no),'[]'::jsonb) INTO result FROM
 (SELECT * FROM audit.events WHERE sequence_no>p_after ORDER BY sequence_no LIMIT p_limit) e;
 RETURN result;
 END $$;

CREATE FUNCTION ledger.guard_period() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE fy ledger.fiscal_years;
 BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'period_delete_forbidden' USING ERRCODE='55000'; END IF;
 IF TG_OP='UPDATE' THEN
  IF (to_jsonb(OLD)-ARRAY['state','version']) IS DISTINCT FROM (to_jsonb(NEW)-ARRAY['state','version'])
   OR NOT ((OLD.state='OPEN' AND NEW.state IN ('SOFT_CLOSED','CLOSED')) OR (OLD.state='SOFT_CLOSED' AND NEW.state='CLOSED') OR (OLD.state='CLOSED' AND NEW.state='LOCKED'))
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
CREATE TRIGGER guard_period BEFORE INSERT OR UPDATE OR DELETE ON ledger.periods FOR EACH ROW EXECUTE FUNCTION ledger.guard_period();
CREATE TRIGGER audit_period AFTER UPDATE ON ledger.periods FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE FUNCTION ledger.close_period(p_id uuid,p_version bigint,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE p ledger.periods;
 BEGIN
 PERFORM security.require('period.close');
 IF length(btrim(coalesce(p_reason,'')))<3 THEN RAISE EXCEPTION 'reason_required' USING ERRCODE='22023'; END IF;
 SELECT * INTO p FROM ledger.periods WHERE id=p_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 IF p.version<>p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
 PERFORM set_config('serk.request_context',(coalesce(nullif(current_setting('serk.request_context',true),'')::jsonb,'{}'::jsonb)||jsonb_build_object('reason',p_reason))::text,true);
 UPDATE ledger.periods SET state='CLOSED',version=version+1 WHERE id=p_id RETURNING * INTO p;
 RETURN to_jsonb(p);
 END $$;
GRANT EXECUTE ON FUNCTION ledger.list_journals(integer,timestamptz,uuid,text),ledger.trial_balance(date,date),ledger.reference_data(),
 audit.list_events(bigint,integer),ledger.close_period(uuid,bigint,text) TO serk_api;
