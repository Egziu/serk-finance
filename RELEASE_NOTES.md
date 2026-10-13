# 0.3.0-rc1 — accountant test release: module switches, Ethiopian fiscal year, Railway deployment

This candidate prepares Serk Finance for hands-on testing by accountants. It adds role-aware module switches, the Ethiopian fiscal calendar, a ready-to-test Ethiopian demo workspace and a single-service Railway deployment. Everything in 0.2.2-rc1 still applies.

## Flexible, permission-controlled modules (migration 053)

- **Module switches per company.** An administrator with `configuration.manage` can switch Sales, Purchases, Inventory, Payroll, Taxes, Multi-currency, Adjustments and Year-end on or off under **Modules & features**. A reason is required, and every change is audited.
- **Enforced in the database, not only hidden.** A disabled module removes its permissions from every user of the company inside `security.can`, `security.has` and `security.held_permissions`. Direct API calls are refused with `permission_denied`. Disabling Multi-currency refuses foreign-currency manual journals. Disabling Year-end refuses year-close requests. Data is kept; switching a module back on restores access.
- **Navigation follows each user's permissions.** The menu shows a page only when the user holds a permission for it and its module is on. A payroll officer sees only payroll, and an auditor sees reports and audit history.

## Ethiopian fiscal year (migration 053)

- A fiscal year can now follow the Ethiopian calendar: Hamle 1 to Sene 30, in 13 periods (Hamle, Nehase, Pagume, then Meskerem to Sene). Pagume has 5 or 6 days. Gregorian dates are computed exactly, including the leap-year shift of Meskerem 1 to 12 September.
- The fiscal-year form defaults to the Ethiopian calendar; Gregorian years remain available. Provisioning accepts `"calendar": "ETHIOPIAN"`.

## Posting by preparers without audit rights (migration 054)

- Module postings check ledger integrity before posting. That check required the preparer to hold `audit.read` and only saw rows the preparer could read, so payroll officers and sales clerks could not submit. The check now runs company-wide as a dedicated login-less role, `serk_integrity`, which can only be called from owner functions and returns counts, never rows. The integrity report itself still requires `audit.read`.

## Self-service password change (migration 055)

- **Profile → Change password.** The user must enter the current password, and the new one must be 14–256 characters and different. Every session of the user is revoked, and the change is recorded in the administrative log.

## Demo workspace and Railway deployment

- **`cmd/platform`.** A single-container launcher. It applies migrations, creates or rotates the two runtime database logins, optionally seeds the demo workspace, then serves the API and web app with the runtime roles only. The operator credentials are removed from the environment before serving. See `docs/RAILWAY.md`.
- **Ethiopian demo** (`SERK_DEMO_SEED=ethiopia`, workspace `demo`). Abay Demo Trading PLC with two branches, EFY 2019, an IFRS-for-SMEs chart of accounts, and VAT 15%. A sample PAYE policy follows the 2025 amendment bands. Seven role-based users are created: Administrator, Chief Accountant, Accountant, Finance Manager, Payroll Officer, Sales Clerk and Auditor. Opening capital, a purchase and a sale are already posted. Seeding is idempotent.
- **Railway private networking.** The database connection may skip TLS only when `SERK_DB_PRIVATE_NETWORK=true` and the host is `*.railway.internal`. Every other host still requires TLS.
- **MFA in staging.** Staging may turn mandatory MFA off with `SERK_REQUIRE_MFA=false` for accountant testing. Production always requires MFA.
- **Accountant test guide.** `docs/ACCOUNTANT_TEST_GUIDE.md` covers the users, the company and 11 test scenarios.

## Tests added

- `tests/controls-022.mjs`, now 24 cases: module switches (F1) and the Ethiopian year (E1).
- `internal/provisioning/periods_test.go`: Ethiopian period boundaries across leap years.
- `tests/profile_password_test.go`: password change.
- `tests/demo-smoke.mjs`: browser test of navigation per role, with a module switched off and on.
- `tests/demo-scenarios.mjs`: the guide's journal, VAT, VAT settlement, payroll, auditor and integrity scenarios, run over HTTP against a local or Railway deployment.

# 0.2.2-rc1 — verified on native PostgreSQL, security and IFRS hardening

0.2.1-rc1 had never been compiled or run on a real PostgreSQL server. This candidate was built with Go 1.27.2 and tested against PostgreSQL 17.10, with a real Chromium browser end to end. That testing, plus an independent security review and an independent IFRS accounting review, found the defects below. All of them are fixed in this release, and each fix has a regression test.

## Defects found by native testing

- **The API did not compile.** `Server.taxLiability` was declared twice (`reports_http.go` and `taxes_http.go`). The stale handler, which read a hard-coded account name, has been removed.
- **Row-level security regressed to per-row evaluation.** Migrations 037, 040 and 047 reintroduced bare `security.has/can/visible_branch` calls into policies. On native PostgreSQL a 500-line foreign-currency journal hit the 10-second statement timeout. Migration 048 restores per-statement evaluation; access decisions are unchanged.
- **The data grid was an unlicensed commercial component.** MUI X Data Grid **Pro** showed a "Missing license key" watermark on every table, and a CSS rule tried to hide it. The app now uses the MIT-licensed `@mui/x-data-grid`. Row details open in a side drawer.
- Some test expectations were stale (release marker, permission count, profile dialog name); these have been updated.

## Security (independent review; migration 049)

