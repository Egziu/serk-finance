# Historical release validation — SERK Finance 0.2.0-rc2

**Supplied historical evidence only. Current rc3 commands and results are in [RC3_RELEASE_REPORT.md](RC3_RELEASE_REPORT.md).** The old `test-results/` paths below now live under `test-results/historical-rc2/`.

**Local gate: PASS. Production readiness: BLOCKED. No live deployment or independent approval occurred.**

Run: 2026-09-20T19:45:19.971230+00:00 → 2026-09-20T19:47:15.127178+00:00 (UTC). This report covers the manual-journal foundation and the review remediation in REVIEW_REMEDIATION.md.

| Check | Result | Evidence under test-results/ |
|---|---|---|
| Immutable upstream references | PASS | immutable_dependencies.log, deploy/dependency-pins.json |
| Go module verification | PASS | go_modules.log |
| Frontend strict typecheck and production build | PASS | web_build.log |
| Race-enabled Go unit/integration/security tests | 78 passing test/subtest records, 0 failures, 6 native-only skips | go-tests.jsonl, test-summary.json |
| Internal Go statement coverage | 71.6% (rc1: 60.8%) | coverage.out, coverage-summary.log |
| Vet and compile all commands/packages | PASS | go-vet.log, go-build.log |
| Populated 0.1.0 and rc1 upgrades | PASS; preserved financial fields, revoked old sessions, replay and drift rejection | upgrade/ and upgrade-rc1/ |
| MFA browser accounting workflow | PASS; journal/approval/posting/reports, FX rounding, blocked/resolved period close, mobile | browser-tests.log, screenshots/ |
| npm audits | Zero reported vulnerabilities in both locked graphs | npm_tools_audit.log, npm_web_audit.log |
| Go vulnerability scan | Zero reachable/imported-package findings; one unused-module advisory | go_vulnerability_scan.log |
| Native PostgreSQL/container/restore gate | BLOCKED at Docker availability | native-attempt.log, native/native-release-gate.json |
| Artifact integrity, schema/pin/file validation | See artifact-validation.json | artifact-validation.json |

All ten local orchestrator steps returned zero. Native execution was attempted separately and failed immediately because Docker is unavailable. No native database lock, real login, pg_dump/restore or container build/run/scan result is claimed.

Native-only tests still requiring execution:

- `TestNativeConcurrentIdempotency`
- `TestNativeConcurrentPosting`
- `TestNativeCloseSerializesWithPosting`
- `TestNativeMFAReplaySerialization`
- `TestNativeCloseSerializesWithCreation`
- `TestNativeRuntimeIdentityBoundaries`

## Scope and limits

Go 1.27.1, Node 24.19.0, PGlite 0.5.8/socket 0.2.11, Playwright 1.63.0 and Chromium 153.0.8010.0 on Linux/amd64. PGlite executes the SQL kernel and explicit role policies but multiplexes one underlying connection with a test-role override. It does not establish native SQL concurrency or distinct database login behavior. The Go race detector only covers Go memory races.

The browser used separately installed Chromium with OS process sandboxing disabled for this workspace; web security/CSP were not disabled. The FX and close-preview screenshots were visually reviewed. Browser tooling and secret-bearing fixtures are excluded from the archive. Production browser/host isolation is not validated by this test.

Coverage is statements in internal/...; SQL and external browser execution are outside that metric. Formerly uncovered HTTP handlers now have direct test coverage: transition 81.0%, trial 100%, audit 100%, closePeriod 87.5%, logout 80.0%. No coverage percentage is a correctness certificate. The money suite includes 4,999 deterministic property cases and fuzz seeds; no extended fuzz campaign or production load test ran.

The Go advisory GO-2026-5932 concerns the unused x/crypto/openpgp package. The application does not import it; the complete scan is retained. This is not a claim that every required module is vulnerability-free.

## Upgrade and release identity

Migrations 001–005 remain byte-identical to the delivered rc1 archive. New migrations 006–007 implement review controls and MFA. Upgrade rehearsals post an exact 12345678901234567890-minor-unit journal on each supported baseline, then compare all existing journal/line fields, receipts, audit rows/heads and outbox records. Added rounding metadata defaults to false. Existing sessions are intentionally revoked. These are upgrade-continuity checks, not backup-restore evidence.

BUILD_INFO.json and SOURCE_MANIFEST.json identify this build; SHA256SUMS covers the packaged bytes. Unsigned checksums prove byte consistency, not publisher identity. No remote CI, upstream commit, signed image provenance, independent acceptance or full-product completion is invented. Historical results are isolated under baseline-v0.1.0 and baseline-rc1.

Remaining promotion gates are in PRODUCTION_READINESS.md: native and container verification, target TLS/secrets/MFA recovery, real restoration and capacity, approved FX policy, independent accounting/security acceptance and acceptance of the implemented business scope.
# Historical rc2 evidence

This report was supplied in the rc2 archive and is preserved as history. **For current rc3 results, use [RC3_RELEASE_REPORT.md](RC3_RELEASE_REPORT.md) and `test-results/rc3/`.** Historic claims below are not new execution evidence.
