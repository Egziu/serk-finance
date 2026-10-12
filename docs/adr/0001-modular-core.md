# ADR 0001 — Modular core with a database-enforced posting boundary

Status: accepted for the initial implementation.

The product must own financial truth while accepting events from multiple operational products. Premature distribution would turn invoice/tax/subledger/GL atomicity into a cross-service coordination problem before the business contracts are stable.

Use a modular Go core, PostgreSQL ACID transactions, private domain mutation ports and immutable audit/outbox events. Keep authoritative monetary intent/value objects in Go and enforce final state transitions/invariants in restricted PostgreSQL functions/triggers. Runtime financial identities receive no direct financial DML. Python/OCR/AI are consumers/proposers, not alternative ledgers.

Consequences: a strong, testable accounting boundary; SQL migrations are financial code and require review; database-specific implementation is intentional; all replicas share the same authoritative schema. Extract independent workers/read models first. Future extraction of transactional domains requires an explicit replacement consistency design and migration plan.
