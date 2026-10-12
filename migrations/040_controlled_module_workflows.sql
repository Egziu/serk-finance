-- All financial module writes pass through the existing ledger command engine.
CREATE SCHEMA finance AUTHORIZATION serk_owner;
SET LOCAL ROLE serk_owner;
GRANT USAGE ON SCHEMA finance TO serk_api;

CREATE TABLE finance.settings(
 id uuid NOT NULL DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL, company_id uuid PRIMARY KEY, accounts jsonb NOT NULL DEFAULT '{}',
 version bigint NOT NULL DEFAULT 1,
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id));
CREATE TABLE finance.documents(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN('INVOICE','BILL','OPENING','PAYROLL')),
 state text NOT NULL DEFAULT 'DRAFT' CHECK(state IN('DRAFT','SUBMITTED','APPROVED','PAID','VOIDED')),
 version bigint NOT NULL DEFAULT 1,branch_id uuid NOT NULL,document_no text NOT NULL,
 accounting_date date NOT NULL,due_date date NOT NULL,currency text NOT NULL,
 counterparty_id uuid,control_account_id uuid,created_by uuid NOT NULL,submitted_by uuid,approved_by uuid,
 subtotal ledger.minor NOT NULL,tax_total ledger.minor NOT NULL,total_amount ledger.minor NOT NULL,
 payload jsonb NOT NULL,journal_id uuid,payment_journal_id uuid,
 reversal_journal_id uuid,reversal_payment_journal_id uuid,reversal_by uuid,reversal_state text,
 payment_state text CHECK(payment_state IN('SUBMITTED','POSTED')),payment_by uuid,
 payment_date date,payment_account_id uuid,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,company_id,branch_id) REFERENCES organization.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,created_by) REFERENCES security.users(tenant_id,id),
 FOREIGN KEY(tenant_id,company_id,control_account_id) REFERENCES ledger.accounts(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,company_id,journal_id) REFERENCES ledger.journals(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,company_id,payment_journal_id) REFERENCES ledger.journals(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,company_id,payment_account_id) REFERENCES ledger.accounts(tenant_id,company_id,id),
 UNIQUE(company_id,kind,document_no),UNIQUE(tenant_id,company_id,id),CHECK(due_date>=accounting_date));
CREATE INDEX finance_document_scope ON finance.documents(company_id,kind,created_at DESC,id);
CREATE TABLE finance.item_usage(tenant_id uuid NOT NULL,company_id uuid NOT NULL,item_id uuid NOT NULL,document_id uuid NOT NULL,
 PRIMARY KEY(item_id,document_id),FOREIGN KEY(tenant_id,company_id,item_id) REFERENCES inventory.items(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,company_id,document_id) REFERENCES finance.documents(tenant_id,company_id,id));
CREATE TABLE finance.control_accounts(tenant_id uuid NOT NULL,company_id uuid NOT NULL,purpose text NOT NULL,account_id uuid NOT NULL,
 PRIMARY KEY(company_id,purpose,account_id),FOREIGN KEY(tenant_id,company_id,account_id) REFERENCES ledger.accounts(tenant_id,company_id,id));
CREATE TABLE finance.receipts(
 tenant_id uuid NOT NULL,company_id uuid NOT NULL,user_id uuid NOT NULL,key text NOT NULL,
 request_hash text NOT NULL,response jsonb NOT NULL,PRIMARY KEY(company_id,user_id,key),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id));
CREATE TABLE finance.positions(
 tenant_id uuid NOT NULL,company_id uuid NOT NULL,item_id uuid PRIMARY KEY,
 quantity numeric NOT NULL DEFAULT 0 CHECK(quantity>=0 AND quantity<1e20 AND scale(quantity)<=6),
 last_accounting_date date,value_minor ledger.minor NOT NULL DEFAULT 0,reserved_quantity numeric NOT NULL DEFAULT 0,
 reserved_minor ledger.minor NOT NULL DEFAULT 0,
 FOREIGN KEY(tenant_id,company_id,item_id) REFERENCES inventory.items(tenant_id,company_id,id),
 CHECK(reserved_quantity>=0 AND reserved_quantity<=quantity AND reserved_minor<=value_minor),
 CHECK(quantity>0 OR value_minor=0));

ALTER TABLE taxes.tax_rates ADD COLUMN effective_to date;
ALTER TABLE payroll.employees ADD COLUMN branch_id uuid;
ALTER TABLE payroll.employees ADD FOREIGN KEY(tenant_id,company_id,branch_id) REFERENCES organization.branches(tenant_id,company_id,id);
ALTER TABLE payroll.payruns ADD COLUMN document_id uuid UNIQUE;
ALTER TABLE payroll.payruns ADD FOREIGN KEY(tenant_id,company_id,document_id) REFERENCES finance.documents(tenant_id,company_id,id);
ALTER TABLE payroll.pay_slips ADD COLUMN employee_pension_minor ledger.minor NOT NULL DEFAULT 0;
ALTER TABLE payroll.pay_slips ADD COLUMN employer_pension_minor ledger.minor NOT NULL DEFAULT 0;

CREATE TABLE finance.payroll_policies(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,
 name text NOT NULL,effective_from date NOT NULL,effective_to date,
 rules jsonb NOT NULL,created_by uuid NOT NULL,approved_by uuid,version bigint NOT NULL DEFAULT 1,
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,created_by) REFERENCES security.users(tenant_id,id),
 CHECK(effective_to IS NULL OR effective_to>=effective_from),
 CHECK(approved_by IS NULL OR approved_by<>created_by),UNIQUE(tenant_id,company_id,id));

DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['finance.settings','finance.documents','finance.receipts','finance.positions','finance.payroll_policies','finance.item_usage','finance.control_accounts'] LOOP
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY scoped ON %s USING(tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()))',t);
 END LOOP;
