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

## Office installation (0.4.0-rc1)

Office installations (`docs/OFFICE_INSTALL.md`) have built-in backup and restore commands. The PostgreSQL client steps above are not needed there.

**Backup** (Serk Finance running; people can keep working):

```bash
sudo serk-finance backup                 # Linux
# Windows: Start menu > Serk Finance > Back up now
#   or: "C:\Program Files\Serk Finance\serk-server.exe" backup --data "C:\ProgramData\SerkFinance" [--out FILE]
```

- The result is `<data>/backups/serk-backup-YYYYMMDD-HHMMSS.zip`. It is written as `.partial` and renamed only when complete.
- It is a physical online backup: `pg_backup_start`, a copy of the data directory, `pg_backup_stop`, then the write-ahead log.
- A temporary physical replication slot, held for the length of the backup, stops PostgreSQL from recycling write-ahead log segments while files are copied.
- The backup fails, rather than reporting success, if the starting log segment named in the backup label is not in the archive.
- The archive also contains `serk.json`, which holds the installation's secrets, including the encryption key (the office equivalent of `SERK_MFA_KEY`). Treat every backup as highly confidential. Serk Finance does not encrypt it, so copy it to encrypted, off-site storage.
- Backups are not scheduled automatically. Use Task Scheduler, a systemd timer or cron if needed.

**Restore** (Serk Finance stopped):

```bash
sudo systemctl stop serk-finance
sudo serk-finance restore --from /path/serk-backup-….zip [--with-settings]
sudo systemctl start serk-finance
```

On Windows, use `sc stop SerkFinance`, then `serk-server.exe restore --data "C:\ProgramData\SerkFinance" --from …`, then `sc start SerkFinance`.

- The archive must carry the Serk Finance marker and a backup label. Paths that would escape the data folder are refused, and every file's size is checked.
- Files are unpacked into a staging folder. The current database is kept as `pgdata.before-restore-<time>`, and the staging folder takes its place. If that swap fails, the previous database is renamed back. Recovery to a consistent state completes on the next start.
- `postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf` and `pg_ident.conf` are never taken from the archive. The installation's own files (or Serk Finance's standard ones) are written instead.
- If `pgdata` is missing while a `pgdata.before-restore-*` folder exists, the server refuses to start rather than initialise a new, empty database.
- `--with-settings` also restores `serk.json`. Use it when restoring onto a new computer: install, start once, stop, then restore. Without the original key, authenticator secrets and stored AI provider keys cannot be decrypted.

The restore logic is covered by `cmd/serk-server/backup_test.go`. A restore on the target office computer remains the operator's acceptance step. The Windows commands have not yet been run on real Windows.
