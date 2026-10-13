-- 0.3.0: company feature switches and the Ethiopian fiscal calendar.
--
--  F1  Each company can switch modules and capabilities on or off (sales, purchases, inventory,
--      payroll, taxes, multi-currency, controlled adjustments, year-end close). A switched-off
--      module behaves as if nobody held its permissions: its screens, reads and commands are
--      refused at the database. Data is kept and reappears when the module is switched back on.
--      Switching needs company-wide configuration.manage, a reason, and is audited.
--  F2  Reference data reports the caller's effective permissions and the company's switches so
--      the interface shows only what each role may use.
--  E1  Ethiopian fiscal year: Hamle 1 – Sene 30 with Ethiopian month periods (Hamle, Nehase,
--      Pagume, Meskerem … Sene). Dates stay Gregorian in the ledger.
SET LOCAL ROLE serk_owner;

CREATE TABLE organization.features(
 code text PRIMARY KEY,label text NOT NULL,description text NOT NULL,sort_order integer NOT NULL);
INSERT INTO organization.features VALUES
 ('sales','Sales & receivables','Customers, sales invoices, receipts and receivable adjustments.',10),
 ('purchases','Purchases & payables','Vendors, bills, supplier payments and payable adjustments.',20),
 ('inventory','Inventory','Stock items, openings, moving weighted-average cost and count adjustments.',30),
 ('payroll','Payroll','Employees, payroll policies, payruns, payslips and payroll remittances.',40),
 ('taxes','Taxes','Tax agencies, tax rates, VAT report and tax settlements.',50),
 ('multi_currency','Multiple currencies','Foreign-currency journals with recorded exchange rates.',60),
 ('adjustments','Controlled adjustments','Settlements, write-offs, write-downs and opening balances on controlled accounts.',70),
 ('year_end','Year-end close','Dual-controlled transfer of the year''s profit or loss to retained earnings.',80);
GRANT SELECT ON organization.features TO serk_api;

CREATE TABLE organization.company_features(
 id uuid NOT NULL DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,
 feature text NOT NULL REFERENCES organization.features(code),enabled boolean NOT NULL,
 reason text NOT NULL,version bigint NOT NULL DEFAULT 1,updated_by uuid,updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(company_id,feature),UNIQUE(id),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id));
ALTER TABLE organization.company_features ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization.company_features FORCE ROW LEVEL SECURITY;
CREATE POLICY scoped ON organization.company_features USING(tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
GRANT SELECT ON organization.company_features TO serk_api;
CREATE TRIGGER company_features_audit AFTER INSERT OR UPDATE ON organization.company_features FOR EACH ROW EXECUTE FUNCTION audit.record_change();

-- Module that governs a permission (NULL = always available core permission).
CREATE FUNCTION security.permission_feature(p_permission text) RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$
 SELECT CASE split_part(p_permission,'.',1) WHEN 'sales' THEN 'sales' WHEN 'purchases' THEN 'purchases'
  WHEN 'inventory' THEN 'inventory' WHEN 'payroll' THEN 'payroll' WHEN 'taxes' THEN 'taxes' END $$;

-- Switched off only by an explicit row; every feature is on by default.
CREATE FUNCTION security.feature_enabled(p_feature text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,organization,security,pg_temp AS $$
 SELECT p_feature IS NULL OR NOT EXISTS(SELECT FROM organization.company_features
  WHERE company_id=(SELECT security.company()) AND feature=p_feature AND NOT enabled) $$;

CREATE FUNCTION security.disabled_features() RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,organization,security,pg_temp AS $$
 SELECT coalesce(array_agg(feature),'{}'::text[]) FROM organization.company_features
 WHERE company_id=(SELECT security.company()) AND NOT enabled $$;

CREATE OR REPLACE FUNCTION security.can(p_permission text,p_branch uuid DEFAULT NULL::uuid,p_amount numeric DEFAULT 0) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT NOT (coalesce(security.permission_feature(p_permission),'')=ANY((SELECT security.disabled_features())::text[]))
 AND EXISTS(SELECT FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor()) AND rp.permission=p_permission
 AND (m.branch_id IS NULL OR m.branch_id=p_branch)
 AND (p_permission<>'journal.approve' OR m.approval_limit_minor IS NULL OR p_amount<=m.approval_limit_minor)) $$;

CREATE OR REPLACE FUNCTION security.has(p_permission text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT NOT (coalesce(security.permission_feature(p_permission),'')=ANY((SELECT security.disabled_features())::text[]))
 AND EXISTS(SELECT FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor()) AND rp.permission=p_permission) $$;

CREATE OR REPLACE FUNCTION security.held_permissions() RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT coalesce(array_agg(DISTINCT rp.permission) FILTER(WHERE NOT (coalesce(security.permission_feature(rp.permission),'')=ANY((SELECT security.disabled_features())::text[]))),'{}'::text[])
 FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor()) $$;

