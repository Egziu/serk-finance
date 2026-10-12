import { useEffect, useState } from "react";
import { CalendarCheck2, RefreshCw } from "lucide-react";
import { api, money } from "../api";
import { Badge, person, when } from "../shared";
import type { Reference, Session } from "../types";

type FiscalYear = { id: string; name: string; start_date: string; end_date: string };
type Closing = {
  id: string; fiscal_year_id: string; state: string; version: number; net_result_minor: string;
  requested_by: string; approved_by: string | null; reason: string; created_at: string; journal_ids: string[];
};
type Reopening = { id: string; period_id: string; state: string; version: number; requested_by: string; approved_by: string | null; reason: string; created_at: string };
type Preview = {
  fiscal_year: FiscalYear; final_period: { id: string; name: string; state: string } | null;
  profit_minor: string; blockers: string[]; ready: boolean;
  accounts: { account_id: string; code: string; name: string; type: string; balance_minor: string }[];
};
type Overview = { fiscal_years: FiscalYear[]; year_closings: Closing[]; period_reopenings: Reopening[] };

const blockerText: Record<string, string> = {
  no_periods: "The fiscal year has no periods.",
  final_period_not_open: "The final period must still be open; the close posts into it and then closes it.",
  earlier_periods_open: "Close every earlier period of the year first.",
  unfinished_journals: "Finish or void every draft, submitted and approved journal in the year.",
  close_already_requested: "A close for this year is already requested or posted.",
};

type Props = { company: string; csrf: string; reference: Reference | null; me: Session; places: number; currency: string; onChanged: () => Promise<void> };

