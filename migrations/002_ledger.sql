SET LOCAL ROLE serk_owner;
CREATE DOMAIN ledger.minor AS numeric CHECK(VALUE>=0 AND VALUE<1e28 AND VALUE=trunc(VALUE));
CREATE TABLE ledger.accounts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, company_id uuid NOT NULL,
 code text NOT NULL CHECK(length(code) BETWEEN 1 AND 32), name text NOT NULL CHECK(length(name) BETWEEN 1 AND 200),
 type text NOT NULL CHECK(type IN ('ASSET','LIABILITY','EQUITY','REVENUE','COST_OF_SALES','EXPENSE','OTHER_INCOME','OTHER_EXPENSE')),
 normal_balance text NOT NULL CHECK(normal_balance IN ('DEBIT','CREDIT')), parent_id uuid,
 active boolean NOT NULL DEFAULT true, posting_allowed boolean NOT NULL DEFAULT true,
 control_account boolean NOT NULL DEFAULT false, reporting_category text NOT NULL,
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 UNIQUE(tenant_id,company_id,id), UNIQUE(company_id,code),
 FOREIGN KEY(tenant_id,company_id,parent_id) REFERENCES ledger.accounts(tenant_id,company_id,id), CHECK(parent_id IS DISTINCT FROM id)
);
CREATE TABLE ledger.fiscal_years (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,
 name text NOT NULL, start_date date NOT NULL,end_date date NOT NULL CHECK(end_date>=start_date),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 UNIQUE(tenant_id,company_id,id), UNIQUE(company_id,name)
);
CREATE TABLE ledger.periods (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,fiscal_year_id uuid NOT NULL,
 name text NOT NULL,start_date date NOT NULL,end_date date NOT NULL CHECK(end_date>=start_date),
 state text NOT NULL DEFAULT 'OPEN' CHECK(state IN ('OPEN','SOFT_CLOSED','CLOSED','LOCKED')), version bigint NOT NULL DEFAULT 1,
 FOREIGN KEY(tenant_id,company_id,fiscal_year_id) REFERENCES ledger.fiscal_years(tenant_id,company_id,id),
 UNIQUE(tenant_id,company_id,id), UNIQUE(company_id,fiscal_year_id,name)
);
CREATE TABLE ledger.dimensions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('DEPARTMENT','COST_CENTER','PROJECT','CONTRACT','WBS','FUNDING_SOURCE','EMPLOYEE','CUSTOMER','SUPPLIER','WAREHOUSE','ASSET')),
 code text NOT NULL,name text NOT NULL,active boolean NOT NULL DEFAULT true,
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 UNIQUE(tenant_id,company_id,id,kind),UNIQUE(company_id,kind,code)
);
CREATE TABLE ledger.numbering (
 tenant_id uuid NOT NULL,company_id uuid NOT NULL,fiscal_year_id uuid NOT NULL,
 document_type text NOT NULL CHECK(document_type='JOURNAL'),prefix text NOT NULL DEFAULT 'JRN',next_value bigint NOT NULL DEFAULT 1 CHECK(next_value>0),
 PRIMARY KEY(company_id,fiscal_year_id,document_type),
 FOREIGN KEY(tenant_id,company_id,fiscal_year_id) REFERENCES ledger.fiscal_years(tenant_id,company_id,id)
);
CREATE TABLE ledger.journals (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,
 branch_id uuid NOT NULL,period_id uuid NOT NULL,accounting_date date NOT NULL,
 number text NOT NULL,sequence_no bigint NOT NULL,description text NOT NULL CHECK(length(description) BETWEEN 1 AND 1000),
 currency text NOT NULL REFERENCES organization.currencies(code),functional_currency text NOT NULL REFERENCES organization.currencies(code),
 fx_rate numeric NOT NULL CHECK(fx_rate>0 AND fx_rate<1e12 AND scale(fx_rate)<=12),
 state text NOT NULL DEFAULT 'DRAFT' CHECK(state IN ('DRAFT','SUBMITTED','APPROVED','POSTED','VOIDED')),
 version bigint NOT NULL DEFAULT 1 CHECK(version>0),
 created_by uuid NOT NULL,submitted_by uuid,approved_by uuid,posted_by uuid,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),posted_at timestamptz,
 reversed_from uuid,reason text NOT NULL,source_type text NOT NULL DEFAULT 'MANUAL' CHECK(source_type IN ('MANUAL','REVERSAL')),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,company_id,branch_id) REFERENCES organization.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,company_id,period_id) REFERENCES ledger.periods(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,created_by) REFERENCES security.users(tenant_id,id),
 FOREIGN KEY(tenant_id,submitted_by) REFERENCES security.users(tenant_id,id),
 FOREIGN KEY(tenant_id,approved_by) REFERENCES security.users(tenant_id,id),
 FOREIGN KEY(tenant_id,posted_by) REFERENCES security.users(tenant_id,id),
 UNIQUE(tenant_id,company_id,id),UNIQUE(company_id,number),
 FOREIGN KEY(tenant_id,company_id,reversed_from) REFERENCES ledger.journals(tenant_id,company_id,id),
 CHECK(approved_by IS NULL OR approved_by<>created_by),CHECK((source_type='REVERSAL')=(reversed_from IS NOT NULL)),
 CHECK(state<>'POSTED' OR (posted_at IS NOT NULL AND posted_by IS NOT NULL AND approved_by IS NOT NULL)),
 CHECK(state NOT IN ('APPROVED','POSTED') OR approved_by IS NOT NULL)
);
CREATE UNIQUE INDEX one_active_reversal ON ledger.journals(company_id,reversed_from) WHERE reversed_from IS NOT NULL AND state<>'VOIDED';
CREATE INDEX journal_scope_listing ON ledger.journals(company_id,created_at DESC,id DESC);
CREATE INDEX journal_date ON ledger.journals(company_id,accounting_date,id) WHERE state='POSTED';
CREATE TABLE ledger.lines (
 tenant_id uuid NOT NULL,company_id uuid NOT NULL,journal_id uuid NOT NULL,line_no integer NOT NULL CHECK(line_no BETWEEN 1 AND 500),
 account_id uuid NOT NULL,description text NOT NULL DEFAULT '',debit_minor ledger.minor NOT NULL,credit_minor ledger.minor NOT NULL,
 functional_debit_minor ledger.minor NOT NULL,functional_credit_minor ledger.minor NOT NULL,
 PRIMARY KEY(journal_id,line_no),UNIQUE(tenant_id,company_id,journal_id,line_no),
 FOREIGN KEY(tenant_id,company_id,journal_id) REFERENCES ledger.journals(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,company_id,account_id) REFERENCES ledger.accounts(tenant_id,company_id,id),
 CHECK((debit_minor>0 AND credit_minor=0) OR (credit_minor>0 AND debit_minor=0))
);
CREATE INDEX line_account ON ledger.lines(company_id,account_id,journal_id);
CREATE TABLE ledger.line_dimensions (
 tenant_id uuid NOT NULL,company_id uuid NOT NULL,journal_id uuid NOT NULL,line_no integer NOT NULL,
 kind text NOT NULL,dimension_id uuid NOT NULL,PRIMARY KEY(journal_id,line_no,kind),
 FOREIGN KEY(tenant_id,company_id,journal_id,line_no) REFERENCES ledger.lines(tenant_id,company_id,journal_id,line_no),
 FOREIGN KEY(tenant_id,company_id,dimension_id,kind) REFERENCES ledger.dimensions(tenant_id,company_id,id,kind)
);
CREATE TABLE ledger.idempotency (
 tenant_id uuid NOT NULL,company_id uuid NOT NULL,user_id uuid NOT NULL,key text NOT NULL CHECK(length(key) BETWEEN 8 AND 128),
 request_hash text NOT NULL, response jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(company_id,user_id,key),FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id)
);
CREATE TABLE audit.heads (
 tenant_id uuid NOT NULL,company_id uuid PRIMARY KEY,last_sequence bigint NOT NULL DEFAULT 0,last_hash text NOT NULL DEFAULT '',
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id)
);
CREATE TABLE audit.events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,sequence_no bigint NOT NULL,
 actor_id uuid NOT NULL,recorded_at timestamptz NOT NULL,action text NOT NULL,entity_id uuid NOT NULL,
 previous_state jsonb,new_state jsonb NOT NULL,reason text NOT NULL,request_context jsonb NOT NULL,
 previous_hash text NOT NULL,event_hash text NOT NULL,canonical_payload text NOT NULL,
 UNIQUE(company_id,sequence_no),FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id)
);
CREATE TABLE integration.outbox (
 id uuid PRIMARY KEY,tenant_id uuid NOT NULL,company_id uuid NOT NULL,aggregate_id uuid NOT NULL,
 aggregate_version bigint NOT NULL,event_type text NOT NULL,payload jsonb NOT NULL,
 occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),UNIQUE(aggregate_id,aggregate_version),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id)
);

