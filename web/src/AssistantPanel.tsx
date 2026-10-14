import { useEffect, useRef, useState, type ReactNode } from "react";
import { FileText, Loader2, Send, Sparkles, Trash2, X } from "lucide-react";
import { api, APIError } from "./api";

type Status = { available: boolean; provider?: string; model?: string; configured_by?: string; reason?: string };
type Draft = { kind: string; id: string; number: string; summary: string };
type Step = { tool: string; ok: boolean; note?: string };
export type Turn = { role: "user" | "assistant"; content: string; drafts?: Draft[]; steps?: Step[]; error?: boolean; failed?: boolean };

const toolNames: Record<string, string> = {
  company_overview: "key figures", trial_balance: "trial balance", balance_sheet: "balance sheet", income_statement: "profit or loss",
  account_ledger: "account ledger", list_accounts: "chart of accounts", list_journals: "journals", get_journal: "a journal",
  list_documents: "documents", vat_report: "VAT report", find_parties: "customers / vendors", find_items: "items",
  ledger_integrity: "ledger integrity", review_entries: "entry review", draft_journal: "prepared a draft journal", draft_sales_invoice: "prepared a draft invoice",
  draft_supplier_bill: "prepared a draft bill",
};
const suggestions = [
  "Give me a short overview of how the business is doing this month.",
  "How much VAT do we owe for last month, and how was it calculated?",
  "Which customer invoices are still unpaid?",
  "Explain our gross margin and what drives cost of sales.",
  "Review this month's entries for anything unusual.",
  "Draft a journal for office rent of 20,000 ETB paid today from the CBE account.",
];

