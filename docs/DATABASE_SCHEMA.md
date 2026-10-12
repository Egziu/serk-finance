# Database update — 0.2.0-rc2

Seven additive migrations are embedded in the operator binary. Released 001–005 are unchanged. Migration 004 adds `security.login_windows`, `security.admin_events`, and `ledger.period_receipts`, plus authentication, approval and definition guards. Migration 005 replaces journal creation with period/company/currency row locks with the original runtime schema marker. Migration 006 adds source-aware limits, safe period close, FX configuration/audit and generated rounding metadata. Migration 007 adds encrypted MFA records, session assurance, legacy session revocation and the final rc2 release marker. Financial data remains in PostgreSQL; new private security tables have no runtime table grants, and period receipts use forced tenant/company RLS. Migrate during a coordinated maintenance window because 007 revokes the previous runtime issuance grant and existing sessions. See [DEPLOYMENT.md](DEPLOYMENT.md) and [BACKUP_RECOVERY.md](BACKUP_RECOVERY.md).

# Database architecture

PostgreSQL 17 is the initial native target. The current migrations were exercised on PGlite 0.5.8, which embeds PostgreSQL; native migration, privilege, concurrency and recovery gates remain distinct.

| Schema | Owned relations | Access |
|---|---|---|
| `security` | tenants, users, sessions, roles, permissions, role_permissions, memberships, login_windows, admin_events, configuration_events, user_mfa | Private; narrowly scoped definer functions |
| `organization` | currencies, companies, branches | Companies private; branch RLS; authorized reference functions |
| `ledger` | accounts, fiscal_years, periods, dimensions, numbering, journals, lines, line_dimensions, idempotency, period_receipts; private fx_rounding_settings | Financial relations use forced company/tenant RLS and additional branch policies; rounding settings are operator-private |
| `audit` | heads, events | Company-scoped write chain; separately authorized audit reads |
| `integration` | outbox | Immutable transactional publication records; delivery worker pending |
| `public` | serk_migrations | Migrator-only checksum history |

`serk_owner` is NOLOGIN, non-superuser, without BYPASSRLS, and owns core objects. `serk_api` and `serk_auth` are non-login permission roles inherited by separately provisioned login identities. The API startup checks that live runtime identities are not owners, owner-role members, superusers, or BYPASSRLS users. Test role overrides are restricted to development/testing and rejected in production mode.

The financial API can read authorized financial relations and execute approved commands. It has no direct DML, TRUNCATE, schema creation, password-read, session-issuance, or owner-role grant. Definer function privileges are revoked from PUBLIC by default. Table triggers protect history even if an operator mistakenly attempts an ordinary UPDATE. A database superuser remains part of the trust boundary and requires external monitoring and recovery controls.

Foreign keys include `(tenant_id, company_id, referenced_id)` for financial references. Lines cannot reference an account, branch, period, dimension, or reversal journal belonging to another company. Parent account and dimension relationships are normalized; dimensions are not an unvalidated financial JSON blob. JSONB is used for bounded command receipts, audit snapshots, and event payloads.

Current indexes support company journal ordering, posted journal dates, account activity, unique numbering, and unique reversal sources. Period insert guards serialize against a company row and reject overlapping ranges. Period headers cannot be rewritten after creation through ordinary updates. COA tree editing and hierarchy/currency policy changes are not exposed by runtime APIs and require further audited configuration commands and tests.

Migrations are embedded into the operator binary, alphabetically ordered, hashed with SHA-256, and committed one at a time under an advisory migration lock. An already-applied filename with different bytes fails. The initial files were developed before the first release; after this archive, fixes must append a new migration. There are no destructive down migrations. Rollback of a release is an application rollback plus an independently reviewed forward repair or point-in-time restoration, never an automatic drop of financial tables.

Future schemas should add only modeled aggregates from the domain contracts. Every new table must have an owner, reference integrity model, tenant policy, mutation policy, indexes justified by a query, retention classification, and reconciliation role. Do not create the entire target table list as unused scaffolding.