-- RLS scopes all readable financial relations. No runtime DML grants exist.
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['ledger.accounts','ledger.fiscal_years','ledger.periods','ledger.dimensions','ledger.numbering',
 'ledger.journals','ledger.lines','ledger.line_dimensions','ledger.idempotency','audit.heads','audit.events','integration.outbox'] LOOP
 EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',t);
 EXECUTE format('CREATE POLICY scoped ON %s USING (tenant_id=security.tenant() AND company_id=security.company())',t);
 END LOOP;
END $$;
CREATE POLICY branch_scope ON ledger.journals AS RESTRICTIVE USING(security.visible_branch(branch_id));
CREATE POLICY line_scope ON ledger.lines AS RESTRICTIVE USING(EXISTS(SELECT FROM ledger.journals j WHERE j.id=journal_id));
CREATE POLICY dimension_line_scope ON ledger.line_dimensions AS RESTRICTIVE USING(EXISTS(SELECT FROM ledger.journals j WHERE j.id=journal_id));
CREATE POLICY audit_scope ON audit.events AS RESTRICTIVE FOR SELECT USING(security.can('audit.read'));
CREATE POLICY account_read ON ledger.accounts AS RESTRICTIVE USING(EXISTS(SELECT FROM security.memberships m
 JOIN security.role_permissions p ON p.role_id=m.role_id WHERE m.user_id=security.actor() AND m.company_id=security.company() AND p.permission='ledger.read'));
