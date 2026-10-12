# Current state

Current delivery: **0.2.2-rc1** (schema marker `0.2.2-rc1`, migrations 001–052).

## What exists

- **Financial kernel.**
  - Double-entry journals with draft → submit → independent approval → post.
  - Reversals, idempotent commands, exact minor-unit money, FX with a rounding policy and a recorded-rate tolerance.
  - Period close and dual-controlled reopen, and dual-controlled year-end close to retained earnings.
  - Hash-chained audit trail with outbox and an integrity check.
- **Modules.**
  - Sales invoices and purchase bills with VAT, payments and reversals.
  - Inventory items with moving weighted-average cost, stock openings and controlled adjustments.
  - Payroll with dual-approved policies, payruns and payslips.
  - Taxes: agencies, rates and the VAT report.
  - Controlled adjustments for VAT and payroll remittance, receivable and payable adjustments, inventory write-downs and opening balances.
- **Reports.**
  - Trial balance and general ledger with drill-down.
  - Statement of financial position, using explicit current / non-current classes.
  - Statement of profit or loss, excluding closing entries.
  - Dashboard, ledger integrity and audit history.
- **Security.**
  - Argon2id passwords and TOTP MFA with replay protection.
  - Session cookies with CSRF and strict CSP.
  - Database-level tenant, company and branch row-level security, evaluated once per statement.
  - Module permissions, maker-checker throughout, and no PUBLIC function access.
  - Per-source and per-account login windows.
- **Frontend.** React with the MIT-licensed MUI data grid, plain-language error messages for every application error code, and mobile layouts.

## Verification on this release

Go 1.27.2 build, vet and full test suite with the race detector ran on native PostgreSQL 17.10, including the eight concurrency tests that previously only ever skipped. SQL regression suites ran on both native PostgreSQL and PGlite, alongside upgrade preservation, a real Chromium end-to-end run with MFA, an npm audit and an offline Go vulnerability check. Results are in `VALIDATION_0.2.2.md` and `test-results/validation-0.2.2/`.

## Not yet done

- **Not run in this workspace:**
  - Container image build and scan (Docker Hub unreachable).
  - Restore/PITR rehearsal on the target host.
  - Capacity testing.
- **Missing features:** the larger functional gaps — Ethiopian calendar and statutory reports, AR/AP allocation and aging, bank reconciliation, fixed assets, cash-flow statement, AI assistant, offline sync — are planned in `docs/ROADMAP.md`.

**Production financial use still requires independent accountant and security acceptance of these exact release bytes.**
