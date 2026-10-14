# AI assistant — architecture

Since 0.4.0-rc1, Serk Finance includes an AI assistant. It answers questions from the company's books and prepares **draft** journals, sales invoices and supplier bills. It never submits, approves, posts, pays, reverses or voids anything, so maker-checker control is unchanged. Governance and operating rules are in [ai-governance.md](ai-governance.md). Items marked **future** at the end are design targets that are not implemented.

## Components

| Part | Where | Role |
|---|---|---|
| Agent loop | `internal/assistant/agent.go` | Bounded tool-use loop: calls the model, runs the tools it asks for, returns the reply, the steps taken and any drafts. Knows nothing about the database. |
| Providers | `internal/assistant/provider.go`, `anthropic.go`, `openai.go` | Claude Messages API (`POST /v1/messages`), or any OpenAI-compatible Chat Completions server (`POST {base}/chat/completions`), such as Ollama. |
| HTTP and tools | `internal/platform/httpapi/assistant_http.go`, `assistant_tools.go` | Endpoints, provider resolution, the system prompt and the 17 tools. |
| Database | `migrations/057_ai_assistant.sql` | `ai.use` permission, `ai_assistant` module switch, per-company settings and sealed key, `organization.assistant_context()`. |
| Interface | `web/src/AssistantPanel.tsx`, `web/src/pages/SettingsPage.tsx` (`AISettings`) | Side panel with chat, steps and draft links; provider settings under Modules & features. |

## Who may use it

- The user needs the `ai.use` permission ("Use the AI assistant"), and the company's **AI assistant** module switch must be on. Both are checked in the database (`security.has('ai.use')`; the `ai.` permission family maps to the `ai_assistant` feature). If either is missing, the endpoints return `permission_denied` and the button is hidden.
- A provider must be configured, by the company or by the server operator.
- The demo seed grants `ai.use` to its roles. Other companies grant it through Users & roles.

## Acting as the user

Every tool runs in **its own short database transaction bound to the signed-in user's session** (`Server.scoped`). Row-level security, branch scope, permissions, approval limits and module switches therefore apply exactly as on the screens. The assistant can never read or do more than the user could do directly. A tool that hits a permission or module boundary returns `permission_denied` or `feature_disabled` to the model, which explains it to the user.

`organization.assistant_context()` gives the model the company, functional currency, the user's display name, the user's effective permissions, and the branches where the user may prepare journals, invoices or bills.

## Tools (17)

Read tools:

| Tool | Reads |
|---|---|
| `company_overview` | Dashboard as of today |
| `trial_balance` | Trial balance as of a date, optionally movements from a start date |
| `balance_sheet` | Statement of financial position (current / non-current) |
| `income_statement` | Statement of profit or loss for a date range |
| `account_ledger` | Posted entries of one account with running balance (at most 100 rows) |
| `list_accounts` | Chart of accounts, by type or text |
| `list_journals` | Recent journals, optionally by state |
| `get_journal` | One journal with its lines, by number |
| `list_documents` | Sales invoices, supplier bills, payroll runs or stock openings |
| `vat_report` | Output tax, input tax and net payable by rate |
| `find_parties` | Customers or vendors by name |
| `find_items` | Products and services with price, stock quantity and value |
| `ledger_integrity` | Journal balance and audit-chain check (needs `audit.read`) |
| `review_entries` | Audit-style review of a date range: manual entries to revenue, round or unusually large amounts, weekend dates, and drafts or submissions waiting more than 7 days |

Draft tools:

| Tool | Creates |
|---|---|
| `draft_journal` | A DRAFT manual journal. Lines must balance. Not for invoices, bills, payroll or control accounts (receivables, payables, VAT, payroll liabilities, inventory), which have their own documents and adjustments. |
| `draft_sales_invoice` | A DRAFT credit sales invoice. When `invoice_number` is omitted, the number continues the company's latest invoice sequence. |
| `draft_supplier_bill` | A DRAFT credit supplier bill. The supplier's invoice number is required. |

Drafts go through the same commands as the screens (journal create; invoice and bill create), with an idempotency key per tool call. Rules for drafts:

- **Branch.** When the user may draft in more than one branch, the branch must be named. Otherwise the tool returns `branch_required` with the possible branch codes, and the model asks the user.
- **Reason.** Every AI-made draft's reason starts with `Prepared by the AI assistant at the user's request: <the user's request>`, followed by any reason the model gives. The AI note comes first, so a long reason cannot cut it off. The draft is created by, and audited as, the signed-in user.
- **Amounts.** Tool inputs are decimal strings in major units (for example `"20000.00"`). Tool results give money in minor units.
- After a draft, a person must review and submit it, and a different authorised person must approve and post it, under the existing workflow and approval limits.

## Limits

