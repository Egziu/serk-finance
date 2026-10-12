import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { Integrity } from "../types";

export function IntegrityPage({ company, onError }: { company: string; onError: (e: unknown) => void }) {
  const [result, setResult] = useState<Integrity | null>(null);
  const [busy, setBusy] = useState(false);
  const request = useRef(0);
  async function load() {
    const seq = ++request.current; setBusy(true); setResult(null);
    try { const r = await api<Integrity>("/accounting/integrity", company); if (seq === request.current) setResult(r); }
    catch (e) { if (seq === request.current) onError(e); }
    finally { if (seq === request.current) setBusy(false); }
  }
  useEffect(() => { void load(); return () => { request.current++; }; }, []);
  return <>
    <div className="page-heading"><div><div className="eyebrow">FINANCIAL CONTROLS</div><h1>Ledger integrity</h1><p>Company-wide reconciliation of posted balances, audit records and local outbox events.</p></div><button className="primary" disabled={busy} onClick={() => void load()}>{busy ? "Checking…" : "Run checks"}</button></div>
    {result && <section className="panel"><div className="panel-heading"><h2>{result.ok ? "Local integrity checks passed" : "Integrity differences require review"}</h2><span>{new Date(result.checked_at).toLocaleString()}</span></div>
      <p className="report-note">{result.posted_journals} posted journals · {result.audit_events} audit events</p>
      <div className="table-wrap"><table><thead><tr><th>Control</th><th className="numeric">Exceptions</th></tr></thead><tbody>{[
        ["Unbalanced posted journals", result.unbalanced_posted_journals], ["Audit chain", result.audit_chain_errors], ["Audit head", result.audit_head_errors], ["Outbox linkage", result.outbox_mismatches], ["Journal event versions", result.journal_event_version_errors],
      ].map(([name, value]) => <tr key={name}><td>{name}</td><td className="numeric">{value}</td></tr>)}</tbody></table></div>
      <p className="report-note">{result.limitations}</p>
    </section>}
  </>;
}
