# Construction and project financial control — target design

Projects, contracts, WBS, BOQ, cost codes, measurement/certification and operational site facts are distinct aggregates. Finance owns their financial consequences. Construction Cloud may own site execution and measurement evidence; Finance must not create a second conflicting operational schedule.

## Hierarchy and revision control

Project → Contract → WBS node → BOQ revision/item → cost code → activity → source transaction. Cost categories include material, labour, equipment, subcontract, direct/indirect overhead. Approved contract/BOQ versions are immutable. A variation creates linked revenue, budget and BOQ revisions with explicit approval; forecasts may include separately identified unapproved scenarios but cannot relabel them as contracted revenue.

BOQ quantities and rates use exact decimal quantities, explicit units and unit-conversion versions. The stored extension is derived from quantity × rate with documented rounding. Component breakdowns must reconcile to item rate/amount, and taxes must identify inclusive/exclusive treatment. Import is staging → mapping → validation → preview → approval → version creation; errors never partially alter the live BOQ.

## Cost equations and double-counting controls

| Measure | Definition |
|---|---|
| Revised budget | Original approved budget + approved budget variations |
| Spend variance | Revised budget − actual cost |
| Open commitment | Approved commitment − recognised consumption − approved cancellation |
| Available after commitments | Revised budget − actual cost − open commitments |
| EAC | Actual cost + remaining forecast (ETC) |
| Forecast project profit | Approved forecast contract revenue − EAC |
| VAC | Budget at completion − EAC |

ETC must explicitly include or exclude open commitments. When it includes them, do not add them again to EAC. Purchase invoices/receipts consume commitment quantities/values through allocations; replay cannot consume twice. Returns, cancellations and variations adjust commitment history through events. Distinguish incurred cost, inventory still on hand, capital work in progress and paid cash.

## IPC aggregate

An IPC version records contract/BOQ revision, measurement period, cumulative gross valuation, prior certified valuation, current certified work, retention, advance recovery, tax components, other deductions, current net receivable, engineer/certifier approvals, source documents and payment allocations.

Current work equals cumulative certified work less previously certified work. Do not subtract prior certification again when starting from a current-period work figure. Retention and advance recovery are separate balance movements. Net collectible is current work plus applicable tax, less retention, advance recovery, withholding and other authorized deductions according to the approved contract/tax policy. Revenue recognition is a distinct accounting judgement; certification and payment alone do not automatically define it.

Retention uses its own receivable/release schedule, including partial releases and conditions. Customer advances remain separately tracked liabilities until the approved recognition/recovery event. A certificate correction creates a new version and correcting financial events; no overwrite of an approved certificate or journal.

## Earned value

PV, EV and AC share the same reporting date, scope baseline and monetary unit. CPI=EV/AC and SPI=EV/PV only when the denominators are positive; otherwise return an explained unavailable result. EAC methods must identify whether they use remaining estimate, CPI, or CPI×SPI assumptions. Engineering percent-complete evidence and baseline version must be visible. A cash shortfall must not be confused with negative project margin.

## Acceptance

Approved BOQ → controlled budget → PO commitment → receipt/stock → allocation to project cost → AP invoice → IPC/retention/advance/tax → AR → payment → project P&L and cash flow must reconcile to GL. Include partial receipts/invoices, changes in unit measure, split project allocations, returns, subcontractor certificates, retention release, disputed claims, cancellations and offline replay. None of these construction workflows is implemented in version 0.1.0.
