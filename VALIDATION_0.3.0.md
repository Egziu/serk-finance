# Validation — 0.3.0-rc1

**Decision: ready for accountant testing in a staging environment.** Every check that can run without Docker Hub or target infrastructure passed on native PostgreSQL 17.10. Production financial use is still blocked until the gates in the last section are complete.

Evidence is in `test-results/validation-0.3.0/`:

- `summary.tsv` lists each step with its exit code and duration, and every step has a `.log`.
- Go events are in `go-tests.jsonl`.
- SQL suite results are in `*/results.json`.
- Browser screenshots are in `browser/` and in the demo steps.

## Environment

| Component | Version |
|---|---|
| Go | 1.27.2 |
| PostgreSQL | 17.10 server, with runtime logins `serk_api_login` and `serk_auth_login`. SQL suites were also rerun on 16.x. |
| Node.js | 22.22.0, with PGlite 0.5.8 as the embedded backend |
| Browser | Chromium 141 (Playwright), headless |

## Results

| # | Check | Result |
|---|---|---|
| 01–04 | `go mod verify`, `gofmt`, `go vet`, `go build` | PASS |
| 05 | Fresh database: migrations 001–055 applied, then re-run | PASS. The second run verifies every checksum. |
| 06 | Go suite on native PostgreSQL with `-race` | **PASS: 54/54 top-level tests and 42/42 subtests, 0 skipped.** New: `TestProfilePasswordChange` and the Ethiopian period tests. |
| 07 | `tests/controls-022.mjs` on native PostgreSQL | PASS, 24/24. New cases: F1 module switches and E1 Ethiopian fiscal year. |
| 08 | `tests/controls-022.mjs` on PGlite | PASS, 24/24 |
| 09–10 | `tests/remediation.mjs` on native PostgreSQL and on PGlite | PASS, 27/27 on each |
| 11 | Populated upgrade preservation (baselines 004, 005, 007, 009, 010 and 036, each upgraded to 055) | PASS. Financial, audit and outbox hashes are preserved. |
| 12–13 | Evidence-gate and release-gate regressions | PASS |
| 14–15 | TypeScript and Vite production bundle | PASS. Main bundle 349 KB (112 KB gzip). |
| 16 | `npm audit` (root and web) | PASS, 0 vulnerabilities |
| 17 | Go vulnerability check (OSV, golang/vulndb) | PASS, 0 advisories affecting built packages |
| 18 | Real-browser end to end on native PostgreSQL (MFA login, journal lifecycle, FX, close, reopen, year-end preview, adjustments, VAT report, mobile) | PASS |
| 19 | `tests/demo-scenarios.mjs` against the `cmd/platform` launcher with the Ethiopian demo | PASS, 7/7. Covers: journal maker-checker; invoice with 15% VAT; VAT report; VAT settlement; payroll (gross 15,000 → PAYE 3,200, pension 1,050, net 10,750); auditor read-only; balanced statements and integrity. |
| 20 | `tests/demo-smoke.mjs` (browser) | PASS. Navigation matches permissions for 6 roles. The Administrator switches Payroll off, the page disappears, and switching it back on restores it. |
| 21 | Password change in the browser | PASS. The form refuses a mismatched confirmation. Changing the password signs the user out, and the user signs in with the new password. |

A clean copy of `web/` was built exactly as the Dockerfile `web` stage does (`npm ci --ignore-scripts`, then `npm run build`). It passed.

## Not run here — still required

- **Container build and scan.** The Docker image build, Trivy scan and SBOM were not run, because Docker Hub is unreachable from this workspace. The first Railway build is the first real image build. Refresh the `golang` base-image pin to `1.27.2-bookworm` with its digest.
- **Restore and capacity.** Restore/PITR rehearsal on the target host, plus capacity and soak tests at expected volumes.
- **Statutory review.** The demo's VAT 15%, PAYE bands and 7% / 11% pension are samples. A qualified Ethiopian accountant must confirm the rates, the taxable base, the pension ceiling and rounding.
- **Sign-off.** Independent accountant and security acceptance of these exact bytes.