END $$;
CREATE POLICY branch_scope ON finance.documents AS RESTRICTIVE USING(security.visible_branch(branch_id));
CREATE POLICY employee_branch ON payroll.employees AS RESTRICTIVE USING(security.visible_branch(branch_id));
-- Company-wide reads are required for shared master data/stock valuations.
CREATE POLICY position_access ON finance.positions AS RESTRICTIVE USING(security.can('inventory.read'));
GRANT SELECT ON finance.documents,finance.positions TO serk_api;
CREATE TRIGGER finance_documents_audit AFTER INSERT OR UPDATE ON finance.documents FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER finance_settings_audit AFTER INSERT OR UPDATE ON finance.settings FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER finance_policy_audit AFTER INSERT OR UPDATE ON finance.payroll_policies FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER immutable_stock BEFORE UPDATE OR DELETE ON inventory.transactions FOR EACH ROW EXECUTE FUNCTION ledger.block_mutation();

-- A prior quantity-only stock balance cannot be assigned an invented value.
DO $$ BEGIN
 IF EXISTS(SELECT item_id FROM inventory.transactions GROUP BY item_id HAVING sum(quantity)<>0)
 THEN RAISE EXCEPTION 'legacy_inventory_requires_reconciliation' USING ERRCODE='55000'; END IF;
END $$;

CREATE FUNCTION finance.permission(p_kind text) RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT CASE p_kind WHEN 'INVOICE' THEN 'sales' WHEN 'BILL' THEN 'purchases' WHEN 'OPENING' THEN 'inventory' WHEN 'PAYROLL' THEN 'payroll' END $$;
CREATE FUNCTION finance.amount(p text) RETURNS numeric LANGUAGE plpgsql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ BEGIN
 IF p IS NULL OR p !~ '^(0|[1-9][0-9]{0,27})$' OR p::numeric>=1e28
 THEN RAISE EXCEPTION 'invalid_amount' USING ERRCODE='22023'; END IF; RETURN p::numeric;
END $$;
CREATE FUNCTION finance.account(p_id uuid,p_types text[]) RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$ BEGIN
 IF p_id IS NULL OR NOT EXISTS(SELECT FROM ledger.accounts WHERE id=p_id AND tenant_id=security.tenant()
 AND company_id=security.company() AND active AND posting_allowed AND type=ANY(p_types))
 THEN RAISE EXCEPTION 'account_configuration_required' USING ERRCODE='23514'; END IF; RETURN p_id;
END $$;
CREATE FUNCTION finance.mapped(p_key text,p_types text[]) RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,pg_temp AS $$ DECLARE a uuid; BEGIN
 SELECT (accounts->>p_key)::uuid INTO a FROM finance.settings WHERE company_id=security.company();
 RETURN finance.account(a,p_types);
END $$;
CREATE FUNCTION finance.cash_account(p_id uuid) RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,ledger,security,pg_temp AS $$ BEGIN
 PERFORM finance.account(p_id,ARRAY['ASSET']);
 IF NOT EXISTS(SELECT FROM finance.settings s,jsonb_array_elements_text(s.accounts->'cash_accounts') x
 WHERE s.company_id=security.company() AND x::uuid=p_id)
 THEN RAISE EXCEPTION 'cash_account_configuration_required' USING ERRCODE='23514'; END IF;RETURN p_id;
END $$;
CREATE FUNCTION finance.line(p_account uuid,p_debit numeric,p_credit numeric) RETURNS jsonb LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT jsonb_build_object('account_id',p_account,'debit_minor',p_debit::text,'credit_minor',p_credit::text) $$;

