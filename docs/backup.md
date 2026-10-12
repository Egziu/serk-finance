# Backup and recovery operations

The included recovery rehearsal is implemented in `scripts/native-check.py`. It has not been executed in this workspace because Docker and native PostgreSQL are unavailable. Run `make verify-native` on a Docker host; a green result requires a real dump, restoration into a separate disposable database, exact table fingerprints, and authorization checks against the restored database.

For a deployed database, enable the provider's encrypted backups and continuous WAL archival/PITR. Agree the RPO and RTO with the business, configure retention and off-site copies, protect encryption keys separately, and alert on backup age and failed jobs. This code release does not provision those services or establish recovery objectives by measurement.

## Operator backup

Use a PostgreSQL client compatible with the server and a protected `PGSERVICEFILE`/`.pgpass` entry with verified TLS. Keep connection credentials out of command arguments and logs. Back up roles separately under the same protection; the database dump includes ownership and grants but not cluster role definitions. Runtime passwords should be rotated after a recovery incident.

```bash
umask 077
pg_dump --dbname=service=serk-backup --format=custom --file=/protected/backup/serk.dump
pg_dumpall --database=service=serk-backup --globals-only --file=/protected/backup/roles.sql
sha256sum /protected/backup/serk.dump
```

Store these files only on approved encrypted storage. Do not add them to this source archive. Dump files contain sensitive financial data, password hashes and session metadata. Do not remove ownership or ACLs from the dump: restored role separation and forced row-level policies are part of recovery acceptance.

## Restore rehearsal

Restore into a newly created isolated database. Never overwrite the live database for a rehearsal. An infrastructure operator must provision the reviewed roles in the target cluster before restoring. Do not blindly apply a globals file to an existing shared production cluster.

```bash
pg_restore --dbname=service=serk-restore --exit-on-error /protected/backup/serk.dump
```

Before promotion: compare record counts and ordered data fingerprints, reconcile posted debit/credit totals and trial balances, validate audit chains and heads, compare outbox/receipt continuity, verify restricted login grants and tenant isolation, and confirm the application/schema version. Revoke restored sessions through the operator process before reopening access after an incident. Reconcile external side effects independently; a database restore does not roll back a bank payment.

Record the backup timestamp, restore start/end, achieved RPO/RTO, evidence, operator, reviewer, and exceptions. Repeat the drill after schema/infrastructure changes. A logical dump rehearsal does not demonstrate PITR, failover, cross-region recovery, or production-scale restore performance.

## MFA recovery material

Backups now contain encrypted TOTP secrets, enrollment versions and consumed counters. Keep the matching SERK_MFA_KEY in a separately controlled secret backup. Restore it with the database before testing authenticator access. Revoke restored sessions after an incident. Preserve consumed-counter continuity and synchronize clocks; device recovery uses verified operator reenrollment, never a password-only bypass. Key recovery and target reenrollment drills remain required acceptance evidence.