-- Capability switches that are not tied to a single permission prefix.
CREATE OR REPLACE FUNCTION finance.require_adjustment(p_purpose text,p_branch uuid) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$
DECLARE perm text:=finance.adjustment_permission(p_purpose);
BEGIN
 IF perm IS NULL THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 IF NOT security.feature_enabled('adjustments') THEN RAISE EXCEPTION 'feature_disabled' USING ERRCODE='55000'; END IF;
 PERFORM security.require(perm||'.manage',p_branch);
 IF perm<>'configuration' THEN PERFORM security.require(perm||'.read',p_branch); END IF;
 PERFORM security.require('ledger.read',p_branch);
END $$;

CREATE OR REPLACE FUNCTION ledger.guard_manual_rate() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,core,security,pg_temp AS $$
DECLARE recorded numeric; bps integer;
BEGIN
 IF NEW.source_type='MANUAL' AND NEW.currency<>NEW.functional_currency THEN
  IF NOT security.feature_enabled('multi_currency') THEN RAISE EXCEPTION 'feature_disabled' USING ERRCODE='55000'; END IF;
  recorded:=ledger.recorded_rate(NEW.currency,NEW.accounting_date);
  IF recorded IS NULL OR recorded<=0 THEN RAISE EXCEPTION 'exchange_rate_not_recorded' USING ERRCODE='23514'; END IF;
  SELECT tolerance_bps INTO bps FROM ledger.fx_policies WHERE company_id=NEW.company_id;
  IF abs(NEW.fx_rate-recorded)*10000>recorded*coalesce(bps,200) THEN RAISE EXCEPTION 'exchange_rate_outside_tolerance' USING ERRCODE='23514'; END IF;
 END IF;
 RETURN NEW;
END $$;

CREATE FUNCTION ledger.guard_year_end_feature() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
BEGIN
 IF NOT security.feature_enabled('year_end') THEN RAISE EXCEPTION 'feature_disabled' USING ERRCODE='55000'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER aa_year_end_feature BEFORE INSERT OR UPDATE ON ledger.year_closings FOR EACH ROW EXECUTE FUNCTION ledger.guard_year_end_feature();

CREATE FUNCTION organization.list_features() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,organization,security,pg_temp AS $$
 SELECT jsonb_agg(jsonb_build_object('code',f.code,'label',f.label,'description',f.description,
  'enabled',coalesce(c.enabled,true),'version',coalesce(c.version,0),'reason',c.reason,'updated_at',c.updated_at,'updated_by',c.updated_by) ORDER BY f.sort_order)
 FROM organization.features f LEFT JOIN organization.company_features c ON c.feature=f.code AND c.company_id=(SELECT security.company()) $$;

