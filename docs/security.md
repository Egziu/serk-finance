# Security controls

Current release: 0.4.0-rc1 — see the "0.4.0-rc1 additions" section at the end, and the "0.3.0-rc1 additions" before it. For 0.2.2-rc1 see the "0.2.2-rc1 additions" section at the end and `VALIDATION_0.2.2.md` for current evidence and remaining gates. The 0.2.0-rc2 notes that follow remain accurate unless superseded there. That version added strict environment/TLS configuration, host-only secure cookies, explicit proxy trust, persistent source/account throttling with successful-login reset, password revalidation at issuance, operator lifecycle audit, current approver rechecks and stronger runtime-role validation. The native role checks and public deployment are unverified in this workspace. Older design notes below remain scoped to the initial foundation and do not constitute production approval.

# Security architecture and trust boundaries

## Implemented controls

Passwords are hashed with Argon2id (64 MiB, three iterations, one lane, random 16-byte salt). Verification accepts bounded parameters, preventing a corrupt/malicious encoded hash from requesting unbounded memory. Random 32-byte session tokens are stored as SHA-256 digests, have an eight-hour absolute expiry, and can be revoked. Disabled users/tenants stop resolving as active actors. Successful login rotates an existing browser session.

The browser stores the session only in an HttpOnly, SameSite=Strict cookie. Production-mode cookies require HTTPS; insecure cookies are limited to the explicit localhost development origins. Unsafe HTTP methods enforce the configured Origin. Financial POST requests validate the session CSRF token in PostgreSQL. API responses set no-store, safe content type, CSP, anti-framing, referrer and permissions headers. Authentication uses two Argon2 workers, sixteen bounded waiting requests and a two-second queue deadline. Sustained overload returns HTTP 503 with Retry-After. Per-process login traffic is capped at 60 attempts/minute per source; durable source/account attempts are capped at ten/minute and reset on success. IPv6 /64 prefixes share a source quota. The 10,000-entry LRU cache evicts old keys instead of denying everyone at capacity; shared/edge rate limiting is still needed for multi-instance deployments.

The normal financial DB identity cannot read password hashes or mint sessions. A separate auth pool can read a login record and issue/revoke sessions but cannot read or write financial data. The full API process has both credentials and remains trusted; splitting the auth deployment later can reduce the compromise radius. SQL uses parameter binding. No caller-supplied user ID is authoritative.

`security.bind` resolves a real session digest and an authorized company in a transaction. RLS resolves actor/company through protected session and membership records, not a freely assignable `user_id` setting. Changing a GUC without a valid session cannot forge an actor. All pool request context is transaction-local. Runtime startup rejects owner/superuser/BYPASSRLS identities; production mode rejects test role overrides and unverified/fallback database TLS.

## Roles, attributes, segregation

Permissions are stored in role-permission mappings. Memberships scope roles to companies and optionally branches and approval ceilings in functional minor units. An accountant with Company A membership cannot select Company B merely by changing a header. Branch-limited readers see only journals/lines for that branch. Company-wide COA and calendar metadata is separately authorized reference data. Audit is deliberately a separate company-wide permission.

The creator and submitter cannot approve their own journal even when their role also has approval capability. Posting permission does not imply approval permission. Amount ceilings apply to the complete journal debit total in functional units, not individual lines. Transaction-type, supplier, department, project and cumulative split-purchase policies are later workflow capabilities, not currently implemented ABAC.

## Threat cases covered by automated tests

- Cross-tenant/company scope selection and cross-company account references.
- Branch-hidden journals, read-only role writes, and database credential session issuance.
- Missing/forged identity context and context leakage between pooled transactions.
- Self-approval, approval limit, stale version, duplicate intent, altered replay payload.
- Direct ledger DML, immutable posted content, forbidden deletion, closed-period posting.
- SQL-shaped input, unknown JSON fields, duplicate JSON keys, malformed numeric values.
- Audit mutation, chain inconsistency and outbox/audit atomicity.

Tests demonstrate these cases; they are not an independent penetration test, complete authorization matrix, formal proof, or proof against a compromised database superuser.

## Remaining release gates

Target MFA enrollment/recovery acceptance; OIDC/WebAuthn and self-service lifecycle; credential reset and breach controls; idle-session expiry; audited runtime user/role/configuration administration; device registration and revocation; fine-grained ABAC; distributed edge protection and target trusted-proxy validation; complete authentication/security event retention; encryption/key rotation; object-store tenant controls; backup encryption and restoration; native PostgreSQL privilege/concurrency validation; SAST/DAST, container scan, and independent penetration testing.

