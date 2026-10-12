import { useState } from "react";
import type { GridColDef } from "@mui/x-data-grid";
import { DataTable } from "../DataTable";
import { dateCol, statusCol } from "../columns";
import { api } from "../api";
import { FiscalYearForm } from "../FiscalYearForm";
import type { Period, Reference } from "../types";
type Preview = { period_id: string; version: number; state: string; unfinished: { draft: number; submitted: number; approved: number }; can_close: boolean };
type Props = { reference: Reference | null; company: string; csrf: string; onClosed: () => Promise<void>; refreshReference: () => void };
export function PeriodsPage({ reference, company, csrf, onClosed, refreshReference }: Props) {
  const [preview, setPreview] = useState<Preview | null>(null),
    [reason, setReason] = useState(""),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [done, setDone] = useState("");
  const [pending, setPending] = useState<{ id: string; version: number; reason: string; key: string } | null>(null);
  const [showForm, setShowForm] = useState(false);
  const [reopen, setReopen] = useState<Period | null>(null);
  const [reopenReason, setReopenReason] = useState("");
  async function requestReopen() {
    if (!reopen) return;
    setBusy(true);
    setError("");
    setDone("");
    try {
      await api("/accounting/period-reopenings/request", company, { method: "POST", csrf, key: crypto.randomUUID(), body: { period_id: reopen.id, reason: reopenReason } });
      setDone(`Reopen of ${reopen.name} requested. A second person approves it under Year-end & reopen.`);
      setReopen(null);
      setReopenReason("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Request failed");
    } finally {
      setBusy(false);
    }
  }
  const name = (id: string) => reference?.periods.find((p) => p.id === id)?.name ?? "";
  async function review(id: string) {
    setBusy(true);
    setError("");
    setDone("");
    try {
      setPreview(await api<Preview>(`/accounting/periods/${id}/close-preview`, company));
      setReason("");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Review failed");
    } finally {
      setBusy(false);
    }
  }
  async function close() {
    if (!preview) return;
    const request = pending ?? { id: preview.period_id, version: preview.version, reason, key: crypto.randomUUID() };
    setPending(request);
    setBusy(true);
    setError("");
    try {
      await api(`/accounting/periods/${request.id}/close`, company, {
        method: "POST",
        csrf,
        key: request.key,
        body: { expected_version: request.version, reason: request.reason },
      });
      setPending(null);
      setPreview(null);
      setDone(`Period ${name(request.id)} is closed.`);
      await onClosed();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Close failed");
    } finally {
      setBusy(false);
    }
  }
  const columns: GridColDef<Period>[] = [
    { field: "name", headerName: "Period", width: 110, renderCell: (p) => <strong>{p.value}</strong> },
    dateCol<Period>("start_date", "Start", { flex: 1 }),
    dateCol<Period>("end_date", "End", { flex: 1 }),
    statusCol<Period>("state", "Status", ["OPEN", "SOFT_CLOSED", "CLOSED", "LOCKED"], { flex: 1 }),
    { field: "version", headerName: "Version", type: "number", width: 100 },
    {
      field: "review",
      headerName: "Review",
      minWidth: 150,
      sortable: false,
      filterable: false,
      disableExport: true,
      renderCell: (p) =>
        reference?.permissions.close && ["OPEN", "SOFT_CLOSED"].includes(p.row.state) ? (
          <button className="secondary compact" disabled={busy || !!pending} onClick={() => void review(p.row.id)} aria-label={`Review close ${p.row.name}`}>
            Review close
          </button>
        ) : reference?.permissions.close && p.row.state === "CLOSED" ? (
          <button className="secondary compact" disabled={busy} onClick={() => { setReopen(p.row); setReopenReason(""); }} aria-label={`Request reopen ${p.row.name}`}>
            Request reopen
          </button>
        ) : null,
    },
  ];
  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">ACCOUNTING CALENDAR</div>
          <h1>Fiscal periods</h1>
          <p>Finish or void all draft, submitted and approved journals before closing. Closed periods cannot accept postings; a closed period can be reopened for adjusting entries with a second person's approval.</p>
        </div>
        <div className="toolbar">
          <button className="btn-primary" onClick={() => setShowForm(true)}>+ New fiscal year</button>
        </div>
      </div>
      {error && <div className="error" role="alert">{error}</div>}
      {done && <div className="notice success" role="status">{done}</div>}
      {showForm && (
        <FiscalYearForm 
          company={company} 
          csrf={csrf} 
          onClose={() => setShowForm(false)} 
          onSuccess={() => { setShowForm(false); refreshReference(); }} 
        />
      )}
      <DataTable<Period>
        label="Fiscal periods"
        rows={reference?.periods ?? []}
        columns={columns}
        loading={!reference}
        autoHeight
        initialState={{ sorting: { sortModel: [{ field: "start_date", sort: "asc" }] } }}
        fileName="fiscal-periods"
      />
      {reopen && (
        <section className="panel" aria-label="Request period reopen">
          <div className="panel-heading"><h2>Request reopen · {reopen.name}</h2></div>
          <div className="detail-footer">
            <div>
              <p>Use this for adjusting events (IAS 10) or auditor corrections. The period stays closed until another person approves the request.</p>
              <label>
                Reason
                <input aria-label="Reopen reason" value={reopenReason} maxLength={1000} onChange={(e) => setReopenReason(e.target.value)} />
              </label>
              <button className="primary" disabled={busy || reopenReason.trim().length < 3} onClick={() => void requestReopen()}>Request reopen</button>
              <button className="secondary" disabled={busy} onClick={() => setReopen(null)}>Cancel</button>
            </div>
          </div>
        </section>
      )}
      {preview && (
        <section className="panel">
          <div className="panel-heading">
            <h2>Period close review · {name(preview.period_id)}</h2>
          </div>
          <div className="detail-footer">
            <div>
              <p>
                Unfinished journals: {preview.unfinished.draft} draft, {preview.unfinished.submitted} submitted, {preview.unfinished.approved} approved.
              </p>
              {!preview.can_close ? (
                <p role="alert">Close is blocked. Finish or void these journals, then review again.</p>
              ) : (
                <>
                  <p>Check reconciliations and supporting records before confirming. Reopening later needs a second person's approval.</p>
                  <label>
                    Close reason
                    <input value={reason} disabled={!!pending || busy} maxLength={1000} onChange={(e) => setReason(e.target.value)} />
                  </label>
                  <button className="primary" disabled={busy || reason.trim().length < 3} onClick={() => void close()}>
                    {pending ? "Retry same close" : "Confirm period close"}
                  </button>
                </>
              )}
              <button
                className="secondary"
                disabled={busy}
                onClick={() => {
                  setPreview(null);
                  setPending(null);
                }}
              >
                {pending ? "Dismiss and review current state" : "Dismiss review"}
              </button>
            </div>
          </div>
        </section>
      )}
    </>
  );
}
