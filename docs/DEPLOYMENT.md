# Deployment guide — 0.2.0-rc3

This is a release candidate for the existing manual-journal foundation. Local verification is separate from authorization to use it as a production financial system. Read `PRODUCTION_READINESS.md` before promotion.

## Local persistent acceptance environment

Install Docker Engine/Desktop with Compose, and Python 3. Extract the archive, enter `serk-finance`, and run:

```bash
python3 scripts/init-local.py
docker compose up -d db
docker compose --profile tools run --rm migrate
docker compose --profile tools run --rm roles
docker compose --profile tools run --rm -T bootstrap < .local/bootstrap.json
docker compose up -d --build api
python3 scripts/healthcheck.py http://localhost:8080
```

Open http://localhost:8080. Read `.local/sign-in.txt` privately. Use the accountant to create/submit and a different approver to approve/post. Credentials are randomly generated and excluded from the release. Data persists in `finance-data`. Do not run `docker compose down -v` against data you need.

`make dev` is a separate ephemeral verification workspace. Its generated credentials are in `.local/verification/sign-in.txt`; tests do not replace the persistent development bootstrap file.

## Hosted staging and production-shaped deployment

Provision an external PostgreSQL 17 instance with encryption, verified TLS and a private network. Create separate runtime logins using `scripts/runtime-roles.psql` after applying migrations with the separate operator identity. The API rejects superuser, owner, role-administrator, database-creator, replication, cross-role, or public-schema-creator runtime identities. Mounted secret files (`DATABASE_URL_FILE`, `AUTH_DATABASE_URL_FILE`, and operator `MIGRATOR_DATABASE_URL_FILE`) are supported as an alternative to environment values; providing both sources is rejected.

1. Build and scan both images in your CI. The Dockerfile's `runtime` target contains the API/web assets; `tools` contains migrate/bootstrap/admin/mfa/configure. Record immutable image digests and provenance. The base images and actions are pinned to verified upstream digests/commits in deploy/dependency-pins.json; maintain reviewed updates and configure required repository reviews.
2. Run the [native acceptance procedure](docs/native-acceptance.md) on a representative isolated host. A CI template is included; no remote CI run has been performed here. Missing/filtered tests or any native skip reject the release gate.
3. Back up the existing database and follow [the rc3 upgrade guide](docs/rc3-upgrade.md). From rc2, apply 008–009; from rc1, apply 006–009; from 0.1.0, apply 004–009 through the migrator. All released migration files are immutable. Apply migrations with the matching tools image while the API is stopped. Migration 007 revokes pre-MFA sessions, while an rc2-to-rc3 upgrade preserves rc2 sessions. Migration 008 rejects invalid existing account hierarchies instead of rewriting financial definitions. This is a coordinated maintenance deployment; do not mix older API binaries with the rc3 schema.
4. Provision a new organization only on an empty/new tenant with a reviewed bootstrap configuration. Use `cmd/admin` for lifecycle changes to existing users. Never re-bootstrap an existing tenant. Configure the shared MFA key and enroll every secure-environment user with docs/mfa-operations.md before reopening access. Configure an approved FX rounding account using docs/fx-rounding-policy.md if those entries are required.
5. Copy `.env.release.example` to `.env.release`, restrict it to mode 0600, fill in the image digest, HTTPS origin, URI-encoded credentials, public database CA file, and SERK_MFA_KEY_PATH. The mounted MFA key must be readable by runtime UID 65532 and not world-accessible. Both URLs use `sslmode=verify-full&sslrootcert=/run/serk/db-ca.pem`. The API and authentication connections must point to the same database using distinct logins.
6. Run the offline preflight and start the runtime behind a TLS ingress:

```bash
python3 scripts/preflight.py --env-file .env.release
docker compose --env-file .env.release -f compose.release.yaml up -d
python3 scripts/healthcheck.py https://your-real-finance-domain
```

The release Compose manifest exposes only host loopback port 8080. `deploy/Caddyfile.example` shows a host ingress that overwrites `X-Real-IP`. Set `SERK_TRUSTED_PROXY_CIDRS` to the exact immediate proxy source address the API sees. Without this setting, it ignores forwarded IP headers; all clients behind one proxy share the in-process IP rate limit. Never trust a public/shared network merely to bypass rate limits. The database additionally enforces a source/account login window across replicas. IPv6 addresses share a /64 quota. Successful authentication resets that pair only. Enforce distributed overload protection at the ingress.

Do not print `docker compose config` output with live credentials. Use your secret manager for production; environment examples are deployment inputs, not a secret-management service.

## Configuration and health

`SERK_ENV` is required and accepts only `development`, `staging`, or `production`. Staging/production require HTTPS origins, verified DB TLS without fallback, a valid MFA key and TOTP-authenticated sessions. Development HTTP is restricted to loopback port 8080 origins. Test-role overrides are rejected outside development. Secure environments use the `__Host-serk_session` cookie.

`/health/live` reports process liveness. `/health/ready` requires both financial and authentication pools to respond; probes bypass the client request quota. Startup also checks the schema release marker and the configured web bundle. A healthy response is not a security or accounting certification.

## Upgrade, rollback and operations

Migrations 006–007 add source-aware authentication, explicit FX rounding, safe close controls and MFA. Migrations 008–009 add master-data safeguards and connected reporting. All nine released migrations are immutable. The populated upgrade tests preserve exact journal, line, idempotency, audit and outbox records across supported baselines. They run in PGlite here; native recovery remains a separate gate. Builds 2 and 3 change verification/release tooling only and require no additional database migration.

No destructive down migration is supplied. Application rollback to rc1 after 007 (or to 0.1.0 after 004) is incompatible with revoked authentication functions. Prefer a reviewed forward fix. If restoration is necessary, stop writes, restore a verified pre-upgrade backup into a separate target, reconcile the recovery point and external effects, and switch traffic only after acceptance. Do not silently restore an old database over new financial transactions.

Schedule database maintenance and monitoring. Expired/revoked sessions and login-window rows can be pruned by an operator under a reviewed retention policy; never prune ledger receipts, journal history, audit, or outbox without an explicit retention design. Add external metrics, alerting, backup scheduling, incident response and target identity/MFA enrollment and recovery acceptance before production promotion.

Kubernetes remains a scaffold for teams already operating Kubernetes; no cluster, ingress, TLS certificate, database, network policy, or deployment is created by this archive.

## Startup diagnostics

The API logs startup_failed with a safe stage and code, including database_authentication_failed, database_dns_failed, database_certificate_invalid, database_identity_unsafe, database_migration_version_mismatch, web_bundle_missing or listen_address_in_use. Check the named stage and the protected deployment configuration. Raw DSNs, passwords and SQL details are not logged.
