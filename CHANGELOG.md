# 0.4.0-rc1

- AI assistant (057): side panel that answers from the books and prepares DRAFT journals, sales invoices and supplier bills only. 17 tools, each run in its own transaction as the signed-in user (RLS, branch scope, permissions, module switches). New `ai.use` permission and `ai_assistant` module switch. Providers: Claude Messages API (default `claude-sonnet-5-5`) or OpenAI-compatible servers. Per-company settings with an AES-GCM-sealed, company-bound key that is never returned, or server-wide `SERK_AI_*` variables. Redirects refused; plain HTTP only for loopback (or private addresses with `SERK_AI_ALLOW_PRIVATE_HTTP=true`). Limits: 8 model calls, 6 tools per call, 24 KiB results, 140 s, 12 chats/min, 30 × 8000-byte messages. New endpoints `/api/v1/assistant/{status,chat,settings}`.
- Office installers: `cmd/serk-server` with bundled PostgreSQL 17 on 127.0.0.1, a first-run setup wizard (loopback or one-time token, resumable), optional `demo` practice workspace, online `.zip` backups and safe restore. Windows NSIS (service `SerkFinance`, LocalService, locked data and install folders, optional private/domain firewall rule), Debian package and `.tar.gz` with systemd. `scripts/build-installers.sh`, `docs/OFFICE_INSTALL.md`. Linux `.deb` verified end to end; Windows built but not verified on real Windows.
- Accountant feedback fixes (056): errors name the field (`error.field`); account pickers filter by type; control accounts serve one purpose; unused remapped control accounts are released (not while a draft or submitted adjustment uses them); blank mappings are dropped; module journals link to their source document instead of offering GL reversal; receivable write-off template; people shown by name.
- Tests: `internal/assistant/assistant_test.go`, `tests/assistant_test.go`, `tests/office_setup_test.go`, `cmd/serk-server/backup_test.go`, `tests/assistant-browser.mjs`, `tests/assistant-markdown.mjs`, `tests/fake-claude.mjs`, `tests/accountant-feedback.mjs`, `tests/office-setup.mjs`, controls-022 AF1–AF4 (28 cases).

# 0.3.0-rc1

- Company module switches (053): eight modules can be switched on or off by `configuration.manage`, with a reason and an audit record. They are enforced in `security.can/has/held_permissions`. The navigation is permission- and module-aware, and there is a new Modules & features page.
- Ethiopian fiscal year (053): Hamle–Sene, 13 periods including Pagume, with exact Gregorian conversion. Available as an option in the fiscal-year form and in provisioning.
- Posting integrity check (054): runs company-scoped as `serk_integrity`, so preparers no longer need `audit.read`.
- Self-service password change (055): `POST /api/v1/profile/password` and a Profile form. It revokes all sessions.
- `cmd/platform`, a single-container Railway launcher; Railway private-network TLS exemption; staging MFA switch; the Ethiopian demo workspace seed; `docs/RAILWAY.md` and `docs/ACCOUNTANT_TEST_GUIDE.md`.
- Tests: controls-022 (24 cases), Ethiopian period tests, password-change test, demo browser smoke test and HTTP scenario suite.

# 0.2.2-rc1

- First native verification: Go 1.27.2 build and race-enabled suite on PostgreSQL 17.10 (all 52 top-level tests, including the 8 native concurrency tests), SQL suites on native PostgreSQL and PGlite, real-Chromium MFA end-to-end run.
- Fix: API did not compile (duplicate `taxLiability`). Fix: per-row RLS evaluation reintroduced by 037/040/047 (migration 048). Replace the unlicensed MUI X Data Grid Pro (and the CSS that hid its watermark) with the MIT grid.
- Security (049): general-ledger route can no longer drive module/closing journals; cross-company user takeover closed; company-wide configuration permission enforced; master-data changes audited; no PUBLIC function execution; definer functions owned by serk_owner; tenant-scoped companies; per-account login window; generic static error codes.
- IFRS (050–051): dual-controlled year-end close and period reopen; explicit current/non-current classes; recorded-rate FX tolerance; date-ranged VAT report with correct reversal treatment; in-use tax rates immutable; payroll accrued at period end; purchase returns blocked after stock movement; controlled adjustments for remittances, write-offs, write-downs and opening balances.
- Release verification fixes (052): exchange rates readable with ledger.read (accountants without configuration rights could not post FX journals); maximum recorded-rate age (default 7 days); count adjustments (shortages and found stock) valued at weighted-average cost; FX policy audit fix.
- New API endpoints and UI pages: Year-end & reopen, Adjustments, VAT report, statement class on accounts, recorded-rate pre-fill. New suites: `tests/controls-022.mjs` (22 cases), `tests/period_end_http_test.go`. SQL suites can target native PostgreSQL (`SERK_SQL_BACKEND=native`).
- Go 1.27.2 required (stdlib security release). `source-map-js` build dependency pinned to 1.2.2 (GHSA-68fv-2mgg-jv7q).

# 0.2.1-rc1

- Financial controls repair: immutable posted SYSTEM lines, controlled module workflows through the kernel, payroll policies, stock openings, payment and reversal approvals, document visibility (migrations 037–047). Validated on PGlite only; see `REPAIR_VALIDATION.md` (historical).

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
