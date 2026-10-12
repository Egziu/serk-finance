# Disaster recovery objectives

These are proposed design targets, not achieved SLAs. No failover, PITR or restore timing was measured in this build.

| Deployment tier | Proposed RPO | Proposed RTO | Required capability |
|---|---:|---:|---|
| Small standalone installation | 24 hours | 8 hours | Encrypted daily off-site copy; replacement host; proven restore |
| Business cloud | 5 minutes | 2 hours | Continuous WAL, managed standby, off-site recovery set |
| Enterprise cloud | 1 minute | 30 minutes | Monitored replication, tested failover/fencing, independent recovery region |

Select targets with the customer based on transaction loss tolerance, connectivity, residency, cost and staff response. A company using offline capture also needs recovery objectives for unsynchronized device queues; cloud RPO does not describe those records.

Incident sequence: declare/freeze external money release → identify consistent recovery boundary → fence the failed writer → promote/restore one authorized primary → validate schema/security/ledger/audit → reconcile external bank outcomes → replay safe inbox/outbox operations using stable keys → reopen access → review. Never run two unfenced writable primaries or automatically repeat payment release because a response was lost.

An event acknowledged to an external system but not present after recovery requires explicit reconciliation and source resubmission under the original idempotency/business-event identity. Signatures, document hashes and external statements help establish the authoritative outcome. Preserve forensic evidence before restoration where feasible.

Required playbooks: primary host loss, data corruption, credential compromise, region/account loss, ransomware/operator deletion, failed migration, object-store/key loss, stalled outbox, bank timeout, and offline-device loss. Assign incident commander, database recovery owner, security lead, finance reconciliation owner and business approver. Validate contact/escalation details in the actual organization; this repository invents no recipients or operational ownership assignments.
