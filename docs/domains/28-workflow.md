# 28. Workflow

**Status:** Partial: fixed journal lifecycle plus stored permission/amount rules; configurable workflow engine pending.

| Contract | Definition |
|---|---|
| Entities | WorkflowDefinitionVersion, ApprovalInstance, Decision |
| Aggregate boundary | Approval instance |
| Commands | SubmitApproval, RecordDecision, Escalate, InvalidateApproval |
| Queries | ApprovalInbox, PolicyExplanation |
| Target domain events | ApprovalGranted, ApprovalInvalidated |
| Permissions | workflow.configure / workflow.approve |

**Value objects and validators.** Use scoped TenantID/CompanyID, immutable UUIDs, expected aggregate versions, typed reference IDs, and effective/as-of dates. Where monetary values occur, use exact Money/Rate and explicit original/functional currencies. Validate aggregate references in the same company and reject missing or ambiguous policy/source revisions.

**Repository and services.** A private Workflow repository loads and commits the named aggregate; its application service validates the command, invokes explicit cross-domain ports, and commits its state, audit evidence, event/outbox and idempotency receipt atomically where required. Queries respect current actor scope. No other context or extension writes this repository's tables directly. This contract does not create an unimplemented repository class.

**Policies and invariant.** Rules and thresholds are versioned; distinct-person and current scope enforced at execution.

**Acceptance gate.** Exercise each permitted state transition, forbidden role/company/branch combination, repeated command, stale version, rollback and concurrent conflict. For monetary events, prove source document → expected journal → appropriate control-account reconciliation. Preserve immutable source versions and record the permission/policy decision. Detailed lifecycle/control designs are in the accounting, security, tax, construction, offline and AI architecture documents.
