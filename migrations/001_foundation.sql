-- Applied as the deployment migrator. Runtime roles are never object owners.
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='serk_owner') THEN CREATE ROLE serk_owner NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='serk_api') THEN CREATE ROLE serk_api NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='serk_auth') THEN CREATE ROLE serk_auth NOLOGIN NOSUPERUSER NOBYPASSRLS; END IF;
END $$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
CREATE SCHEMA security AUTHORIZATION serk_owner;
CREATE SCHEMA organization AUTHORIZATION serk_owner;
CREATE SCHEMA ledger AUTHORIZATION serk_owner;
CREATE SCHEMA audit AUTHORIZATION serk_owner;
CREATE SCHEMA integration AUTHORIZATION serk_owner;
SET LOCAL ROLE serk_owner;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE security.tenants (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), slug text NOT NULL UNIQUE CHECK(slug ~ '^[a-z0-9-]{2,63}$'),
 name text NOT NULL CHECK(length(name) BETWEEN 1 AND 200), active boolean NOT NULL DEFAULT true
);
CREATE TABLE security.users (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES security.tenants(id),
 email text NOT NULL CHECK(email=lower(email) AND length(email)<=254), display_name text NOT NULL,
 password_hash text NOT NULL CHECK(password_hash LIKE '$argon2id$%'), active boolean NOT NULL DEFAULT true,
 UNIQUE(tenant_id,email), UNIQUE(tenant_id,id)
);
CREATE TABLE security.sessions (
 token_hash text PRIMARY KEY CHECK(token_hash ~ '^[0-9a-f]{64}$'),
 tenant_id uuid NOT NULL, user_id uuid NOT NULL, csrf_token text NOT NULL,
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(), expires_at timestamptz NOT NULL,
 revoked_at timestamptz, FOREIGN KEY(tenant_id,user_id) REFERENCES security.users(tenant_id,id)
);
CREATE INDEX sessions_expiry ON security.sessions(expires_at);
CREATE TABLE organization.currencies (
 code text PRIMARY KEY CHECK(code ~ '^[A-Z]{3}$'), minor_units smallint NOT NULL CHECK(minor_units BETWEEN 0 AND 4)
);
INSERT INTO organization.currencies VALUES ('ETB',2),('USD',2),('EUR',2),('KES',2),('UGX',0),('RWF',0),('TZS',2),('DJF',0),('SOS',2);
CREATE TABLE organization.companies (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES security.tenants(id),
 code text NOT NULL, name text NOT NULL, functional_currency text NOT NULL REFERENCES organization.currencies(code),
 country_code text NOT NULL CHECK(country_code ~ '^[A-Z]{2}$'), active boolean NOT NULL DEFAULT true,
 UNIQUE(tenant_id,id), UNIQUE(tenant_id,code)
);
CREATE TABLE organization.branches (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL, company_id uuid NOT NULL,
 code text NOT NULL, name text NOT NULL, active boolean NOT NULL DEFAULT true,
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 UNIQUE(tenant_id,company_id,id), UNIQUE(company_id,code)
);
CREATE TABLE security.permissions (code text PRIMARY KEY);
INSERT INTO security.permissions VALUES ('ledger.read'),('journal.create'),('journal.submit'),('journal.approve'),
 ('journal.post'),('journal.reverse'),('journal.void'),('period.close'),('audit.read'),('configuration.manage');
CREATE TABLE security.roles (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), tenant_id uuid NOT NULL REFERENCES security.tenants(id),
 name text NOT NULL, UNIQUE(tenant_id,id), UNIQUE(tenant_id,name)
);
CREATE TABLE security.role_permissions (
 tenant_id uuid NOT NULL, role_id uuid NOT NULL, permission text NOT NULL REFERENCES security.permissions(code),
 PRIMARY KEY(role_id,permission), FOREIGN KEY(tenant_id,role_id) REFERENCES security.roles(tenant_id,id)
);
CREATE TABLE security.memberships (
 tenant_id uuid NOT NULL, company_id uuid NOT NULL, user_id uuid NOT NULL, role_id uuid NOT NULL,
 branch_id uuid, approval_limit_minor numeric CHECK(approval_limit_minor>=0 AND approval_limit_minor=trunc(approval_limit_minor)),
 PRIMARY KEY(company_id,user_id,role_id),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,user_id) REFERENCES security.users(tenant_id,id),
 FOREIGN KEY(tenant_id,role_id) REFERENCES security.roles(tenant_id,id),
 FOREIGN KEY(tenant_id,company_id,branch_id) REFERENCES organization.branches(tenant_id,company_id,id)
);

CREATE FUNCTION security.actor() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT s.user_id FROM security.sessions s JOIN security.users u ON (u.id=s.user_id AND u.tenant_id=s.tenant_id)
 JOIN security.tenants t ON t.id=s.tenant_id
 WHERE s.token_hash=nullif(current_setting('serk.token_hash',true),'')
 AND s.revoked_at IS NULL AND s.expires_at>statement_timestamp() AND u.active AND t.active