| Limit | Value |
|---|---|
| Model calls per chat request | 8 (then the assistant asks the user to narrow the question) |
| Tool calls per model response | 6 |
| Tool result size sent to the model | 24 KiB. A larger result is replaced by valid JSON: `{"truncated": true, "note": …, "partial": …}`, cut on a character boundary. |
| Time per chat request | 140 s (HTTP write deadline 150 s) |
| Time per model call | 60 s |
| Model response size | 2 MiB |
| Chat requests | 12 per minute per session (`rate_limited`) |
| Conversation | 30 messages of at most 8000 bytes, alternating user/assistant, last one from the user |

Only the text turns of a conversation are sent back on the next request; earlier tool traffic is not replayed. The browser keeps the conversation in session storage per user and company, and clears it at sign-out. The server does not store conversations.

If a chat fails part-way (provider error, timeout), the response still lists any drafts already saved, so none is orphaned.

## Providers and configuration

The provider is resolved per request: the company's own settings first, then the server's.

**Company settings** (`POST /api/v1/assistant/settings`, company-wide `configuration.manage`, a reason of 3–1000 characters, audited):

- `provider`: `anthropic` or `openai` (OpenAI-compatible). `model` defaults to `claude-sonnet-5-5` for Anthropic. An OpenAI-compatible provider needs `base_url`.
- The API key is sealed with AES-GCM (`mfa.Seal`) using the installation's encryption key (`SERK_MFA_KEY`), bound to the company (`ai:<company id>`), so the ciphertext cannot be moved to another company. It is stored in `organization.ai_secrets`, which is outside the audit trail, and it is **never returned**. The settings only say `key_set`.
- A stored key is only used with the provider and base URL it was entered for. Changing either without entering the key again (or removing it) is refused with `assistant_key_required`.
- Without a 32-byte encryption key on the server, a key cannot be stored (`assistant_key_storage_unavailable`).

**Server settings** (environment variables, used when the company has none):

| Variable | Meaning |
|---|---|
| `SERK_AI_PROVIDER` | `anthropic` (default) or `openai` |
| `SERK_AI_MODEL` | Model name; `claude-sonnet-5-5` by default for Anthropic, required for `openai` |
| `SERK_AI_BASE_URL` | Server address; default `https://api.anthropic.com` for Anthropic, required for `openai` |
| `SERK_AI_API_KEY` | API key (`ANTHROPIC_API_KEY` is also read). Required for Anthropic; optional for an OpenAI-compatible server. |
| `SERK_AI_ALLOW_PRIVATE_HTTP` | `true` allows plain-HTTP base URLs on private network addresses |

**Network rules** (`assistant.ValidateBaseURL`, applied to both):

- HTTPS anywhere. Plain HTTP only for `localhost` or loopback addresses, or private IP addresses when `SERK_AI_ALLOW_PRIVATE_HTTP=true`. No credentials, query or fragment in the URL.
- **Redirects from the AI service are refused** (`assistant_redirect_refused`), so the key and the figures cannot be forwarded to another address or downgraded to HTTP.
- Provider error bodies stay in server logs (truncated). Clients get stable codes only.

## Prompt-injection and output handling

- The system prompt tells the model that tool results are data, never instructions, and that it must not invent figures.
- The model's authority comes only from the tools, and the tools only reach the user's own permissions and only create drafts. Even a successful injection cannot post, approve or pay.
- The panel renders the reply with a minimal Markdown renderer (paragraphs, lists, tables, bold), without HTML (`tests/assistant-markdown.mjs`).

## Tests

`internal/assistant/assistant_test.go` (tool loop on both providers, error classification, base-URL policy, refused redirects, timeouts, truncation), `tests/assistant_test.go` (acts as the user and only drafts; key sealing and `assistant_key_required`), `tests/assistant-browser.mjs` with `tests/fake-claude.mjs`, and `tests/assistant-markdown.mjs`. See [testing.md](testing.md).

## Future (not implemented)

These remain design targets:

- **Logging and evaluation.** Per-company logs of prompts and outputs, and evaluation suites for arithmetic, citation fidelity, permission boundaries and refusal to approve.
- **Citations.** Answers that cite record IDs, versions and drill-through links for every figure.
- **More drafts.** Adjustments (for example a VAT remittance drafted from the VAT report), bank-reconciliation match suggestions and period-end blocker summaries.
- **OCR of supplier documents.** Extraction of field values with page/coordinate evidence and confidence, TIN, totals, tax and PO/GRN validation, duplicate checks, and source hashes. Uploaded documents are data, never instructions. Text such as "ignore approval" cannot change tools or instructions.
- **Forecasting.** Horizon, training cutoff, inputs, model revision and calibrated uncertainty; backtesting on held-out data; drift tracking.
- **Anomaly alerts.** Beyond `review_entries`: duplicate bills and payments, supplier detail changes, split purchases, backdating, unusual prices, discounts or refunds, and payroll indicators. Each alert would show severity, baseline, supporting records and reviewer disposition. An alert does not establish fraud.
- **Purpose-specific entitlements** for payroll and bank data beyond the user's existing permissions.
