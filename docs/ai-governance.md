# AI assistant governance

This page states the rules the AI assistant (0.4.0-rc1) operates under and what an organisation must decide before turning it on. The technical design is in [AI_ARCHITECTURE.md](AI_ARCHITECTURE.md).

## Principle: a preparer, never an approver

The assistant has lower authority than the person using it.

| Allowed | Not allowed |
|---|---|
| Read reports, ledgers, journals, documents, VAT and integrity status that the user may already see | Reading anything the user cannot see |
| Explain figures and IFRS / Ethiopian practice | Submitting, approving, posting, paying, reversing or voiding |
| Audit-style review of entries (`review_entries`) | Changing posted data or deleting history |
| Prepare DRAFT manual journals, sales invoices and supplier bills | Changing tax rules, configuration, permissions or periods; closing or reopening periods |

These limits are enforced by the code, not by the prompt. The assistant only has the 17 tools listed in AI_ARCHITECTURE.md. Each tool runs as the signed-in user in its own transaction, under row-level security, branch scope, permissions and module switches. The draft tools call the same create commands as the screens. Every draft then needs a person to submit it and a different authorised person to approve and post it.

## Accountability

- A draft is created by, and recorded in the audit trail under, the user who asked for it.
- Its reason begins with `Prepared by the AI assistant at the user's request: …` and the user's request, so reviewers can see where it came from.
- The approver is responsible for checking the draft as with any other preparer's work. AI involvement is not a reason to approve faster.
- Tax and payroll rates come from the company's configured, dual-approved policies. The assistant is told to remind users to confirm statutory rates with a qualified accountant.

## Turning it on

1. **Module switch.** The AI assistant is a module under Modules & features. An administrator with `configuration.manage` can switch it off for the company at any time, with a reason; the change is audited.
2. **Permission.** Grant "Use the AI assistant" (`ai.use`) only to roles that should use it.
3. **Provider.** Choose where data goes:
   - **Claude (Anthropic) API.** Questions, conversation text and the figures the tools return are sent to Anthropic. Agree data-processing terms (retention, training use) with the provider before using it with real books.
   - **OpenAI-compatible server in the office** (for example Ollama). Data stays on your network. Plain HTTP is accepted only on the same computer, or on private addresses when the operator sets `SERK_AI_ALLOW_PRIVATE_HTTP=true`.
   - **Server-wide default** set by the operator through `SERK_AI_*` environment variables (see [RAILWAY.md](RAILWAY.md)). A company's own settings take precedence.
4. **Key custody.** A company key is sealed with the installation's encryption key and bound to the company. It is never shown again after entry, and it is only used with the provider and address it was entered for. Moving to another provider or address requires the key to be entered again. Settings changes need a reason and are audited; the key itself is not written to the audit trail.

## Data handling

- The server does not store conversations. The browser keeps them in session storage for the current user and company, and clears them at sign-out.
- Server logs record request IDs, tool names and error codes, not prompts or financial figures. Provider error details are logged truncated.
- Tool results are capped at 24 KiB per call. The model receives no more than the tools return.
- The assistant does not follow redirects from the AI service.

## Known gaps (future)

- No per-company log of prompts and answers for later review. Organisations that need one should not enable the assistant until it exists, or should keep their own records.
- No automated evaluation suite for answer quality (arithmetic, citations). The tests cover permission boundaries, draft-only behaviour, key handling and limits, not the correctness of model answers.
- Answers do not yet cite record IDs for each figure. Users should check figures against the reports.
- OCR of supplier documents, forecasting and anomaly alerts beyond `review_entries` are not implemented; see the future section of AI_ARCHITECTURE.md.
