# Testing and evidence

## Current: 0.3.0-rc1

0.3.0 adds `tests/profile_password_test.go`, the F1 and E1 cases in `tests/controls-022.mjs` and `internal/provisioning/periods_test.go`. Against a running demo deployment, local or Railway:

```bash
SERK_BASE_URL=https://<host> SERK_DEMO_PASSWORD=… node tests/demo-scenarios.mjs   # HTTP scenarios from the accountant guide
SERK_BASE_URL=https://<host> SERK_DEMO_PASSWORD=… node tests/demo-smoke.mjs       # browser: per-role navigation and module switch
```

## 0.2.2-rc1

Evidence for this release is in `test-results/validation-0.2.2/` (`summary.tsv` lists every step, exit code and duration) and is summarised in `VALIDATION_0.2.2.md`.

Native run on a disposable PostgreSQL 17 server:

```bash
export TEST_DATABASE_URL=postgres://postgres:...@127.0.0.1:5432/serk?sslmode=disable          # operator, disposable
export MIGRATOR_DATABASE_URL=$TEST_DATABASE_URL SERK_ENV=development
go run ./cmd/migrate                                                                          # 001-051
SERK_API_PASSWORD=... SERK_AUTH_PASSWORD=... psql "$TEST_DATABASE_URL" -f scripts/runtime-roles.psql
export TEST_API_DATABASE_URL=postgres://serk_api_login:...@127.0.0.1:5432/serk?sslmode=disable
export TEST_AUTH_DATABASE_URL=postgres://serk_auth_login:...@127.0.0.1:5432/serk?sslmode=disable
go test -race -count=1 ./...                         # 52 top-level tests; the 8 native concurrency tests must PASS, not skip
SERK_SQL_BACKEND=native node tests/controls-022.mjs  # 0.2.2 security/IFRS controls (creates and drops its own database)
SERK_SQL_BACKEND=native node tests/remediation.mjs   # 0.2.1 module controls
node tests/remediation-upgrades.mjs                  # populated upgrade preservation from six baselines (PGlite)
SERK_BROWSER_EXECUTABLE=/path/to/chrome node tests/verify.mjs --native --e2e   # real browser, MFA, on a fresh database
grep -v "/go.mod " go.sum | cut -d" " -f1,2 > /tmp/mods.txt && python3 scripts/osv-check.py /tmp/mods.txt <vulndb>/data/osv   # when vuln.go.dev is unreachable
```

`tests/sql-backend.mjs` lets the SQL fixtures run on PGlite (default) or on native PostgreSQL (`SERK_SQL_BACKEND=native`, which creates a uniquely named database from `TEST_DATABASE_URL` and drops it afterwards).

## Historical (0.2.0-rc3 / rc4)


Current package: **0.2.0-rc3, build 3**. `make release-check` runs 15 local checks covering immutable pins, module verification, frontend build, three harness regression gates, the Go race-enabled financial/security suite, SQL controls, populated 0.1.0/rc1/rc2 upgrades, browser acceptance, npm audits and Go vulnerability scanning. It records exact commands, timestamps, exit codes and durations in `test-results/release-check.json`, or beneath `SERK_RESULTS_DIR` when set. The native profile adds a sixteenth check. Any failed or blocked required step keeps the overall gate nonzero.

The local database is PGlite 0.5.8 through pglite-socket 0.2.11. It executes SQL functions, triggers, constraints and row-level policies. It multiplexes one underlying connection and uses an explicit test-role switch. Eight tests require native PostgreSQL: concurrent idempotency, concurrent posting, period close versus posting, period close versus creation, concurrent MFA counter consumption, real runtime-login boundaries, dimension change versus posting, and chart snapshot write skew. They skip locally and must not skip in native verification. The Go race detector tests Go memory races; it does not replace native SQL concurrency tests.

