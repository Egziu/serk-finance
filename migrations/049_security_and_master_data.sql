-- 0.2.2-rc1: security hardening from the independent review of 0.2.1-rc1.
--
--  S1  Module, closing and module-reversal journals can no longer be driven through the
--      general-ledger command. The guard reads the journal's own source instead of an
--      RLS-filtered document lookup (users without the module's read permission bypassed it).
--  S2  Tenant-wide user changes (rename, disable, password reset, grants) require the actor
--      to cover the target's permissions in EVERY company where the target has access.
--  S3  Chart-of-accounts, branch, dimension and fiscal-year changes require company-wide
--      configuration.manage, are audited, and run as serk_owner (not the migration superuser).
--  S4  No application function is executable by PUBLIC; SECURITY DEFINER functions are owned
--      by serk_owner. Explicit grants preserve exactly the access the runtime roles had.
--  S5  organization.companies is tenant-scoped for the API role; unused direct write grants
--      on master data are revoked (writes go through finance.create_master).
--  S6  A per-account login window (all sources) complements the per-source window.

-- Ownership fixes need the identity that created 014-018 (the operator), not serk_owner.
RESET ROLE;
DROP FUNCTION ledger.update_account(uuid,text,uuid,boolean,boolean,text);
DROP FUNCTION ledger.create_fiscal_year(text,date,date);
DROP FUNCTION organization.create_branch(text,text);
DROP FUNCTION ledger.create_dimension(text,text,text);
-- Data backfills run as the operator: FORCE ROW LEVEL SECURITY would hide rows from serk_owner.
ALTER TABLE ledger.accounts ADD COLUMN statement_class text CHECK(statement_class IN('CURRENT','NON_CURRENT'));
ALTER TABLE ledger.accounts ADD CONSTRAINT accounts_statement_class_type
 CHECK((type IN('ASSET','LIABILITY'))=(statement_class IS NOT NULL)) NOT VALID;
-- One-time backfill using the previous presentation rule so existing statements do not move.
UPDATE ledger.accounts SET statement_class=CASE
 WHEN type='ASSET' AND (reporting_category ILIKE '%fixed%' OR reporting_category ILIKE '%property%' OR reporting_category ILIKE '%depreciation%' OR reporting_category ILIKE '%non-current%') THEN 'NON_CURRENT'
 WHEN type='LIABILITY' AND (reporting_category ILIKE '%long%' OR reporting_category ILIKE '%non-current%') THEN 'NON_CURRENT'
 ELSE 'CURRENT' END
WHERE type IN('ASSET','LIABILITY') AND statement_class IS NULL;
ALTER TABLE ledger.accounts VALIDATE CONSTRAINT accounts_statement_class_type;
SET LOCAL ROLE serk_owner;
DROP FUNCTION ledger.create_account(text,text,text,text,uuid,boolean,boolean,text);

------------------------------------------------------------------------------------------
-- S1: general-ledger commands only operate on MANUAL journals and reversals of MANUAL ones.
------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ledger.command(p_key text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,finance,security,pg_temp AS $$
DECLARE src text; original_src text;
BEGIN
 IF p_action<>'create' THEN
  SELECT j.source_type,o.source_type INTO src,original_src
  FROM ledger.journals j LEFT JOIN ledger.journals o ON o.id=j.reversed_from WHERE j.id=(p->>'id')::uuid;
  IF src IS NOT NULL AND NOT (src='MANUAL' OR (src='REVERSAL' AND original_src='MANUAL')) THEN
   RAISE EXCEPTION 'use_module_workflow' USING ERRCODE='55000';
  END IF;
 END IF;
 RETURN ledger.command_internal(p_key,p_action,p);
END $$;

------------------------------------------------------------------------------------------
-- S2: cross-company coverage for tenant-wide user changes.
------------------------------------------------------------------------------------------
CREATE FUNCTION security.admin_cover_user_tenant(p_user uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
BEGIN
 -- In every other company where the target has access, the actor must be a company-wide
 -- user administrator and must hold every permission the target holds there.
 IF EXISTS(
  SELECT FROM security.memberships m
  WHERE m.user_id=p_user AND m.company_id<>(SELECT security.company())
   AND NOT EXISTS(SELECT FROM security.memberships am JOIN security.role_permissions arp ON arp.role_id=am.role_id
     WHERE am.user_id=(SELECT security.actor()) AND am.company_id=m.company_id AND am.branch_id IS NULL AND arp.permission='user.manage'))
 OR EXISTS(
  SELECT FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
  WHERE m.user_id=p_user AND m.company_id<>(SELECT security.company())
   AND NOT EXISTS(SELECT FROM security.memberships am JOIN security.role_permissions arp ON arp.role_id=am.role_id
     WHERE am.user_id=(SELECT security.actor()) AND am.company_id=m.company_id AND am.branch_id IS NULL AND arp.permission=rp.permission))
 THEN RAISE EXCEPTION 'privilege_escalation' USING ERRCODE='42501'; END IF;
END $$;

CREATE OR REPLACE FUNCTION security.admin_lock_user(p_user uuid,p_version bigint) RETURNS security.users LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE u security.users;
 BEGIN
 SELECT * INTO u FROM security.users WHERE id=p_user AND tenant_id=(SELECT security.tenant()) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 IF u.version<>p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
 PERFORM security.admin_cover_user(p_user);
 PERFORM security.admin_cover_user_tenant(p_user);
 RETURN u;
 END $$;
REVOKE ALL ON FUNCTION security.admin_cover_user_tenant(uuid) FROM PUBLIC;

------------------------------------------------------------------------------------------
-- S3: master data. Explicit statement classification replaces name/category pattern matching.
------------------------------------------------------------------------------------------
-- (column, backfill and constraint are created above, before SET ROLE, so RLS does not hide rows)

CREATE FUNCTION ledger.default_statement_class() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,pg_temp AS $$ BEGIN
 -- Operator provisioning predates the column; ASSET/LIABILITY default to CURRENT there.
 IF NEW.type IN('ASSET','LIABILITY') AND NEW.statement_class IS NULL THEN NEW.statement_class:='CURRENT'; END IF;
 IF NEW.type NOT IN('ASSET','LIABILITY') THEN NEW.statement_class:=NULL; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER aa_default_statement_class BEFORE INSERT ON ledger.accounts FOR EACH ROW EXECUTE FUNCTION ledger.default_statement_class();

CREATE FUNCTION ledger.create_account(
 p_code text,p_name text,p_type text,p_normal_balance text,p_parent_id uuid,
 p_posting_allowed boolean,p_control_account boolean,p_reporting_category text,p_statement_class text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,security,pg_temp AS $$
DECLARE new_id uuid; t uuid:=(SELECT security.tenant()); c uuid:=(SELECT security.company());
BEGIN
 PERFORM security.require('configuration.manage');
 IF length(btrim(coalesce(p_code,''))) NOT BETWEEN 1 AND 32 OR length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 200
  OR length(btrim(coalesce(p_reporting_category,''))) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 IF (p_type IN('ASSET','LIABILITY')) <> (p_statement_class IS NOT NULL) OR coalesce(p_statement_class,'CURRENT') NOT IN('CURRENT','NON_CURRENT')
 THEN RAISE EXCEPTION 'statement_class_required' USING ERRCODE='22023'; END IF;
 IF p_parent_id IS NOT NULL THEN
  -- A parent that already carries entries cannot silently become a header account.
  IF EXISTS(SELECT FROM ledger.lines WHERE account_id=p_parent_id) THEN RAISE EXCEPTION 'parent_has_postings' USING ERRCODE='55000'; END IF;
  UPDATE ledger.accounts SET posting_allowed=false WHERE id=p_parent_id AND tenant_id=t AND company_id=c AND posting_allowed;
 END IF;
 INSERT INTO ledger.accounts(tenant_id,company_id,code,name,type,normal_balance,parent_id,posting_allowed,control_account,reporting_category,statement_class)
 VALUES(t,c,btrim(p_code),btrim(p_name),p_type,p_normal_balance,p_parent_id,p_posting_allowed,p_control_account,btrim(p_reporting_category),p_statement_class)
 RETURNING id INTO new_id;
 RETURN new_id;
END $$;

CREATE FUNCTION ledger.update_account(
 p_id uuid,p_name text,p_parent_id uuid,p_active boolean,p_posting_allowed boolean,p_reporting_category text,p_statement_class text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,finance,inventory,security,pg_temp AS $$
DECLARE a ledger.accounts; bal numeric;
BEGIN
 PERFORM security.require('configuration.manage');
 SELECT * INTO a FROM ledger.accounts WHERE id=p_id AND tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 200 OR p_active IS NULL OR p_posting_allowed IS NULL THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 IF (a.type IN('ASSET','LIABILITY')) <> (p_statement_class IS NOT NULL) OR coalesce(p_statement_class,'CURRENT') NOT IN('CURRENT','NON_CURRENT')
 THEN RAISE EXCEPTION 'statement_class_required' USING ERRCODE='22023'; END IF;
 IF a.active AND NOT p_active THEN
  SELECT coalesce(sum(l.functional_debit_minor-l.functional_credit_minor),0) INTO bal
  FROM ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id WHERE l.account_id=p_id AND j.state='POSTED';
  IF bal<>0 THEN RAISE EXCEPTION 'account_has_balance' USING ERRCODE='55000'; END IF;
  IF EXISTS(SELECT FROM ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id WHERE l.account_id=p_id AND j.state IN('DRAFT','SUBMITTED','APPROVED'))
  THEN RAISE EXCEPTION 'account_has_pending_entries' USING ERRCODE='55000'; END IF;
  IF EXISTS(SELECT FROM finance.settings s,jsonb_each_text(s.accounts) e WHERE s.company_id=a.company_id AND e.value=p_id::text)
   OR EXISTS(SELECT FROM finance.settings s,jsonb_array_elements_text(coalesce(s.accounts->'cash_accounts','[]')) x WHERE s.company_id=a.company_id AND x=p_id::text)
   OR EXISTS(SELECT FROM finance.control_accounts WHERE account_id=p_id)
   OR EXISTS(SELECT FROM inventory.items WHERE active AND p_id IN(income_account_id,expense_account_id,asset_account_id))
   OR EXISTS(SELECT FROM ledger.fx_rounding_settings WHERE account_id=p_id)
  THEN RAISE EXCEPTION 'account_in_use_by_configuration' USING ERRCODE='55000'; END IF;
 END IF;
 UPDATE ledger.accounts SET name=btrim(p_name),parent_id=p_parent_id,active=p_active,posting_allowed=p_posting_allowed,
  reporting_category=p_reporting_category,statement_class=p_statement_class WHERE id=p_id;
END $$;

CREATE FUNCTION ledger.create_fiscal_year(p_name text,p_start_date date,p_end_date date) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$
DECLARE t uuid:=(SELECT security.tenant()); c uuid:=(SELECT security.company()); fy_id uuid; i integer; ps date; pe date;
BEGIN
 PERFORM security.require('configuration.manage');
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 40 OR p_start_date IS NULL OR p_end_date IS NULL
  OR p_start_date>p_end_date OR p_end_date>p_start_date+interval '18 months' THEN RAISE EXCEPTION 'invalid_dates' USING ERRCODE='22008'; END IF;
 INSERT INTO ledger.fiscal_years(tenant_id,company_id,name,start_date,end_date) VALUES(t,c,btrim(p_name),p_start_date,p_end_date) RETURNING id INTO fy_id;
 FOR i IN 1..18 LOOP
  ps:=(p_start_date+((i-1)||' month')::interval)::date;
  EXIT WHEN ps>p_end_date;
  pe:=least((p_start_date+(i||' month')::interval)::date-1,p_end_date);
  INSERT INTO ledger.periods(tenant_id,company_id,fiscal_year_id,name,start_date,end_date,state) VALUES(t,c,fy_id,'Period '||i,ps,pe,'OPEN');
 END LOOP;
 INSERT INTO ledger.numbering(tenant_id,company_id,fiscal_year_id,document_type,prefix,next_value) VALUES(t,c,fy_id,'JOURNAL','JRN',1) ON CONFLICT DO NOTHING;
 RETURN fy_id;
END $$;

CREATE FUNCTION organization.create_branch(p_code text,p_name text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,organization,security,pg_temp AS $$
DECLARE new_id uuid;
BEGIN
 PERFORM security.require('configuration.manage');
 IF length(btrim(coalesce(p_code,''))) NOT BETWEEN 1 AND 32 OR length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 INSERT INTO organization.branches(tenant_id,company_id,code,name,active) VALUES((SELECT security.tenant()),(SELECT security.company()),btrim(p_code),btrim(p_name),true) RETURNING id INTO new_id;
 RETURN new_id;
END $$;

CREATE FUNCTION ledger.create_dimension(p_kind text,p_code text,p_name text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$
DECLARE new_id uuid;
BEGIN
 PERFORM security.require('configuration.manage');
 IF length(btrim(coalesce(p_code,''))) NOT BETWEEN 1 AND 32 OR length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 INSERT INTO ledger.dimensions(tenant_id,company_id,kind,code,name,active) VALUES((SELECT security.tenant()),(SELECT security.company()),p_kind,btrim(p_code),btrim(p_name),true) RETURNING id INTO new_id;
 RETURN new_id;
END $$;

REVOKE ALL ON FUNCTION ledger.create_account(text,text,text,text,uuid,boolean,boolean,text,text),
 ledger.update_account(uuid,text,uuid,boolean,boolean,text,text),ledger.create_fiscal_year(text,date,date),
 organization.create_branch(text,text),ledger.create_dimension(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.create_account(text,text,text,text,uuid,boolean,boolean,text,text),
 ledger.update_account(uuid,text,uuid,boolean,boolean,text,text),ledger.create_fiscal_year(text,date,date),
 organization.create_branch(text,text),ledger.create_dimension(text,text,text) TO serk_api;

-- Runtime (session-bound) changes are audited; operator provisioning has no company session
-- and is recorded by the operator audit path instead.
CREATE TRIGGER accounts_audit AFTER INSERT OR UPDATE ON ledger.accounts FOR EACH ROW WHEN (security.company() IS NOT NULL) EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER branches_audit AFTER INSERT OR UPDATE ON organization.branches FOR EACH ROW WHEN (security.company() IS NOT NULL) EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER dimensions_audit AFTER INSERT OR UPDATE ON ledger.dimensions FOR EACH ROW WHEN (security.company() IS NOT NULL) EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER fiscal_years_audit AFTER INSERT OR UPDATE ON ledger.fiscal_years FOR EACH ROW WHEN (security.company() IS NOT NULL) EXECUTE FUNCTION audit.record_change();

------------------------------------------------------------------------------------------
-- S4: no PUBLIC execute on application functions; keep current effective runtime access explicit.
------------------------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
 FOR f IN
  SELECT p.oid::regprocedure AS sig, n.nspname,
   has_function_privilege('serk_api',p.oid,'EXECUTE') AND has_schema_privilege('serk_api',n.oid,'USAGE') AS api,
   has_function_privilege('serk_auth',p.oid,'EXECUTE') AND has_schema_privilege('serk_auth',n.oid,'USAGE') AS auth
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname IN('ledger','security','finance','organization','audit','integration','core','taxes','payroll','inventory','invoicing')
   AND p.prokind='f' AND has_function_privilege('public',p.oid,'EXECUTE')
 LOOP
  IF f.api THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO serk_api',f.sig); END IF;
  IF f.auth THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO serk_auth',f.sig); END IF;
  EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC',f.sig);
 END LOOP;
END $$;
ALTER DEFAULT PRIVILEGES FOR ROLE serk_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

------------------------------------------------------------------------------------------
-- S5: tenant scope on companies; least-privilege table grants.
------------------------------------------------------------------------------------------
ALTER TABLE organization.companies ENABLE ROW LEVEL SECURITY;
CREATE POLICY api_tenant ON organization.companies TO serk_api USING(tenant_id=(SELECT security.tenant()));
REVOKE INSERT,UPDATE ON inventory.items,invoicing.customers,invoicing.vendors,payroll.employees,taxes.tax_agencies,taxes.tax_rates FROM serk_api;

------------------------------------------------------------------------------------------
-- S6: per-account login window across all sources (50 attempts per 15 minutes).
------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION security.consume_login_attempt(p_slug text,p_email text,p_source text) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
DECLARE n integer; m integer; stamp timestamptz:=clock_timestamp();
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
 INSERT INTO security.login_windows VALUES
 (encode(sha256(convert_to(jsonb_build_array(p_slug,lower(btrim(p_email)),'*account*')::text,'UTF8')),'hex'),stamp,1)
 ON CONFLICT(key_hash) DO UPDATE SET
 attempts=CASE WHEN login_windows.window_start<stamp-interval '15 minutes' THEN 1 ELSE least(login_windows.attempts+1,1000) END,
 window_start=CASE WHEN login_windows.window_start<stamp-interval '15 minutes' THEN stamp ELSE login_windows.window_start END
 RETURNING attempts INTO m;
 RETURN n<=10 AND m<=50;
END $$;
