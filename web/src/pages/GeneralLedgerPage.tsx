import { useEffect, useRef, useState } from "react";
import type { GridColDef } from "@mui/x-data-grid-pro";
import { api, money } from "../api";
import { today } from "../shared";
import { DataTable } from "../DataTable";
import { dateCol, moneyCol } from "../columns";
import type { GeneralLedger, Reference } from "../types";

type Row = GeneralLedger["rows"][number];
type Props = { company: string; reference: Reference; initialAccount: string; asOf: string; onOpen: (id: string) => void; onError: (e: unknown) => void };
const MAX_ROWS = 20000;
export function GeneralLedgerPage({ company, reference, initialAccount, asOf, onOpen, onError }: Props) {
  const [account, setAccount] = useState(initialAccount || reference.accounts[0]?.id || "");
  const [from, setFrom] = useState(reference.periods[0]?.start_date || today().slice(0, 4) + "-01-01");
  const [asof, setAsof] = useState(asOf || today());
  const [report, setReport] = useState<GeneralLedger | null>(null);
  const [busy, setBusy] = useState(false);
  const request = useRef(0);
  const places = reference.currencies.find((c) => c.code === report?.currency)?.minor_units ?? 2;
  // Follows the server cursor until every line in the range is loaded, so the grid can sort and filter all of it.
  async function load() {
    if (!account) return;
    const seq = ++request.current;
    setBusy(true);
    try {
      const q = new URLSearchParams({ account_id: account, from, as_of: asof, limit: "100" });
      let data = await api<GeneralLedger>("/reports/general-ledger?" + q, company);
      const rows = [...data.rows];
      while (data.has_more && data.next_cursor && rows.length < MAX_ROWS && seq === request.current) {
        Object.entries(data.next_cursor).forEach(([k, v]) => q.set(k, String(v)));
        data = await api<GeneralLedger>("/reports/general-ledger?" + q, company);
        rows.push(...data.rows);
      }
      if (seq === request.current) setReport({ ...data, rows });
    } catch (e) {
      if (seq === request.current) {
        setReport(null);
        onError(e);
      }
    } finally {
      if (seq === request.current) setBusy(false);
    }
  }
  useEffect(() => {
    void load();
    return () => {
      request.current++;
    };
  }, []);
  function changed(set: (v: string) => void, value: string) {
    set(value);
    setReport(null);
  }
  const columns: GridColDef<Row>[] = [
    dateCol<Row>("accounting_date", "Date"),
    {
      field: "number",
      headerName: "Journal",
      minWidth: 170,
      renderCell: (p) => (
        <button className="report-link" onClick={() => onOpen(p.row.journal_id)}>
          {p.row.number}
        </button>
      ),
    },
    { field: "line_no", headerName: "Line", type: "number", width: 80 },
    {
      field: "description",
      headerName: "Description",
      flex: 2,
      minWidth: 220,
      valueGetter: (_v, r) => (r.description || r.journal_description) + (r.is_rounding ? " · System rounding" : ""),
    },
    { field: "transaction_currency", headerName: "Txn currency", width: 120 },
    moneyCol<Row>("debit_minor", "Debit", (r) => r.debit_minor, () => places),
    moneyCol<Row>("credit_minor", "Credit", (r) => r.credit_minor, () => places),
    moneyCol<Row>("running_minor", "Running balance", (r) => r.running_minor, () => places, { sortable: false }),
  ];
  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">CONNECTED REPORTING</div>
          <h1>General ledger</h1>
          <p>Opening balance, posted movements and source-journal drill-down.</p>
        </div>
      </div>
      <form
        className="panel report-filters"
        onSubmit={(e) => {
          e.preventDefault();
          void load();
        }}
      >
        <label>
          Account
          <select aria-label="Ledger account" value={account} disabled={busy} onChange={(e) => changed(setAccount, e.target.value)}>
            {reference.accounts.map((a) => (
              <option key={a.id} value={a.id}>
                {a.code} · {a.name}
              </option>
            ))}
          </select>
        </label>
        <label>
          From
          <input aria-label="Ledger from date" type="date" required value={from} disabled={busy} onChange={(e) => changed(setFrom, e.target.value)} />
        </label>
        <label>
          As of
          <input aria-label="Ledger as of date" type="date" required value={asof} disabled={busy} onChange={(e) => changed(setAsof, e.target.value)} />
        </label>
        <button className="primary" disabled={busy || !account}>
          {busy ? "Loading…" : "Run ledger"}
        </button>
      </form>
      {report && (
        <>
          <section className="panel">
            <div className="panel-heading">
              <h2>
                {report.account.code} · {report.account.name}
              </h2>
              <span>
                {report.currency} · {report.from} to {report.as_of}
              </span>
            </div>
            {!report.company_wide && <p className="notice">Branch-restricted view. These are only the entries your role can access.</p>}
            <dl className="ledger-totals">
              {[
                ["Opening", report.opening_minor],
                ["Debits", report.debit_minor],
                ["Credits", report.credit_minor],
                ["Closing", report.closing_minor],
              ].map(([label, value]) => (
                <div key={label}>
                  <dt>{label}</dt>
                  <dd>{money(value, places)}</dd>
                </div>
              ))}
            </dl>
          </section>
          <DataTable<Row>
            label="General ledger lines"
            rows={report.rows}
            columns={columns}
            getRowId={(r) => r.journal_id + ":" + r.line_no}
            loading={busy}
            fileName={`general-ledger-${report.account.code}-${report.as_of}`}
            footerNote={
              (report.rows.length >= MAX_ROWS ? `Showing the first ${MAX_ROWS.toLocaleString()} lines; narrow the dates to see the rest. ` : "") +
              "Balances are debit minus credit; negative balances are credits. The running balance follows posting order. Re-run for a fresh view."
            }
          />
        </>
      )}
    </>
  );
}