The runner reads effective `go env GOFLAGS` and rejects selection options (`-run`, `-skip`, `-short`, `-list`, `-fuzz`, including `-test.*` forms). Run targeted diagnostics separately; they do not count as full-release evidence. `GOFLAGS=-buildvcs=false` remains allowed for source archives. Go's own JSON discovery enumerates top-level tests/fuzz targets; every entry must have terminal execution evidence and successful package completion. Missing tests, invalid JSON, failed packages, duplicate completions and unexpected skips fail the gate. All eight native definitions must exist, and native runs require eight named PASS records. Embedded runs permit only those eight skips. This prevents empty or filtered runs from earning PASS; it does not prove complete application-path coverage.

Current authoritative evidence:

- `go-test-discovery.jsonl`: Go's declared top-level tests and fuzz targets.
- `go-tests.jsonl`: fresh Go test events, including named subtests and skips.
- `test-summary.json`: discovery/execution reconciliation, test/subtest counts, required native results and errors; package-level summary events are not double-counted.
- `coverage.out` / `coverage-summary.log`: statement coverage across `internal/...`; SQL and external browser execution are outside that metric.
- `upgrade/upgrade-result.json`, `upgrade-rc1/upgrade-result.json`, `upgrade-rc2/upgrade-result.json`: three supported baselines preserve financial fields and correct session treatment; reapplication succeeds, checksum drift is rejected and teardown completes before final PASS.
- `browser-tests.log` and `screenshots/`: real MFA login, journal/report workflow, visible FX rounding and blocked/successful period close.
- `release-check.json`: complete local gate results.
- `native/native-release-gate.json`: latest native attempt beneath the selected results directory; unavailable Docker records BLOCKED and keeps the overall gate nonzero.

`make verify-native` provisions only disposable script-owned containers. It uses three separate PostgreSQL login URLs, disallows role override, rejects skipped tests, runs browser acceptance on native PostgreSQL, takes/restores a real dump to a separate database, compares all application tables, tests restored authorization, builds and starts the runtime image and checks health/web responses. CI additionally scans that image and generates its SBOM. No native success is claimed until those commands actually pass.

Use [the native acceptance instructions](native-acceptance.md) on a suitable host. The new host preflight is read-only. Missing Docker or an unusable unprivileged local account returns BLOCKED, exit 2, `tests_run=false`, before initialization. Preflight PASS permits the subsequent attempt; it is not evidence that native tests ran.

For an existing disposable PostgreSQL instance you may set `TEST_DATABASE_URL`, `TEST_API_DATABASE_URL`, and `TEST_AUTH_DATABASE_URL` and run `node tests/verify.mjs --native`. These tests provision synthetic tenants: never point them at production or a business database. Production-shaped TLS and restore tests belong in an isolated representative staging environment.

The browser harness supports `SERK_BROWSER_EXECUTABLE` and `SERK_BROWSER_ARGS_JSON` for constrained test hosts. CI uses its standard Playwright browser. The current workspace required a separately obtained Chromium build with OS sandboxing disabled; no frontend web-security bypass flags were used. Ephemeral fixtures are under `.local/verification`, separate from persistent local initialization.

Initial rc3 evidence is under `test-results/rc3/`, build-2 evidence under `test-results/rc3-build2/`, build-3 evidence under `test-results/rc3-build3/`, and supplied independent evidence under `test-results/independent-rc3-2026-09-22/`. Historical rc2/rc1/0.1 records are under `test-results/historical-rc2/`. Read the report for the exact build; historical records are not a current execution claim. No long fuzz campaign, production capacity test, external security assessment or compliance certification was performed.

MFA tests cover RFC 6238 vectors, authenticated-encryption tampering and user binding, required factors, session assurance, consumed-counter replay denial, legacy issuance denial and operator recovery. HTTP integration tests exercise transition/trial/general-ledger/integrity/audit/close/logout handlers, including failures. The 500-source-line FX regression verifies the one generated-line boundary.
