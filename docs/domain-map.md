# Domain ownership and development contracts

These are the 36 requested logical domain boundaries. They can share a deployment and foundational schemas without sharing uncontrolled mutation authority. Commands/events below are target contracts unless the implementation status explicitly identifies working code.

| Domain | Aggregate | Current implementation |
|---|---|---|
| [Identity](domains/01-identity.md) | User identity / active session | Partial: password/session runtime; MFA, devices and recovery pending. |
| [Tenancy](domains/02-tenancy.md) | Tenant lifecycle | Partial: tenant provisioning, active-state enforcement. |
| [Organization](domains/03-organization.md) | Organization configuration revision | Partial: operator provisioning; audited runtime administration pending. |
| [Company](domains/04-company.md) | Legal company configuration | Partial: company records and scoped memberships. |
| [Branch](domains/05-branch.md) | Branch configuration | Partial: provisioning, active checks and branch row policies. |
| [Accounting](domains/06-accounting.md) | COA/period policy | Partial: COA, dimensions, periods, close; reopen and runtime administration pending. |
| [General Ledger](domains/07-general-ledger.md) | Journal aggregate | Implemented manual-journal slice; scheduled/closing/advanced statement workflows pending. |
| [Accounts Payable](domains/08-accounts-payable.md) | Approved supplier liability | Designed; no AP tables or APIs. |
| [Accounts Receivable](domains/09-accounts-receivable.md) | Customer receivable | Designed; no AR tables or APIs. |
| [Cash Management](domains/10-cash-management.md) | Cash ledger movement | Designed. |
| [Banking](domains/11-banking.md) | Bank reconciliation session | Designed. |
| [Tax](domains/12-tax.md) | Effective-dated tax calculation | Designed; Ethiopia pack disabled. |
| [Sales](domains/13-sales.md) | Sales fulfilment obligation | Designed. |
| [Procurement](domains/14-procurement.md) | Procurement commitment | Designed. |
| [Inventory](domains/15-inventory.md) | Stock movement / costing layer | Designed. |
| [Projects](domains/16-projects.md) | Project financial baseline | Designed; PROJECT dimension linkage exists only in kernel. |
| [Construction](domains/17-construction.md) | Construction valuation package | Designed. |
| [BOQ](domains/18-boq.md) | BOQ revision | Designed. |
| [Contracts](domains/19-contracts.md) | Commercial contract revision | Designed. |
| [IPC](domains/20-ipc.md) | IPC certification | Designed. |
| [Fixed Assets](domains/21-fixed-assets.md) | Asset valuation book | Designed. |
| [Payroll](domains/22-payroll.md) | Approved payroll run | Designed. |
| [Budgeting](domains/23-budgeting.md) | Approved budget version | Designed. |
| [Treasury](domains/24-treasury.md) | Treasury proposal/scenario | Designed. |
| [Consolidation](domains/25-consolidation.md) | Versioned consolidation run | Designed. |
| [Intercompany](domains/26-intercompany.md) | Intercompany pair | Designed. |
| [Documents](domains/27-documents.md) | Document evidence version | Designed; journal reasons do not substitute for attachment storage. |
| [Workflow](domains/28-workflow.md) | Approval instance | Partial: fixed journal lifecycle plus stored permission/amount rules; configurable workflow engine pending. |
| [Audit](domains/29-audit.md) | Append-only event chain | Partial: atomic hash chain and immutable audit records; external sealing pending. |
| [Notifications](domains/30-notifications.md) | Notification delivery | Designed; no email/SMS/push sent. |
| [AI](domains/31-ai.md) | AI analysis/proposal | Designed; no model connection. |
| [Analytics](domains/32-analytics.md) | Versioned analytical snapshot | Designed. |
| [Synchronization](domains/33-synchronization.md) | Device operation receipt | Designed; online UI only. |
| [Integrations](domains/34-integrations.md) | Business-event receipt / delivery | Partial: transactional immutable outbox records; no publishing or inbound event consumers. |
| [Reporting](domains/35-reporting.md) | Authorized report snapshot | Partial: trial balance and journal/audit reads; full statements and exports pending. |
| [System Administration](domains/36-system-administration.md) | Audited configuration change | Partial: operator bootstrap/migrations; runtime audited admin center pending. |
