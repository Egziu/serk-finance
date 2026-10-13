# Deploying the accountant test environment on Railway

Two services run in one Railway project:

| Service | Source | Purpose |
|---|---|---|
| `Postgres` | Railway PostgreSQL template | Database |
| `serk-finance` | GitHub `Egziu/serk-finance`, branch `main`, built from `Dockerfile` (final stage `platform`) | Migrations, runtime logins, demo workspace and the web app |

`railway.json` sets the Dockerfile builder, the health check (`/health/ready`) and the restart policy. Each push to `main` redeploys.

## What happens on every start (`cmd/platform`)

1. Migrations 001–055 are applied with the owner connection. Already-applied files are checksum-verified.
2. The two unprivileged logins `serk_api_login` and `serk_auth_login` are created or updated. They get no superuser, no create-role and no RLS bypass.
3. If `SERK_DEMO_SEED=ethiopia` and the workspace `demo` does not exist yet, the Ethiopian test workspace is provisioned (see `docs/ACCOUNTANT_TEST_GUIDE.md`). It is never overwritten.
4. The API starts on `$PORT` using only the unprivileged logins. The operator URL is removed from the process environment first.

## Service variables (`serk-finance`)

| Variable | Value |
|---|---|
| `OPERATOR_DATABASE_URL` | `${{Postgres.DATABASE_URL}}?sslmode=disable`. This is the private network URL (`postgres.railway.internal`). |
| `SERK_DB_PRIVATE_NETWORK` | `true`. This waives database TLS only for `*.railway.internal` hosts, because Railway's private network is already encrypted. Every other host still needs verified TLS. |
| `SERK_ENV` | `staging` |
| `SERK_REQUIRE_MFA` | `false` while accountants test. Users can still enrol an authenticator from their profile. Remove this variable to make MFA mandatory; production always requires it. |
| `SERK_API_PASSWORD`, `SERK_AUTH_PASSWORD` | Two different random strings of 32+ characters. Keep them stable. |
| `SERK_MFA_KEY` | 32 random bytes, base64. Keep it stable, because it encrypts authenticator secrets. |
| `SERK_DEMO_SEED` | `ethiopia` |
| `SERK_DEMO_PASSWORD` | The shared password for the demo users (14+ characters). Change it per user after first sign-in. |
| `SERK_TRUSTED_PROXY_CIDRS` | `10.0.0.0/8,100.64.0.0/10,fd00::/8`. This is Railway's edge, so login throttling sees real client addresses. |
| `SERK_ORIGIN` | Optional. It defaults to `https://$RAILWAY_PUBLIC_DOMAIN`. |

Generate a public domain for the service (Settings → Networking, or `generate-domain`).

## Resetting the test data

Delete the `demo` tenant's data by recreating the database (drop the Postgres volume or create a new Postgres service and point `OPERATOR_DATABASE_URL` at it), then redeploy. The workspace is provisioned again on start.

## Checking a deployment

```bash
SERK_BASE_URL=https://<domain> SERK_DEMO_PASSWORD=<password> node tests/demo-smoke.mjs
```

The smoke test signs in as each demo role and checks the navigation matches the role. It opens the main reports and switches one module off and on again as the administrator.
