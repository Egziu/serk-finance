# Deploying the accountant test environment on Railway

Two services run in one Railway project:

| Service | Source | Purpose |
|---|---|---|
| `Postgres` | Railway PostgreSQL template | Database |
| `serk-finance` | GitHub `Egziu/serk-finance`, branch `main`, built from `Dockerfile` (final stage `platform`) | Migrations, runtime logins, demo workspace and the web app |

`railway.json` sets the Dockerfile builder, the health check (`/health/ready`) and the restart policy. Each push to `main` redeploys.

## What happens on every start (`cmd/platform`)

1. Migrations 001–057 are applied with the owner connection. Already-applied files are checksum-verified.
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

## Enabling the AI assistant (optional)

The assistant needs a model provider. There are two ways to set one up, and a company's own settings take precedence over the server's.

**Server-wide, with service variables.** This suits the test environment: every company without its own settings uses it.

| Variable | Value |
|---|---|
| `SERK_AI_API_KEY` | An Anthropic API key. `ANTHROPIC_API_KEY` is also read if `SERK_AI_API_KEY` is not set. Mark it as a sealed variable. |
| `SERK_AI_PROVIDER` | Optional. `anthropic` (default) or `openai` for an OpenAI-compatible server. |
| `SERK_AI_MODEL` | Optional for Anthropic (default `claude-sonnet-5-5`). Required for `openai`. |
| `SERK_AI_BASE_URL` | Optional for Anthropic (default `https://api.anthropic.com`). Required for `openai`, and must be HTTPS unless it is a loopback address. |
| `SERK_AI_ALLOW_PRIVATE_HTTP` | Leave unset on Railway. It allows plain HTTP to private addresses, which is meant for office model servers. |

Redeploy after setting the variables. Check with `GET /api/v1/assistant/status` (as a signed-in user with `ai.use`): it returns `"available": true` and `"configured_by": "server"`.

**Per company, in the app.** An administrator with company-wide `configuration.manage` opens **Modules & features → AI assistant provider**, chooses the provider and model, enters the API key and a reason, and saves. The key is sealed with `SERK_MFA_KEY` and bound to the company, so `SERK_MFA_KEY` must be set and must stay stable. If it changes, stored keys can no longer be read (`assistant_key_unreadable`) and must be entered again.

In both cases, users also need the **Use the AI assistant** (`ai.use`) permission, which the demo roles already have, and the **AI assistant** module must be on under Modules & features. Questions and the figures the assistant looks up are sent to the provider. Use demo or test data unless data-processing terms with the provider have been agreed (`docs/ai-governance.md`).

For automated checks without a real key, `tests/fake-claude.mjs` stands in for the Claude API; see `docs/testing.md`.

## Resetting the test data

Delete the `demo` tenant's data by recreating the database (drop the Postgres volume or create a new Postgres service and point `OPERATOR_DATABASE_URL` at it), then redeploy. The workspace is provisioned again on start.

## Checking a deployment

```bash
SERK_BASE_URL=https://<domain> SERK_DEMO_PASSWORD=<password> node tests/demo-smoke.mjs
```

The smoke test signs in as each demo role and checks the navigation matches the role. It opens the main reports and switches one module off and on again as the administrator.
