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