CREATE FUNCTION finance.configure(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
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
   WHEN 'opening_equity' THEN ARRAY['EQUITY'] WHEN 'payroll_expense' THEN ARRAY['EXPENSE']
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
CREATE FUNCTION finance.get_settings() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$ BEGIN
 PERFORM security.require('ledger.read'); RETURN coalesce((SELECT jsonb_build_object('accounts',accounts,'version',version) FROM finance.settings WHERE company_id=security.company()),'{"accounts":{}}'::jsonb);
END $$;

CREATE FUNCTION finance.create_master(p_kind text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,invoicing,inventory,payroll,taxes,ledger,security,pg_temp AS $$
DECLARE id uuid;perm text;b uuid;v numeric;BEGIN
 perm:=CASE p_kind WHEN 'CUSTOMER' THEN 'sales' WHEN 'VENDOR' THEN 'purchases' WHEN 'ITEM' THEN 'inventory'
 WHEN 'EMPLOYEE' THEN 'payroll' WHEN 'AGENCY' THEN 'taxes' WHEN 'RATE' THEN 'taxes' END;
 IF perm IS NULL THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM security.require(perm||'.manage'); PERFORM security.require(perm||'.read');
 IF p_kind='CUSTOMER' THEN
  IF length(btrim(coalesce(p->>'name',''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_name' USING ERRCODE='22023'; END IF;
  INSERT INTO invoicing.customers(tenant_id,company_id,name,email,phone,address,tax_id) VALUES(security.tenant(),security.company(),p->>'name',p->>'email',p->>'phone',p->>'address',p->>'tax_id') RETURNING customers.id INTO id;
 ELSIF p_kind='VENDOR' THEN
  IF length(btrim(coalesce(p->>'name',''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_name' USING ERRCODE='22023'; END IF;
  INSERT INTO invoicing.vendors(tenant_id,company_id,name,email,phone,address,tax_id) VALUES(security.tenant(),security.company(),p->>'name',p->>'email',p->>'phone',p->>'address',p->>'tax_id') RETURNING vendors.id INTO id;
 ELSIF p_kind='ITEM' THEN
  IF coalesce(p->>'initial_quantity','0')::numeric<>0 THEN RAISE EXCEPTION 'use_controlled_stock_opening' USING ERRCODE='22023'; END IF;
  IF p->>'type' NOT IN('PRODUCT','SERVICE') OR length(btrim(coalesce(p->>'name',''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  IF nullif(p->>'income_account_id','') IS NOT NULL THEN PERFORM finance.account((p->>'income_account_id')::uuid,ARRAY['REVENUE','OTHER_INCOME']); END IF;
  IF nullif(p->>'expense_account_id','') IS NOT NULL THEN PERFORM finance.account((p->>'expense_account_id')::uuid,ARRAY['EXPENSE','COST_OF_SALES']); END IF;
  IF nullif(p->>'asset_account_id','') IS NOT NULL THEN PERFORM finance.account((p->>'asset_account_id')::uuid,ARRAY['ASSET']); END IF;
  INSERT INTO inventory.items(tenant_id,company_id,type,name,sku,description,unit_price,cost_price,income_account_id,expense_account_id,asset_account_id)
  VALUES(security.tenant(),security.company(),p->>'type',p->>'name',nullif(p->>'sku',''),p->>'description',finance.amount(coalesce(p->>'unit_price','0')),finance.amount(coalesce(p->>'cost_price','0')),
  nullif(p->>'income_account_id','')::uuid,nullif(p->>'expense_account_id','')::uuid,nullif(p->>'asset_account_id','')::uuid) RETURNING items.id INTO id;
  INSERT INTO finance.positions(tenant_id,company_id,item_id) VALUES(security.tenant(),security.company(),id);
 ELSIF p_kind='EMPLOYEE' THEN
  b:=(p->>'branch_id')::uuid;PERFORM security.require('ledger.read',b);
  IF b IS NULL OR NOT EXISTS(SELECT FROM organization.branches WHERE organization.branches.id=b AND company_id=security.company() AND active)
  OR length(btrim(coalesce(p->>'first_name',''))) NOT BETWEEN 1 AND 100 OR length(btrim(coalesce(p->>'last_name',''))) NOT BETWEEN 1 AND 100
  THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  INSERT INTO payroll.employees(tenant_id,company_id,branch_id,first_name,last_name,email,department,salary_amount,pay_frequency)
  VALUES(security.tenant(),security.company(),b,p->>'first_name',p->>'last_name',p->>'email',p->>'department',finance.amount(p->>'salary_amount'),p->>'pay_frequency') RETURNING employees.id INTO id;
 ELSIF p_kind='AGENCY' THEN
  INSERT INTO taxes.tax_agencies(tenant_id,company_id,name,code) VALUES(security.tenant(),security.company(),p->>'name',p->>'code') RETURNING tax_agencies.id INTO id;
 ELSE
  v:=(p->>'rate_percent')::numeric;
  INSERT INTO taxes.tax_rates(tenant_id,company_id,agency_id,name,code,rate_percent,effective_from,effective_to)
  VALUES(security.tenant(),security.company(),(p->>'agency_id')::uuid,p->>'name',p->>'code',v,(p->>'effective_from')::date,nullif(p->>'effective_to','')::date) RETURNING tax_rates.id INTO id;
 END IF;
 RETURN jsonb_build_object('id',id);
END $$;

CREATE FUNCTION ledger.command_internal(p_key text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
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
REVOKE EXECUTE ON FUNCTION ledger.command_internal(text,text,jsonb) FROM PUBLIC,serk_api,serk_auth;
CREATE OR REPLACE FUNCTION ledger.command(p_key text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,finance,security,pg_temp AS $$ BEGIN
 IF p_action<>'create' AND EXISTS(SELECT FROM finance.documents WHERE journal_id=(p->>'id')::uuid OR payment_journal_id=(p->>'id')::uuid)
 THEN RAISE EXCEPTION 'use_module_workflow' USING ERRCODE='55000'; END IF;
 RETURN ledger.command_internal(p_key,p_action,p);
END $$;
CREATE FUNCTION ledger.create_module_journal(p jsonb,p_original uuid DEFAULT NULL) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
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
 CASE WHEN p_original IS NULL THEN 'SYSTEM' ELSE 'REVERSAL' END);
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

CREATE FUNCTION ledger.module_command(p_key text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
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
 IF p_action='create' THEN jid:=ledger.create_module_journal(p);
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
REVOKE EXECUTE ON FUNCTION ledger.create_module_journal(jsonb,uuid),ledger.module_command(text,text,jsonb) FROM PUBLIC,serk_api,serk_auth;
CREATE FUNCTION finance.assert_clean() RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$ BEGIN
 IF NOT (ledger.integrity_status()->>'ok')::boolean THEN RAISE EXCEPTION 'ledger_reconciliation_required' USING ERRCODE='55000'; END IF;
END $$;
CREATE FUNCTION finance.document_command(p_key text,p_kind text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,ledger,invoicing,inventory,payroll,taxes,organization,security,pg_temp AS $$
DECLARE control_account uuid;perm text:=finance.permission(p_kind);hash text;prior finance.receipts;d finance.documents;
 id uuid;b uuid;dt date;due date;party uuid;curr text;item inventory.items;pos finance.positions;line jsonb;norm jsonb:='[]';
 qty numeric;price numeric;amount numeric;tax numeric;rate numeric;sub numeric:=0;taxes_total numeric:=0;
 entry_lines jsonb:='[]';jn jsonb;account uuid;cost numeric;mode text;no text;result jsonb;freq text;ps date;pe date;
 emp payroll.employees;policy finance.payroll_policies;slips jsonb:='[]';gross numeric:=0;net numeric:=0;
 deductions numeric:=0;pension_emp numeric:=0;pension_er numeric:=0;one_tax numeric;one_ep numeric;one_er numeric;bracket jsonb;
 payrun uuid;paydate date;payment uuid;
BEGIN
 IF perm IS NULL OR p_action NOT IN('create','submit','approve','pay','pay-approve','void') OR jsonb_typeof(p)<>'object' THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM security.require(perm||'.read');PERFORM security.require(perm||'.manage');
 IF EXISTS(SELECT FROM jsonb_object_keys(p) k WHERE k NOT IN('branch_id','accounting_date','due_date','settlement_type','payment_account_id','invoice_number','bill_number','document_number','payrun_number','customer_id','vendor_id','lines','pay_frequency','pay_period_start','pay_period_end','policy_id','id','expected_version','reason'))
 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'idempotency_key_required' USING ERRCODE='22023'; END IF;
 hash:=encode(sha256(convert_to(jsonb_build_object('kind',p_kind,'action',p_action,'payload',p)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(security.company()::text||security.actor()::text||p_key,0));
 SELECT * INTO prior FROM finance.receipts WHERE company_id=security.company() AND user_id=security.actor() AND key=p_key;
 IF FOUND THEN
  IF prior.request_hash<>hash THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='22000'; END IF;
  SELECT * INTO d FROM finance.documents WHERE documents.id=(prior.response->>'id')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  PERFORM security.require(perm||'.manage',d.branch_id); RETURN prior.response;
 END IF;
 IF p_action='create' THEN
  b:=(p->>'branch_id')::uuid;dt:=(p->>'accounting_date')::date;due:=coalesce(nullif(p->>'due_date','')::date,dt);
  PERFORM security.require(perm||'.manage',b);PERFORM security.require('ledger.read',b);
  IF b IS NULL OR dt IS NULL OR NOT isfinite(dt) OR due<dt OR NOT EXISTS(SELECT FROM organization.branches WHERE branches.id=b AND company_id=security.company() AND active)
  THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  SELECT functional_currency INTO curr FROM organization.companies WHERE companies.id=security.company();
  mode:=coalesce(p->>'settlement_type','CREDIT');IF mode NOT IN('CREDIT','DIRECT') THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  no:=coalesce(p->>'invoice_number',p->>'bill_number',p->>'document_number',p->>'payrun_number');
  IF length(btrim(coalesce(no,''))) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  IF p_kind='INVOICE' THEN
   party:=(p->>'customer_id')::uuid;IF NOT EXISTS(SELECT FROM invoicing.customers WHERE customers.id=party AND company_id=security.company() AND active) THEN RAISE EXCEPTION 'invalid_reference' USING ERRCODE='23503'; END IF;
  ELSIF p_kind='BILL' THEN
   party:=(p->>'vendor_id')::uuid;IF NOT EXISTS(SELECT FROM invoicing.vendors WHERE vendors.id=party AND company_id=security.company() AND active) THEN RAISE EXCEPTION 'invalid_reference' USING ERRCODE='23503'; END IF;
  END IF;
  IF p_kind='PAYROLL' THEN
   freq:=p->>'pay_frequency';ps:=(p->>'pay_period_start')::date;pe:=(p->>'pay_period_end')::date;
   IF ps IS NULL OR pe IS NULL OR NOT isfinite(ps) OR NOT isfinite(pe) OR pe<ps OR dt<pe OR freq NOT IN('WEEKLY','BIWEEKLY','MONTHLY')
   OR (freq='WEEKLY' AND pe-ps<>6) OR (freq='BIWEEKLY' AND pe-ps<>13)
   OR (freq='MONTHLY' AND (ps<>date_trunc('month',ps)::date OR pe<>(ps+interval '1 month'-interval '1 day')::date))
   THEN RAISE EXCEPTION 'invalid_payroll_period' USING ERRCODE='22023'; END IF;
   PERFORM pg_advisory_xact_lock(hashtextextended(security.company()::text||b::text||freq,1));
   IF EXISTS(SELECT FROM finance.documents WHERE kind='PAYROLL' AND branch_id=b AND state NOT IN('VOIDED','REVERSED') AND payload->>'pay_frequency'=freq
    AND (payload->>'pay_period_start')::date<=pe AND (payload->>'pay_period_end')::date>=ps)
   THEN RAISE EXCEPTION 'payroll_period_already_processed' USING ERRCODE='23505'; END IF;
   SELECT * INTO policy FROM finance.payroll_policies WHERE payroll_policies.id=(p->>'policy_id')::uuid AND approved_by IS NOT NULL
    AND pay_frequency=freq AND effective_from<=ps AND (effective_to IS NULL OR effective_to>=pe);
   IF NOT FOUND THEN RAISE EXCEPTION 'approved_payroll_policy_required' USING ERRCODE='23514'; END IF;
   FOR emp IN SELECT * FROM payroll.employees WHERE company_id=security.company() AND branch_id=b AND active AND pay_frequency=freq ORDER BY employees.id FOR SHARE LOOP
    one_tax:=NULL;
    FOR bracket IN SELECT * FROM jsonb_array_elements(policy.rules->'income_tax_brackets') LOOP
     IF bracket->>'up_to_minor' IS NULL OR emp.salary_amount<=finance.amount(bracket->>'up_to_minor') THEN
      one_tax:=greatest(0,round(emp.salary_amount*(bracket->>'rate_percent')::numeric/100)-finance.amount(bracket->>'subtract_minor'));EXIT;
     END IF;
    END LOOP;
    IF one_tax IS NULL THEN RAISE EXCEPTION 'invalid_payroll_policy' USING ERRCODE='23514'; END IF;
    one_ep:=round(emp.salary_amount*(policy.rules->>'employee_pension_percent')::numeric/100);
    one_er:=round(emp.salary_amount*(policy.rules->>'employer_pension_percent')::numeric/100);
    IF one_tax+one_ep>=emp.salary_amount THEN RAISE EXCEPTION 'invalid_net_pay' USING ERRCODE='23514'; END IF;
    gross:=gross+emp.salary_amount;deductions:=deductions+one_tax;pension_emp:=pension_emp+one_ep;pension_er:=pension_er+one_er;
    slips:=slips||jsonb_build_array(jsonb_build_object('employee_id',emp.id,'gross_minor',emp.salary_amount::text,'income_tax_minor',one_tax::text,
      'employee_pension_minor',one_ep::text,'employer_pension_minor',one_er::text,'net_minor',(emp.salary_amount-one_tax-one_ep)::text));
   END LOOP;
   IF gross=0 THEN RAISE EXCEPTION 'no_active_employees_or_salaries' USING ERRCODE='23514'; END IF;
   net:=gross-deductions-pension_emp;sub:=gross;taxes_total:=deductions;
   norm:=slips;
  ELSE
   IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_lines' USING ERRCODE='22023'; END IF;
   FOR line IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    IF jsonb_typeof(line) IS DISTINCT FROM 'object' OR EXISTS(SELECT FROM jsonb_object_keys(line) k WHERE k NOT IN('item_id','description','quantity','unit_price','tax_rate_id')) THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
    qty:=(line->>'quantity')::numeric;price:=finance.amount(line->>'unit_price');
    IF qty IS NULL OR qty<=0 OR qty>=1e20 OR scale(qty)>6 OR price=0 THEN RAISE EXCEPTION 'invalid_amount' USING ERRCODE='22023'; END IF;
    SELECT * INTO item FROM inventory.items WHERE items.id=(line->>'item_id')::uuid AND company_id=security.company() AND active FOR SHARE;
    IF NOT FOUND OR (p_kind='OPENING' AND item.type<>'PRODUCT') THEN RAISE EXCEPTION 'invalid_reference' USING ERRCODE='23503'; END IF;
    amount:=round(qty*price);PERFORM finance.amount(amount::text);IF amount=0 THEN RAISE EXCEPTION 'invalid_amount' USING ERRCODE='22023'; END IF;
    tax:=0;
    IF nullif(line->>'tax_rate_id','') IS NOT NULL THEN
     SELECT rate_percent INTO rate FROM taxes.tax_rates WHERE tax_rates.id=(line->>'tax_rate_id')::uuid AND company_id=security.company() AND active
      AND effective_from<=dt AND (effective_to IS NULL OR effective_to>=dt) FOR SHARE;
     IF NOT FOUND OR p_kind='OPENING' THEN RAISE EXCEPTION 'invalid_reference' USING ERRCODE='23503'; END IF;
     tax:=round(amount*rate/100);
    END IF;
    sub:=sub+amount;taxes_total:=taxes_total+tax;
    norm:=norm||jsonb_build_array(line||jsonb_build_object('quantity',qty::text,'unit_price',price::text,'line_total',amount::text,'tax_minor',tax::text));
   END LOOP;
  END IF;
  PERFORM finance.amount(sub::text);PERFORM finance.amount(taxes_total::text);
  IF p_kind<>'PAYROLL' THEN net:=sub+taxes_total; END IF;PERFORM finance.amount(net::text);
  IF mode='DIRECT' AND p_kind IN('INVOICE','BILL') THEN payment:=finance.cash_account((p->>'payment_account_id')::uuid); END IF;
  INSERT INTO finance.documents(tenant_id,company_id,kind,branch_id,document_no,accounting_date,due_date,currency,counterparty_id,created_by,subtotal,tax_total,total_amount,payload,payment_account_id)
  VALUES(security.tenant(),security.company(),p_kind,b,no,dt,due,curr,party,security.actor(),sub,taxes_total,net,
   p||jsonb_build_object('lines',norm,'settlement_type',mode,'policy_rules',CASE WHEN p_kind='PAYROLL' THEN policy.rules ELSE NULL END),payment) RETURNING * INTO d;
  IF p_kind<>'PAYROLL' THEN FOR line IN SELECT * FROM jsonb_array_elements(norm) LOOP INSERT INTO finance.item_usage VALUES(security.tenant(),security.company(),(line->>'item_id')::uuid,d.id) ON CONFLICT DO NOTHING; END LOOP; END IF;
  IF p_kind='PAYROLL' THEN
   INSERT INTO payroll.payruns(tenant_id,company_id,document_id,pay_period_start,pay_period_end,payment_date,total_gross,total_net,total_taxes)
   VALUES(security.tenant(),security.company(),d.id,ps,pe,dt,gross,net,deductions) RETURNING payruns.id INTO payrun;
   FOR line IN SELECT * FROM jsonb_array_elements(norm) LOOP
    INSERT INTO payroll.pay_slips(tenant_id,company_id,payrun_id,employee_id,gross_pay,net_pay,taxes_withheld,employee_pension_minor,employer_pension_minor)
    VALUES(security.tenant(),security.company(),payrun,(line->>'employee_id')::uuid,(line->>'gross_minor')::numeric,(line->>'net_minor')::numeric,
     (line->>'income_tax_minor')::numeric,(line->>'employee_pension_minor')::numeric,(line->>'employer_pension_minor')::numeric);
   END LOOP;
  END IF;
 ELSE
  SELECT * INTO d FROM finance.documents WHERE documents.id=(p->>'id')::uuid AND kind=p_kind FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  PERFORM security.require(perm||'.manage',d.branch_id);
  IF d.version IS DISTINCT FROM (p->>'expected_version')::bigint THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
  IF length(btrim(coalesce(p->>'reason',''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'invalid_reason' USING ERRCODE='22023'; END IF;
  IF p_action IN('submit','approve','pay','pay-approve') THEN PERFORM finance.assert_clean(); END IF;
  IF d.reversal_state IS NOT NULL THEN RAISE EXCEPTION 'use_reversal_workflow' USING ERRCODE='55000'; END IF;
  IF p_action='submit' THEN
   IF d.state<>'DRAFT' OR d.created_by<>security.actor() THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   norm:='[]';mode:=d.payload->>'settlement_type';
   IF p_kind IN('INVOICE','BILL','OPENING') THEN
    -- Stable item order avoids multi-document stock lock inversion.
    FOR line IN SELECT * FROM jsonb_array_elements(d.payload->'lines') ORDER BY value->>'item_id' LOOP
     SELECT * INTO STRICT item FROM inventory.items WHERE items.id=(line->>'item_id')::uuid AND active FOR SHARE;
     amount:=(line->>'line_total')::numeric;qty:=(line->>'quantity')::numeric;
     IF p_kind='INVOICE' THEN
      account:=finance.account(item.income_account_id,ARRAY['REVENUE','OTHER_INCOME']);entry_lines:=entry_lines||jsonb_build_array(finance.line(account,0,amount));
     ELSE
      account:=finance.account(CASE WHEN item.type='PRODUCT' THEN item.asset_account_id ELSE item.expense_account_id END,
       CASE WHEN item.type='PRODUCT' THEN ARRAY['ASSET'] ELSE ARRAY['EXPENSE','COST_OF_SALES'] END);
      entry_lines:=entry_lines||jsonb_build_array(finance.line(account,amount,0));
     END IF;
     cost:=0;
     IF item.type='PRODUCT' THEN
      IF item.asset_account_id IN(SELECT x::uuid FROM finance.settings st,jsonb_array_elements_text(st.accounts->'cash_accounts') x WHERE st.company_id=security.company()) THEN RAISE EXCEPTION 'invalid_account_mapping' USING ERRCODE='23514'; END IF;
      INSERT INTO finance.control_accounts VALUES(security.tenant(),security.company(),'inventory',item.asset_account_id) ON CONFLICT DO NOTHING;
      INSERT INTO finance.positions(tenant_id,company_id,item_id) VALUES(security.tenant(),security.company(),item.id) ON CONFLICT DO NOTHING;
      SELECT * INTO STRICT pos FROM finance.positions WHERE item_id=item.id FOR UPDATE;
      IF pos.last_accounting_date IS NOT NULL AND d.accounting_date<pos.last_accounting_date THEN RAISE EXCEPTION 'inventory_date_order' USING ERRCODE='23514'; END IF;
      IF p_kind='INVOICE' THEN
       IF qty>pos.quantity-pos.reserved_quantity THEN RAISE EXCEPTION 'insufficient_stock' USING ERRCODE='23514'; END IF;
       cost:=CASE WHEN qty=pos.quantity-pos.reserved_quantity THEN pos.value_minor-pos.reserved_minor
        ELSE round((pos.value_minor-pos.reserved_minor)*qty/(pos.quantity-pos.reserved_quantity)) END;
       UPDATE finance.positions SET reserved_quantity=reserved_quantity+qty,reserved_minor=reserved_minor+cost WHERE item_id=item.id;
       IF cost>0 THEN entry_lines:=entry_lines||jsonb_build_array(finance.line(finance.account(item.expense_account_id,ARRAY['EXPENSE','COST_OF_SALES']),cost,0),finance.line(finance.account(item.asset_account_id,ARRAY['ASSET']),0,cost)); END IF;
      END IF;
     END IF;
     norm:=norm||jsonb_build_array(line||jsonb_build_object('stock_cost_minor',cost::text));
    END LOOP;
    IF p_kind='INVOICE' THEN
     account:=CASE WHEN mode='DIRECT' THEN finance.cash_account(d.payment_account_id) ELSE finance.mapped('receivable',ARRAY['ASSET']) END;
     control_account:=account;entry_lines:=entry_lines||jsonb_build_array(finance.line(account,d.total_amount,0));
     IF d.tax_total>0 THEN entry_lines:=entry_lines||jsonb_build_array(finance.line(finance.mapped('output_tax',ARRAY['LIABILITY']),0,d.tax_total)); END IF;
    ELSIF p_kind='BILL' THEN
     account:=CASE WHEN mode='DIRECT' THEN finance.cash_account(d.payment_account_id) ELSE finance.mapped('payable',ARRAY['LIABILITY']) END;
     control_account:=account;entry_lines:=entry_lines||jsonb_build_array(finance.line(account,0,d.total_amount));
     IF d.tax_total>0 THEN entry_lines:=entry_lines||jsonb_build_array(finance.line(finance.mapped('input_tax',ARRAY['ASSET']),d.tax_total,0)); END IF;
    ELSE entry_lines:=entry_lines||jsonb_build_array(finance.line(finance.mapped('opening_equity',ARRAY['EQUITY']),0,d.total_amount)); END IF;
   ELSE
    gross:=d.subtotal;net:=d.total_amount;deductions:=d.tax_total;pension_emp:=0;pension_er:=0;
    FOR line IN SELECT * FROM jsonb_array_elements(d.payload->'lines') LOOP pension_emp:=pension_emp+(line->>'employee_pension_minor')::numeric;pension_er:=pension_er+(line->>'employer_pension_minor')::numeric; END LOOP;
    control_account:=finance.mapped('payroll_payable',ARRAY['LIABILITY']);
    entry_lines:=jsonb_build_array(finance.line(finance.mapped('payroll_expense',ARRAY['EXPENSE']),gross,0),finance.line(finance.mapped('payroll_payable',ARRAY['LIABILITY']),0,net));
    IF deductions>0 THEN entry_lines:=entry_lines||jsonb_build_array(finance.line(finance.mapped('payroll_tax',ARRAY['LIABILITY']),0,deductions)); END IF;
    IF pension_er>0 THEN entry_lines:=entry_lines||jsonb_build_array(finance.line(finance.mapped('pension_expense',ARRAY['EXPENSE']),pension_er,0)); END IF;
    IF pension_emp+pension_er>0 THEN entry_lines:=entry_lines||jsonb_build_array(finance.line(finance.mapped('pension_payable',ARRAY['LIABILITY']),0,pension_emp+pension_er)); END IF;
    norm:=d.payload->'lines';
   END IF;
   jn:=ledger.module_command('finance:'||d.id||':create'||':'||d.version,'create',jsonb_build_object('branch_id',d.branch_id,'accounting_date',d.accounting_date,
    'currency',d.currency,'fx_rate','1','description',p_kind||' '||d.document_no,'reason',p->>'reason','lines',entry_lines));
   jn:=ledger.module_command('finance:'||d.id||':submit'||':'||d.version,'submit',jsonb_build_object('id',jn->>'id','expected_version',jn->>'version','reason',p->>'reason'));
   UPDATE finance.documents SET state='SUBMITTED',submitted_by=security.actor(),journal_id=(jn->>'id')::uuid,
    payload=payload||jsonb_build_object('lines',norm),control_account_id=control_account,version=version+1 WHERE documents.id=d.id RETURNING * INTO d;
  ELSIF p_action='approve' THEN
   IF d.state<>'SUBMITTED' THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   IF d.created_by=security.actor() OR d.submitted_by=security.actor() THEN RAISE EXCEPTION 'segregation_of_duties' USING ERRCODE='42501'; END IF;
   IF d.payload->>'settlement_type'='DIRECT' THEN PERFORM finance.cash_account(d.payment_account_id); END IF;
   SELECT version INTO amount FROM ledger.journals WHERE journals.id=d.journal_id;
   jn:=ledger.module_command('finance:'||d.id||':approve'||':'||d.version,'approve',jsonb_build_object('id',d.journal_id,'expected_version',amount,'reason',p->>'reason'));
   jn:=ledger.module_command('finance:'||d.id||':post'||':'||d.version,'post',jsonb_build_object('id',d.journal_id,'expected_version',jn->>'version','reason',p->>'reason'));
   FOR line IN SELECT * FROM jsonb_array_elements(d.payload->'lines') ORDER BY value->>'item_id' LOOP
    IF p_kind='PAYROLL' THEN EXIT; END IF;
    SELECT * INTO STRICT item FROM inventory.items WHERE items.id=(line->>'item_id')::uuid FOR SHARE;
    IF item.type='PRODUCT' THEN
     SELECT * INTO STRICT pos FROM finance.positions WHERE item_id=item.id FOR UPDATE;
     IF pos.last_accounting_date IS NOT NULL AND d.accounting_date<pos.last_accounting_date THEN RAISE EXCEPTION 'inventory_date_order' USING ERRCODE='23514'; END IF;
     qty:=(line->>'quantity')::numeric;cost:=(line->>'stock_cost_minor')::numeric;
     IF p_kind='INVOICE' THEN
      UPDATE finance.positions SET last_accounting_date=d.accounting_date,quantity=quantity-qty,value_minor=value_minor-cost,reserved_quantity=reserved_quantity-qty,reserved_minor=reserved_minor-cost WHERE item_id=item.id;
     ELSE UPDATE finance.positions SET last_accounting_date=d.accounting_date,quantity=quantity+qty,value_minor=value_minor+(line->>'line_total')::numeric WHERE item_id=item.id; END IF;
     INSERT INTO inventory.transactions(tenant_id,company_id,item_id,quantity,reference_type,reference_id)
     VALUES(security.tenant(),security.company(),item.id,CASE WHEN p_kind='INVOICE' THEN -qty ELSE qty END,p_kind,d.id);
    END IF;
   END LOOP;
   IF p_kind IN('INVOICE','BILL') THEN
    FOR line IN SELECT * FROM jsonb_array_elements(d.payload->'lines') LOOP
     IF (line->>'tax_minor')::numeric>0 THEN
      INSERT INTO taxes.tax_entries(tenant_id,company_id,tax_rate_id,journal_id,taxable_amount,tax_amount,transaction_type)
      VALUES(security.tenant(),security.company(),(line->>'tax_rate_id')::uuid,d.journal_id,(line->>'line_total')::numeric,
       (line->>'tax_minor')::numeric,CASE WHEN p_kind='INVOICE' THEN 'SALE' ELSE 'PURCHASE' END);
     END IF;
    END LOOP;
   END IF;
   UPDATE finance.documents SET state=CASE WHEN payload->>'settlement_type'='DIRECT' AND kind IN('INVOICE','BILL') THEN 'PAID' ELSE 'APPROVED' END,
    approved_by=security.actor(),version=version+1 WHERE documents.id=d.id RETURNING * INTO d;
   IF p_kind='PAYROLL' THEN UPDATE payroll.payruns SET status='APPROVED',journal_id=d.journal_id WHERE document_id=d.id; END IF;
  ELSIF p_action IN('pay','pay-approve') THEN
   IF p_kind='OPENING' OR d.state<>'APPROVED' THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   IF p_action='pay' THEN
    IF d.payment_journal_id IS NOT NULL THEN RAISE EXCEPTION 'payment_already_submitted' USING ERRCODE='55000'; END IF;
    paydate:=(p->>'accounting_date')::date;IF paydate IS NULL OR paydate<d.accounting_date OR NOT isfinite(paydate) THEN RAISE EXCEPTION 'invalid_dates' USING ERRCODE='22023'; END IF;
    payment:=finance.cash_account((p->>'payment_account_id')::uuid);
    account:=finance.account(d.control_account_id,CASE WHEN p_kind='INVOICE' THEN ARRAY['ASSET'] ELSE ARRAY['LIABILITY'] END);
    entry_lines:=CASE WHEN p_kind='INVOICE' THEN jsonb_build_array(finance.line(payment,d.total_amount,0),finance.line(account,0,d.total_amount))
     ELSE jsonb_build_array(finance.line(account,d.total_amount,0),finance.line(payment,0,d.total_amount)) END;
    jn:=ledger.module_command('finance:'||d.id||':payment-create'||':'||d.version,'create',jsonb_build_object('branch_id',d.branch_id,'accounting_date',paydate,'currency',d.currency,'fx_rate','1','description','Payment '||d.document_no,'reason',p->>'reason','lines',entry_lines));
    jn:=ledger.module_command('finance:'||d.id||':payment-submit'||':'||d.version,'submit',jsonb_build_object('id',jn->>'id','expected_version',jn->>'version','reason',p->>'reason'));
    UPDATE finance.documents SET payment_journal_id=(jn->>'id')::uuid,payment_by=security.actor(),payment_state='SUBMITTED',payment_date=paydate,payment_account_id=payment,version=version+1 WHERE documents.id=d.id RETURNING * INTO d;
   ELSE
    IF d.payment_state IS DISTINCT FROM 'SUBMITTED' THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
    IF d.payment_by=security.actor() THEN RAISE EXCEPTION 'segregation_of_duties' USING ERRCODE='42501'; END IF;
    PERFORM finance.cash_account(d.payment_account_id);
    SELECT version INTO amount FROM ledger.journals WHERE journals.id=d.payment_journal_id;
    jn:=ledger.module_command('finance:'||d.id||':payment-approve'||':'||d.version,'approve',jsonb_build_object('id',d.payment_journal_id,'expected_version',amount,'reason',p->>'reason'));
    jn:=ledger.module_command('finance:'||d.id||':payment-post'||':'||d.version,'post',jsonb_build_object('id',d.payment_journal_id,'expected_version',jn->>'version','reason',p->>'reason'));
    UPDATE finance.documents SET state='PAID',payment_state='POSTED',version=version+1 WHERE documents.id=d.id RETURNING * INTO d;
    IF p_kind='PAYROLL' THEN UPDATE payroll.payruns SET status='PAID' WHERE document_id=d.id; END IF;
   END IF;
  ELSE
   IF d.state NOT IN('DRAFT','SUBMITTED') OR d.created_by<>security.actor() THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   IF d.journal_id IS NOT NULL THEN
    SELECT version INTO amount FROM ledger.journals WHERE journals.id=d.journal_id;
    jn:=ledger.module_command('finance:'||d.id||':void'||':'||d.version,'void',jsonb_build_object('id',d.journal_id,'expected_version',amount,'reason',p->>'reason'));
    IF p_kind='INVOICE' THEN
     FOR line IN SELECT * FROM jsonb_array_elements(d.payload->'lines') ORDER BY value->>'item_id' LOOP
      UPDATE finance.positions SET reserved_quantity=reserved_quantity-(line->>'quantity')::numeric,reserved_minor=reserved_minor-(line->>'stock_cost_minor')::numeric WHERE item_id=(line->>'item_id')::uuid AND EXISTS(SELECT FROM inventory.items WHERE items.id=(line->>'item_id')::uuid AND type='PRODUCT');
     END LOOP;
    END IF;
   END IF;
   UPDATE finance.documents SET state='VOIDED',version=version+1 WHERE documents.id=d.id RETURNING * INTO d;
   IF p_kind='PAYROLL' THEN UPDATE payroll.payruns SET status='VOIDED' WHERE document_id=d.id; END IF;
  END IF;
 END IF;
 result:=to_jsonb(d)||jsonb_build_object('subtotal',d.subtotal::text,'tax_total',d.tax_total::text,'total_amount',d.total_amount::text);
 INSERT INTO finance.receipts VALUES(security.tenant(),security.company(),security.actor(),p_key,hash,result);
 RETURN result;
END $$;

CREATE FUNCTION finance.list_documents(p_kind text) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,invoicing,security,pg_temp AS $$ DECLARE result jsonb;BEGIN
 IF finance.permission(p_kind) IS NULL THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM security.require(finance.permission(p_kind)||'.read');
 SELECT coalesce(jsonb_agg(to_jsonb(d)||jsonb_build_object('status',d.state,'invoice_number',d.document_no,'bill_number',d.document_no,'issue_date',d.accounting_date,
  'customer_id',d.counterparty_id,'vendor_id',d.counterparty_id,'customer_name',c.name,'vendor_name',v.name,'settlement_type',d.payload->>'settlement_type',
  'subtotal',d.subtotal::text,'tax_total',d.tax_total::text,'total_amount',d.total_amount::text) ORDER BY d.created_at DESC,d.id),'[]') INTO result
 FROM (SELECT * FROM finance.documents WHERE kind=p_kind ORDER BY created_at DESC,id LIMIT 200) d
 LEFT JOIN invoicing.customers c ON p_kind='INVOICE' AND c.id=d.counterparty_id LEFT JOIN invoicing.vendors v ON p_kind='BILL' AND v.id=d.counterparty_id;
 RETURN result;
END $$;
GRANT EXECUTE ON FUNCTION finance.configure(jsonb),finance.get_settings(),finance.create_master(text,jsonb),
 finance.document_command(text,text,text,jsonb),finance.list_documents(text) TO serk_api;
REVOKE ALL ON ALL TABLES IN SCHEMA finance FROM PUBLIC,serk_auth;
