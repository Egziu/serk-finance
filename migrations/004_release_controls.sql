-- Additive upgrade: never edit the checksummed 001-003 migrations.
SET LOCAL ROLE serk_owner;

CREATE TABLE security.login_windows (
 key_hash text PRIMARY KEY,
 window_start timestamptz NOT NULL,
 attempts integer NOT NULL CHECK(attempts > 0)
);
CREATE INDEX login_windows_age ON security.login_windows(window_start);
CREATE FUNCTION security.consume_login_attempt(p_slug text, p_email text) RETURNS boolean
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE n integer; stamp timestamptz := clock_timestamp();
 BEGIN
 IF length(p_slug)>63 OR length(p_email)>254 THEN RETURN false; END IF;
 INSERT INTO security.login_windows VALUES
  (encode(sha256(convert_to(jsonb_build_array(p_slug,p_email)::text,'UTF8')),'hex'),stamp,1)
 ON CONFLICT(key_hash) DO UPDATE SET
  attempts=CASE WHEN login_windows.window_start < stamp-interval '1 minute' THEN 1 ELSE least(login_windows.attempts+1,1000) END,
  window_start=CASE WHEN login_windows.window_start < stamp-interval '1 minute' THEN stamp ELSE login_windows.window_start END
 RETURNING attempts INTO n;
 RETURN n<=10;
 END $$;
GRANT EXECUTE ON FUNCTION security.consume_login_attempt(text,text) TO serk_auth;

-- Password/active-state recheck and row lock close the verification/issuance race.
CREATE FUNCTION security.issue_verified_session(p_user uuid,p_hash text,p_csrf text,p_verified_hash text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 BEGIN
 PERFORM 1 FROM security.users u JOIN security.tenants t ON t.id=u.tenant_id
 WHERE u.id=p_user AND u.active AND t.active AND u.password_hash=p_verified_hash FOR SHARE OF u,t;
 IF NOT FOUND THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 IF p_csrf !~ '^[A-Za-z0-9_-]{43}$' THEN RAISE EXCEPTION 'invalid_csrf' USING ERRCODE='22023'; END IF;
 PERFORM security.issue_session(p_user,p_hash,p_csrf);
 END $$;
REVOKE EXECUTE ON FUNCTION security.issue_session(uuid,text,text) FROM serk_auth;
GRANT EXECUTE ON FUNCTION security.issue_verified_session(uuid,text,text,text) TO serk_auth;

CREATE TABLE security.admin_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 tenant_id uuid NOT NULL REFERENCES security.tenants(id),
 target_user_id uuid NOT NULL,
 actor_login text NOT NULL DEFAULT session_user,
 action text NOT NULL CHECK(action IN ('reset_password','disable_user','enable_user','revoke_sessions')),
 reason text NOT NULL CHECK(length(btrim(reason)) BETWEEN 3 AND 1000),
 recorded_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(tenant_id,target_user_id) REFERENCES security.users(tenant_id,id)
);
CREATE TRIGGER immutable_admin_events BEFORE UPDATE OR DELETE ON security.admin_events
 FOR EACH ROW EXECUTE FUNCTION ledger.block_mutation();

-- Approval must still be authorized at posting. Lock matched rows until commit,
-- so a concurrent operator revocation/disable cannot invalidate an already checked row.
CREATE FUNCTION ledger.recheck_posting_approval() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE amount numeric;
 BEGIN
 IF OLD.state='APPROVED' AND NEW.state='POSTED' THEN
  SELECT sum(functional_debit_minor) INTO amount FROM ledger.lines WHERE journal_id=OLD.id;
  PERFORM 1 FROM security.users u
   JOIN security.memberships m ON m.user_id=u.id AND m.tenant_id=u.tenant_id
   JOIN security.role_permissions rp ON rp.role_id=m.role_id AND rp.tenant_id=m.tenant_id
   WHERE u.id=OLD.approved_by AND u.active AND u.tenant_id=OLD.tenant_id
   AND m.company_id=OLD.company_id AND (m.branch_id IS NULL OR m.branch_id=OLD.branch_id)
   AND rp.permission='journal.approve' AND (m.approval_limit_minor IS NULL OR amount<=m.approval_limit_minor)
   FOR SHARE OF u,m,rp;
  IF NOT FOUND THEN RAISE EXCEPTION 'approval_no_longer_authorized' USING ERRCODE='42501'; END IF;
 END IF;
 RETURN NEW;
 END $$;
