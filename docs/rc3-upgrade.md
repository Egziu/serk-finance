# rc2 → rc3 controlled upgrade

Scope: a strengthened manual-journal financial kernel and connected reporting, not an AP/AR or banking release.

1. Take a verified backup and rehearse restoration on the target infrastructure. This workspace has not performed a production restore or PITR drill.
2. Stop/drain rc2 application traffic in a planned maintenance window. rc2 and rc3 enforce different schema release markers; mixed-version operation is not supported.
3. Review chart preflight conditions. Every existing parent must be a non-posting, non-control group of the same account type. Cycles and paths deeper than 256 are rejected. Migration 008 fails rather than rewriting incompatible historical data. Refer failures to an accounting owner; do not disable triggers or edit a released migration.
4. Run the existing operator migration command against the intended database: `go run ./cmd/migrate`. It checks prior SQL hashes and applies 008 and 009 transactionally, each recorded separately.
5. Install the matching rc3 API and rebuilt web bundle together. Existing rc2 MFA/session configuration remains required; 008–009 do not intentionally revoke existing rc2 sessions.
6. Run readiness checks and the staging scenario in `docs/erpnext-domain-intelligence.md`. Verify ordinary users cannot access company-wide integrity checks without both ledger and audit authority.
7. Close native PostgreSQL, container, backup/recovery, capacity and independent review gates before approving any live financial use.

Rollback is a reviewed backup/restore or forward-fix operation. No destructive down migration is supplied. Do not deploy the rc2 binary against an rc3 schema.

## Master-data changes

An account's identity is immutable. Once referenced by journal lines, its code, type, normal balance, parent, control designation and reporting category cannot be changed by ordinary SQL updates. Use reviewed reclassification journals/new accounts instead of rewriting history. Account active/posting flags remain changeable to stop future posting. Display names remain editable; a complete dual-approved master-data administration interface and audit coverage are still future work.

Used dimension identity, kind and code are protected. Dimensions may be deactivated, but posting with an inactive dimension is blocked. Native race tests are supplied to verify concurrent deactivation, and remain unexecuted in this workspace.

## Reporting semantics and limitations

- General-ledger numbers are functional-currency integer strings. Opening precedes `from`; movement includes both date boundaries; closing = opening + debit − credit. Negative running balances represent credit balances.
- Only `POSTED` lines are included. A reversal remains a separate posting; original history is not deleted.
- A branch-restricted report is explicitly marked partial. The integrity endpoint instead requires company-wide `ledger.read` and `audit.read`.
- Keyset pages are deterministic for an unchanged dataset, but are separate live reads. Backdated postings may change totals between pages; rerun before reconciliation. Snapshot exports are not implemented.
- Integrity checks compare posted balance equality, audit sequence/hash/payload linkage, audit head, one-to-one outbox correspondence and journal event-version continuity. They do not validate source-document authenticity, statutory compliance, external delivery, completeness against a signed external checkpoint, or immunity to a privileged database administrator.
- Ledger and integrity queries scan scoped financial data and are bounded by the existing database statement timeout. No enterprise-scale throughput or latency promise is established.

## Engineering references

The use of SHARE locks to protect non-key account/dimension changes follows [PostgreSQL's explicit locking documentation](https://www.postgresql.org/docs/current/explicit-locking.html). Reporting functions retain forced row security as described in [PostgreSQL's row-security documentation](https://www.postgresql.org/docs/current/ddl-rowsecurity.html). Those references explain the mechanisms; only the included test evidence describes what ran on this release.
