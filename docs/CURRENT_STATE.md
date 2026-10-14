# Current state

Current delivery: **0.4.0-rc1** (schema marker `0.4.0-rc1`, migrations 001–057). The latest published validation record is `VALIDATION_0.3.0.md` (0.3.0-rc1); the 0.4.0-rc1 validation run is in progress.

## New in 0.4.0-rc1

- **AI assistant** (`docs/AI_ARCHITECTURE.md`). It answers from the books and prepares DRAFT journals, sales invoices and supplier bills only, acting strictly as the signed-in user. It needs the `ai.use` permission and the AI assistant module switch. Providers: the Claude API or an OpenAI-compatible server, configured per company or server-wide.
- **Office installers** (`docs/OFFICE_INSTALL.md`) for Windows and Linux. They bundle PostgreSQL 17 on 127.0.0.1 and provide a first-run setup wizard, an optional practice workspace, online backups and safe restore. The Linux `.deb` was verified end to end; the Windows installer was built but not run on real Windows.
- **Accountant feedback fixes:** errors name the field; account pickers offer only usable accounts; control accounts serve one purpose, and unused remapped ones are released; module journals link to their source document; receivable write-off template; people shown by name.

## New in 0.3.0-rc1

- Per-company module switches (Sales, Purchases, Inventory, Payroll, Taxes, Multi-currency, Adjustments, Year-end). They are enforced in the database permission functions, and the navigation follows each user's permissions.
- Ethiopian fiscal year: Hamle to Sene, 13 periods including Pagume.
- Self-service password change.
- Single-service Railway deployment (`cmd/platform`) with an Ethiopian demo workspace for accountant testing (`docs/ACCOUNTANT_TEST_GUIDE.md`).

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
- **AI assistant.** 17 tools (14 read and review, 3 create drafts), each run in its own transaction as the user, with fixed limits and a sealed, company-bound provider key. Nothing is submitted, approved or posted by the AI.
- **Deployment.** Railway single service (`cmd/platform`), Docker, and office installers (`cmd/serk-server`) with backup, restore and password reset commands.
- **Frontend.** React with the MIT-licensed MUI data grid, plain-language error messages for every application error code (naming the field where one is wrong), and mobile layouts.

## Verification on this release

The 0.4.0-rc1 validation run is in progress; the new tests are listed in `docs/testing.md`. The Linux `.deb` installer has been installed and verified end to end. The Windows installer has not been run on real Windows (under Wine the bundled `postgres.exe` fails for an unrelated Wine limitation).

For 0.2.2-rc1: Go 1.27.2 build, vet and full test suite with the race detector ran on native PostgreSQL 17.10, including the eight concurrency tests that previously only ever skipped. SQL regression suites ran on both native PostgreSQL and PGlite, alongside upgrade preservation, a real Chromium end-to-end run with MFA, an npm audit and an offline Go vulnerability check. Results are in `VALIDATION_0.2.2.md` and `test-results/validation-0.2.2/`.

## Not yet done

- **Not run in this workspace:**
  - Container image build and scan (Docker Hub unreachable).
  - Restore/PITR rehearsal on the target host.
  - Capacity testing.
  - The Windows office installer on real Windows.
- **Missing features:** the larger functional gaps — Ethiopian statutory reports and dual-calendar dates, AR/AP allocation and aging, bank reconciliation, fixed assets, cash-flow statement, offline sync between offices — are planned in `docs/ROADMAP.md`. For the AI assistant, prompt/answer logging, evaluation suites, citations, OCR, forecasting and anomaly alerts are still future work.

**Production financial use still requires independent accountant and security acceptance of these exact release bytes.**
