# AI CFO and intelligence governance — target design

No AI model is connected to this release. There are no AI financial-write endpoints. The design treats AI as an evidence-bound assistant with lower authority than financial command services.

## Authorization and semantic layer

Every AI query starts from a server-resolved actor, tenant, company, permitted branches/projects, purpose and as-of date. Retrieval, joins, summaries, caches and embeddings enforce this scope before data reaches a model. An LLM-provided SQL WHERE clause is not authorization. Use typed, allowlisted query tools over a semantic model of accounts, customers, suppliers, projects, invoices, payments, budgets, taxes, contracts, assets and employees. Payroll and bank data require additional purpose-specific entitlements.

Responses cite exact internal record IDs, versions, reporting dates and authorized drill-through links. An explanation of falling project profit must show the budget/revenue baseline, actual costs, remaining commitments, forecast-to-complete method and main drivers. A statement that lacks adequate evidence should identify the missing inputs rather than invent a cause.

## Capability boundary

Allowed: classify, summarize, flag, compare, explain, forecast and prepare a proposed transaction. Disallowed: direct ledger writes, changing posted data, deleting financial history, changing effective tax rules, closing/reopening periods, granting permissions, approving itself, or releasing money. A proposal crosses into the normal authenticated command workflow with version, idempotency, budget, tax and independent approval checks. Model output is untrusted input.

## OCR and prompt injection

Treat supplier invoices, emails and uploaded documents as data, never instructions to the AI agent. OCR extraction returns field values, page/coordinate evidence and confidence. Validate TIN, invoice identity, quantities, totals, tax rule selection and PO/GRN match. Duplicate checks and a human approval precede posting. Vendor text such as "ignore approval" cannot modify tools or instructions. Record original content hash, extraction model/version, reviewed corrections and final source linkage.

## Forecasting and anomaly alerts

Forecasts identify horizon, training cutoff, input source sequences, collection/payment assumptions, model revision, forecast range and calibrated uncertainty. Distinguish scenario ranges from statistically calibrated confidence intervals. Backtest against time-held-out data; avoid leakage from later payments or project revisions. Show actual outcomes and drift over time.

Alerts include severity, what occurred, why it is unusual, compared cohort/baseline, supporting records, uncertainty and recommended review. Rules cover duplicate bills/payments, supplier changes, split purchases, backdating, abnormal price/discount/refund patterns, cash behaviour and payroll indicators. An alert does not establish fraud. Track reviewer disposition, false positives, and appeal/correction history.

## Release evidence

Before deployment: cross-tenant and branch retrieval tests; adversarial document injection; tool permission tests; arithmetic/source reconciliation; denied critical actions; citation fidelity; stale-report disclosure; absent-data handling; PII minimization; model retention contracts; signed tool/audit records; and evaluation suites for every proposed capability. Financial correctness comes from deterministic query/calculation services, not text generation.
