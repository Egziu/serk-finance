# Financial validation — historical rc2 baseline

For current rc3 changes, executed evidence and remaining financial gates, see [RC3_RELEASE_REPORT.md](RC3_RELEASE_REPORT.md). The baseline results below are retained for traceability; their original logs are under `test-results/historical-rc2/`.

Local controlled results apply to manual journals only. They do not validate absent AP/AR, tax, inventory, payroll, bank or consolidation modules.

| Requirement | Implementation and test | Result |
|---|---|---|
| Exact money and balance | Integer strings, numeric domain, Go big-number values; 4,999 deterministic property cases and money/fuzz seeds | PASS |
| Independent approval and ceiling | Database transition guard and current approval recheck | PASS |
| Approval revoked before posting | `TestApprovalRevocationPreventsPosting` | PASS: no posted effect |
| Safe close and date controls | HTTP/SQL preview, unfinished/other-branch guards, resolved close, backdated reversal denial | PASS |
| Race with period close / duplicate posting / idempotency | Four native financial concurrency tests | BLOCKED / skipped here |
| FX snapshot and rounding | Explicit bounded system line, missing/excess policy denial, exact reversal and 500-source-line boundary | PASS for supplied scenarios |
| Posted immutability | SQL privileges plus active triggers | PASS |
| Controlled correction | Separately approved linked reversal; trial-balance net returns to zero | PASS |
| Duplicate create and close requests | Durable user/company-scoped receipts, payload hashes, atomic commit | PASS |
| Audit/outbox atomicity | Chained events, sequence/head, outbox counts and mutation denial | PASS |
| Configuration cannot reinterpret used denominations/fiscal years | Definition guards | PASS for tested updates |
| Upgrade preserves accounting evidence | Populated 0.1.0 and rc1 → rc2 rehearsals with posted amount `12345678901234567890` minor units; exact preserved-field hashes for six financial/audit tables | PASS in PGlite |
| User-facing journal/report cycle | Real browser, separate preparer/approver, synthetic ETB 250,000 capital journal | PASS |
| Full statements and statutory accounting | Not implemented/reviewed | NOT IMPLEMENTED |

The trial-balance screen shows debit/credit activity and net debit balances in functional currency. It is not a complete financial-statement package. Rounding requires an operator-configured account/cap and creates one labeled functional-only line under normal independent approval; originals and reversals remain exact. Missing/excess policy fails. See docs/fx-rounding-policy.md. Account/currency localization, effective-date policies, complete statement mappings and country-specific rules still require implementation/qualified accounting acceptance.

An in-use fiscal/currency definition must be changed by a reviewed migration strategy, not by rewriting its meaning in place. Definition locks in migration 005 need native concurrency evidence in the target database engine before production approval.
