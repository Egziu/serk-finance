# Engineering contribution policy

Keep financial invariants and tenant boundaries explicit. Every new command needs a typed request, authorization policy, source/aggregate owner, optimistic concurrency rule, idempotency semantics, atomic boundary, audited state transition, expected journal map and reconciliation check. Test a successful case and the concrete failure/race cases that could produce incorrect money or unauthorized access.

Use Go for authoritative runtime orchestration and exact value objects. Do not add business arithmetic to React, Python/OCR or integration adapters. The PostgreSQL kernel is the final posting gate; no ORM or extension receives direct financial DML privileges. Add country rules only through versioned reviewed localization contracts.

After 0.1.0 is released, do not edit applied SQL files. Append a migration, assess historical-data implications, prove migration compatibility and a restore path, and keep the previous application release compatible during rollout where required. Do not add automatic destructive down migrations.

Run `make verify`, `make web`, browser acceptance and native PostgreSQL tests for financial/schema changes. An explicitly skipped native test is an unmet gate, not success. Keep a truthful matrix of implementation versus planned features. Fix failed checks or document the exact blocking infrastructure limitation; never alter a test solely to turn a failure green.

Do not commit secrets or initialization data. Test fixtures must be synthetic. Preserve tenant scope in logs, object storage, analytics, search, jobs and AI from the first implementation of each surface. External integrations and country packs use public commands/events, not direct SQL writes. Design changes affecting posting, permissions, tax, offline reconciliation or immutable history require an ADR and financial/security review.
