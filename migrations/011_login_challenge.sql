-- Two-step MFA login: password first, then an authenticator code bound to a
-- short-lived, single-use, attempt-limited challenge. Released migrations 001-010 stay unchanged.
--
-- The challenge token is returned to the client once and stored only as a SHA-256 digest.
-- It proves the password step only; it never carries or reveals the TOTP code or secret.
-- A session is still issued exclusively by issue_verified_session, which re-checks the
-- current password hash and MFA enrollment version and consumes the TOTP time step once.
SET LOCAL ROLE serk_owner;

CREATE TABLE security.login_challenges (
 token_hash text PRIMARY KEY CHECK(token_hash ~ '^[0-9a-f]{64}$'),
 tenant_id uuid NOT NULL, user_id uuid NOT NULL,
 password_digest text NOT NULL CHECK(password_digest ~ '^[0-9a-f]{64}$'),
 mfa_version uuid NOT NULL,
 attempts smallint NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 expires_at timestamptz NOT NULL, consumed_at timestamptz,
 FOREIGN KEY(tenant_id,user_id) REFERENCES security.users(tenant_id,id)
);
CREATE INDEX login_challenges_expiry ON security.login_challenges(expires_at);
CREATE INDEX login_challenges_user ON security.login_challenges(user_id);

-- Called after the password has been verified. Replaces any open challenge of the user.
CREATE FUNCTION security.create_login_challenge(p_user uuid,p_hash text,p_verified_hash text,p_mfa_version uuid)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE t uuid; stamp timestamptz:=clock_timestamp();
 BEGIN
 IF p_hash !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 -- Bounded cleanup work on the indexed expiry column.
 DELETE FROM security.login_challenges WHERE token_hash IN
 (SELECT token_hash FROM security.login_challenges WHERE expires_at<stamp-interval '1 hour' ORDER BY expires_at LIMIT 100);
 SELECT u.tenant_id INTO t FROM security.users u JOIN security.tenants t ON t.id=u.tenant_id
 JOIN security.user_mfa m ON m.user_id=u.id
 WHERE u.id=p_user AND u.active AND t.active AND u.password_hash=p_verified_hash AND m.version=p_mfa_version;
 IF NOT FOUND THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 DELETE FROM security.login_challenges WHERE user_id=p_user;
 INSERT INTO security.login_challenges(token_hash,tenant_id,user_id,password_digest,mfa_version,expires_at)
 VALUES(p_hash,t,p_user,encode(sha256(convert_to(p_verified_hash,'UTF8')),'hex'),p_mfa_version,stamp+interval '5 minutes');
 END $$;

-- Counts one attempt (committed by the caller before the code is checked) and returns the
-- current login record. Fails once expired, consumed, out of attempts, or if the password
-- or MFA enrollment changed after the challenge was issued.
CREATE FUNCTION security.open_login_challenge(p_hash text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE c security.login_challenges; r jsonb;
 BEGIN
 SELECT * INTO c FROM security.login_challenges WHERE token_hash=p_hash FOR UPDATE;
 IF NOT FOUND OR c.consumed_at IS NOT NULL OR c.expires_at<=clock_timestamp() OR c.attempts>=5 THEN
  RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 UPDATE security.login_challenges SET attempts=attempts+1 WHERE token_hash=p_hash;
 SELECT jsonb_build_object('user_id',u.id,'tenant',t.slug,'email',u.email,'password_hash',u.password_hash,
  'mfa_secret',m.encrypted_secret,'mfa_version',m.version) INTO r
 FROM security.users u JOIN security.tenants t ON t.id=u.tenant_id JOIN security.user_mfa m ON m.user_id=u.id
 WHERE u.id=c.user_id AND u.active AND t.active AND m.version=c.mfa_version
 AND encode(sha256(convert_to(u.password_hash,'UTF8')),'hex')=c.password_digest;
 IF r IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 RETURN r;
 END $$;

-- Single use: runs in the same transaction that issues the session.
CREATE FUNCTION security.finish_login_challenge(p_hash text) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 BEGIN
 UPDATE security.login_challenges SET consumed_at=clock_timestamp()
 WHERE token_hash=p_hash AND consumed_at IS NULL AND expires_at>clock_timestamp();
 IF NOT FOUND THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 END $$;

REVOKE ALL ON TABLE security.login_challenges FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION security.create_login_challenge(uuid,text,text,uuid),security.open_login_challenge(text),security.finish_login_challenge(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.create_login_challenge(uuid,text,text,uuid),security.open_login_challenge(text),security.finish_login_challenge(text) TO serk_auth;
