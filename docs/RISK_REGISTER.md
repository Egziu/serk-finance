# Risk register

| ID | Risk | Priority | Current disposition | Required next evidence / owner |
|---|---|---|---|---|
| R1 | Native concurrency/login behavior unverified | Release blocker | Six native-only tests skip in the embedded run | Run native CI, review locks and credentials — Infrastructure/QA |
| R2 | MFA operational recovery and incomplete privileged governance | Release blocker | Encrypted TOTP, session assurance, recovery and replay controls pass locally; native replay and target enrollment unverified | Validate target enrollment/key recovery and privileged lifecycle controls — Security |
| R3 | Product lacks operational subledgers and complete statements | Release blocker for full product | Explicitly disabled/not exposed | Implement and reconcile accepted scope — Backend/Business Domains |
| R4 | Restore/failover/PITR unverified in target infrastructure | Release blocker | Native rehearsal script and runbook delivered | Successful native and target recovery drills, measured RPO/RTO — Infrastructure |
| R5 | Container build/scan and supply-chain provenance unverified here | Release blocker | Verified immutable action/base-image pins and CI gates supplied | Scanned application digest, SBOM, signed provenance — Infrastructure/Security |
| R6 | Independent security/accounting acceptance outstanding | Release blocker | User-supplied review remediated; no approval signature | Independent review and acceptance signatures — Product/Finance/Security |
| R7 | Upgrade compatibility with old login binary | High | Revoked old function; maintenance upgrade documented | Rehearse coordinated migration/application cutover and forward recovery — Backend |
| R8 | Enterprise data volume and lock contention | High | Only a small sequential embedded workload measured | Native load profile and latency percentiles at accepted volumes — QA |
| R9 | Privileged direct database changes can bypass application controls | High | Operator workflow records supported actions | Restricted privileged access and external immutable logs — Security |
| R10 | Proxy trust and shared address limits configured incorrectly | Medium | Defaults ignore forwarded addresses; broad trust rejected | Validate ingress overwrite and exact trusted address in target — Infrastructure |
| R11 | Authentication-window/session table growth | Medium | Bounded age cleanup for login windows; session retention/monitoring still operational | Scheduled retention job and capacity alerts — Infrastructure |
| R12 | Outbox records have no delivery worker | Medium for current isolated scope | No external delivery claimed | Implement delivery lifecycle before enabling integrations — Backend |

No production risk exception or approval has been granted by these documents. Named engineering roles in the supplied brief may be used to assign the reviews; no notifications were sent.
