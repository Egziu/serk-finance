# Validation — 0.2.2-rc1

**Decision: release candidate.** Every check that can run without Docker Hub or target infrastructure passed on native PostgreSQL. Production financial use is still blocked until the gates in the last section are complete.

Evidence: `test-results/validation-0.2.2/`. `summary.tsv` lists each step with its exit code and duration, and every step has a `.log`. The Go events are in `go-tests.jsonl`; SQL suite results are in `*/results.json`; browser screenshots are in `browser/screenshots/`.

## Environment

| Component | Version |
|---|---|
| Go | 1.27.2 (built from the official source tag; module downloads verified against `go.sum`) |
| PostgreSQL | 17.10 server (`postgres` operator, `serk_api_login` / `serk_auth_login` runtime logins from `scripts/runtime-roles.psql`) |
| Node.js | 22.22.0; PGlite 0.5.8 for the embedded backend |
| Browser | Chromium 141 (Playwright 1.63), headless |

## Results

| # | Check | Result |
|---|---|---|
| 01 | `go mod verify` | PASS — all modules verified |
| 02 | `gofmt` clean | PASS |
| 03 | `go vet ./...` | PASS |
| 04 | `go build ./...` | PASS. **0.2.1-rc1 failed this step**: duplicate `Server.taxLiability`. |
| 05 | Fresh database: migrations 001–051 applied, then re-run | PASS — 52 files applied, then 52 checksums verified |
| 06 | Go suite on native PostgreSQL with `-race` | **PASS — 52/52 top-level tests, 42/42 subtests, 0 skipped.** Includes the 8 native concurrency tests (idempotency, posting, close-vs-post, close-vs-create, MFA counter, runtime identity, dimension change, chart write skew) that had never run before. |
| 07 | `tests/controls-022.mjs` on native PostgreSQL | PASS — 18/18 (security S1–S5, IFRS A1–A7, adjustments D1) |
| 08 | `tests/controls-022.mjs` on PGlite | PASS — 18/18 |
| 09 | `tests/remediation.mjs` on native PostgreSQL | PASS — 27/27 (module workflows, stock costing, payroll, payments, reversals) |
| 10 | `tests/remediation.mjs` on PGlite | PASS — 27/27 |
| 11 | Populated upgrade preservation (baselines 004, 005, 007, 009, 010, 036 → 051) | PASS — 6/6; financial, audit and outbox hashes preserved |
| 12 | Evidence-gate unit tests | PASS — 14/14 |
| 13 | Python release-gate regression | PASS |
| 14 | TypeScript `--noEmit` | PASS |
| 15 | Vite production bundle | PASS (main bundle 343 KB, 110 KB gzip) |
| 16 | `npm audit` (root and web) | PASS — 0 vulnerabilities after pinning `source-map-js` 1.2.2 |
| 17 | Go vulnerability check (`scripts/osv-check.py` against golang/vulndb OSV data) | PASS — 0 advisories affecting built packages on Go 1.27.2. 1.27.1 had 15 standard-library advisories. One x/crypto advisory concerns `openpgp`, which is not imported. |
| 18 | Real-browser end to end on native PostgreSQL | PASS (see below) |

The browser run covered:

- MFA login and journal draft, submit, independent approval and post.
- Trial balance and general-ledger drill-down.
- Integrity check and audit evidence drawer, with no licence watermark present.
- An administrator records a USD rate, and the journal form pre-fills it.
- FX rounding journal, blocked close, void, then period close.
- Reopen request, which the requester cannot approve.
- Year-end preview with its blockers.
- Adjustments form and VAT report.
- Mobile layouts with no horizontal overflow and no browser errors.

## Independent reviews

Two separate reviewers, who had not seen the fixes being written, demonstrated their findings with real attacks and real postings against migrations 001–048.

- **Security review:** 2 high, 4 medium and 1 low finding.
- **IFRS accounting review:** 1 critical, 3 high, 4 medium and 2 low defects, plus a prioritised list of missing capabilities.

Each confirmed defect is fixed in migrations 049–051 and has a regression case in `tests/controls-022.mjs`, with one exception: the `serk_auth` trust boundary is documented as a design limit in `docs/security.md` and `docs/ROADMAP.md`. Missing capabilities are planned in `docs/ROADMAP.md`.

## Not run here — still required

- **Container build and scan.** The image build, Trivy scan and SBOM were not run because Docker Hub is unreachable from this workspace. Refresh the `golang` base-image pin to `1.27.2-bookworm` with its digest.
- **`scripts/native-check.py`.** Docker-based; needs a Docker host.
- **Restore and capacity.** Restore/PITR rehearsal on the target host, plus capacity and soak tests at expected volumes.
- **Statutory review.** Ethiopian VAT, withholding, PAYE and pension policies need review by a qualified accountant. No statutory rates are shipped.
- **Sign-off.** Independent accountant and security acceptance of these exact bytes (`SHA256SUMS`, `BUILD_INFO.json`).
