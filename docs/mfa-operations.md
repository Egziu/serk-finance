# MFA enrollment and recovery

Staging and production require a password and a six-digit TOTP authenticator code. An enrolled user also requires MFA in development. Password-only sessions cannot access an MFA-required API, even if they were created by a development instance or restored from a backup. Migration 007 revokes pre-upgrade sessions.

The implementation uses `github.com/pquerna/otp` v1.5.0 (30-second periods, six digits, SHA-1 HMAC for authenticator compatibility, at most one adjacent period of clock skew). AES-256-GCM with a fresh random nonce encrypts each secret; authenticated data binds it to the user UUID. The database stores the encrypted secret and an enrollment version. Session issuance locks the user/MFA record, checks the verified password and enrollment version, and consumes the time step once. A parallel replay must not issue a second session. The native replay test is provided; its execution is still blocked in this workspace.

## Deployment key

Generate 32 random bytes, encode them as standard base64, and store them in your secret manager. Supply `SERK_MFA_KEY_FILE` to the API and enrollment command (or `SERK_MFA_KEY`, never both). The release Compose manifest mounts `SERK_MFA_KEY_PATH` at `/run/serk/mfa-key`. Its non-root runtime UID 65532 must be able to read the mounted file; it must not be world-accessible. Use the same key for every API replica serving that database. `SERK_REQUIRE_MFA=true` enables the same policy for a development acceptance environment.

Back up this key separately from the database, with independently controlled access and recovery approval. A database backup alone cannot restore authenticator access. Do not replace a live key file without a coordinated reenrollment/recovery plan: there is no online key-ring rotation workflow in this release.

## Enroll a device

This release uses an offline operator workflow. The operator must verify the user's identity and obtain the organization's required privileged-change approval. The database operator identity must be individually attributable. Application-level dual approval for privileged administration is not implemented.

1. Generate the device setup material in a protected operator environment:

   ```bash
   umask 077
   go run ./cmd/mfa --prepare 'your-workspace:user@example.com' > /protected/mfa-setup.json
   ```

2. Deliver the `otpauth_uri` or base32 `secret` to the verified user through your approved secure channel. Import it into the user's authenticator. These are secrets, not ordinary audit attachments. Do not place them in tickets, command-line arguments, application logs, or source control.
3. Create a protected JSON enrollment request containing `tenant`, `email`, `secret`, the current six-digit `code` from the device, and a nonsecret `reason`/approval reference. Provide operator database credentials and the encryption-key file, then run:

   ```bash
   go run ./cmd/mfa < /protected/mfa-enrollment.json
   ```

   In the tools image the entrypoint is `/app/mfa`. The request is supplied on standard input. Successful enrollment records `enroll_mfa` in the private append-only administrator audit, revokes existing sessions, and consumes the proof's time step.
4. Wait for the next code before signing in. Retain approval/audit evidence; securely dispose of temporary secret-bearing setup/request files according to policy.

## Signing in (two-step)

1. `POST /api/v1/auth/login` with `tenant`, `email` and `password`. For an enrolled user the reply is `{"mfa_required":true,"mfa_token":"…","expires_in":300}` and no session.
2. `POST /api/v1/auth/login/mfa` with `mfa_token` and the current six-digit `code`. The reply sets the session cookie and returns `csrf_token`.

The `mfa_token` proves only the password step. It is stored as a SHA-256 digest (migration 011), is single use, expires after five minutes, allows five code attempts, and is replaced by any newer challenge for the same user. A password reset, disablement or re-enrollment after step 1 invalidates it. Step 2 uses the same source/account throttling and time-step replay control as step 1. Sending `password` and `code` together in one `POST /auth/login` still works.

## Lost device and access changes

Verify the user again and repeat enrollment with a newly generated secret. This rotates the enrollment version, rejects stale verification results, and revokes previous sessions. There is no password-only bypass or MFA-disable endpoint. Disable a compromised user with `cmd/admin` while investigating. Resetting a password preserves the MFA requirement. Recovery codes, self-service enrollment, WebAuthn/passkeys, federation and automated encryption-key rotation are not implemented.

Synchronize server clocks. TOTP is not phishing-resistant; protect the real HTTPS origin, train users against relay phishing, and evaluate WebAuthn/OIDC for the intended deployment. Establish alerts for authentication failures, overload and privileged recovery events.

Sources: [TOTP library](https://github.com/pquerna/otp), [RFC 6238](https://www.rfc-editor.org/rfc/rfc6238), [Go authenticated encryption](https://pkg.go.dev/crypto/cipher#NewGCMWithRandomNonce).
