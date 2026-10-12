# Roadmap: an IFRS-grounded, AI-assisted finance system for Ethiopia and Africa

Target: a Sage 50-class accounting system for small and medium businesses that is trustworthy by construction. It should be IFRS / IFRS for SMEs-aligned, localised for Ethiopia first, usable offline, and include an AI assistant that drafts but never posts.

Decisions recorded with the product owner (2026-10-12):

| Topic | Decision |
|---|---|
| First phase | Verify and harden the existing core (done in 0.2.2-rc1) |
| AI assistant authority | **Drafts only; a person approves.** The assistant prepares journals, invoices and adjustments in DRAFT and never submits, approves or posts. This reuses the existing maker-checker controls. |
| Interface languages | English for now. Keep every string in one place so other languages can be added without code changes. |
| Deployment | **Cloud and offline.** Hosted multi-company web app, plus a local office server that keeps working without internet and synchronises later. |

## Phase 1 — Verified, hardened core (0.2.2-rc1, this release)

Native PostgreSQL and browser verification, security and IFRS review fixes, year-end close, period reopen, controlled adjustments, VAT report, FX rate controls and statement classification. See `RELEASE_NOTES.md` and `VALIDATION_0.2.2.md`.

Remaining gates outside this workspace: container build and scan, restore/PITR on the target host, capacity test, and independent accountant and security sign-off.

## Phase 2 — Ethiopia localisation (next)

All rates come from versioned, dual-approved policy tables (as payroll policies already do), never hard-coded. Each item ships with fixtures reviewed by an Ethiopian accountant.

1. **Ethiopian calendar.**
   - Fiscal year Hamle 1 – Sene 30, with 12 periods of 30 days plus Pagume (5/6 days).
   - Dates shown in both calendars and stored as Gregorian.
   - The current fiscal-year generator only makes Gregorian-month periods.
2. **VAT.**
   - 15% standard rate, plus zero-rated and exempt as separate treatments.
   - Sequential tax-invoice numbering per branch with no gaps, and voids recorded.
   - Buyer and seller TIN on invoices.
   - Monthly VAT return layout matching the Ministry of Revenues declaration, with settlement through the TAX_SETTLEMENT adjustment.
3. **Withholding tax.**
   - 2% on qualifying purchases above the threshold, and 30% where no TIN is given.
   - Withholding receipts issued and received; certificates register.
4. **Turnover tax (TOT)** for non-VAT-registered businesses, with VAT treated as part of cost.
5. **Payroll.**
   - PAYE bands, 7% employee / 11% employer pension.
   - Taxable vs exempt allowances, overtime, and leave and severance accruals under the Labour Proclamation.
   - Payroll remittance through PAYROLL_SETTLEMENT.
6. **Reports:** VAT, withholding, PAYE and pension schedules in authority formats, plus excise duty where relevant.
7. **Currency:** ETB with NBE reference rates, imported daily into the rate table (manual import first).

## Phase 3 — Sage 50-class everyday modules

1. **Receivables and payables.**
   - Partial receipts and payments, with allocation across documents.
   - Credit and debit notes that reverse part of a document.
   - Aging reports and customer and supplier statements.
   - Customer and supplier opening balances by document.
   - Expected credit loss (IFRS 9 simplified matrix).
2. **Banking.**
   - Bank accounts, statement import (CSV and bank formats) and matching rules.
   - Bank reconciliation report.
   - Cheques and transfers.
3. **Sales and purchasing documents:** quotes, sales orders, delivery notes, purchase orders and goods received, converted into invoices and bills.
4. **Fixed assets (IAS 16).**
   - Asset register, straight-line and diminishing-balance depreciation, and a scheduled depreciation run (dual-controlled).
   - Disposals, revaluation and impairment flags.
   - Tax depreciation tracked separately.
5. **Inventory (IAS 2).**
   - Stock counts, transfers between branches and landed cost (duty and freight) for imports.
   - FIFO option and NRV review report.
6. **Financial statements.**
   - Statement of changes in equity and cash-flow statement (IAS 7, indirect method).
   - Comparative periods, IAS 1 line-item mapping, notes scaffolding and PDF and Excel export.
7. **Recurring and auto-reversing journals** for accruals and prepayments, and **budgets** with budget-vs-actual reports.
8. **Foreign-currency documents** with realised FX on settlement and closing-rate revaluation of monetary items (IAS 21.23).

## Phase 4 — AI assistant (drafts only, human approves)

The design principle is that the assistant is a preparer, never an approver.

- **Read access.** Read-only tools over the reports the user may already see: trial balance, general ledger, aging, VAT report and integrity. Authorisation is enforced by the same database session and RLS. The assistant never gets broader access than the signed-in user.
- **Write access.** Write tools only create DRAFT journals, invoices, bills and adjustments, with a stated rationale and source references. The audit trail records `prepared_by_assistant` together with the prompting user.
- **Tasks.**
  - Explain a report line ("why did gross margin fall?").
  - Draft a VAT remittance from the VAT report.
  - Find anomalies: duplicate bills, unusual amounts, round-sum journals, postings outside working hours.
  - Suggest bank-reconciliation matches.
  - Summarise period-end blockers.
- **Safety.**
  - Prompts and outputs are logged per company.
  - No customer data is used for training; data processing terms are agreed with the model provider.
  - Every draft goes through the existing independent approval.
  - Evaluation suites cover arithmetic, permission boundaries and refusal to approve.
- **Provider.** Provider-agnostic interface. The first implementation uses the Claude API (Anthropic) with tool use, configurable per tenant, and can be disabled entirely.

## Phase 5 — Offline-first office server and sync

- **Local server.** A local server (same Go binary and PostgreSQL) runs per office or branch. It is the system of record for documents it creates while offline.
- **Sync.**
  - Synchronisation through the existing transactional outbox with idempotent replay. The audit chain is preserved per company, and conflicts are resolved by document ownership.
  - Numbering ranges are allocated per office so tax invoices stay sequential offline.
  - Period close and year-end only run while connected.
- **Resilience:**
  - Bounded offline window.
  - Encrypted local backups.
  - Health reporting to the cloud.

## Phase 6 — Scale and certification

- **Performance.** Today a two-line journal takes about 87 ms end to end, including audit hashing. Targets: profiling, partitioned audit and outbox tables, report materialisation, load tests at target volumes.
- **Security.**
  - External penetration test.
  - Image scanning and SBOM in CI.
  - Key rotation runbooks.
  - Optional SSO.
- **Compliance.**
  - Engage an Ethiopian audit firm to review IFRS for SMEs mapping and statutory reports.
  - Data-residency options.
  - ISO 27001-style controls documentation.
- **Languages:** Amharic, Tigrinya and Afaan Oromo, using the externalised strings (fonts and number formats already render Ethiopic script in modern browsers).

## Known design limits carried forward

- **Authentication role (`serk_auth`).** It can create a session for any user once a password has been verified in the API process. The database cannot verify argon2id or TOTP itself. Treat the `serk_auth_login` credential as a top-tier secret, restrict it by network, and rotate it. A separate verifier service (Phase 6) would remove this trust.
- **Sub-ledger vs ledger.** Receivable and payable write-offs reduce the control account but do not yet allocate against individual documents (Phase 3, allocation).