export function PeriodEndPage({ company, csrf, reference, me, places, currency, onChanged }: Props) {
  const [data, setData] = useState<Overview | null>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [retained, setRetained] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [done, setDone] = useState("");
  const equity = (reference?.accounts ?? []).filter((a) => a.type === "EQUITY" && a.active && a.posting_allowed);
  const periodName = (id: string) => reference?.periods.find((p) => p.id === id)?.name ?? id.slice(0, 8);
  const yearName = (id: string) => data?.fiscal_years.find((y) => y.id === id)?.name ?? id.slice(0, 8);

  async function load() {
    setError("");
    try {
      setData(await api<Overview>("/accounting/period-end", company));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load period-end status");
    }
  }
  useEffect(() => {
    void load();
  }, [company]);

  async function run(label: string, fn: () => Promise<unknown>) {
    setBusy(true);
    setError("");
    setDone("");
    try {
      await fn();
      setDone(label);
      await load();
      await onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Action failed");
    } finally {
      setBusy(false);
    }
  }
  const post = (path: string, body: unknown) => api(path, company, { method: "POST", csrf, key: crypto.randomUUID(), body });

  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">CONTROL · IAS 1 / IAS 10</div>
          <h1>Year-end &amp; reopening</h1>
          <p>
            Close a fiscal year by transferring its profit or loss to retained earnings, and reopen a closed period for an adjusting entry. Both need a second person to approve.
          </p>
        </div>
        <button className="secondary" onClick={() => void load()} disabled={busy}>
          <RefreshCw size={16} />
          Refresh
        </button>
      </div>
      {error && <div className="error" role="alert">{error}</div>}
      {done && <div className="notice success" role="status">{done}</div>}

      <section className="panel">
        <div className="panel-heading"><h2>Fiscal years</h2></div>
        <div className="table-wrap"><table className="simple-table">
          <thead><tr><th>Year</th><th>Dates</th><th>Close status</th><th /></tr></thead>
          <tbody>
            {(data?.fiscal_years ?? []).map((y) => {
              const c = data?.year_closings.find((x) => x.fiscal_year_id === y.id && x.state !== "VOIDED");
              return (
                <tr key={y.id}>
                  <td><strong>{y.name}</strong></td>
                  <td>{y.start_date} – {y.end_date}</td>
                  <td>{c ? <Badge state={c.state === "POSTED" ? "CLOSED" : c.state} /> : <span className="muted">open</span>}</td>
                  <td>
                    {!c && reference?.permissions.close && (
                      <button className="secondary compact" disabled={busy} aria-label={`Preview close ${y.name}`}
                        onClick={() => void run("", async () => { setPreview(await api<Preview>(`/accounting/fiscal-years/${y.id}/close-preview`, company)); setReason(""); })}>
                        Preview close
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table></div>
      </section>

      {preview && (
        <section className="panel" aria-label="Year-end close preview">
          <div className="panel-heading"><h2><CalendarCheck2 size={18} /> Close {preview.fiscal_year.name}</h2></div>
          <div className="detail-footer">
            <div>
              <p>
                Profit for the year: <strong>{currency} {money(preview.profit_minor, places)}</strong>. The close posts one entry per branch dated{" "}
                {preview.fiscal_year.end_date}, moving every income and expense balance to retained earnings, then closes {preview.final_period?.name ?? "the final period"}.
              </p>
              {preview.accounts.length > 0 && (
                <div className="table-wrap"><table className="simple-table">
                  <thead><tr><th>Account</th><th>Type</th><th className="num">Balance closed</th></tr></thead>
                  <tbody>
                    {preview.accounts.map((a) => (
                      <tr key={a.account_id}><td>{a.code} · {a.name}</td><td>{a.type.replaceAll("_", " ").toLowerCase()}</td><td className="num">{money(a.balance_minor, places)}</td></tr>
                    ))}
                  </tbody>
                </table></div>
              )}
              {!preview.ready ? (
                <ul role="alert" className="blockers">
                  {preview.blockers.map((b) => <li key={b}>{blockerText[b] ?? b}</li>)}
                </ul>
              ) : (
                <>
                  <label>
                    Retained earnings account
                    <select value={retained} onChange={(e) => setRetained(e.target.value)}>
                      <option value="">Choose an equity account</option>
                      {equity.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
                    </select>
                  </label>
                  <label>
                    Reason
                    <input value={reason} maxLength={1000} onChange={(e) => setReason(e.target.value)} />
                  </label>
                  <button className="primary" disabled={busy || !retained || reason.trim().length < 3}
                    onClick={() => void run(`Close of ${preview.fiscal_year.name} requested. A second person must approve it.`, async () => {
                      await post("/accounting/year-close/request", { fiscal_year_id: preview.fiscal_year.id, retained_earnings_account_id: retained, reason });
                      setPreview(null);
                    })}>
                    Request year-end close
                  </button>
                </>
              )}
              <button className="secondary" disabled={busy} onClick={() => setPreview(null)}>Dismiss</button>
            </div>
          </div>
        </section>
      )}

      <section className="panel">
        <div className="panel-heading"><h2>Year-end closes</h2></div>
        <div className="table-wrap"><table className="simple-table">
          <thead><tr><th>Year</th><th className="num">Result</th><th>Status</th><th>Requested</th><th>Approved by</th><th /></tr></thead>
          <tbody>
            {(data?.year_closings ?? []).length === 0 && <tr><td colSpan={6} className="muted">No year-end closes yet.</td></tr>}
            {(data?.year_closings ?? []).map((c) => (
              <tr key={c.id}>
                <td>{yearName(c.fiscal_year_id)}</td>
                <td className="num">{money(c.net_result_minor, places)}</td>
                <td><Badge state={c.state} /></td>
                <td>{person(c.requested_by, me)} · {when(c.created_at)}</td>
                <td>{person(c.approved_by, me)}</td>
                <td>
                  {c.state === "SUBMITTED" && c.requested_by !== me.user_id && (
                    <button className="primary compact" disabled={busy} onClick={() => void run("Year-end close approved and posted.", () => post("/accounting/year-close/approve", { id: c.id, expected_version: c.version, reason: "Closing entries reviewed and approved" }))}>Approve close</button>
                  )}
                  {c.state === "SUBMITTED" && c.requested_by === me.user_id && (
                    <button className="secondary compact" disabled={busy} onClick={() => void run("Close request voided.", () => post("/accounting/year-close/void", { id: c.id, expected_version: c.version, reason: "Close request withdrawn" }))}>Void request</button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table></div>
      </section>

      <section className="panel">
        <div className="panel-heading"><h2>Period reopen requests</h2></div>
        <p className="muted panel-note">Request a reopen from Fiscal periods. A reopen is refused once the year has been closed.</p>
        <div className="table-wrap"><table className="simple-table">
          <thead><tr><th>Period</th><th>Status</th><th>Reason</th><th>Requested</th><th /></tr></thead>
          <tbody>
            {(data?.period_reopenings ?? []).length === 0 && <tr><td colSpan={5} className="muted">No reopen requests.</td></tr>}
            {(data?.period_reopenings ?? []).map((r) => (
              <tr key={r.id}>
                <td>{periodName(r.period_id)}</td>
                <td><Badge state={r.state} /></td>
                <td>{r.reason}</td>
                <td>{person(r.requested_by, me)} · {when(r.created_at)}</td>
                <td>
                  {r.state === "SUBMITTED" && r.requested_by !== me.user_id && (
                    <button className="primary compact" disabled={busy} onClick={() => void run("Period reopened.", () => post("/accounting/period-reopenings/approve", { id: r.id, expected_version: r.version, reason: "Reopen for adjusting entries approved" }))}>Approve reopen</button>
                  )}
                  {r.state === "SUBMITTED" && r.requested_by === me.user_id && (
                    <button className="secondary compact" disabled={busy} onClick={() => void run("Reopen request voided.", () => post("/accounting/period-reopenings/void", { id: r.id, expected_version: r.version, reason: "Request withdrawn" }))}>Void request</button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table></div>
      </section>
    </>
  );
}
