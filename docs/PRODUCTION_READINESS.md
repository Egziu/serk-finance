# Production readiness — BLOCKED

**0.2.0-rc4 is an accounting-integrity/reporting candidate for controlled acceptance testing. It is not approved for live financial use or as the complete global SERK Finance product.**

Current rc4 evidence (see `RC4_RELEASE_REPORT.md`): the full native profile ran for the first time on native PostgreSQL 17.10 (one minor release below the pinned 17.11 image) with distinct unprivileged OS and database identities: 89 passes, 0 failures, 0 skips, all 8 native-only tests PASS, native browser PASS. That run first exposed a native-only defect (a 500-line journal exceeded the 10 s statement timeout because row-level security re-evaluated session context per row), fixed by migration 010. Local embedded evidence: 81 Go passes, 18 database scenarios, four populated upgrade paths including rc3→rc4 (20/20 repeated), browser acceptance. A native physical-backup + WAL point-in-time recovery rehearsal passed 11/11 checks. The following gates are still required:

| Gate | Status | Closure evidence |
|---|---|---|
| Local implementation/build/financial controls | PASS | Current release-check, JSON test events and upgrade/browser evidence |
| Native PostgreSQL races and distinct runtime identities | PASS (local native binaries, PG 17.10) | `native-local-check.py --browser`: 8/8 native cases, 0 skips; repeat on the pinned 17.11 image via the Docker route |
| Docker image execution and vulnerability scan | NOT TESTED | CI image build, smoke test, scan and immutable digest |
| Target TLS, network, secret management and monitored deployment | NOT TESTED | Staging deployment record and operator checks |
| Real backup restoration and production recovery objectives | PARTIAL | Native physical backup + WAL PITR rehearsal PASS (11/11). Still required: logical `pg_dump`/`pg_restore` rehearsal, standby failover, and a target-environment drill with RPO/RTO measured at production data volume |
| MFA and account/privilege lifecycle | LOCAL MFA PASS; target governance PARTIAL | Enroll target users, validate key/device recovery and privileged-change controls; independent security acceptance |
| Independent financial and security acceptance | PENDING | Review the new remediation matrix, code, evidence and approved FX/MFA policies; record sign-off |
| Complete product scope / localization / statements | NOT IMPLEMENTED | AP/AR, banking, statutory/localized outputs, accepted business scope and golden subledger scenarios |
| Production-scale capacity and reliability | NOT TESTED | Representative native load, outage and recovery results |

Release approval must identify the exact source manifest, image digests, schema version, environment, test evidence, reviewer and intended product scope. Egziu/product ownership can accept scope; accounting and security reviewers must validate their respective controls. This automated engineering work does not impersonate those approvals.

To continue on an appropriate host: run the included release/native checks, deploy staging using `DEPLOYMENT.md`, and close the gates above. Do not label unimplemented AI, payment, tax, offline or business-domain designs as available features.
