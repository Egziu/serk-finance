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

## IFRS and accounting controls (independent review; migrations 050–051)

- **Year-end close (IAS 1).** A dual-controlled CLOSING entry per branch moves the year's profit or loss to a configured retained-earnings account, then closes the final period. Profit-or-loss reports exclude CLOSING entries. The statement of financial position shows retained earnings separately from profit for the open period. Nothing can be posted into a closed year.
- **Period reopen (IAS 10).** A closed period can be reopened for adjusting events with a second approver. Reopening is refused once the year is closed.
- **Current / non-current presentation (IAS 1.66–76).** Every asset and liability account carries an explicit `statement_class`. Existing accounts were backfilled using the previous presentation rule.
- **Exchange rates (IAS 21).** Foreign-currency manual journals must use a recorded rate for their date, within a company tolerance (default 2%). An inverted or mistyped rate is rejected. Rates must be positive and recorded against the functional currency, and the journal form pre-fills the recorded rate.
- **Controlled adjustments.** VAT and payroll remittances, receivable write-offs, payable adjustments, inventory count adjustments, write-downs to net realisable value (IAS 2.28) and opening balances now each have a purpose-specific, dual-controlled workflow. Previously the control-account protection made these impossible. Inventory adjustments move the item's quantity and value together with the ledger.
- **VAT report.** A date-ranged VAT report reports reversals as negative amounts of the original type and reconciles to ledger movement. A tax rate that is in use cannot be re-priced or back-dated.
- **Payroll accrual (IAS 19).** Payroll is dated on the last day of its pay period; the payment date is recorded separately.
- **Purchase returns (IAS 2).** A purchase return is refused once the item's stock has moved after the bill, because it would distort weighted-average cost. Use an inventory adjustment instead.

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
- **After upgrading:** review the backfilled current / non-current classes, map `retained_earnings` in finance settings, record exchange rates for currencies you use, and set the FX tolerance if 2% does not fit.
- **Toolchain:** Go **1.27.2** is required (security release fixing `net/http`, `crypto/tls` and `html/template` advisories present in 1.27.1). Refresh the `golang` base-image pin to `1.27.2-bookworm`; the Dockerfile meanwhile lets `go` fetch the verified 1.27.2 toolchain.

## Still required before live financial use

Container image build and scan, target-host restore/PITR rehearsal, capacity testing and a statutory review of payroll and tax policies were not run here. Independent accountant and security sign-off on these exact bytes is also still needed. See `VALIDATION_0.2.2.md`.