Runtime financial payloads are not written into operational logs. Current logs contain generated request IDs, method/route templates and elapsed time. The current request-context device/user-agent metadata is diagnostic, not a verified device identity. Health endpoints contain no financial data. Private telemetry and OpenTelemetry integration remain planned.

## Audit and privileged operators

Audit rows and outbox events are append-only to ordinary writes. A per-company hash chain stores canonical event payload bytes, predecessor hash and sequence; creation snapshots include journal lines/dimensions at transaction commit. Hash chains detect alteration relative to a trusted checkpoint. A superuser can disable triggers and rewrite an entire chain; therefore external signed checkpoints/WORM retention and independently controlled backups are required before claiming protection from privileged compromise.

Treat financial records as CONFIDENTIAL. Future payroll and bank-account details are HIGHLY CONFIDENTIAL and require field encryption, key access separation, export audit and purpose-limited retrieval. No payroll/banking PII storage is implemented in this release.

## Authenticator assurance

Staging/production require TOTP and a 32-byte encryption key. Password-only sessions are denied on all scoped API requests and session discovery. MFA enrollment is operator-only, revokes prior sessions, and consumes the setup proof. Encrypted secrets are bound to the user; issuance checks enrollment version and consumes a time step atomically. See [MFA operations](mfa-operations.md). Offline recovery and source-isolation tests run locally; parallel replay needs the native gate.


## 0.2.2-rc1 additions

- **General-ledger command scope.** The general-ledger command (`ledger.command`) only operates on MANUAL journals and reversals of MANUAL journals. Module, adjustment and year-end journals (SYSTEM / CLOSING) can only move through their own dual-controlled workflows. The check reads the journal's own source and is not subject to row-level visibility.
- **Tenant-wide user changes.** Renaming, disabling, resetting a password or changing grants requires the acting administrator to cover the target's permissions in every company where the target has access.
- **No PUBLIC function access.** `tests/controls-022.mjs` (S4) fails if any application function is executable by PUBLIC or any SECURITY DEFINER function is not owned by `serk_owner`.
- **Error disclosure.** Only static snake_case application codes cross the database boundary (`internal/platform/httpapi/errors.go`). PostgreSQL's own messages never reach clients.
- **Login windows.** Up to 10 attempts per minute per (tenant, email, source) and 50 per 15 minutes per (tenant, email) across all sources. Behind a proxy or ingress, set `SERK_TRUSTED_PROXY_CIDRS`; otherwise every client shares the proxy's source window.
- **Trust boundary of `serk_auth`.** Password (argon2id) and TOTP verification happen in the API process, because PostgreSQL cannot compute argon2id. The `serk_auth` role can therefore issue a session for any user of its tenant, and its credential is equivalent to the ability to sign in as anyone. Keep `serk_auth_login` out of every environment except the API, restrict it by network (`pg_hba.conf`), rotate it, and alert on use from unexpected hosts. A separate verifier service is on the roadmap.

## 0.3.0-rc1 additions

- **Module switches.** Disabling a module removes its permissions inside `security.can`, `security.has` and `security.held_permissions`, so the switch is enforced by the database and not only by the interface. Changes need `configuration.manage` and a reason, and they are audited.
- **Integrity role.** `serk_integrity` (NOLOGIN, BYPASSRLS) owns only `ledger.integrity_status_core()` and `ledger.posted_snapshot_mismatches()`. Every query filters on `security.company()`; the results are counts; EXECUTE is granted only to `serk_owner`. The runtime roles cannot call them.
- **Password change.** The API verifies the current password. The database applies the change only if the stored hash is unchanged and the session is live, then revokes all of the user's sessions. The change is rate-limited per session, uses the same argon2id parameters as before, and is recorded in `security.admin_events`.
- **Railway launcher.** `cmd/platform` holds operator credentials only while migrating and creating the runtime logins. The logins are created NOSUPERUSER NOBYPASSRLS with passwords of 24 characters or more, which must differ. The operator variables are unset before the HTTP server starts.
- **TLS exemption.** The database connection may skip TLS only for `*.railway.internal` hosts with `SERK_DB_PRIVATE_NETWORK=true`. That traffic stays on Railway's encrypted private network.
- **MFA.** Staging can disable mandatory MFA with `SERK_REQUIRE_MFA=false`, for accountant testing only. Production ignores the setting.

## 0.4.0-rc1 additions

### AI assistant (migration 057)

