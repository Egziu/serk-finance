SET LOCAL ROLE serk_owner;
ALTER TABLE security.sessions ADD COLUMN mfa_verified boolean NOT NULL DEFAULT false;
CREATE TABLE security.user_mfa (
 user_id uuid PRIMARY KEY,tenant_id uuid NOT NULL,
 encrypted_secret text NOT NULL CHECK(length(encrypted_secret) BETWEEN 40 AND 512),
 version uuid NOT NULL DEFAULT gen_random_uuid(),last_step bigint NOT NULL DEFAULT -1,
 FOREIGN KEY(tenant_id,user_id) REFERENCES security.users(tenant_id,id)
);
ALTER TABLE security.admin_events DROP CONSTRAINT admin_events_action_check;
ALTER TABLE security.admin_events ADD CONSTRAINT admin_events_action_check CHECK(action IN ('reset_password','disable_user','enable_user','revoke_sessions','enroll_mfa'));
CREATE OR REPLACE FUNCTION security.login_record(p_slug text,p_email text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT jsonb_build_object('user_id',u.id,'password_hash',u.password_hash,'mfa_secret',m.encrypted_secret,'mfa_version',m.version)
 FROM security.users u JOIN security.tenants t ON t.id=u.tenant_id LEFT JOIN security.user_mfa m ON m.user_id=u.id
 WHERE t.slug=p_slug AND u.email=p_email AND u.active AND t.active $$;
-- The password-only path remains operator-private for historical migration compatibility.
REVOKE EXECUTE ON FUNCTION security.issue_verified_session(uuid,text,text,text) FROM serk_auth;
CREATE FUNCTION security.issue_verified_session(p_user uuid,p_hash text,p_csrf text,p_verified_hash text,p_mfa_version uuid,p_step bigint,p_required boolean)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE m security.user_mfa; current_step bigint:=floor(extract(epoch FROM clock_timestamp())/30);
 BEGIN
 PERFORM 1 FROM security.users u JOIN security.tenants t ON t.id=u.tenant_id
 WHERE u.id=p_user AND u.active AND t.active AND u.password_hash=p_verified_hash FOR SHARE OF u,t;
 IF NOT FOUND THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 SELECT * INTO m FROM security.user_mfa WHERE user_id=p_user FOR UPDATE;
 IF FOUND THEN
  IF p_mfa_version IS DISTINCT FROM m.version OR p_step IS NULL OR p_step<=m.last_step OR p_step NOT BETWEEN current_step-1 AND current_step+1 THEN
   RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  UPDATE security.user_mfa SET last_step=p_step WHERE user_id=p_user;
 ELSIF p_required IS DISTINCT FROM false OR p_mfa_version IS NOT NULL THEN
  RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000';
 END IF;
 IF p_csrf !~ '^[A-Za-z0-9_-]{43}$' THEN RAISE EXCEPTION 'invalid_csrf' USING ERRCODE='22023'; END IF;
 PERFORM security.issue_session(p_user,p_hash,p_csrf);
 UPDATE security.sessions SET mfa_verified=(m.user_id IS NOT NULL) WHERE token_hash=p_hash;
 END $$;
GRANT EXECUTE ON FUNCTION security.issue_verified_session(uuid,text,text,text,uuid,bigint,boolean) TO serk_auth;
-- Existing password-only sessions cannot survive the security upgrade.
UPDATE security.sessions SET revoked_at=clock_timestamp() WHERE revoked_at IS NULL;

CREATE FUNCTION security.require_session_assurance(p_token text,p_required boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 BEGIN
 IF p_required IS DISTINCT FROM false AND NOT EXISTS(SELECT FROM security.sessions
 WHERE token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') AND mfa_verified AND revoked_at IS NULL AND expires_at>statement_timestamp())
 THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 END $$;
GRANT EXECUTE ON FUNCTION security.require_session_assurance(text,boolean) TO serk_api;
CREATE OR REPLACE FUNCTION security.release_version() RETURNS text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog,pg_temp AS $$ SELECT '0.2.0-rc2'::text $$;
