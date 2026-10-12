# 0.2.0-rc4, build 1

- Fix a native-only performance defect found by the first native PostgreSQL run: RLS policies and security helpers compared columns directly against non-inlinable SECURITY DEFINER functions, re-evaluating session context per row. A 500-line journal exceeded the 10 s statement timeout. Migration 010 evaluates row-independent context once per statement; access decisions, signatures, owners and grants are unchanged. Worst-case 500-line command: >10 s → 2.6 s.
- Add `TestSecurityContextIsStatementScoped` (catalog check of every policy and helper; fails on all 19 affected policies and 4 helpers against the rc3 schema).
- Schema version 0.2.0-rc4. Add a required rc3→rc4 populated upgrade rehearsal; rc4 database controls now run against the full rc4 schema.
- Add `scripts/pitr-rehearsal.py` (native physical backup + WAL point-in-time recovery rehearsal). Migrations 001–009 unchanged. See `RC4_RELEASE_REPORT.md`.

# 0.2.0-rc3, build 3

- Reproduce and close a release-gate defect: Go could exit successfully with zero selected tests and the harness reported PASS. Reconcile Go discovery with actual test/package completions and reject selection flags, missing tests, unexpected skips and incomplete evidence.
- Require all eight native definitions and explicit native PASS records, with no native skips. Add 14 evidence-validator regression cases; existing Go tests are unchanged.
- Add read-only Docker/local native preflights, explicit BLOCKED records and consistent result-directory handling. No unavailable native test is converted to PASS.
- Update the native acceptance handoff, test evidence guide and stale rc2 deployment instructions. Preserve all product code, dependencies and migrations 001–009. See `RC3_BUILD3_REPORT.md`.

# 0.2.0-rc3, build 2

- Address independent finding F1: drain the pinned socket library's deferred close callbacks and rollback work before closing PGlite in upgrade and verification harnesses.
- Finalize upgrade PASS/results after teardown and await child-process output closure. Require a fresh completed result plus zero process exit; never accept a PASS file after a crash.
- Add an exact baseline-crash reproduction, repeated shutdown/rollback regressions, contradictory-evidence gate tests and repeated populated upgrades.
- Preserve the independent report and evidence, all migrations 001–009, product code and dependency versions. Schema remains 0.2.0-rc3. See `RC3_BUILD2_REPORT.md` for commands, real outputs and open production gates.

# 0.2.0-rc3

- Preserve migrations 001–007 and every inherited Go test file byte-for-byte against the uploaded archive; add 008–009.
- Reproduce and guard used-account reclassification and chart cycles. Protect used dimensions and acquire explicit SHARE locks around line/master interpretation and posting dimension validation.
- Add scoped general-ledger reporting and trial-balance/source-journal drill-down, with exact string amounts, opening/movement/closing and deterministic keyset pagination.
- Add read-only company-wide ledger/audit/outbox integrity checks and a connected UI, with explicit diagnostic limitations.
- Add 18 database checks, two Go/HTTP tests, two native-only race tests and browser report acceptance; extend actual migrator upgrade tests to rc2 without weakening the older upgrade/session checks.
- Document the domain-intelligence boundary and phased AP/AR/banking development plan. Those business modules remain unimplemented.
- Current evidence and unsuccessful attempts are documented in `RC3_RELEASE_REPORT.md`. No production approval is asserted.

# 0.2.0-rc2 (historical)

- Fix the review’s limiter exhaustion, remote account lockout, immediate burst rejection, FX rounding, unsafe period-close behavior, reversal dates, startup diagnostics, handler coverage, mutable dependency references and asset directory listing.
- Add encrypted TOTP MFA with required secure-environment session assurance, replay counters and audited offline enrollment/recovery. Existing sessions are revoked on upgrade; the legacy auth-role issuance grant is removed.
- Add explicit, capped FX rounding configuration with operator audit and visible original/functional amounts. Add period-close preview and blocked-close UI.
- Preserve migrations 001–005; add 006–007. Verify populated upgrades from both supported baselines, existing financial history and checksum drift rejection.
- Add direct HTTP regression and native close/create/MFA replay tests. Local result: 78 passes, zero failures, six native-only skips; coverage 71.6%. Ten local release checks pass.
- Pin CI actions and Docker/database bases to verified immutable upstream identifiers. Container build/scan, native restore, target operations and independent acceptance remain blocked or pending.

Upgrade rc1 in a maintenance window. Provision the shared MFA key and enroll users before reopening staging/production. Older binaries are incompatible with the new issuance grant. No live deployment or production approval occurred.

# 0.2.0-rc1

## Financial and authorization controls

- Revalidate the original approver's active status, branch scope, approval permission and monetary ceiling at posting; lock those rows until transaction completion.
- Reject modifications to currency denominations and fiscal-year definitions that are already in use. Serialize period/company/currency reads during journal creation with configuration changes.
- Add persistent, company/user-scoped period-close receipts; replay the same key/result once, reject changed payloads, and avoid duplicate audit/outbox effects.
- Keep all original migration files unchanged; apply new behavior in 004 and 005.

## Identity and deployment

- Require an explicit supported environment. Enforce HTTPS origins and verified database TLS in staging/production for both runtime and operator connections.
- Reject unsafe runtime identities, wrong-role credentials, dangerous inherited roles and schema ownership privileges. Native validation for these checks is supplied but not executed here.
- Recheck a verified password under a user/tenant lock when issuing a session; revoke the older auth-role session-minting grant.
- Add cross-replica account login throttling, secure host-only cookies, strict UTF-8 request validation, mounted secret support and explicit trusted-proxy CIDRs.
- Add atomic operator password reset, disable/enable and revoke-sessions actions with private append-only administrative audit rows.
- Check both pools in readiness, exempt probes from client quotas, verify the schema release marker and check configured web assets at startup.
- Fix piped bootstrap input, retain browser retry scope and bound fetch time, separate ephemeral test credentials from persistent development configuration.

## Release operations

- Add hosted release Compose, preflight, TLS ingress example, native disposable infrastructure checks, real backup/restore comparison tooling, populated 0.1.0 upgrade testing, coverage output, machine-readable evidence, CI image scans and SBOM generation.
- Preserve prior supplied evidence as historical records; current JSON logs and dated reports describe the new run.

## Compatibility

Coordinate an API maintenance window for upgrading from 0.1.0: migration 004 revokes the function used by the old login code. Staging/production cookies change to `__Host-serk_session`; users sign in again. The HTTP period-close endpoint now requires `Idempotency-Key`. No destructive down migration or zero-downtime guarantee is supplied.
