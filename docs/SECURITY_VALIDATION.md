# Security validation — historical rc2 baseline

For current rc3 changes, executed evidence and remaining security gates, see [RC3_RELEASE_REPORT.md](RC3_RELEASE_REPORT.md). The baseline results below are retained for traceability; their original logs are under `test-results/historical-rc2/`.

Scope: 0.2.0-rc2 manual-journal foundation, local controlled tests. Overall production-security acceptance is **PARTIAL**, not certified.

| Control / attack | Evidence | Result |
|---|---|---|
| Cross-company, cross-tenant and branch reads | `TestIsolationAndHTTP` | PASS with explicit restricted roles in PGlite |
| Reader attempting a financial write | HTTP authorization cases | PASS: denied |
| Direct runtime mutation of posted lines; API role minting sessions | Financial lifecycle and isolation tests | PASS: denied |
| Posted journal deletion and audit mutation | Database guard tests | PASS: denied by active triggers |
| CSRF/origin forgery, UUID injection, malformed/duplicate JSON, body/nesting bounds | HTTP and decoder tests | PASS |
| Insecure/mistyped deployment config and test-role override in secure environments | Config/database tests | PASS for tested rejection paths |
| Forged forwarded IP and unrestricted proxy trust | `TestForwardedAddressTrustBoundary` | PASS |
| Old password racing a reset into new session issuance | `TestPasswordResetAndOperatorAudit` | PASS: denied after reset |
| Disabled account's existing session | Same test | PASS: unauthorized |
| Authentication-role legacy session minting | Same test | PASS: old grant revoked |
| Source/account login quota and reset; capacity exhaustion; IPv6 churn | Persistent throttle, source isolation and limiter tests | PASS |
| Queued login burst and cancellation | TestLoginBurstsQueueAndCancel | PASS |
| MFA vectors, encryption, assurance, replay and recovery | internal/mfa tests, TestMFAEnforcementReplayAndRecovery, browser MFA flow | PASS locally; concurrent counter proof needs native PostgreSQL |
| Static asset enumeration and startup diagnostics | review_test.go | PASS |
| Secure cookie identity and attributes | `TestProductionCookieBoundary` | PASS |
| Separate native logins, dangerous inherited roles and schema/database privilege checks | `TestNativeRuntimeIdentityBoundaries` | BLOCKED / skipped here |
| Distributed traffic, DAST, independent penetration test, target MFA/key recovery | No executed target evidence | NOT TESTED |

The fresh npm audits reported zero vulnerabilities in both locked dependency graphs. The Go symbol/import scan found zero reachable or imported-package vulnerabilities. It reported one required-module advisory, GO-2026-5932, in the unused `golang.org/x/crypto/openpgp` package; this application uses Argon2id and does not import OpenPGP. See the complete current `test-results/go_vulnerability_scan.log`, rather than interpreting the result as every dependency being vulnerability-free. Advisory: [Go vulnerability database](https://pkg.go.dev/vuln/GO-2026-5932).

The browser test uses Chromium 153.0.8010.0 from the separately installed `@sparticuz/chromium@153.0.0` tooling package, with OS sandboxing disabled for this constrained test workspace. Web security/CSP were not disabled. This establishes the exercised UI workflow; it does not validate browser process isolation or a public deployment. The alternate browser package is not a production application dependency or included in the release archive.

The database superuser and deployment operator remain trusted. They can modify ownership, permissions or disable triggers. Native provisioning/restore verification, external privileged-access audit, target MFA/key recovery and independent acceptance remain production gates.
