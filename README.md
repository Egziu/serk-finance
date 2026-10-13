# SERK Finance ERP — 0.3.0-rc1

IFRS-oriented accounting and ERP for businesses in Ethiopia and Africa: double-entry ledger with maker-checker approval, sales, purchases, inventory, payroll, VAT, period and year-end controls, and a hash-chained audit trail. Start with `RELEASE_NOTES.md`, `VALIDATION_0.3.0.md` and `docs/ROADMAP.md`. Accountants testing the hosted demo should read `docs/ACCOUNTANT_TEST_GUIDE.md`; operators deploying to Railway should read `docs/RAILWAY.md`.

This is a release candidate verified on native PostgreSQL 17 and a real browser. It is **not** approved for live financial use until the remaining infrastructure gates (image build/scan, restore/PITR, capacity) and independent accountant/security acceptance are complete.

## Deploy for testing (Railway)

One service built from this repository's `Dockerfile` (target `platform`) plus a Railway PostgreSQL service. On start it migrates, creates the runtime logins, seeds the Ethiopian demo workspace when `SERK_DEMO_SEED=ethiopia`, and serves the app. Variables and steps: `docs/RAILWAY.md`.

## Run locally

Required: Go 1.27.2, Node.js 22+, Python 3, PostgreSQL 17 (or the embedded PGlite development database).

```bash
npm ci --ignore-scripts
npm --prefix web ci
npm --prefix web run build
node tests/verify.mjs --serve      # embedded development database, synthetic data, http://localhost:8080
```

Sign-in details for the synthetic workspace are written to `.local/verification/sign-in.txt`. Data resets when stopped.

For a persistent database set `MIGRATOR_DATABASE_URL`, run `go run ./cmd/migrate`, apply `scripts/runtime-roles.psql` as the operator, then provision with `go run ./cmd/bootstrap --file <config.json>`.

## Configure before financial use

1. Create the company's chart and fiscal periods. Mark every asset and liability account current or non-current. Map a retained-earnings account, record exchange rates for the currencies you use, and review the FX tolerance (default 2%). Configure explicit account mappings and the allowed cash/bank accounts in the relevant workspace. Choose dedicated accounts for receivables, payables, inventory, tax, and payroll. Configuration changes do not change the control account recorded on an existing document.
2. Create customers/vendors, catalog items, and employees. Product items need inventory and cost-of-sales account mappings. Employees need a branch, salary per pay period, and frequency.
3. Use a stock-opening document for opening quantities/value; obtain independent approval. Direct quantity-only opening entries are rejected.
4. A configuration manager enters payroll brackets, offsets, pension percentages, frequency, and effective dates. A different configuration manager approves the policy. No statutory tax/pension rates are assumed. Obtain current accountant/localization approval for actual policies.
5. The preparer saves a document, reviews it, and submits it. A different authorized person approves and posts it. Payments and reversals have their own review and independent approval. Review the document preview before authorizing an action.

Module preparers need the module's read/manage permissions, ledger read, and journal create/submit permissions. Modules can be switched off per company under Modules & features. Approvers also need journal approve/post with suitable limits. Configuration permissions are separately controlled.

The local Docker seed includes an administrator, accountant, finance approver, and restricted configuration reviewer so payroll rules can be reviewed by a second identity. Use distinct real people and credentials for production.

## Validate on a suitable host

```bash
npm ci --ignore-scripts && npm --prefix web ci
# disposable PostgreSQL 17 with the three login URLs (see docs/testing.md)
go test -race -count=1 ./...
SERK_SQL_BACKEND=native node tests/controls-022.mjs
SERK_SQL_BACKEND=native node tests/remediation.mjs
node tests/verify.mjs --native --e2e
python3 scripts/release-check.py && python3 scripts/native-check.py   # on a host with Docker
```

The release gate includes the repaired full-schema SQL suite and SQL upgrade-preservation checks, in addition to the original Go, browser, dependency, and upgrade gates. Do not accept a failed, blocked, filtered, or stale run. Also complete verified TLS/secrets/MFA setup, target capacity tests, image/dependency scans, backup restore/PITR, and independent accounting/security acceptance.

## Upgrading an existing database

Read `serk-finance/UPGRADE_FROM_ORIGINAL.md` first. Preserve a verified backup and stop the application during migration. Migrations 001–047 are byte-identical to 0.2.1-rc1 and 048–052 are forward-only; the original numbered migrations 001–036 are unchanged; a narrowly scoped operator preparation step enables the legacy 033 migration on populated databases, and later migrations remove that temporary access policy.

Invalid historical account references, zero/invalid salaries, or quantity-only inventory balances cause migration to fail rather than inventing corrections. Posted records whose old contents were never captured by the audit trail also require accounting reconciliation. This repair does not fabricate historical audit evidence or rewrite existing posted amounts to make an integrity indicator green.

Archive checksums are in the outer and inner `SHA256SUMS` files. Existing source-version/design documents are labelled historical references; the current release notes and validation record are authoritative.
