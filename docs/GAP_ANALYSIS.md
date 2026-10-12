# Gap analysis

| Capability | Current implementation | Status / acceptance gap |
|---|---|---|
| Manual GL journals | Exact amounts, submit/approve/post, reversals, locks, receipts, audit/outbox | PASS in local controlled scenarios; native races remain BLOCKED |
| Tenant/company/branch authorization | Scoped roles, forced financial RLS, composite foreign keys | PASS in embedded role tests; distinct login boundary NOT TESTED here |
| Authentication | Argon2id, secure cookies, CSRF, revocable sessions, source/account throttling, encrypted TOTP and replay control | PARTIAL: federation, self-service recovery, phishing-resistant factors and target identity acceptance remain |
| Administration | Operator bootstrap and audited reset/disable/enable/revoke, MFA enrollment/recovery and FX configuration | PARTIAL: privileged dual approval, membership administration and full configuration audit absent |
| Reporting | Functional-currency trial balance; exact general ledger with opening/movement/closing and source drill-down; audit listing; company-wide ledger/audit/outbox integrity | PARTIAL: complete financial statements, snapshot exports, AP/AR statements and statutory outputs absent |
| Chart / dimensions | Used-definition guards; chart cycle/group validation; explicit configuration locks | Local regression evidence available; native concurrent-write cases remain unverified |
| AP / AR / cash / banking | Domain contracts only beyond manual cash journals | NOT IMPLEMENTED |
| Tax / payroll / localization | Currency metadata and country-pack design; no active tax rules | NOT IMPLEMENTED; requires reviewed country rules |
| Procurement / inventory / assets | Domain designs | NOT IMPLEMENTED |
| Construction / projects / BOQ / IPC | Domain designs | NOT IMPLEMENTED |
| Treasury / intercompany / consolidation | Domain designs | NOT IMPLEMENTED |
| AI / OCR | Governance and integration architecture | NOT IMPLEMENTED; no AI action/claim fabricated |
| Mobile / offline sync | Design only | NOT IMPLEMENTED |
| Outbox delivery / external integrations | Atomic outbox recording | PARTIAL: dispatch, consumer deduplication, retries and dead letters absent |
| Recovery / high availability | Executable native rehearsal, runbook | BLOCKED here; production PITR/failover/restore objectives unverified |
| Deployment / supply chain | Docker targets, CI gates, release Compose, preflight | PARTIAL: image/cluster execution, scans and signed provenance unverified; reviewed action/image pins now included |
| Observability / performance | Redacted structured HTTP logs, health probes, small batch measurement | PARTIAL: production metrics, alerting, capacity and long-duration load testing absent |

Follow the attached engineering brief's phase order. Complete native foundation/kernel gates before extending into subledgers and business domains. A green local build is not acceptance of the full product specification.
