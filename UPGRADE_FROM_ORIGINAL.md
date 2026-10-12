# Upgrade from the supplied package

Use a disposable copy first. Back up the real database and prove restoration before changing it. Stop application writers for the rehearsal and actual upgrade.

The existing migration filenames and bytes for 001–036 remain unchanged. `033_0_operator_migration_access.sql` runs immediately before the unchanged legacy 033 migration. Its maintenance predicate checks the **connection identity**, not the definer identity; ordinary API/authentication connections do not receive operator access. Migration 037 removes these temporary policies and restores normal scoped/restrictive ledger policies.

Before proceeding, reconcile existing financial data:

- Identify empty/unbalanced SYSTEM postings and any posted lines that changed outside their audited journal transitions.
- Validate inventory account UUIDs and company ownership. Record and reconcile opening stock values rather than guessing values from a quantity-only history.
- Validate employee salaries, branch assignments, and policy dates. Historical employees without a branch must be assigned before a new payrun can include them.
- Review balances and source links for old invoices/bills/payroll. Old module tables remain present; corrected operations use the new finance document registry. Historical records must be migrated/reconciled deliberately, not represented as newly validated documents.

Run the existing migrator with privileged operator credentials; keep those credentials separate from the API and authentication logins. A checksum mismatch must be investigated, not removed. Do not edit previously applied SQL files or delete migration receipts to bypass a failure.

The included SQL-only rehearsals preserve existing journals, lines, receipts, audit events/heads, and outbox records from six baseline schema positions. They do not establish native lock behavior, Go migrator execution, backup recovery, or correctness of your particular legacy data.

After migration, verify all schemas, ledger invariants, permissions, source balances, and final posting snapshots. Configure the new account mappings and approved policies. Module posting refuses a failed reconciliation. If historical posting snapshots do not exist, retain the historical ledger for review and establish an independently verified opening position in a clean company/database rather than inventing an old audit event.

Promote only the exact artifact that passes the full release/native, accounting, security, recovery, and capacity gates.

Preserve the existing MFA encryption key with the backup. Never replace it without a controlled re-encryption or verified re-enrollment/recovery plan for all existing factors. The former shared development key must be retired through that process. Apply all repair migrations before starting the new application; the runtime version marker is published only by the final migration.
