# API changes in 0.2.0-rc2

Staging/production use `__Host-serk_session`; loopback development uses `serk_session`. The period-close POST now requires an `Idempotency-Key` of 8–128 characters, just like journal commands. Identical replay returns its original response without a second audit effect; a different payload on that key returns HTTP 409. Posting can return HTTP 403 / `approval_no_longer_authorized` if the independent approver is no longer eligible. Source/account login attempts have a persistent 10/minute window, reset on success, in addition to the process source limit. Login accepts a six-digit code; TOTP is required for enrolled users and all secure-environment sessions. Existing statements below describe the unchanged routes and journal model; see the updated `openapi.json` contract.

# API contract

Base path: `/api/v1`. JSON only. Monetary values are integer **strings in minor units**. Rate values are decimal strings. Dates use ISO Gregorian dates internally; localized calendars are presentation/input adapters.

The machine-readable contract is [openapi.json](openapi.json). It describes the implemented routes only; future domain APIs are not exposed as working capabilities.

Authentication is an HttpOnly cookie named `serk_session`. Login returns a CSRF token, and `/session` returns current authorized companies and the CSRF token. All financial requests supply `X-Company-ID`. Unsafe requests require a matching `Origin`; authenticated POST requests also require `X-CSRF-Token`. Bearer/service credentials, OAuth/OIDC and mobile authentication adapters are still pending.

| Method and route | Purpose | Required permission/control |
|---|---|---|
| POST `/auth/login` | Workspace/email/password/TOTP login | Origin, login rate limit |
| POST `/auth/logout` | Revoke current session | Cookie + CSRF |
| GET `/session` | Current user/company choices | Valid session |
| GET `/accounting/reference` | COA, branches, periods, dimensions, currencies | ledger.read |
| GET `/accounting/journals` | Cursor-paginated journal list | ledger.read and branch scope |
| POST `/accounting/journals` | Create balanced draft | journal.create + Idempotency-Key |
| GET `/accounting/journals/{id}` | Journal, lines, action permissions | ledger.read and branch scope |
| POST `/accounting/journals/{id}/submit` | Submit for independent review | journal.submit + version + idempotency |
| POST `/accounting/journals/{id}/approve` | Approve | branch/amount ceiling + segregation |
| POST `/accounting/journals/{id}/post` | Commit approved journal to ledger | journal.post + open period |
| POST `/accounting/journals/{id}/reverse` | Create inverse draft | journal.reverse + journal.create |
| POST `/accounting/journals/{id}/void` | Void unposted journal | journal.void |
| GET `/accounting/periods/{id}/close-preview` | Counts unfinished drafts/submissions/approvals | period.close + company-wide ledger.read |
| POST `/accounting/periods/{id}/close` | Close period, permanently blocking posting until future authorized reopen support | period.close + company-wide ledger.read + version + reason + no unfinished journals |
| GET `/reports/trial-balance` | Posted functional account balances/activity | ledger.read |
| GET `/audit/events` | Ascending company audit sequence | audit.read, unrestricted company audit scope |

Journal writes have a persistent idempotency receipt. Period close creates no monetary transaction; it uses an expected version and an irreversible state transition. A lost close response can be retried with the identical body and idempotency key.

Create example, using actual IDs from authorized reference data:

```json
{
  "branch_id": "<authorized branch UUID>",
  "accounting_date": "2026-09-14",
  "description": "Capital contribution received",
  "currency": "ETB",
  "fx_rate": "1",
  "reason": "Bank receipt and approved capital schedule",
  "lines": [
    {"account_id": "<bank account UUID>", "debit_minor": "25000000", "credit_minor": "0"},
    {"account_id": "<capital account UUID>", "debit_minor": "0", "credit_minor": "25000000"}
  ]
}
```

Action body: `{"expected_version":2,"reason":"Independent source verification"}`. Reversal additionally requires `accounting_date`. Client-provided actors, posted timestamps, statuses, unknown fields, duplicate JSON object keys, and fractional monetary numbers are rejected. Body limit is 512 KiB, nesting limit 32, and journal input limit 500 source lines. Responses can include one additional is_rounding=true line with zero original amounts and an explicit functional-currency adjustment; clients must display it.

Journal list parameters: `limit` 1–100 (default 50), optional `state`, and a pair `before` (RFC3339 timestamp) + `before_id` (UUID). Use the last loaded row as the next cursor. Ordering is `(created_at DESC,id DESC)`. Audit uses `after` sequence and batches of 100. Trial balance requires `as_of=YYYY-MM-DD`; optional `from` changes the report to period activity.

Errors use `{"error":{"code":"version_conflict","message":"version conflict","request_id":"..."}}`. Statuses: 400 malformed request, 401 authentication, 403 authorization/CSRF, 404 inaccessible or missing record, 409 state/version/idempotency/duplicate conflict, 422 financial/reference validation, 429 rate limit, 503 retriable infrastructure/lock failure. SQL details, DSNs, password hashes and conflicting foreign-company IDs are not returned.

On uncertain delivery, repeat exactly the same body and `Idempotency-Key`. Do not generate another key because a response timed out. The React interface retains the pending request in memory and prevents company navigation while an uncertain command is unresolved; durable recovery after browser/device loss is not yet an offline queue.

The current API intentionally returns 404 for unimplemented AP, AR, tax, AI and other domain routes. Their future command contracts are in `docs/domains`; they are not ready integration endpoints.