- **Module workflow bypass (high).** A ledger-only user could approve, post or reverse an invoice, bill, payroll or adjustment journal through the general-ledger route, because the guard read an RLS-filtered table. The guard now checks the journal's own source: only MANUAL journals, and reversals of MANUAL journals, can go through the general-ledger command.
- **Cross-company account takeover (high).** A user administrator in one company could reset the password of, or disable, an administrator of another company in the same tenant. Tenant-wide user changes now require the actor to cover the target's permissions in every company where the target has access.
- **Branch-scoped configuration (medium).** A user with configuration rights for one branch could create company-wide accounts, branches, dimensions and fiscal years. These now require company-wide `configuration.manage`.
- **Chart-of-accounts changes are audited.** Changes to accounts, branches, dimensions and fiscal years are now in the audit trail. An account with a balance, pending entries, or a configuration or item mapping cannot be deactivated. A parent account that already has postings cannot become a header account.
- **No PUBLIC function access.** No application function can be executed by PUBLIC, and every SECURITY DEFINER function is owned by `serk_owner`. Four functions previously ran as the migration superuser.
- **Narrower table access.** `organization.companies` is tenant-scoped for the API role, and unused direct write grants on master data are revoked.
- **Per-account login limit.** A per-account login window (50 attempts per 15 minutes across all sources) complements the per-source window. The deployment templates now carry `SERK_TRUSTED_PROXY_CIDRS`.
- **Error messages.** Application error codes reach the client as stable snake_case codes, never PostgreSQL text. The interface shows a plain-language message for every code.

## IFRS and accounting controls (independent review; migrations 050–052)

- **Year-end close (IAS 1).** A dual-controlled CLOSING entry per branch moves the year's profit or loss to a configured retained-earnings account, then closes the final period. Profit-or-loss reports exclude CLOSING entries. The statement of financial position shows retained earnings separately from profit for the open period. Nothing can be posted into a closed year.
- **Period reopen (IAS 10).** A closed period can be reopened for adjusting events with a second approver. Reopening is refused once the year is closed.
- **Current / non-current presentation (IAS 1.66–76).** Every asset and liability account carries an explicit `statement_class`. Existing accounts were backfilled using the previous presentation rule.
- **Exchange rates (IAS 21).** Foreign-currency manual journals must use a rate recorded on or before their date and no older than the company's maximum rate age (default 7 days). The journal rate must also be within the company tolerance (default 2%), so an inverted or mistyped rate is rejected. Rates are positive and recorded against the functional currency. Anyone who can read the ledger can see rates, and the journal form pre-fills the recorded rate. Both checks are set under Currencies & Rates.
- **Controlled adjustments.** VAT and payroll remittances, receivable write-offs, payable adjustments, inventory count adjustments, write-downs to net realisable value (IAS 2.28) and opening balances now each have a purpose-specific, dual-controlled workflow. Previously the control-account protection made these impossible. Inventory adjustments move the item's quantity and value together with the ledger.
- **VAT report.** A date-ranged VAT report reports reversals as negative amounts of the original type and reconciles to ledger movement. A tax rate that is in use cannot be re-priced or back-dated.
- **Payroll accrual (IAS 19).** Payroll is dated on the last day of its pay period; the payment date is recorded separately.
- **Purchase returns (IAS 2).** A purchase return is refused once the item's stock has moved after the bill, because it would distort weighted-average cost. Use an inventory adjustment instead.
- **Stock counts (IAS 2).** Stock removed or found by a count adjustment moves at its moving weighted-average cost, recalculated at approval. Found stock can carry its own cost only when there is no unreserved stock to average.

## Fixes from the independent release verification (migration 052)

- Exchange rates were readable only by configuration administrators, so no other accountant could post a foreign-currency journal. Rates are now readable with `ledger.read`; writing them still needs `configuration.manage`.
- Recorded rates now have a maximum age, so an old rate can no longer validate a current journal.
- Count adjustments (shortages and found stock) are now valued at weighted-average cost, and the adjustments screen suggests exactly that value, including when stock is reserved.
- FX policy changes are now audited correctly; saving the policy previously failed.

## API changes

- **Accounts:** `POST/PUT /api/v1/accounting/accounts` take `statement_class` (`CURRENT` | `NON_CURRENT`; required for ASSET and LIABILITY).
- **New endpoints:**
  - `GET /accounting/period-end`
  - `GET /accounting/fiscal-years/{id}/close-preview`
  - `POST /accounting/year-close/{request|approve|void}`
  - `POST /accounting/period-reopenings/{request|approve|void}`
  - `GET|POST /finance/adjustments[/{create|submit|approve|void}]`
  - `GET /taxes/report`
  - `GET|POST /fx-policy`
  - `GET /exchange-rates/recorded`
- **Idempotency:** commands require `Idempotency-Key`, `X-Company-ID` and CSRF.
- **Reference:** `docs/openapi.json` describes every route.

## Upgrade notes

- **Order:** apply migrations 048–051 in order with the operator connection. They change policies, functions and triggers. The only data they alter is the backfill of `statement_class` and the alignment of `companies.base_currency`.
- **After upgrading:** review the backfilled current / non-current classes, map `retained_earnings` in finance settings, record exchange rates for currencies you use, and set the FX tolerance and maximum rate age if 2% and 7 days do not fit.
- **Toolchain:** Go **1.27.2** is required (security release fixing `net/http`, `crypto/tls` and `html/template` advisories present in 1.27.1). Refresh the `golang` base-image pin to `1.27.2-bookworm`; the Dockerfile meanwhile lets `go` fetch the verified 1.27.2 toolchain.

## Still required before live financial use

Container image build and scan, target-host restore/PITR rehearsal, capacity testing and a statutory review of payroll and tax policies were not run here. Independent accountant and security sign-off on these exact bytes is also still needed. See `VALIDATION_0.2.2.md`.
