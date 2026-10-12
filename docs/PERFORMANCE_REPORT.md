# Performance evidence

Observed local measurement:

`release_controls_test.go:154: 50 sequential two-line journal creates: 1.800938641s (includes DB validation, audit and outbox; this is not an enterprise load benchmark)`

Backend: PGlite 0.5.8/socket 0.2.11; Go 1.27.1, Node 24.19.0, Linux/amd64. Fifty sequential two-line journal creates include validation, receipts, numbering, audit and outbox commit after fixture setup. This is not end-to-end posting/approval latency, a capacity target or an SLA.

No native concurrent load, p95/p99 measurements, long-duration saturation, failover or production-scale dataset was exercised. Two Argon2 workers and a sixteen-request/two-second queue bound authentication resources; unit tests cover burst/cancellation behavior, not distributed overload resistance. Native period/account locks and per-company numbering/audit serialization require profiling before scale claims.

Evidence: test-results/go-tests.jsonl, TestJournalBatchLatencyEvidence. Native concurrency execution remains blocked.
