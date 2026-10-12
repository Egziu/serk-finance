# Functional-currency rounding policy

Source journal amounts must balance exactly in original currency. Each source line is converted using the journal's immutable rate, currency minor-unit definitions, and nearest-unit/half-away-from-zero rounding. Source values and converted values are never silently redistributed.

If converted totals differ, the company must have an explicitly configured FX rounding account. The engine appends exactly one visible, system-created line with zero original-currency amounts and the exact functional-currency difference. The account must be an active, postable, non-control leaf account of type `OTHER_EXPENSE` or `OTHER_INCOME`. All ordinary account controls are rechecked before posting. The complete journal, including the rounding line, goes through normal submission, independent approval and posting. Approval ceilings use the resulting total functional debits.

The allowed difference is the lesser of the configured cap and `floor(source_line_count / 2)` functional minor units. The configured cap is an integer from 1 to 250. This is a bounded engineering policy, not an assertion of statutory or accounting-policy acceptance. Finance must approve the account classification, cap, reporting treatment and use cases before production use.

A journal accepts 2–500 source lines; a generated rounding line may make the response contain 501 lines. A caller cannot supply `is_rounding` or functional amounts. A missing account or excess difference fails the entire command and records no partial journal/receipt. Original-currency imbalance always fails. Journals whose total rounds to zero still fail the positive-functional-total rule.

Example at USD→ETB rate 0.5 with equal minor-unit scales: source debits 1 + 1 and credit 2 become functional debits 1 + 1 and credit 1. One functional credit of 1 is added to the configured rounding account; original amounts remain 1 + 1 = 2. The browser shows both currencies and labels the generated line.

Reversals swap every stored original/functional value and preserve the rounding flag, account and dimensions. They do not use a new rate, new rounding account or current cap to reinterpret history. Their date cannot precede the original journal's accounting date.

## Configure a company

Provision an appropriate account in the company's approved chart of accounts. From an authorized operator environment, supply a protected JSON request:

```json
{
  "company_id": "<company UUID>",
  "account_id": "<approved rounding account UUID>",
  "max_difference_minor": 2,
  "reason": "Approved rounding policy and finance review reference"
}
```

```bash
go run ./cmd/configure < /protected/rounding-policy.json
```

Use `SERK_ENV` and `MIGRATOR_DATABASE_URL_FILE` (verified TLS outside development). The tools image entrypoint is `/app/configure`. The function is unavailable to API/auth roles. The configuration change and previous/new settings are recorded atomically in `security.configuration_events`, including the operator login and reason. Configuration changes affect newly created journals only. Never update posted data to change historical rounding.