// Minimal, safe rendering of the assistant's markdown: paragraphs, bullet lists, tables, bold.
// Text is always rendered as text, never as HTML. Every branch consumes at least one line, so
// any input terminates.
function inline(text: string): ReactNode[] {
  return text.split(/(\*\*[^*]+\*\*)/g).map((part, i) => (part.length > 4 && part.startsWith("**") && part.endsWith("**") ? <strong key={i}>{part.slice(2, -2)}</strong> : part));
}
const isTable = (l: string) => /^\s*\|.*\|\s*$/.test(l);
const isRule = (l: string) => /^\s*\|[\s:|-]+\|\s*$/.test(l);
const isList = (l: string) => /^\s*([-*]|\d+\.)\s+/.test(l);
const isHeading = (l: string) => /^\s{0,3}#{1,6}\s+\S/.test(l);
export function Markdown({ text }: { text: string }) {
  const blocks: ReactNode[] = [];
  const lines = text.replace(/\r/g, "").split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (isTable(line)) {
      const rows: string[][] = [];
      while (i < lines.length && isTable(lines[i])) {
        if (!isRule(lines[i])) rows.push(lines[i].trim().slice(1, -1).split("|").map((c) => c.trim()));
        i++;
      }
      if (rows.length === 0) continue;
      const [head, ...body] = rows;
      blocks.push(
        <div className="assistant-table" key={blocks.length}>
          <table>
            <thead><tr>{head.map((c, j) => <th key={j}>{inline(c)}</th>)}</tr></thead>
            <tbody>{body.map((r, k) => <tr key={k}>{r.map((c, j) => <td key={j}>{inline(c)}</td>)}</tr>)}</tbody>
          </table>
        </div>,
      );
    } else if (isList(line)) {
      const items: string[] = [];
      while (i < lines.length && isList(lines[i])) items.push(lines[i++].replace(/^\s*([-*]|\d+\.)\s+/, ""));
      blocks.push(<ul key={blocks.length}>{items.map((t, j) => <li key={j}>{inline(t)}</li>)}</ul>);
    } else if (isHeading(line)) {
      blocks.push(<h4 key={blocks.length}>{inline(line.replace(/^\s*#{1,6}\s+/, ""))}</h4>);
      i++;
    } else if (line.trim() === "") {
      i++;
    } else {
      const para: string[] = [line];
      i++;
      while (i < lines.length && lines[i].trim() !== "" && !isTable(lines[i]) && !isList(lines[i]) && !isHeading(lines[i])) para.push(lines[i++]);
      blocks.push(<p key={blocks.length}>{inline(para.join(" "))}</p>);
    }
  }
  return <>{blocks}</>;
}

/** The conversation sent to the server: failed exchanges are left out, the turns alternate
 * starting with the user (of consecutive user messages, an unanswered one is dropped), and each
 * message fits the server's 8,000-byte limit (long replies keep their end). */
export function history(turns: Turn[]): { role: "user" | "assistant"; content: string }[] {
  const out: { role: "user" | "assistant"; content: string }[] = [];
  for (const t of turns) {
    if (t.error || t.failed || !t.content.trim()) continue;
    const content = t.role === "assistant" ? fit(t.content, 7900) : t.content;
    const last = out[out.length - 1];
    if (last && last.role === t.role) {
      if (t.role === "user") last.content = content;
      else last.content = fit(last.content + "\n\n" + content, 7900);
    } else out.push({ role: t.role, content });
  }
  if (out.length && bytes(out[out.length - 1].content) > 8000) out.pop();
  while (out.length && out[0].role !== "user") out.shift();
  let recent = out.slice(-20);
  while (recent.length && recent[0].role !== "user") recent = recent.slice(1);
  return recent;
}

const bytes = (s: string) => new TextEncoder().encode(s).length;
/** The last part of s that fits in max bytes, without splitting a character. */
function fit(s: string, max: number): string {
  if (bytes(s) <= max) return s;
  const chars = Array.from(s);
  let size = 4; // "… " prefix
  let start = chars.length;
  while (start > 0 && size + bytes(chars[start - 1]) <= max) size += bytes(chars[--start]);
  return "… " + chars.slice(start).join("");
}

// Conversations are kept per user and company for this browser tab only.
const storageKey = (user: string, company: string) => "serk.assistant." + user + "." + company;
export function clearAssistantHistory() {
  try {
    for (let i = sessionStorage.length - 1; i >= 0; i--) {
      const k = sessionStorage.key(i);
      if (k?.startsWith("serk.assistant.")) sessionStorage.removeItem(k);
    }
  } catch { /* storage unavailable */ }
}

// Mount with key={user + company} so a different company or user starts a fresh panel.
export function AssistantPanel({ user, company, csrf, screen, canConfigure, onClose, openDraft, onDrafts }: {
  user: string; company: string; csrf: string; screen: string; canConfigure: boolean; onClose: () => void; openDraft: (d: Draft) => void; onDrafts?: () => void;
}) {
  const [status, setStatus] = useState<Status | null>(null);
  const [turns, setTurns] = useState<Turn[]>(() => {
    try { return JSON.parse(sessionStorage.getItem(storageKey(user, company)) ?? "[]") as Turn[]; } catch { return []; }
  });
  const input = useRef<HTMLTextAreaElement>(null);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const end = useRef<HTMLDivElement>(null);
  useEffect(() => {
    api<Status>("/assistant/status", company)
      .then(setStatus)
      .catch((e) => setStatus({ available: false, reason: e instanceof APIError && e.status === 403 ? "permission_denied" : "status_failed" }));
  }, [company]);
  useEffect(() => {
    try { sessionStorage.setItem(storageKey(user, company), JSON.stringify(turns.slice(-30))); } catch { /* storage unavailable */ }
    end.current?.scrollIntoView({ block: "end" });
  }, [turns, user, company]);
  useEffect(() => { if (!busy && status?.available) input.current?.focus(); }, [busy, status]);

  async function send(message: string) {
    const content = message.trim();
    if (!content || busy) return;
    if (bytes(content) > 8000) {
      setTurns([...turns, { role: "assistant", content: "That message is too long. Shorten it or split it into parts.", error: true }]);
      return;
    }
    const next: Turn[] = [...turns, { role: "user", content }];
    setTurns(next);
    setText("");
    setBusy(true);
    try {
      const res = await api<{ reply: string; drafts: Draft[]; steps: Step[] }>("/assistant/chat", company, { method: "POST", csrf, body: { messages: history(next), screen }, timeoutMs: 150000 });
      setTurns([...next, { role: "assistant", content: res.reply, drafts: res.drafts, steps: res.steps }]);
      if (res.drafts.length) onDrafts?.();
    } catch (e) {
      // The question stays visible but is not resent; drafts saved before the failure are shown.
      const msg = e instanceof APIError ? e.message : "The assistant did not answer. Try again.";
      const drafts = (e instanceof APIError && Array.isArray(e.body?.drafts) ? e.body.drafts : []) as Draft[];
      const failed = next.map((t, i) => (i === next.length - 1 ? { ...t, failed: true } : t));
      setTurns([...failed, { role: "assistant", content: msg, error: true, drafts }]);
      if (drafts.length) onDrafts?.();
    } finally {
      setBusy(false);
    }
  }

  const unavailable = status && !status.available;
  return (
    <aside className="assistant-panel" role="dialog" aria-label="Finance assistant">
      <header>
        <div>
          <h2><Sparkles size={18} /> Finance assistant</h2>
          <p>Answers from your books. Prepares drafts only; people review, submit and approve.</p>
        </div>
        <div className="assistant-actions">
          <button className="icon-btn" aria-label="Clear conversation" disabled={busy || turns.length === 0} onClick={() => setTurns([])}><Trash2 size={16} /></button>
          <button className="icon-btn" aria-label="Close assistant" onClick={onClose}><X size={18} /></button>
        </div>
      </header>
      <div className="assistant-body" aria-live="polite">
        {unavailable && (
          <div className="assistant-note">
            {status.reason === "assistant_not_configured" ? (
              <p>The assistant is not set up yet. {canConfigure ? "Add an AI provider key under Modules & features → AI assistant." : "Ask an administrator to add an AI provider key."}</p>
            ) : status.reason === "permission_denied" ? (
              <p>Your role does not include the AI assistant, or it is switched off for this company.</p>
            ) : status.reason === "status_failed" ? (
              <p>The assistant could not be reached. Check your connection and open it again.</p>
            ) : (
              <p>The assistant's configuration is not valid. {canConfigure ? "Check the provider settings under Modules & features." : "Ask an administrator to check it."}</p>
            )}
          </div>
        )}
        {status?.available && turns.length === 0 && (
          <div className="assistant-empty">
            <p>Ask about balances, profit, VAT, unpaid invoices or any account — or ask for a draft entry.</p>
            {suggestions.map((s) => <button key={s} className="assistant-suggestion" onClick={() => void send(s)}>{s}</button>)}
          </div>
        )}
        {turns.map((t, i) => (
          <div key={i} className={"assistant-turn " + t.role + (t.error ? " error" : "") + (t.failed ? " failed" : "")}>
            {t.role === "assistant" && t.steps && t.steps.length > 0 && (
              <div className="assistant-steps">Looked at: {[...new Set(t.steps.map((s) => (toolNames[s.tool] ?? s.tool) + (s.ok ? "" : " (refused)")))].join(" · ")}</div>
            )}
            {t.role === "assistant" ? <Markdown text={t.content} /> : <p>{t.content}</p>}
            {t.drafts?.map((d) => (
              <div className="assistant-draft" key={d.id}>
                <FileText size={16} />
                <div><strong>Draft {d.kind.toLowerCase()} {d.number}</strong><small>{d.summary} · awaiting your review</small></div>
                <button className="secondary compact" onClick={() => openDraft(d)}>Review</button>
              </div>
            ))}
          </div>
        ))}
        {busy && <div className="assistant-turn assistant thinking"><Loader2 size={16} className="spin" /> Looking at your books…</div>}
        <div ref={end} />
      </div>
      <form className="assistant-input" onSubmit={(e) => { e.preventDefault(); void send(text); }}>
        <textarea
          ref={input}
          aria-label="Message the assistant"
          placeholder={status?.available ? "Ask a question or describe an entry…" : "Assistant unavailable"}
          disabled={!status?.available || busy}
          value={text}
          maxLength={8000}
          rows={2}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void send(text); } }}
        />
        <button className="primary" aria-label="Send" disabled={!status?.available || busy || !text.trim()}><Send size={16} /></button>
      </form>
      {status?.available && <small className="assistant-footnote">{status.provider === "anthropic" ? "Claude" : "Local model"} · {status.model}. Check figures before relying on them.</small>}
    </aside>
  );
}