- **No authority beyond the user.** Each assistant tool runs in its own transaction bound to the caller's session, so RLS, branch scope, permissions, approval limits and module switches apply. The only write tools create DRAFT journals, sales invoices and supplier bills through the normal commands. No tool submits, approves, posts, pays, reverses or voids. Maker-checker is unchanged, and the approver must be a different person.
- **Gates.** `ai.use` permission and the `ai_assistant` module switch, checked in `organization.ai_config()` and `organization.assistant_context()` (`permission_denied` otherwise). Provider settings need company-wide `configuration.manage`, a reason, and are audited.
- **Key handling.** A company API key is sealed in the API process with AES-GCM (`mfa.Seal`) under the installation's `SERK_MFA_KEY`, with the company as associated context (`ai:<company id>`), so ciphertext cannot be moved to another company. It is stored in `organization.ai_secrets` (forced RLS, not audited) and never returned by any endpoint. The settings expose only `key_set`. A stored key is only used with the provider and base URL it was entered for. Changing either requires the key again (`assistant_key_required`), so an administrator cannot redirect an existing key to a server they control.
- **Egress.** HTTPS to any host; plain HTTP only to `localhost` or loopback addresses, or private addresses when `SERK_AI_ALLOW_PRIVATE_HTTP=true`. URLs with credentials, query or fragment are refused. Redirects from the AI service are never followed (`assistant_redirect_refused`). Responses over 2 MiB are refused.
- **Prompt injection.** Tool results are presented to the model as data. Because the tools cannot exceed the user's rights or create anything beyond drafts, an injected instruction cannot post, approve or pay. AI-made drafts are labelled in their reason (`Prepared by the AI assistant at the user's request: …`).
- **Resource limits.** 8 model calls and 6 tools per call; tool results capped at 24 KiB (valid-JSON truncation); 140 s per chat; 12 chats per minute per session; 30 messages × 8000 bytes. The chat route alone gets a 150 s request timeout; every other route keeps 15 s.
- **Disclosure.** Provider failures reach clients only as stable codes (`assistant_unavailable`, `assistant_key_rejected`, `assistant_rate_limited`, `assistant_request_rejected`, `assistant_timeout`, …). Provider response details are logged truncated and are never sent to the browser. Conversations are not stored on the server; the browser keeps them in session storage and clears them at sign-out.
- **Data leaving the installation.** With a cloud provider, questions and tool results (the company's figures) are sent to that provider. See `docs/ai-governance.md`.

### Office installation (`cmd/serk-server`)

- **Database.** Bundled PostgreSQL 17 listens on 127.0.0.1 only, with `pg_hba.conf` allowing scram-sha-256 password logins from loopback only and no Unix socket. The API still connects with the unprivileged runtime logins; the owner credential is used only for migration, setup and operator commands.
- **Secrets.** `serk.json` holds the database passwords and the encryption key. It is created with mode 0600 in a data folder that only the service account (and, on Windows, Administrators and SYSTEM) can read.
- **Windows.** Service `SerkFinance` runs as `LocalService`. `%ProgramData%\SerkFinance` is restricted to Administrators, SYSTEM and LocalService (modify). The install folder is owned by Administrators and read/execute-only for LocalService and Users, so the service's programs cannot be replaced by an ordinary user. The optional firewall rule covers TCP 8080 for `serk-server.exe` on private and domain profiles only.
- **Linux.** `serk-finance` system user without a login shell, data in `/var/lib/serk-finance` (0700), and a systemd unit with `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=full`, `ProtectHome` and `UMask=0077`. The server refuses to run as root.
- **Setup wizard.** Only a direct loopback connection (not one arriving through a proxy) or a browser presenting the one-time token from `setup-token.txt` (0600) may create the first company. The token is compared in constant time and deleted when setup completes.
- **Transport.** Office mode (`SERK_ENV=office`) serves plain HTTP inside the office. Cookies are therefore not marked Secure, and MFA is optional unless `SERK_REQUIRE_MFA=true`. Origin checks accept only this computer's names and local addresses (plus explicit `extra_origins`). Use a trusted network, or an HTTPS proxy/VPN for anything wider.
- **Backups.** Backup archives contain `serk.json` and therefore every secret of the installation. They are not encrypted by Serk Finance. Restore never takes `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` or `pg_ident.conf` from an archive, rejects unsafe paths, and checks file sizes.
- **Not verified:** the Windows installer has not been run on real Windows, and it is not code-signed.

### Accountant feedback (migration 056)

- Error responses may include `error.field`, a snake_case field key taken from the database error DETAIL only when it matches `^[a-z][a-z0-9_]{1,63}$`. It never carries data values.
- Colleagues are shown by display name only (no email or contact data), and only for members of the current company with `ledger.read`.

