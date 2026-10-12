# Testing and evidence

`make release-check` runs Go module verification, frontend strict typecheck/build, the Go race-enabled financial/security suite, populated 0.1.0 and rc1 upgrade rehearsals, real browser acceptance, npm audits and a Go vulnerability scan. It records exact commands, timestamps, exit codes and durations in `test-results/release-check.json` and fails if any required step fails or cannot run.

The local database is PGlite 0.5.8 through pglite-socket 0.2.11. It executes SQL functions, triggers, constraints and row-level policies. It multiplexes one underlying connection and uses an explicit test-role switch. Six tests require native PostgreSQL: concurrent idempotency, concurrent posting, period close versus posting, period close versus creation, concurrent MFA counter consumption, and real runtime-login boundaries. They skip locally and must not skip in native verification. The Go race detector tests Go memory races; it does not replace native SQL concurrency tests.

Current authoritative evidence:

- `go-tests.jsonl`: fresh Go test events, including named subtests and skips.
- `test-summary.json`: test/subtest counts; package-level summary events are not double-counted.
- `coverage.out` / `coverage-summary.log`: statement coverage across `internal/...`; SQL and external browser execution are outside that metric.
- `upgrade/upgrade-result.json` and `upgrade-rc1/upgrade-result.json`: both supported upgrade paths preserve existing financial fields, reapplication succeeds and checksum drift is rejected.
- `browser-tests.log` and `screenshots/`: real MFA login, journal/report workflow, visible FX rounding and blocked/successful period close.
- `release-check.json`: complete local gate results.
- `native/native-release-gate.json`: latest attempted native gate; an unavailable Docker engine is a failed gate, not a silent skip.

`make verify-native` provisions only disposable script-owned containers. It uses three separate PostgreSQL login URLs, disallows role override, rejects skipped tests, runs browser acceptance on native PostgreSQL, takes/restores a real dump to a separate database, compares all application tables, tests restored authorization, builds and starts the runtime image and checks health/web responses. CI additionally scans that image and generates its SBOM. No native success is claimed until those commands actually pass.

For an existing disposable PostgreSQL instance you may set `TEST_DATABASE_URL`, `TEST_API_DATABASE_URL`, and `TEST_AUTH_DATABASE_URL` and run `node tests/verify.mjs --native`. These tests provision synthetic tenants: never point them at production or a business database. Production-shaped TLS and restore tests belong in an isolated representative staging environment.

The browser harness supports `SERK_BROWSER_EXECUTABLE` and `SERK_BROWSER_ARGS_JSON` for constrained test hosts. CI uses its standard Playwright browser. The current workspace required a separately obtained Chromium build with OS sandboxing disabled; no frontend web-security bypass flags were used. Ephemeral fixtures are under `.local/verification`, separate from persistent local initialization.

Historical supplied 0.1.0 logs/screenshots remain under `test-results/baseline-v0.1.0`. They are not current-run evidence. No long fuzz campaign, production capacity test, external security assessment or compliance certification was performed.

MFA tests cover RFC 6238 vectors, authenticated-encryption tampering and user binding, required factors, session assurance, consumed-counter replay denial, legacy issuance denial and operator recovery. HTTP integration tests directly exercise transition/trial/audit/close/logout handlers, including failures. The 500-source-line FX regression verifies the one generated-line boundary. Historical rc1 evidence is under test-results/baseline-rc1.
