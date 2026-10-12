# 0.2.1-rc1 — financial controls repair

The supplied package permitted mutable posted SYSTEM lines and direct module posting without the kernel's approval/validation sequence. This candidate restores those boundaries and replaces the unsafe HTTP posting shortcuts with controlled database commands.

The new registry holds document identity, branch/date, normalized exact amounts, payroll/stock snapshots, journal/payment/reversal links, version, and actor evidence. The preparer and approver remain different identities. Source transactions and their journal/outbox/audit effects commit together. Cash accounts and financial mappings are explicit; an existing document retains its original settlement control account when mappings change.

The release adds forward migrations for financial immutability, final audit snapshot checks, master/company/branch permissions, statement classification, controlled module workflows, verified MFA changes, policy versions, reversals, dashboard reporting, control accounts, and document visibility. A preparation migration fixes populated execution of the unchanged legacy 033 migration without granting ordinary runtime connections operator privileges.

The frontend now provides draft/submission/approval, exact amounts, document preview, account mappings, approved payroll policy selection, dated payruns, stock openings, payment review, and reversal review. Heavy pages/grids load on demand. Current validation and remaining acceptance gates are in `REPAIR_VALIDATION.md`.

API changes: monetary values and decimal rates are strings. Financial commands require `Idempotency-Key`, `X-Company-ID`, CSRF for unsafe methods, `expected_version` for transitions, and an audit reason. Payroll creation requires branch, period/frequency, accounting date, payrun number, and approved policy. Updated operations are described in `docs/openapi.json`.

Development leftovers, environment files, local credentials, repository history, dependency folders, debug patch scripts, database dumps, and stale execution evidence are excluded from the release ZIP. Install dependencies using the lockfiles. The frontend bundle and fresh checksums are included.

No production approval, native test result, recovery proof, vulnerability scan, statutory policy validation, or zero-defect guarantee is implied by this candidate.
