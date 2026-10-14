# Validation — 0.4.0-rc1

**Decision: ready for accountant testing on Railway staging and for trial office installations on Linux. The Windows installer is built but has not yet been run on real Windows.** Production financial use is still blocked by the gates in the last section.

Evidence is in `test-results/validation-0.4.0/` (`summary.tsv`, one `.log` per step, `go-tests.jsonl`, SQL suite results and browser screenshots).

## Environment

| Component | Version |
|---|---|
| Go | 1.27.2 |
| PostgreSQL | 17.10 (native), PGlite 0.5.8 (embedded backend), bundled `@embedded-postgres` 17.10 in the office packages |
| Node.js | 22.22.0 |
| Browser | Chromium 141 (Playwright), headless |

## Results

| # | Check | Result |
|---|---|---|
| 01–04 | `go mod verify`, `gofmt`, `go vet`, `go build` | PASS |
| 05 | Fresh database: migrations 001–057 applied, then re-run (checksums verified) | PASS |
| 06 | Go suite on native PostgreSQL with `-race` | **PASS: 76/76 top-level tests, 42/42 subtests, 0 skipped.** New: assistant (acts as the user, drafts only, branch choice, stored-key protection, real-server timeout), office setup repeatability, provider/agent unit tests, backup/restore unit tests. |
| 07–08 | `tests/controls-022.mjs` on native PostgreSQL and PGlite | PASS, 28/28 on each. New: AF1–AF4 (field-named errors, mapping rules and release, module-journal source, next document number). |
| 09–10 | `tests/remediation.mjs` native and PGlite | PASS |
| 11 | Populated upgrade preservation to 057 | PASS |
| 12–13 | Evidence-gate and release-gate regressions | PASS |
| 13b | `tests/assistant-markdown.mjs` (renderer always terminates, safe output, history fits server limits) | PASS |
| 13c | `go test ./cmd/serk-server` (restore ignores archive server configuration, refuses incomplete archives, no empty database over a kept one) | PASS |
| 14–15 | TypeScript and Vite production build | PASS |
| 16–17 | `npm audit`; Go vulnerability check (OSV) | PASS, 0 findings |
| 18 | Real-browser end to end on native PostgreSQL (MFA, journal lifecycle, FX, close, mobile) | PASS |
| 19 | Browser suites against the demo launcher with a fake Claude service: `assistant-browser` 4/4, `accountant-feedback` 4/4, `demo-smoke` 6 roles, `demo-scenarios` 7/7 | PASS |
| 20 | Linux `.deb` installed, service run as `serk-finance`, `tests/office-setup.mjs` 6/6 (wizard, Ethiopian year, practice workspace with its own password, setup cannot run twice) | PASS |
| 21 | Office online backup → change → stop → restore → start: the change is gone, recovery completes, sign-in works, `pg_hba.conf` kept from the installation | PASS |

## Independent review

Nine read-only code audits covered the assistant, migrations 056–057, setup, backup, the panel and the Windows installer. Every critical and high finding was fixed with a regression test where one could be written, then re-checked by separate reviewers. Remaining low items are listed in `RELEASE_NOTES.md`.

## Not run here — still required

- **Windows runtime.** `SerkFinance-0.4.0-rc1-Setup.exe` compiles with warnings as errors and `serk-server.exe version` runs, but the bundled `postgres.exe` cannot run under Wine. Install it on a Windows 10/11 test PC: setup wizard, a second office computer, backup and restore, upgrade over itself, uninstall.
- **Real AI provider.** The assistant was tested against a scripted Claude-compatible service. Enter a real Anthropic API key (or a local Ollama server) and review answers with an accountant.
- **Container build and scan, capacity and soak tests, statutory review of tax and payroll rates, and independent sign-off**, as listed for 0.3.0.
