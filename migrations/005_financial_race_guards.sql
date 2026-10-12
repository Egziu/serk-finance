-- Serialize interpretation changes with creation; preserve the original migration files.
SET LOCAL ROLE serk_owner;
CREATE OR REPLACE FUNCTION ledger.create_journal(p jsonb,p_original uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 DECLARE jid uuid:=gen_random_uuid(); cid uuid:=security.company(); tid uuid:=security.tenant();
 b uuid:=(p->>'branch_id')::uuid;dt date:=(p->>'accounting_date')::date;per ledger.periods; original ledger.journals;
 fyname text; sn bigint;pref text;curr text;fc text;rate numeric;te integer;fe integer;item jsonb;dim jsonb;ln integer:=0;
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
  b:=original.branch_id;curr:=original.currency;rate:=original.fx_rate;fc:=original.functional_currency;
 END IF;
 SELECT minor_units INTO STRICT te FROM organization.currencies WHERE code=curr FOR SHARE;
 SELECT minor_units INTO STRICT fe FROM organization.currencies WHERE code=fc FOR SHARE;
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

CREATE FUNCTION security.release_version() RETURNS text LANGUAGE sql IMMUTABLE
 SET search_path=pg_catalog,pg_temp AS $$ SELECT '0.2.0-rc1'::text $$;
GRANT EXECUTE ON FUNCTION security.release_version() TO serk_api,serk_auth;
