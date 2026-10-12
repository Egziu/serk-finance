-- 031_profile_mfa.sql
SET LOCAL ROLE serk_owner;

ALTER TABLE security.admin_events DROP CONSTRAINT IF EXISTS admin_events_action_check;
ALTER TABLE security.admin_events ADD CONSTRAINT admin_events_action_check CHECK(action IN
 ('reset_password','disable_user','enable_user','revoke_sessions','enroll_mfa','disable_mfa','grant_super_admin','create_user'));

CREATE OR REPLACE FUNCTION security.current_user_mfa_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
DECLARE
  uid uuid := security.actor();
  enrolled boolean;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  SELECT EXISTS(SELECT FROM security.user_mfa WHERE user_id = uid) INTO enrolled;
  RETURN jsonb_build_object('enrolled', enrolled);
END;
$$;
GRANT EXECUTE ON FUNCTION security.current_user_mfa_status() TO serk_api;

CREATE OR REPLACE FUNCTION security.self_enroll_mfa(p_encrypted_secret text, p_step bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
DECLARE
  uid uuid := security.actor();
  tid uuid := security.tenant();
BEGIN
  IF uid IS NULL OR tid IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  INSERT INTO security.user_mfa(user_id, tenant_id, encrypted_secret, last_step)
  VALUES(uid, tid, p_encrypted_secret, p_step)
  ON CONFLICT(user_id) DO UPDATE SET encrypted_secret = EXCLUDED.encrypted_secret, last_step = EXCLUDED.last_step, version = gen_random_uuid();

  INSERT INTO security.admin_events(tenant_id, target_user_id, action, reason)
  VALUES(tid, uid, 'enroll_mfa', 'Self-service MFA enabled from user profile');

  RETURN jsonb_build_object('status', 'enabled');
END;
$$;
GRANT EXECUTE ON FUNCTION security.self_enroll_mfa(text, bigint) TO serk_api;

CREATE OR REPLACE FUNCTION security.self_disable_mfa()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
DECLARE
  uid uuid := security.actor();
  tid uuid := security.tenant();
BEGIN
  IF uid IS NULL OR tid IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  DELETE FROM security.user_mfa WHERE user_id = uid;

  INSERT INTO security.admin_events(tenant_id, target_user_id, action, reason)
  VALUES(tid, uid, 'disable_mfa', 'Self-service MFA disabled from user profile');

  RETURN jsonb_build_object('status', 'disabled');
END;
$$;
GRANT EXECUTE ON FUNCTION security.self_disable_mfa() TO serk_api;
