> **Historical record for 0.2.1-rc1.** Superseded by `VALIDATION_0.2.2.md`; the native gates listed below as not run have since been run for 0.2.2-rc1.

# Repair validation — 0.2.1-rc1

**Decision: release candidate; production financial use remains blocked pending native/infrastructure and independent acceptance.**

| Independently executed check | Result |
|---|---|
| Current-schema sequential SQL regressions | 27 PASS, 0 FAIL |
| Populated SQL upgrades from six baseline positions (004, 005, 007, 009, 010, 036) | 6 PASS; existing financial/audit/outbox hashes preserved |
| Original database controls against migrations 001–010 | 18 PASS; historical scope, not full-schema certification |
| JavaScript evidence-gate unit tests | 14 PASS |
| Python release-gate regression | 1 test PASS, six scenarios |
| TypeScript no-emit check | PASS |
| Vite production bundle | PASS |
| Configured immutable dependency/image/action pins | PASS; no image build or scan implied |
| Original migrations 001–036 | Byte-identical to upload |
| Private local setup and generated 32-byte MFA key | PASS |

The full suite applies 48 numbered SQL files, including the operator preparation file before legacy 033. All current application data in these tests is synthetic. Actual results are included under `test-results/repair/`.

The regressions cover self-approval, immutable financial writes, unauthorized salary/document reads, cross-company references, exact large money and half-minor tax rounding, weighted stock costs/reservations, source posting, approved stock openings, payroll policy approval/gross-to-net calculations/payslips, duplicate periods, idempotency, payment/reversal retries and refunds, settlement after account-mapping changes, statement reconciliation, exclusion of submitted drafts from dashboards, posted audit snapshots, balanced fault detection, MFA privileges/session revocation, mandatory-factor protection, and closed periods.

Go compilation/full Go tests, native PostgreSQL concurrency/role tests, real HTTP/browser acceptance, container execution/scans, online dependency vulnerability scans, target restore/PITR, and capacity tests were **not** completed. Go, PostgreSQL, Docker, govulncheck, Trivy, and a local browser engine were unavailable. No successful native or production result is inferred from these SQL/frontend checks.

The frontend is split into on-demand pages. The main bundle is roughly 344 KB before gzip; the deferred grid bundle is about 788 KB. Vite still reports a size warning for that deferred grid. This is not a measured mobile/browser performance result.

Run `python3 scripts/release-check.py` and the native acceptance/recovery checks on a suitable host, then obtain accountant/security acceptance for the exact release bytes. Preserve existing encryption keys and reconcile legacy data before upgrade. No statutory payroll/tax rates are assumed by the product; test fixture percentages are explicitly synthetic.
