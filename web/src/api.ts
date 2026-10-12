// Plain-language text for the static error codes the API returns.
const messages: Record<string, string> = {
  invalid_credentials: "The workspace, email, password or code is not correct.",
  unauthenticated: "Your session has ended. Sign in again.",
  rate_limited: "Too many attempts. Wait a minute, then try again.",
  authentication_busy: "Sign-in is busy. Try again in a few seconds.",
  authentication_unavailable: "Sign-in is temporarily unavailable. Contact your administrator.",
  permission_denied: "Your role does not allow this action.",
  invalid_csrf: "Your session could not be verified. Sign in again.",
  segregation_of_duties: "You prepared this journal. A different person must approve it.",
  version_conflict: "Someone else changed this record. Reload it and try again.",
  invalid_transition: "This action is not allowed in the journal's current status.",
  journal_immutable: "Posted journals cannot be changed. Create a reversal instead.",
  period_not_open: "The accounting period for this date is not open.",
  period_has_unfinished_journals: "Finish or void the unfinished journals in this period first.",
  invalid_journal: "The journal is not valid. Check that debits equal credits and amounts are whole minor units.",
  journal_unbalanced: "Debits and credits must be equal.",
  invalid_posting_account: "One of the accounts cannot receive postings.",
  inactive_branch: "The selected branch is not active.",
  reversal_mismatch: "This reversal does not match the original journal.",
  reversal_date_before_original: "A reversal cannot be dated before the original journal.",
  approval_no_longer_authorized: "The approval is no longer valid for your role. Ask for a new approval.",
  invalid_currency_conversion: "The exchange rate or currency is not valid for this company.",
  fx_rounding_not_configured: "Foreign-currency rounding is not configured for this company.",
  fx_rounding_limit_exceeded: "The foreign-currency rounding difference is larger than the approved limit.",
  idempotency_conflict: "This request was already used with different details. Start the action again.",
  duplicate_record: "This record already exists.",
  invalid_reference: "A selected account, branch or dimension no longer exists.",
  validation_failed: "Some details are not valid. Check the form and try again.",
  invalid_value: "A value has the wrong format.",
  invalid_json: "The request had unexpected fields.",
  invalid_pagination: "The list filter is not valid.",
  invalid_state: "This action is blocked in the current state.",
  not_found: "The record was not found, or you do not have access to it.",
  retry_later: "The server is busy. Try again in a moment.",
  internal_error: "Something went wrong on the server. Try again.",
  last_administrator: "This change would leave the company without an administrator.",
  privilege_escalation: "You cannot grant or change permissions that you do not hold yourself.",
  cannot_change_self: "You cannot disable or reset the password of your own account here.",
  role_in_use: "This role is still assigned to users. Remove it from them first.",
  invalid_grant: "A role assignment is not valid. Check the role, branch and approval limit.",
  invalid_permission: "One of the selected permissions does not exist.",
  invalid_reason: "Enter a reason of at least 3 characters.",
  invalid_email: "Enter a valid email address.",
  invalid_name: "Check the name: it is empty or too long.",
  weak_password: "The password must be 14 to 256 characters long.",
  invalid_request: "Some details are missing or not valid.",
  // Accounts and master data
  access_denied: "Your role does not allow this action.",
  company_access_denied: "You do not have access to this company.",
  account_configuration_required: "An account mapping is missing. Ask an administrator to complete the finance settings.",
  account_definition_in_use: "This account already has entries, so its code, type or parent cannot change.",
  account_has_balance: "This account still has a balance. Move the balance before deactivating it.",
  account_has_pending_entries: "This account is used by unfinished journals. Finish or void them first.",
  account_hierarchy_cycle_or_depth: "That parent would create a loop in the chart of accounts.",
  account_in_use_by_configuration: "This account is used in finance settings or by an item. Change those first.",
  invalid_account_parent: "The parent account must be a header account of the same type.",
  invalid_group_account: "A header account with sub-accounts cannot receive postings.",
  parent_has_postings: "This account already has entries, so it cannot become a header account.",
  statement_class_required: "Choose whether this asset or liability is current or non-current.",
  invalid_account_mapping: "One of the selected accounts cannot be used for this setting.",
  cash_account_configuration_required: "Choose at least one bank or cash account in finance settings.",
  item_definition_in_use: "This item is already used, so its accounts cannot change.",
  dimension_definition_in_use: "This dimension is already used and cannot change.",
  currency_definition_in_use: "This currency is already used and cannot change.",
  functional_currency_in_use: "The company's functional currency cannot change once entries exist.",
  master_identity_immutable: "This record's identity cannot change.",
  immutable_record: "This record is part of the audit trail and cannot change.",
  inactive_dimension: "One of the dimensions is no longer active.",
  // Journals and periods
  reason_required: "Enter a reason of at least 3 characters.",
  description_and_reason_required: "Enter a description and a reason.",
  invalid_lines: "A journal needs at least two lines.",
  invalid_amount: "Enter a positive whole amount in minor units.",
  invalid_dates: "Check the dates.",
  invalid_action: "This action is not available.",
  invalid_reversal: "Only a posted journal can be reversed, and not to an earlier date.",
  only_posted_can_reverse: "Only posted journals can be reversed.",
  reversal_dimensions_mismatch: "This reversal's dimensions do not match the original.",
  invalid_rounding_line: "The rounding line is not valid.",
  invalid_rounding_account: "Choose an active expense account for foreign-currency rounding.",
  invalid_rounding_configuration: "The rounding limit is not valid.",
  invalid_reference_or_period: "There is no accounting period for this date, or a reference is not valid.",
  invalid_period_range: "The period overlaps another period or is outside the fiscal year.",
  invalid_period_transition: "This period cannot move to that status.",
  period_not_closed: "Only a closed period can be reopened.",
  fiscal_year_closed: "This fiscal year is closed. Nothing more can be posted into it.",
  fiscal_year_in_use: "This fiscal year already has periods or entries and cannot change.",
  year_close_blocked: "The year cannot be closed yet. Resolve the items listed in the preview.",
  year_close_stale_void_and_request_again: "Entries were posted after the close was requested. Void the request and request it again.",
  too_many_accounts_to_close: "Too many profit-or-loss accounts in one branch to close in a single entry.",
  ledger_reconciliation_required: "The ledger integrity check is failing. Ask an administrator to investigate before continuing.",
  use_module_workflow: "This entry belongs to an invoice, bill, payroll, adjustment or year-end close. Use that screen instead.",
  use_general_journal: "This adjustment does not touch a controlled account. Use an ordinary journal instead.",
  use_reversal_workflow: "A reversal is in progress for this document. Finish or void it first.",
  control_account_not_allowed_for_purpose: "One of the accounts is controlled by another module and cannot be used for this kind of adjustment.",
  // Currency
  exchange_rate_not_recorded: "Record an exchange rate for this currency and date under Currencies & Rates first.",
  exchange_rate_outside_tolerance: "The rate differs too much from the recorded rate for this date. Check the rate or record the new official rate.",
  invalid_exchange_rate: "Enter a positive exchange rate for a currency other than the company's own.",
  // Modules
  insufficient_stock: "There is not enough stock for this quantity.",
  insufficient_stock_for_reversal: "There is not enough stock left to return these goods.",
  inventory_date_order: "Stock movements must be dated on or after the item's last movement.",
  inventory_value_without_quantity: "An item with no stock left cannot keep a value. Adjust value and quantity together.",
  inconsistent_inventory_adjustment: "Adding stock must increase its value and removing stock must decrease it.",
  stock_moved_since_bill_use_inventory_adjustment: "This stock has already been sold or adjusted since the bill. Record the return as an inventory adjustment.",
  use_controlled_stock_opening: "Enter opening stock with a stock opening document, not on the item.",
  payment_already_submitted: "A payment is already waiting for approval.",
  reverse_payment_first_or_settle_with_credit_document: "This document cannot be reversed in its current state.",
  approved_payroll_policy_required: "Choose an approved payroll policy that covers this pay period.",
  approved_policy_immutable: "An approved payroll policy cannot change. Create a new version instead.",
  overlapping_payroll_policy: "Another policy already covers these dates.",
  invalid_payroll_policy: "The payroll policy's tax bands are not complete.",
  invalid_payroll_period: "The pay period does not match the pay frequency.",
  invalid_net_pay: "Deductions would leave an employee with no net pay. Check the policy.",
  no_active_employees_or_salaries: "No active employees with salaries were found for this branch and frequency.",
  payroll_period_already_processed: "Payroll for this period has already been run.",
  payroll_accounting_date_must_be_period_end: "Date the payroll on the last day of the pay period. Record the payment date when you pay it.",
  tax_rate_in_use_create_new_version: "This tax rate is already used. End it and create a new rate instead.",
  // Reports and setup
  as_of_required: "Choose a report date.",
  to_date_required: "Choose an end date.",
  invalid_report_parameters: "The report dates are not valid.",
  idempotency_key_required: "The request could not be identified. Refresh and try again.",
  mfa_required: "Two-factor authentication is required for this action.",
  chart_preflight_cycle_or_depth: "The chart of accounts import would create a loop.",
  chart_preflight_invalid_parent: "The chart of accounts import has an invalid parent.",
};
export class APIError extends Error {
  constructor(
    public status: number,
    public code: string,
  ) {
    super(messages[code] ?? code.replaceAll("_", " "));
  }
}
export async function api<T>(
  path: string,
  company?: string,
  options?: { method?: string; body?: unknown; csrf?: string; key?: string },
): Promise<T> {
  const headers: Record<string, string> = {};
  if (company) headers["X-Company-ID"] = company;
  if (options?.body !== undefined) headers["Content-Type"] = "application/json";
  if (options?.csrf) headers["X-CSRF-Token"] = options.csrf;
  if (options?.key) headers["Idempotency-Key"] = options.key;
  const r = await fetch("/api/v1" + path, {
    method: options?.method ?? "GET",
    credentials: "same-origin",
    signal: AbortSignal.timeout(25000),
    headers,
    body:
      options?.body !== undefined ? JSON.stringify(options.body) : undefined,
  });
  let data;
  try {
    data = await r.json();
  } catch {
    throw new APIError(r.status, r.status >= 500 ? "retry_later" : "request_failed");
  }
  if (!r.ok) throw new APIError(r.status, data.error?.code ?? "request_failed");
  return data;
}
export function minor(value: string, places: number): string {
  if (!/^\d+(\.\d*)?$/.test(value)) throw new Error("Enter a positive amount.");
  const [whole, frac = ""] = value.split(".");
  if (frac.length > places)
    throw new Error(`Use at most ${places} decimal places.`);
  return BigInt(whole + frac.padEnd(places, "0")).toString();
}
export function money(value: string, places = 2): string {
  const n = BigInt(value),
    negative = n < 0n;
  const digits = (negative ? -n : n).toString().padStart(places + 1, "0");
  const integer = (places ? digits.slice(0, -places) : digits).replace(
    /\B(?=(\d{3})+(?!\d))/g,
    ",",
  );
  return (
    (negative ? "−" : "") +
    integer +
    (places ? "." + digits.slice(-places) : "")
  );
}
