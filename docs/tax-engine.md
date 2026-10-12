# Universal tax engine and Ethiopia localization

Status: architecture contract only. `localization/et/manifest.json` is disabled and contains no production rates. The current kernel supports ETB as a currency; this does not establish Ethiopian statutory compliance.

## Separation

The universal kernel accepts evaluated monetary consequences, versioned rule references and source evidence. Country packs own jurisdiction, taxable-event definition, place/time of supply, invoice rules, effective dates, exemptions, reporting mappings, payroll schedules and calendar/language adapters. Other countries install independent packs without branching journal logic on country codes.

## Rule aggregate

Model TaxRuleVersion with immutable ID, jurisdiction, tax_type, tax_code, transaction_class, effective_from, effective_until (exclusive), taxable_base_definition, calculation_method, ordered rate/bands, threshold/cap rules, exemptions, compounding_order, rounding_policy, reporting_code, source_document, source_hash, legal_effective_date, publication_date, reviewed_by, approved_by and approval_state.

Reject overlapping active versions for the same rule-selection dimensions. New regulations create a new version; never update historical calculations in place. A posted TaxCalculation stores transaction facts, rule versions, base components, adjustments, exact amounts, rounding results, exchange-rate evidence, and calculation explanation. Credit notes/reversals refer to the original treatment, subject to an explicit legal adjustment policy.

## Evaluation and posting

Evaluate a typed expression tree or a constrained policy format, not arbitrary Python/JavaScript/SQL supplied by administrators. No unrestricted `eval`. Use exact decimal/rational arithmetic with jurisdiction-specified rounding, base/total reconciliation and golden cases.

Invoice command → select effective rule → calculate components → show explanation → approve → atomically record source + tax subledger + AR/AP + journal + audit/outbox. A missing or ambiguous rule prevents posting; it never defaults to zero tax. Exempt and zero-rated transactions remain distinct treatments even when both calculate zero.

Withholding generally needs a separate recoverable/payable balance and evidence lifecycle rather than being treated as a discount. Whether it applies, when it is recognized, and its base must come from the approved country rule. IPC retention, advance recovery and payroll benefit treatment must invoke this engine rather than embedding rates in construction/payroll code.

## Ethiopian pack acceptance

Collect authoritative VAT, withholding, payroll, pension, invoice, e-invoicing and reporting sources and any amendments/directives relevant at launch. Have a qualified local reviewer and a different approver approve an effective-dated configuration with statutory examples and a versioned evidence archive. Verify legal obligations for each entity/registration profile and reporting period; do not infer that one nationally published rate covers every supply or taxpayer.

The official Ministry of Finance resource portal and Ministry of Justice law portal are starting points for authoritative material, not evidence that this release has been certified: [Ministry of Finance](https://www.mofed.gov.et/), [Ministry of Justice](https://justice.gov.et/).

Store dates internally in Gregorian ISO form plus original input calendar/context. Ethiopian calendar entry/display requires independently tested conversion and leap-year edge cases. English, Amharic and Tigrinya strings require professional linguistic review; the present UI is English only. TIN format/verification, VAT registration evidence, tax invoice numbering/layout and banking formats must be country-pack validations.

Future packs: Kenya, Rwanda, Uganda, Tanzania, Djibouti and Somalia use the same interfaces with their own rule/evidence/version lifecycles. No rates are copied between jurisdictions.
