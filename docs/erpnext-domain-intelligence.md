# ERPNext domain intelligence; SERK implementation

## Boundary

The uploaded ERPNext PostgreSQL reference is a domain catalog, not a SERK migration. This release does not ship that SQL, translate its tables into SERK automatically, or copy ERPNext controllers. Business concepts inform requirements; executable changes here use SERK's existing ledger, authorization and transaction boundaries. This is not a legal determination of independent IP or licensing compliance: the product's distribution model and any future source reuse still require qualified review.

## Applied in rc3

| Reference concepts | SERK implementation | Evidence |
|---|---|---|
| Account hierarchy, account type and reporting categories | Used-account classification guards; hierarchy preflight, cycle and group-parent checks | `008_master_data_integrity.sql`; database and HTTP regression checks |
| General ledger entries and account balances | Posted-journal line report with opening, movement, running and closing balances | `009_connected_reporting.sql`; precise large-number, pagination and scope tests |
| Accounting dimensions and inactive masters | Used dimension identity protection; SHARE locks during line creation and posting | SQL regression and supplied native race test (native execution remains a gate) |
| Journal references / ledger investigation | Trial balance account → general ledger → original journal in React | Connected browser acceptance in current release evidence |
| Ledger health / reconciliation concepts | Read-only ledger, audit-chain and outbox-link verification | Permission tests, independent recomputation and rollback-only fault injection |

No claim is made that ERPNext itself has the weaknesses discovered in this independent rc2 implementation.

## Next delivery slices, not available features

1. **Supplier invoice to reconciled payment (AP).** Supplier and tax evidence; invoice/line model; duplicate supplier invoice controls; approval; immutable subledger posting; credit note; partial allocation; payment proposal and settlement; GL reconciliation. Build one genuine vertical slice before enabling live payment rails.
2. **Customer invoice to collection (AR).** Customer credit policy, invoice/credit note, receipts, partial allocation, aging as of a date, unapplied cash, write-off authorization, GL reconciliation.
3. **Bank reconciliation.** Statement import provenance, duplicate import protection, immutable statement lines, manual/partial/split matching, undo through audited commands, reconciliation sign-off. Integration adapters use credentials supplied for that bank/provider; no simulated connection is marketed as live.
4. **Procurement / inventory integration.** PR, PO, goods receipt and supplier invoice matching; inventory valuation postings owned by the inventory domain; no manual control-account bypass.
5. **Construction commercial control.** BOQ/WBS, IPC, retention, advance recovery, variations, commitments and project cash reporting, through explicit accounting event contracts.
6. **Localization / reporting / automation.** Versioned tax rules reviewed by local specialists; statutory statements; forecast scenarios; approved OCR/AI suggestions; offline drafts with online validation at posting.

## Contract every new module must satisfy

- Composite tenant/company foreign keys; deny-by-default authorization; tested branch behavior.
- Exact decimal or integer-string amounts with documented currency scales, rounding and FX policy.
- Domain-owned subledger entries reconciled to the GL; never manufacture a mutable `balance` as the source of truth.
- One atomic command transaction: domain state, balanced journal, audit evidence, idempotency receipt, outbox event.
- Stable event identifiers and schema versions; at-least-once consumers need an inbox and deduplication. rc3 records outbox events but has no delivery worker.
- Maker/checker approval, effective permission checks, reversal/adjustment corrections, and period rules.
- Database and HTTP negative tests, two-company and two-tenant fixtures, race tests on native PostgreSQL, populated upgrades, and actual recovery evidence.
- Published implementation status and separate product/accounting/security acceptance. No automatic production approval.

## First staging acceptance scenario

Provision two legal entities and at least two users. Prepare, independently approve and post an exact-value journal; open trial balance, drill into its account ledger and return to the original journal; verify the integrity screen; reverse through approval; inspect both original and reversal in the report; close only a fully resolved period. Repeat with restricted branch access and attempt cross-tenant reads. Preserve commands and output for the exact release source ID.
