# Security controls

Current release: 0.2.2-rc1 — see the "0.2.2-rc1 additions" section at the end and `VALIDATION_0.2.2.md` for current evidence and remaining gates. The 0.2.0-rc2 notes that follow remain accurate unless superseded there. That version added strict environment/TLS configuration, host-only secure cookies, explicit proxy trust, persistent source/account throttling with successful-login reset, password revalidation at issuance, operator lifecycle audit, current approver rechecks and stronger runtime-role validation. The native role checks and public deployment are unverified in this workspace. Older design notes below remain scoped to the initial foundation and do not constitute production approval.

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
