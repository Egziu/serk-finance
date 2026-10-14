# 0.4.0-rc1 — AI assistant, office installers, accountant feedback fixes

This candidate adds an AI assistant that answers from the books and prepares drafts, installers that run Serk Finance on an office computer with its own database, and the fixes from the first accountant test round. Everything in 0.3.0-rc1 still applies. Schema marker `0.4.0-rc1`, migrations 001–057.

## AI assistant (migration 057)

- **Ask the books, get drafts.** An **Assistant** button opens a side panel. Users can ask about balances, profit, VAT, unpaid invoices or any account, or ask for an audit-style review of entries. They can also ask for a draft journal, sales invoice or supplier bill. The panel shows which tools the assistant used and links to each draft for review.
- **Drafts only.** The assistant has 17 tools: 14 read reports, ledgers, journals, documents, VAT and integrity status, or review entries; 3 create DRAFT journals, invoices and bills. Nothing is submitted, approved, posted, paid, reversed or voided by the AI. Every draft goes through the existing maker-checker workflow.
- **Acts as the user.** Every tool runs in its own database transaction as the signed-in user, so row-level security, branch scope, permissions, approval limits and module switches apply exactly as on the screens.
- **Traceable drafts.** The reason of every AI-made draft starts with `Prepared by the AI assistant at the user's request: …`. When the user may draft in several branches, the branch must be named. When an invoice number is omitted, it continues the company's latest sequence.
- **Access.** New permission `ai.use` and new module switch **AI assistant** (`ai_assistant`). The demo roles receive `ai.use`.
- **Providers.** The Claude Messages API (default model `claude-sonnet-5-5`) or any OpenAI-compatible server, such as Ollama in the office. Configure it per company under **Modules & features → AI assistant provider** (company-wide `configuration.manage`, with a reason, audited), or server-wide with `SERK_AI_PROVIDER`, `SERK_AI_MODEL`, `SERK_AI_BASE_URL`, `SERK_AI_API_KEY` (or `ANTHROPIC_API_KEY`) and `SERK_AI_ALLOW_PRIVATE_HTTP`.
- **Key protection.** A company API key is sealed with AES-GCM using the installation's encryption key, bound to the company, and never returned. A stored key is only used with the provider and address it was entered for; changing them requires entering the key again (`assistant_key_required`). Redirects from the AI service are refused. Plain-HTTP addresses are accepted only for this computer, or private addresses when `SERK_AI_ALLOW_PRIVATE_HTTP=true`.
- **Limits.** 8 model calls and 6 tools per call, tool results capped at 24 KiB (larger results become a valid-JSON truncated wrapper), 140 s per chat, 12 chats per minute per session, and 30 messages of 8000 bytes. Drafts saved before a failure are still reported.
- **API.** `GET /api/v1/assistant/status`, `POST /api/v1/assistant/chat`, `GET`/`POST /api/v1/assistant/settings`. See `docs/AI_ARCHITECTURE.md` and `docs/ai-governance.md`.

## Office installers

- **Windows and Linux installers** (`scripts/build-installers.sh`): `SerkFinance-0.4.0-rc1-Setup.exe` (NSIS), `serk-finance_0.4.0~rc1_amd64.deb` and `serk-finance-0.4.0-rc1-linux-amd64.tar.gz`, with `SHA256SUMS`. Each bundles PostgreSQL 17, which listens on 127.0.0.1 only.
- **`serk-server`** (`cmd/serk-server`) runs the database and the application (`SERK_ENV=office`), with the commands `run`, `service`, `backup`, `restore`, `reset-password`, `stop-database` and `version`.
- **First-run setup wizard.** It creates the company, fiscal year (Ethiopian by default), branches and first administrator. Access needs the server computer itself, or the one-time token in `setup-token.txt`. If setup is interrupted, submit again with the same workspace and administrator email to finish it. Setup can also create the `demo` practice workspace. Its generated password is shown once at the end of setup and is also stored in `serk.json` as `practice_password`.
- **Online backups** to a `.zip`. A temporary replication slot keeps the write-ahead log while files are copied, and the backup checks that its starting log segment is in the archive.
- **Restore** keeps the previous database as `pgdata.before-restore-<time>`, never takes server configuration (`postgresql.conf`, `pg_hba.conf` and similar) from the archive, and puts the previous database back if the swap fails. The server refuses to create a new, empty database when a before-restore folder exists without `pgdata`. `--with-settings` restores `serk.json` on a new computer.
- **Windows:** service `SerkFinance` under `LocalService`. Data in `%ProgramData%\SerkFinance` is restricted to Administrators, SYSTEM and LocalService, and the install folder is locked too. A firewall rule for private and domain networks only is added when chosen. Start-menu shortcuts are provided for backup and password reset.
- **Linux:** `/var/lib/serk-finance`, the `serk-finance` system user and a hardened systemd unit. `sudo serk-finance backup|restore|reset-password`.
- **Verification:** the Linux `.deb` was installed and verified end to end. **The Windows installer has been built but not run on real Windows.** Under Wine, the bundled `postgres.exe` fails because of an unrelated Wine limitation. Treat Windows as unverified. Guide: `docs/OFFICE_INSTALL.md`.

## Fixes from the first accountant test round (migration 056)

- **Errors name the field.** Account mapping and item errors now say which field is wrong: `account_type_not_allowed`, `account_reserved` or `account_required`. The API returns the field key as `error.field`, and the message on screen starts with the field's label. Before, every case said "an account mapping is missing".
- **Account pickers** offer only accounts of the right type that are not reserved for another purpose.
- **Control accounts serve one purpose.** One account can no longer be both cash and a control account, or two control purposes. Remapping a control purpose releases the old account when it never carried an entry. An account is not released while a draft or submitted adjustment uses it. Blank mappings are dropped instead of being saved.
- **Module journals** (from invoices, bills, adjustments and year close) show their source document and send the user to it, instead of offering a general-ledger reversal.
- **Receivable write-off template.** A receivable write-off starts from impairment expense and trade receivables.
- **People are shown by name** in control trails (display names of the company's members only).

## Tests added

- `internal/assistant/assistant_test.go`: tool loop on both providers, error classification, base-URL policy, refused redirects, timeouts, valid-JSON truncation.
- `tests/assistant_test.go`: the assistant acts as the user and only drafts; company key sealing and `assistant_key_required`.
- `tests/assistant-browser.mjs` with `tests/fake-claude.mjs` (a stand-in Claude API), and `tests/assistant-markdown.mjs`.
- `tests/accountant-feedback.mjs` and `tests/controls-022.mjs` AF1–AF4 (now 28 cases).
- `tests/office_setup_test.go`, `tests/office-setup.mjs` and `cmd/serk-server/backup_test.go`.

## Known limitations

- **Windows is unverified** (see above). Run the checks in `VALIDATION_0.4.0.md` on a Windows 10/11 PC before giving the installer to an office.
- **Supplier bills drafted by the assistant need the supplier's invoice number**; only sales invoices continue the company's own sequence.
- **Resuming an interrupted setup** keeps the company and administrator from the first attempt; the second form's password and company details are not applied.
- **Opening the browser after a Windows install** relies on Explorer to drop administrator rights. If a browser opens as administrator, close it and use the Start-menu shortcut.
- **An adjustment saved at the exact moment its control account is remapped** may still name the old account (a window of milliseconds, since remapping waits for adjustments being saved). The approver sees every line before approving.

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
