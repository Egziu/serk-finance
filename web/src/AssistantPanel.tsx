import { useEffect, useRef, useState, type ReactNode } from "react";
import { FileText, Loader2, Send, Sparkles, Trash2, X } from "lucide-react";
import { api, APIError } from "./api";

type Status = { available: boolean; provider?: string; model?: string; configured_by?: string; reason?: string };
type Draft = { kind: string; id: string; number: string; summary: string };
type Step = { tool: string; ok: boolean; note?: string };
type Turn = { role: "user" | "assistant"; content: string; drafts?: Draft[]; steps?: Step[]; error?: boolean };

const toolNames: Record<string, string> = {
  company_overview: "key figures", trial_balance: "trial balance", balance_sheet: "balance sheet", income_statement: "profit or loss",
  account_ledger: "account ledger", list_accounts: "chart of accounts", list_journals: "journals", get_journal: "a journal",
  list_documents: "documents", vat_report: "VAT report", find_parties: "customers / vendors", find_items: "items",
  ledger_integrity: "ledger integrity", draft_journal: "prepared a draft journal", draft_sales_invoice: "prepared a draft invoice",
  draft_supplier_bill: "prepared a draft bill",
};
const suggestions = [
  "Give me a short overview of how the business is doing this month.",
  "How much VAT do we owe for last month, and how was it calculated?",
  "Which customer invoices are still unpaid?",
  "Explain our gross margin and what drives cost of sales.",
  "Draft a journal for office rent of 20,000 ETB paid today from the CBE account.",
];

// Minimal, safe rendering of the assistant's markdown: paragraphs, bullet lists, tables, bold.
// Text is always rendered as text, never as HTML.
function inline(text: string): ReactNode[] {
  return text.split(/(\*\*[^*]+\*\*)/g).map((part, i) => (part.startsWith("**") && part.endsWith("**") ? <strong key={i}>{part.slice(2, -2)}</strong> : part));
}
function Markdown({ text }: { text: string }) {
  const blocks: ReactNode[] = [];
  const lines = text.replace(/\r/g, "").split("\n");
  for (let i = 0; i < lines.length; ) {
    const line = lines[i];
    if (/^\s*\|.*\|\s*$/.test(line)) {
      const rows: string[][] = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) {
        if (!/^\s*\|[\s:|-]+\|\s*$/.test(lines[i])) rows.push(lines[i].trim().slice(1, -1).split("|").map((c) => c.trim()));
        i++;
      }
      const [head, ...body] = rows;
      blocks.push(
        <div className="assistant-table" key={blocks.length}>
          <table>
            <thead><tr>{head.map((c, j) => <th key={j}>{inline(c)}</th>)}</tr></thead>
            <tbody>{body.map((r, k) => <tr key={k}>{r.map((c, j) => <td key={j}>{inline(c)}</td>)}</tr>)}</tbody>
          </table>
        </div>,
      );
    } else if (/^\s*([-*]|\d+\.)\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) items.push(lines[i++].replace(/^\s*([-*]|\d+\.)\s+/, ""));
      blocks.push(<ul key={blocks.length}>{items.map((t, j) => <li key={j}>{inline(t)}</li>)}</ul>);
    } else if (/^#{1,4}\s+/.test(line)) {
      blocks.push(<h4 key={blocks.length}>{inline(line.replace(/^#{1,4}\s+/, ""))}</h4>);
      i++;
    } else if (line.trim() === "") {
      i++;
    } else {
      const para: string[] = [];
      while (i < lines.length && lines[i].trim() !== "" && !/^\s*(\||[-*]\s|\d+\.\s|#)/.test(lines[i])) para.push(lines[i++]);
      blocks.push(<p key={blocks.length}>{inline(para.join(" "))}</p>);
    }
  }
  return <>{blocks}</>;
}

const storageKey = (company: string) => "serk.assistant." + company;

export function AssistantPanel({ company, csrf, screen, canConfigure, onClose, openDraft, onDrafts }: {
  company: string; csrf: string; screen: string; canConfigure: boolean; onClose: () => void; openDraft: (d: Draft) => void; onDrafts?: () => void;
}) {
  const [status, setStatus] = useState<Status | null>(null);
  const [turns, setTurns] = useState<Turn[]>(() => {
    try { return JSON.parse(sessionStorage.getItem(storageKey(company)) ?? "[]") as Turn[]; } catch { return []; }
  });
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const end = useRef<HTMLDivElement>(null);
  useEffect(() => {
    api<Status>("/assistant/status", company).then(setStatus).catch(() => setStatus({ available: false, reason: "permission_denied" }));
  }, [company]);
  useEffect(() => {
    try { sessionStorage.setItem(storageKey(company), JSON.stringify(turns.slice(-30))); } catch { /* storage unavailable */ }
    end.current?.scrollIntoView({ block: "end" });
  }, [turns, company]);

  async function send(message: string) {
    const content = message.trim();
    if (!content || busy) return;
    const next: Turn[] = [...turns.filter((t) => !t.error), { role: "user", content }];
    setTurns(next);
    setText("");
    setBusy(true);
    try {
      // Only the text of earlier turns is sent; at most the last 20.
      const messages = next.slice(-20).map((t) => ({ role: t.role, content: t.content }));
      while (messages.length && messages[0].role !== "user") messages.shift();
      const res = await api<{ reply: string; drafts: Draft[]; steps: Step[] }>("/assistant/chat", company, { method: "POST", csrf, body: { messages, screen }, timeoutMs: 150000 });
      setTurns([...next, { role: "assistant", content: res.reply, drafts: res.drafts, steps: res.steps }]);
      if (res.drafts.length) onDrafts?.();
    } catch (e) {
      const msg = e instanceof APIError ? e.message : "The assistant did not answer. Try again.";
      setTurns([...next, { role: "assistant", content: msg, error: true }]);
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
          <div key={i} className={"assistant-turn " + t.role + (t.error ? " error" : "")}>
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
