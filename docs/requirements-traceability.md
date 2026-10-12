# Requirement-to-evidence traceability

The original brief is retained in `product-requirements.md`. Implementation PASS below means the named exercised scenarios passed locally. Independent review remains pending for every release-sensitive item.

| Requirement | Implementation | Test / evidence | Engineering status | Independent review |
|---|---|---|---|---|
| Balanced exact accounting | Go money objects; SQL numeric domain/validation | Money properties; financial lifecycle; JSON test events | PASS | Pending |
| Authorized company/branch/tenant | Session binding, policies, composite keys | Isolation/HTTP tests | PASS in embedded roles | Pending native/independent review |
| Independent eligible approval | Transition guard and posting recheck | Approval ceiling, segregation, revocation tests | PASS | Pending |
| Posted immutability and reversals | SQL triggers, grants, reversal constraints | Mutation denial and separately approved reversal | PASS | Pending |
| Period integrity | Guards, locks, version/receipt checks | Unfinished/other-branch close denial, preview, backdate rejection and replay; native races skipped | PARTIAL | Pending native review |
| No duplicate journal effect | Durable receipt and transactional advisory lock | Sequential replay passed; native concurrency skipped | PARTIAL | Pending native review |
| Audit/transaction atomicity | Deferred chained audit trigger + outbox | Chain validation, counts, mutation denial, failed creation | PASS in exercised scenarios | Pending |
| Safe identity lifecycle | Password recheck; encrypted TOTP, session assurance, operator recovery/audit | Reset race, legacy grant denial, disabled session, MFA vectors/replay/recovery | PASS for implemented actions | Pending target MFA/key recovery and governance |
| Hardened deployment configuration | Explicit env/origin/TLS, separate runtime roles, host-only cookie | Unit rejection/cookie tests; native real-role test skipped | PARTIAL | Pending target review |
| Safe migrations | Checksummed embedded scripts; original files unchanged | Populated upgrade, exact fingerprints, drift rejection | PASS in PGlite | Pending native rehearsal |
| Browser-backed finance workflow | React + real API and SQL kernel | Desktop/mobile journal-to-audit E2E | PASS | Pending user acceptance |
| Build and dependency integrity | Lockfiles, build/typecheck, scanners | Combined local release-check | PASS with documented unused-module advisory | Pending image/provenance review |
| Backup and recovery | Native dump/restore/reconcile script, runbook | Docker unavailable; no restore performed here | BLOCKED | Pending infrastructure evidence |
| Full subledgers/statements/localization | Domain plans only | No passing implementation evidence | NOT IMPLEMENTED | Pending scope/delivery |
| AI/mobile/offline/bank integrations | Governance and architecture only | No fake runtime, no invented tests | NOT IMPLEMENTED | Pending phased delivery |

The release report, gap analysis and readiness matrix define the promotion boundary. None of the PASS entries substitutes for external approval or acceptance of unimplemented requirements.
