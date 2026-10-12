# 24. Treasury

**Status:** Designed.

| Contract | Definition |
|---|---|
| Entities | CashForecast, DebtSchedule, PaymentProposal, FXExposure |
| Aggregate boundary | Treasury proposal/scenario |
| Commands | SchedulePayment, ApproveFunding, ReviseForecast |
| Queries | 7/30/60/90DayLiquidity, DebtExposure |
| Target domain events | PaymentProposed, FundingApproved |
| Permissions | treasury.plan / treasury.approve / payment.release separately |

**Value objects and validators.** Use scoped TenantID/CompanyID, immutable UUIDs, expected aggregate versions, typed reference IDs, and effective/as-of dates. Where monetary values occur, use exact Money/Rate and explicit original/functional currencies. Validate aggregate references in the same company and reject missing or ambiguous policy/source revisions.

**Repository and services.** A private Treasury repository loads and commits the named aggregate; its application service validates the command, invokes explicit cross-domain ports, and commits its state, audit evidence, event/outbox and idempotency receipt atomically where required. Queries respect current actor scope. No other context or extension writes this repository's tables directly. This contract does not create an unimplemented repository class.

**Policies and invariant.** A forecast is not spendable cash; distinguish approvals from external release and uncertain bank outcomes.

**Acceptance gate.** Exercise each permitted state transition, forbidden role/company/branch combination, repeated command, stale version, rollback and concurrent conflict. For monetary events, prove source document → expected journal → appropriate control-account reconciliation. Preserve immutable source versions and record the permission/policy decision. Detailed lifecycle/control designs are in the accounting, security, tax, construction, offline and AI architecture documents.