-- The policy's private membership query is evaluated only by narrowly scoped definer functions.
-- Direct account access uses a safe definer predicate instead.
DROP POLICY account_read ON ledger.accounts;
GRANT SELECT ON ledger.accounts,ledger.fiscal_years,ledger.periods,ledger.dimensions,ledger.journals,ledger.lines,ledger.line_dimensions TO serk_api;

CREATE FUNCTION ledger.block_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,pg_temp AS $$
 BEGIN RAISE EXCEPTION 'immutable_record' USING ERRCODE='55000'; END $$;
CREATE TRIGGER immutable_audit BEFORE UPDATE OR DELETE ON audit.events FOR EACH ROW EXECUTE FUNCTION ledger.block_mutation();
CREATE TRIGGER immutable_outbox BEFORE UPDATE OR DELETE ON integration.outbox FOR EACH ROW EXECUTE FUNCTION ledger.block_mutation();
CREATE FUNCTION ledger.guard_line() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,pg_temp AS $$
 DECLARE j ledger.journals;
 BEGIN
 SELECT * INTO j FROM ledger.journals WHERE id=CASE WHEN TG_OP='DELETE' THEN OLD.journal_id ELSE NEW.journal_id END FOR UPDATE;
 IF NOT FOUND OR j.state<>'DRAFT' THEN RAISE EXCEPTION 'journal_lines_immutable' USING ERRCODE='55000'; END IF;
 IF TG_OP='UPDATE' AND (NEW.journal_id,NEW.tenant_id,NEW.company_id) IS DISTINCT FROM (OLD.journal_id,OLD.tenant_id,OLD.company_id) THEN
 RAISE EXCEPTION 'journal_identity_immutable' USING ERRCODE='55000'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
 END $$;
