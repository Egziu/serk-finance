# Domain ownership and development contracts

These are the 36 requested logical domain boundaries. They can share a deployment and foundational schemas without sharing uncontrolled mutation authority. Commands/events below are target contracts unless the implementation status explicitly identifies working code.

| Domain | Aggregate | Current implementation |
|---|---|---|
| [Identity](docs/domains/01-identity.md) | User identity / active session | Partial: password/session runtime; MFA, devices and recovery pending. |
| [Tenancy](docs/domains/02-tenancy.md) | Tenant lifecycle | Partial: tenant provisioning, active-state enforcement. |
| [Organization](docs/domains/03-organization.md) | Organization configuration revision | Partial: operator provisioning; audited runtime administration pending. |
| [Company](docs/domains/04-company.md) | Legal company configuration | Partial: company records and scoped memberships. |
| [Branch](docs/domains/05-branch.md) | Branch configuration | Partial: provisioning, active checks and branch row policies. |
| [Accounting](docs/domains/06-accounting.md) | COA/period policy | Partial: COA, dimensions, periods, close; reopen and runtime administration pending. |
| [General Ledger](docs/domains/07-general-ledger.md) | Journal aggregate | Implemented manual-journal slice; scheduled/closing/advanced statement workflows pending. |
| [Accounts Payable](docs/domains/08-accounts-payable.md) | Approved supplier liability | Designed; no AP tables or APIs. |
| [Accounts Receivable](docs/domains/09-accounts-receivable.md) | Customer receivable | Designed; no AR tables or APIs. |
| [Cash Management](docs/domains/10-cash-management.md) | Cash ledger movement | Designed. |
| [Banking](docs/domains/11-banking.md) | Bank reconciliation session | Designed. |
| [Tax](docs/domains/12-tax.md) | Effective-dated tax calculation | Designed; Ethiopia pack disabled. |
| [Sales](docs/domains/13-sales.md) | Sales fulfilment obligation | Designed. |
| [Procurement](docs/domains/14-procurement.md) | Procurement commitment | Designed. |
| [Inventory](docs/domains/15-inventory.md) | Stock movement / costing layer | Designed. |
| [Projects](docs/domains/16-projects.md) | Project financial baseline | Designed; PROJECT dimension linkage exists only in kernel. |
| [Construction](docs/domains/17-construction.md) | Construction valuation package | Designed. |
| [BOQ](docs/domains/18-boq.md) | BOQ revision | Designed. |
| [Contracts](docs/domains/19-contracts.md) | Commercial contract revision | Designed. |
| [IPC](docs/domains/20-ipc.md) | IPC certification | Designed. |
| [Fixed Assets](docs/domains/21-fixed-assets.md) | Asset valuation book | Designed. |
| [Payroll](docs/domains/22-payroll.md) | Approved payroll run | Designed. |
| [Budgeting](docs/domains/23-budgeting.md) | Approved budget version | Designed. |
| [Treasury](docs/domains/24-treasury.md) | Treasury proposal/scenario | Designed. |
| [Consolidation](docs/domains/25-consolidation.md) | Versioned consolidation run | Designed. |
| [Intercompany](docs/domains/26-intercompany.md) | Intercompany pair | Designed. |
| [Documents](docs/domains/27-documents.md) | Document evidence version | Designed; journal reasons do not substitute for attachment storage. |
| [Workflow](docs/domains/28-workflow.md) | Approval instance | Partial: fixed journal lifecycle plus stored permission/amount rules; configurable workflow engine pending. |
| [Audit](docs/domains/29-audit.md) | Append-only event chain | Partial: atomic hash chain and immutable audit records; external sealing pending. |
| [Notifications](docs/domains/30-notifications.md) | Notification delivery | Designed; no email/SMS/push sent. |
| [AI](docs/domains/31-ai.md) | AI analysis/proposal | Designed; no model connection. |
| [Analytics](docs/domains/32-analytics.md) | Versioned analytical snapshot | Designed. |
| [Synchronization](docs/domains/33-synchronization.md) | Device operation receipt | Designed; online UI only. |
| [Integrations](docs/domains/34-integrations.md) | Business-event receipt / delivery | Partial: transactional immutable outbox records; no publishing or inbound event consumers. |
| [Reporting](docs/domains/35-reporting.md) | Authorized report snapshot | Partial: trial balance and journal/audit reads; full statements and exports pending. |
| [System Administration](docs/domains/36-system-administration.md) | Audited configuration change | Partial: operator bootstrap/migrations; runtime audited admin center pending. |
