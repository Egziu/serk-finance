# Review remediation — 0.2.0-rc2

The review's source defects are addressed below. The release remains a candidate for controlled acceptance testing. Native execution, infrastructure recovery, target deployment and independent acceptance are not represented as completed.

| Review item | Change | Evidence / disposition |
|---|---|---|
| 1. Global limiter exhaustion and immediate login rejection | Bounded 10,000-key LRU replaces global denial; IPv6 /64 quotas; separate login map. Two Argon2 workers retain the memory bound, with sixteen waiting requests and a two-second deadline; overload is retryable 503. | PASS: capacity/churn, quota, queue and cancellation regressions. Distributed saturation resistance still needs edge controls and load validation. |
| 2. Account-wide lockout and no success reset | Durable quota keyed by workspace/email/source; successful authentication clears only that pair. Old two-argument auth function removed. | PASS: attacker source cannot block a different source; twelve successful logins do not accumulate lockout. Same-source/NAT users still share source limits. |
| 3. Multi-line FX rounding rejection | Explicit operator-configured rounding account/cap; one labeled functional-only system line; exact source balance and per-line conversion retained. Normal approval includes the adjustment. | PASS: three-line case, missing policy, cap exceeded, exact reversal, 500 source lines plus one system line, browser display. Accounting-policy sign-off remains required. |
| 4. Close strands unfinished journals | Database rejects closure while drafts/submissions/approvals remain. Requires full-company ledger visibility. GET close-preview and browser show counts and finality warning. | PASS: draft/approved/other-branch blocks; after resolution close succeeds and replays once. Reopen is not implemented; no historical data is rewritten. Native close/create/post ordering still requires execution. |
| 5. Reversal before original date | Database creation rejects an earlier date; reversal validation also checks the original's date. | PASS: HTTP backdating rejection and exact approved reversal tests. |
| 6. Hidden startup cause | Structured safe stage/code diagnostics classify configuration, SQL authentication, schema version, privileges, network/TLS and listener failures without printing raw connection errors. | PASS: diagnostic classification and secret-redaction regression. |
| 7. Zero handler coverage | Direct Go HTTP lifecycle suite covers transition, reports, audit, close, preview and logout, including denial/validation paths. | PASS: transition 81.0%, trial 100%, audit 100%, closePeriod 87.5%, logout 80.0%; total internal statement coverage 71.6%. |
| 8. Untested database locks | Revised native post/close test for the safer close policy; added close/create and concurrent MFA replay cases. Native gate forbids any skipped test. | BLOCKED: Docker unavailable. Six native-only tests remain unexecuted here. Added tests are not proof that locks work. |
| 9. Mutable action/image references | All CI actions pinned to upstream 40-character commit IDs; Docker and database images pinned to verified manifest SHA-256 digests. Recorded sources in deploy/dependency-pins.json. | PASS: upstream resolution, manifest digest checks and offline pin gate. Container build/scan, signed provenance and remote CI still unexecuted. |
| 10. Asset directory listing | Static filesystem denies directories without an index and hidden path segments, while retaining the root page and individual assets. | PASS: root/assets/private/missing-path regression and browser asset loading. |

## Additional identity work

MFA is implemented with an established TOTP library, AES-256-GCM secrets bound to user UUIDs, transactional single-use counters and enrollment-version checks. Staging/production require MFA. Password-only sessions are denied even if restored or minted in development. The operator can enroll/recover a verified device; each change revokes sessions and creates an administrator audit event. No MFA-disable/password-only recovery bypass exists.

Local tests cover RFC vectors, encryption tampering/user binding, mandatory factors, assurance checks, replay rejection, legacy issuance denial, recovery and a real MFA browser login. Concurrent replay needs native PostgreSQL. Self-service enrollment, passkeys/OIDC, automated key rotation and application-enforced dual approval for privileged administration remain outside this release. See docs/mfa-operations.md.

## Upgrade and evidence

Migrations 001–005 are byte-identical to the delivered rc1 archive. New controls are in 006 and 007. Populated upgrade rehearsals from both 0.1.0 and rc1 preserve existing journal/line fields, receipts, audit bytes/heads and outbox records; added line metadata defaults to false, and pre-MFA sessions are deliberately revoked. Repeated migration succeeds; altered migration checksums fail. Existing closed/locked periods are not reopened by migration.

All ten local release checks passed: 78 passing test/subtest records, zero failures, six native-only skips. Full logs and historical rc1 evidence are included. See RELEASE_VALIDATION_REPORT.md and PRODUCTION_READINESS.md for exact promotion limits.

Supply-chain guidance: [GitHub immutable action pins](https://docs.github.com/en/actions/reference/security/secure-use), [Docker base-image digest pins](https://docs.docker.com/build/building/best-practices/).
