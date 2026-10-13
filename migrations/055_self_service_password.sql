-- 0.3.0-rc1: users change their own password.
--
-- The API verifies the current password (argon2id) and hashes the new one; this function only
-- accepts the change when the session is live and the stored hash still equals the one the API
-- verified, then revokes every session of the user and records the event.
SET LOCAL ROLE serk_owner;

ALTER TABLE security.admin_events DROP CONSTRAINT admin_events_action_check;
ALTER TABLE security.admin_events ADD CONSTRAINT admin_events_action_check CHECK(action IN
 ('reset_password','disable_user','enable_user','revoke_sessions','enroll_mfa','disable_mfa','grant_super_admin','create_user','change_own_password'));

CREATE FUNCTION security.change_own_password(p_token text,p_verified_hash text,p_new_hash text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
DECLARE uid uuid; tid uuid;
BEGIN
 SELECT u.id,u.tenant_id INTO uid,tid FROM security.sessions s JOIN security.users u ON u.id=s.user_id JOIN security.tenants t ON t.id=u.tenant_id
 WHERE s.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') AND s.revoked_at IS NULL AND s.expires_at>statement_timestamp()
 AND u.password_hash=p_verified_hash AND u.active AND t.active FOR UPDATE OF u;
 IF uid IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 IF p_new_hash IS NULL OR p_new_hash !~ '^\$argon2id\$' OR p_new_hash=p_verified_hash THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 UPDATE security.users SET password_hash=p_new_hash,version=version+1 WHERE id=uid;
 UPDATE security.sessions SET revoked_at=clock_timestamp() WHERE user_id=uid AND revoked_at IS NULL;
 INSERT INTO security.admin_events(tenant_id,target_user_id,action,reason)
 VALUES(tid,uid,'change_own_password','Verified current password; all sessions revoked');
 RETURN jsonb_build_object('status','changed','reauthentication_required',true);
END $$;
REVOKE ALL ON FUNCTION security.change_own_password(text,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.change_own_password(text,text,text) TO serk_auth;

-- Publish the runtime marker only after every 0.3.0 migration is present.
CREATE OR REPLACE FUNCTION security.release_version() RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT '0.3.0-rc1'::text $$;