CREATE FUNCTION organization.set_feature(p_feature text,p_enabled boolean,p_reason text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,organization,security,pg_temp AS $$
BEGIN
 PERFORM security.require('configuration.manage');
 IF NOT EXISTS(SELECT FROM organization.features WHERE code=p_feature) OR p_enabled IS NULL THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 IF length(btrim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'invalid_reason' USING ERRCODE='22023'; END IF;
 PERFORM set_config('serk.request_context',(coalesce(nullif(current_setting('serk.request_context',true),'')::jsonb,'{}'::jsonb)||jsonb_build_object('reason',p_reason))::text,true);
 INSERT INTO organization.company_features(tenant_id,company_id,feature,enabled,reason,updated_by)
 VALUES(security.tenant(),security.company(),p_feature,p_enabled,btrim(p_reason),security.actor())
 ON CONFLICT(company_id,feature) DO UPDATE SET enabled=EXCLUDED.enabled,reason=EXCLUDED.reason,updated_by=EXCLUDED.updated_by,
  updated_at=clock_timestamp(),version=company_features.version+1;
 RETURN organization.list_features();
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
 'permissions',jsonb_build_object('create',security.has('journal.create'),'audit',security.has('audit.read'),
  'close',security.can('period.close') AND security.can('ledger.read'),
  'users',security.can('user.manage'),'roles',security.can('role.manage'),'configure',security.can('configuration.manage')),
 -- Effective permissions (any branch), after company feature switches.
 'held',to_jsonb(security.held_permissions()),
 'features',(SELECT jsonb_object_agg(f.code,NOT (f.code=ANY(security.disabled_features()))) FROM organization.features f));
END $$;

REVOKE ALL ON FUNCTION security.permission_feature(text),security.feature_enabled(text),security.disabled_features(),
 organization.list_features(),organization.set_feature(text,boolean,text),ledger.guard_year_end_feature() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.permission_feature(text),security.feature_enabled(text),security.disabled_features(),
 organization.list_features(),organization.set_feature(text,boolean,text) TO serk_api;

------------------------------------------------------------------------------------------
-- E1: Ethiopian fiscal year (Hamle 1 – Sene 30).
------------------------------------------------------------------------------------------
-- Meskerem 1 falls on 11 September, or 12 September when the next Gregorian year is a leap year.
CREATE FUNCTION ledger.meskerem_one(p_year integer) RETURNS date LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$
 SELECT make_date(p_year,9,CASE WHEN ((p_year+1)%4=0 AND (p_year+1)%100<>0) OR (p_year+1)%400=0 THEN 12 ELSE 11 END) $$;

CREATE FUNCTION ledger.create_ethiopian_fiscal_year(p_name text,p_start date) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$
DECLARE t uuid:=(SELECT security.tenant()); c uuid:=(SELECT security.company()); fy uuid; m1 date; next_hamle date; ps date; pe date; i integer;
 names text[]:=ARRAY['Meskerem','Tikimt','Hidar','Tahsas','Tir','Yekatit','Megabit','Miyazya','Ginbot','Sene'];
BEGIN
 PERFORM security.require('configuration.manage');
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 40 OR p_start IS NULL THEN RAISE EXCEPTION 'invalid_dates' USING ERRCODE='22008'; END IF;
 m1:=ledger.meskerem_one(extract(year FROM p_start)::integer);
 -- Hamle 1 is 300 days after the previous Meskerem 1.
 IF p_start<>ledger.meskerem_one(extract(year FROM p_start)::integer-1)+300 THEN RAISE EXCEPTION 'not_hamle_one' USING ERRCODE='22008'; END IF;
 next_hamle:=m1+300;
 INSERT INTO ledger.fiscal_years(tenant_id,company_id,name,start_date,end_date) VALUES(t,c,btrim(p_name),p_start,next_hamle-1) RETURNING id INTO fy;
 INSERT INTO ledger.periods(tenant_id,company_id,fiscal_year_id,name,start_date,end_date,state) VALUES
  (t,c,fy,'01 Hamle',p_start,p_start+29,'OPEN'),(t,c,fy,'02 Nehase',p_start+30,p_start+59,'OPEN'),(t,c,fy,'03 Pagume',p_start+60,m1-1,'OPEN');
 ps:=m1;
 FOR i IN 1..10 LOOP
  pe:=ps+29;
  INSERT INTO ledger.periods(tenant_id,company_id,fiscal_year_id,name,start_date,end_date,state) VALUES(t,c,fy,lpad((i+3)::text,2,'0')||' '||names[i],ps,pe,'OPEN');
  ps:=pe+1;
 END LOOP;
 INSERT INTO ledger.numbering(tenant_id,company_id,fiscal_year_id,document_type,prefix,next_value) VALUES(t,c,fy,'JOURNAL','JRN',1) ON CONFLICT DO NOTHING;
 RETURN fy;
END $$;
REVOKE ALL ON FUNCTION ledger.meskerem_one(integer),ledger.create_ethiopian_fiscal_year(text,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.meskerem_one(integer),ledger.create_ethiopian_fiscal_year(text,date) TO serk_api;