CREATE TRIGGER guard_lines BEFORE INSERT OR UPDATE OR DELETE ON ledger.lines FOR EACH ROW EXECUTE FUNCTION ledger.guard_line();
CREATE TRIGGER guard_dimensions BEFORE INSERT OR UPDATE OR DELETE ON ledger.line_dimensions FOR EACH ROW EXECUTE FUNCTION ledger.guard_line();

CREATE FUNCTION ledger.validate(p_id uuid,p_posting boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 DECLARE j ledger.journals;p ledger.periods; n integer;td numeric;tc numeric;fd numeric;fc numeric; te integer;fe integer;
 BEGIN
 SELECT * INTO STRICT j FROM ledger.journals WHERE id=p_id;
 IF p_posting THEN
  SELECT * INTO STRICT p FROM ledger.periods WHERE id=j.period_id FOR SHARE;
  PERFORM 1 FROM ledger.accounts WHERE id IN(SELECT account_id FROM ledger.lines WHERE journal_id=p_id) ORDER BY id FOR SHARE;
 END IF;
 SELECT count(*),sum(debit_minor),sum(credit_minor),sum(functional_debit_minor),sum(functional_credit_minor)
 INTO n,td,tc,fd,fc FROM ledger.lines WHERE journal_id=p_id;
 IF n<2 OR n>500 OR td IS DISTINCT FROM tc OR fd IS DISTINCT FROM fc OR coalesce(td,0)<=0 OR coalesce(fd,0)<=0
 THEN RAISE EXCEPTION 'journal_unbalanced' USING ERRCODE='23514'; END IF;
 SELECT minor_units INTO te FROM organization.currencies WHERE code=j.currency;
 SELECT minor_units INTO fe FROM organization.currencies WHERE code=j.functional_currency;
 IF EXISTS(SELECT FROM ledger.lines l WHERE l.journal_id=p_id AND
 (l.functional_debit_minor<>round(l.debit_minor*j.fx_rate*power(10::numeric,fe-te)) OR
 l.functional_credit_minor<>round(l.credit_minor*j.fx_rate*power(10::numeric,fe-te)))) THEN
 RAISE EXCEPTION 'invalid_currency_conversion' USING ERRCODE='23514'; END IF;
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
  IF NOT EXISTS(SELECT FROM ledger.journals WHERE id=j.reversed_from AND state='POSTED') THEN RAISE EXCEPTION 'invalid_reversal' USING ERRCODE='23514'; END IF;
  IF EXISTS((SELECT line_no,account_id,debit_minor,credit_minor,functional_debit_minor,functional_credit_minor FROM ledger.lines WHERE journal_id=p_id
   EXCEPT SELECT line_no,account_id,credit_minor,debit_minor,functional_credit_minor,functional_debit_minor FROM ledger.lines WHERE journal_id=j.reversed_from)
   UNION ALL (SELECT line_no,account_id,credit_minor,debit_minor,functional_credit_minor,functional_debit_minor FROM ledger.lines WHERE journal_id=j.reversed_from
   EXCEPT SELECT line_no,account_id,debit_minor,credit_minor,functional_debit_minor,functional_credit_minor FROM ledger.lines WHERE journal_id=p_id)) THEN
   RAISE EXCEPTION 'reversal_mismatch' USING ERRCODE='23514'; END IF;
  IF EXISTS((SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=p_id EXCEPT SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=j.reversed_from)
   UNION ALL (SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=j.reversed_from EXCEPT SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=p_id)) THEN
   RAISE EXCEPTION 'reversal_dimensions_mismatch' USING ERRCODE='23514'; END IF;
 END IF;
 END $$;

CREATE FUNCTION ledger.guard_journal() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE amount numeric;
 BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'journal_delete_forbidden' USING ERRCODE='55000'; END IF;
 IF TG_OP='INSERT' THEN
  IF NEW.state<>'DRAFT' OR NEW.created_by<>security.actor() OR NEW.version<>1 THEN RAISE EXCEPTION 'invalid_initial_state' USING ERRCODE='23514'; END IF;
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
CREATE TRIGGER guard_journal BEFORE INSERT OR UPDATE OR DELETE ON ledger.journals FOR EACH ROW EXECUTE FUNCTION ledger.guard_journal();

CREATE FUNCTION audit.record_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,audit,integration,security,pg_temp AS $$
 DECLARE h audit.heads; ts timestamptz:=clock_timestamp();eid uuid:=gen_random_uuid();old_json jsonb;new_json jsonb;ctx jsonb; payload text;eh text;action_name text;
 BEGIN
 new_json:=to_jsonb(NEW);IF TG_OP='UPDATE' THEN old_json:=to_jsonb(OLD); END IF;
 IF TG_TABLE_NAME='journals' THEN
  new_json:=new_json||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no) FROM ledger.lines l WHERE l.journal_id=NEW.id),
   'dimensions',(SELECT jsonb_agg(to_jsonb(d) ORDER BY d.line_no,d.kind) FROM ledger.line_dimensions d WHERE d.journal_id=NEW.id));
 END IF;
 ctx:=coalesce(nullif(current_setting('serk.request_context',true),'')::jsonb,'{}'::jsonb);
 action_name:=TG_TABLE_NAME||'.'||lower(NEW.state);
 INSERT INTO audit.heads(tenant_id,company_id) VALUES(NEW.tenant_id,NEW.company_id) ON CONFLICT DO NOTHING;
 SELECT * INTO STRICT h FROM audit.heads WHERE company_id=NEW.company_id FOR UPDATE;
 payload:=jsonb_build_object('id',eid,'tenant_id',NEW.tenant_id,'company_id',NEW.company_id,'sequence',h.last_sequence+1,
  'actor',security.actor(),'at',ts,'action',action_name,'entity',NEW.id,'before',old_json,'after',new_json,'context',ctx)::text;
 eh:=encode(sha256(convert_to(h.last_hash||payload,'UTF8')),'hex');
 INSERT INTO audit.events VALUES(eid,NEW.tenant_id,NEW.company_id,h.last_sequence+1,security.actor(),ts,action_name,NEW.id,
 old_json,new_json,coalesce(new_json->>'reason',ctx->>'reason','State transition'),ctx,h.last_hash,eh,payload);
 UPDATE audit.heads SET last_sequence=h.last_sequence+1,last_hash=eh WHERE company_id=NEW.company_id;
 INSERT INTO integration.outbox(id,tenant_id,company_id,aggregate_id,aggregate_version,event_type,payload)
 VALUES(eid,NEW.tenant_id,NEW.company_id,NEW.id,NEW.version,action_name,jsonb_build_object('schema_version',1,'id',eid,
 'tenant_id',NEW.tenant_id,'company_id',NEW.company_id,'aggregate_id',NEW.id,'version',NEW.version,'state',NEW.state,'audit_hash',eh));
 RETURN NEW;
 END $$;
CREATE CONSTRAINT TRIGGER audit_journal AFTER INSERT OR UPDATE ON ledger.journals DEFERRABLE INITIALLY DEFERRED
 FOR EACH ROW EXECUTE FUNCTION audit.record_change();