$$;
CREATE FUNCTION security.tenant() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT tenant_id FROM security.users WHERE id=security.actor()
$$;
CREATE FUNCTION security.company() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,organization,pg_temp AS $$
 SELECT c.id FROM organization.companies c WHERE c.id=nullif(current_setting('serk.company_id',true),'')::uuid
 AND c.tenant_id=security.tenant() AND c.active
 AND EXISTS(SELECT FROM security.memberships m WHERE m.company_id=c.id AND m.user_id=security.actor())
$$;
-- Organization company lookup in company() must not recursively evaluate its RLS policy.
-- The table is private: runtime company discovery is only through session_info().
CREATE FUNCTION security.can(p_permission text, p_branch uuid DEFAULT NULL, p_amount numeric DEFAULT 0)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT EXISTS(SELECT FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=security.company() AND m.user_id=security.actor() AND rp.permission=p_permission
 AND (m.branch_id IS NULL OR m.branch_id=p_branch)
 AND (p_permission<>'journal.approve' OR m.approval_limit_minor IS NULL OR p_amount<=m.approval_limit_minor))
$$;
CREATE FUNCTION security.visible_branch(p_branch uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT security.can('ledger.read',p_branch,0)
$$;
CREATE FUNCTION security.require(p_permission text, p_branch uuid DEFAULT NULL, p_amount numeric DEFAULT 0)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 BEGIN IF NOT security.can(p_permission,p_branch,p_amount) THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF; END $$;
CREATE FUNCTION security.bind(p_token text,p_company uuid,p_csrf text DEFAULT NULL,p_context jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE a uuid; expected text;
 BEGIN
 PERFORM set_config('serk.token_hash',encode(sha256(convert_to(p_token,'UTF8')),'hex'),true);
 a:=security.actor();
 IF a IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 PERFORM set_config('serk.company_id',p_company::text,true);
 IF security.company() IS NULL THEN RAISE EXCEPTION 'company_access_denied' USING ERRCODE='42501'; END IF;
 IF p_csrf IS NOT NULL THEN
  SELECT csrf_token INTO expected FROM security.sessions WHERE token_hash=current_setting('serk.token_hash');
  IF p_csrf<>expected THEN RAISE EXCEPTION 'invalid_csrf' USING ERRCODE='42501'; END IF;
 END IF;
 PERFORM set_config('serk.request_context',p_context::text,true);
 RETURN a;
 END $$;

CREATE FUNCTION security.login_record(p_slug text,p_email text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT jsonb_build_object('user_id',u.id,'password_hash',u.password_hash) FROM security.users u
 JOIN security.tenants t ON t.id=u.tenant_id WHERE t.slug=p_slug AND u.email=p_email AND u.active AND t.active
$$;
CREATE FUNCTION security.issue_session(p_user uuid,p_hash text,p_csrf text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 BEGIN
 INSERT INTO security.sessions(token_hash,tenant_id,user_id,csrf_token,expires_at)
 SELECT p_hash,tenant_id,id,p_csrf,statement_timestamp()+interval '8 hours' FROM security.users WHERE id=p_user AND active;
 IF NOT FOUND THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 END $$;
CREATE FUNCTION security.revoke_session(p_token text) RETURNS void LANGUAGE sql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 UPDATE security.sessions SET revoked_at=clock_timestamp() WHERE token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
$$;
CREATE FUNCTION security.session_info(p_token text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,organization,pg_temp AS $$
 DECLARE a uuid; result jsonb;
 BEGIN
 PERFORM set_config('serk.token_hash',encode(sha256(convert_to(p_token,'UTF8')),'hex'),true);
 a:=security.actor(); IF a IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 SELECT jsonb_build_object('user_id',u.id,'name',u.display_name,'csrf_token',s.csrf_token,'companies',
  coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'currency',c.functional_currency))
   FROM organization.companies c WHERE c.tenant_id=u.tenant_id AND c.active AND EXISTS
   (SELECT FROM security.memberships m WHERE m.company_id=c.id AND m.user_id=u.id)),'[]'::jsonb)) INTO result
 FROM security.users u JOIN security.sessions s ON s.user_id=u.id
 WHERE u.id=a AND s.token_hash=current_setting('serk.token_hash');
 RETURN result;
 END $$;

GRANT USAGE ON SCHEMA security TO serk_api,serk_auth;
GRANT USAGE ON SCHEMA organization,ledger,audit,integration TO serk_api;
GRANT EXECUTE ON FUNCTION security.actor(),security.tenant(),security.company(),security.can(text,uuid,numeric),
 security.visible_branch(uuid),security.require(text,uuid,numeric),security.bind(text,uuid,text,jsonb),security.session_info(text)
 TO serk_api;
GRANT EXECUTE ON FUNCTION security.login_record(text,text),security.issue_session(uuid,text,text),security.revoke_session(text)
 TO serk_auth;
GRANT SELECT ON organization.currencies TO serk_api;
ALTER TABLE organization.branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE organization.branches FORCE ROW LEVEL SECURITY;
CREATE POLICY scoped ON organization.branches USING(tenant_id=security.tenant() AND company_id=security.company()
 AND security.visible_branch(id));
GRANT SELECT ON organization.branches TO serk_api;