CREATE TRIGGER aa_recheck_posting_approval BEFORE UPDATE ON ledger.journals
 FOR EACH ROW EXECUTE FUNCTION ledger.recheck_posting_approval();

-- Existing amounts must retain their denomination and fiscal interpretation.
CREATE FUNCTION organization.guard_currency_definition() RETURNS trigger LANGUAGE plpgsql
 SET search_path=pg_catalog,organization,ledger,pg_temp AS $$
 BEGIN
 IF TG_TABLE_NAME='currencies' THEN
  IF (NEW.code,NEW.minor_units) IS DISTINCT FROM (OLD.code,OLD.minor_units)
   AND EXISTS(SELECT FROM organization.companies WHERE functional_currency=OLD.code
    UNION ALL SELECT FROM ledger.journals WHERE currency=OLD.code OR functional_currency=OLD.code)
  THEN RAISE EXCEPTION 'currency_definition_in_use' USING ERRCODE='55000'; END IF;
 ELSE
  IF NEW.functional_currency IS DISTINCT FROM OLD.functional_currency
   AND EXISTS(SELECT FROM ledger.journals WHERE company_id=OLD.id)
  THEN RAISE EXCEPTION 'functional_currency_in_use' USING ERRCODE='55000'; END IF;
 END IF;
 RETURN NEW;
 END $$;
CREATE TRIGGER currency_definition BEFORE UPDATE ON organization.currencies
 FOR EACH ROW EXECUTE FUNCTION organization.guard_currency_definition();
CREATE TRIGGER company_currency BEFORE UPDATE ON organization.companies
 FOR EACH ROW EXECUTE FUNCTION organization.guard_currency_definition();

CREATE FUNCTION ledger.guard_year() RETURNS trigger LANGUAGE plpgsql
 SET search_path=pg_catalog,ledger,pg_temp AS $$
 BEGIN
 IF (NEW.id,NEW.company_id,NEW.tenant_id,NEW.name,NEW.start_date,NEW.end_date)
 IS DISTINCT FROM (OLD.id,OLD.company_id,OLD.tenant_id,OLD.name,OLD.start_date,OLD.end_date)
 AND EXISTS(SELECT FROM ledger.periods WHERE fiscal_year_id=OLD.id)
 THEN RAISE EXCEPTION 'fiscal_year_in_use' USING ERRCODE='55000'; END IF;
 RETURN NEW;
 END $$;
CREATE TRIGGER fiscal_year_definition BEFORE UPDATE ON ledger.fiscal_years
 FOR EACH ROW EXECUTE FUNCTION ledger.guard_year();

CREATE TABLE ledger.period_receipts (
 tenant_id uuid NOT NULL,company_id uuid NOT NULL,user_id uuid NOT NULL,
 key text NOT NULL CHECK(length(key) BETWEEN 8 AND 128),request_hash text NOT NULL,response jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(company_id,user_id,key),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,user_id) REFERENCES security.users(tenant_id,id)
);
ALTER TABLE ledger.period_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger.period_receipts FORCE ROW LEVEL SECURITY;
CREATE POLICY scoped ON ledger.period_receipts USING(tenant_id=security.tenant() AND company_id=security.company());
CREATE FUNCTION ledger.close_period_command(p_key text,p_id uuid,p_version bigint,p_reason text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE prior ledger.period_receipts; h text; result jsonb;
 BEGIN
 PERFORM security.require('period.close');
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'idempotency_key_required' USING ERRCODE='22023'; END IF;
 h:=encode(sha256(convert_to(jsonb_build_array(p_id,p_version,p_reason)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended('period:'||security.company()::text||security.actor()::text||p_key,0));
 SELECT * INTO prior FROM ledger.period_receipts WHERE company_id=security.company() AND user_id=security.actor() AND key=p_key;
 IF FOUND THEN
  IF prior.request_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='22000'; END IF;
  RETURN prior.response;
 END IF;
 result:=ledger.close_period(p_id,p_version,p_reason);
 INSERT INTO ledger.period_receipts VALUES(security.tenant(),security.company(),security.actor(),p_key,h,result,clock_timestamp());
 RETURN result;
 END $$;
GRANT EXECUTE ON FUNCTION ledger.close_period_command(text,uuid,bigint,text) TO serk_api;
