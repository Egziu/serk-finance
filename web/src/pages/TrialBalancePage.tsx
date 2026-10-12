import { Check, AlertCircle } from "lucide-react";
import type { GridColDef } from "@mui/x-data-grid";
import { DataTable } from "../DataTable";
import { moneyCol } from "../columns";
import { money } from "../api";
import type { Trial } from "../types";
type Row = Trial["rows"][number];
type Props = {
  asof: string;
  setAsof: (v: string) => void;
  from: string;
  setFrom: (v: string) => void;
  loadTrial: () => Promise<void>;
  busy: boolean;
  trial: Trial | null;
  companyName: string;
  places: (c: string) => number;
  onAccount: (id: string) => void;
};
const lower = (v: unknown) => (v ? String(v).replaceAll("_", " ").toLowerCase() : "—");
export function TrialBalancePage({ asof, setAsof, from, setFrom, loadTrial, busy, trial, companyName, places, onAccount }: Props) {
  const p = places(trial?.currency ?? "");
  const columns: GridColDef<Row>[] = [
    { field: "code", headerName: "Code", width: 100, cellClassName: "mono-cell" },
    {
      field: "name",
      headerName: "Account",
      flex: 2,
      minWidth: 200,
      renderCell: (c) => (
        <button className="report-link" onClick={() => onAccount(c.row.account_id)}>
          {c.row.name}
        </button>
      ),
    },
    { field: "type", headerName: "Type", type: "singleSelect", valueOptions: [...new Set(trial?.rows.map((r) => r.type) ?? [])], minWidth: 120, valueFormatter: lower },
    { field: "normal_balance", headerName: "Normal", type: "singleSelect", valueOptions: ["DEBIT", "CREDIT"], width: 110, valueFormatter: lower },
    moneyCol<Row>("debit_minor", "Debit activity", (r) => r.debit_minor, () => p),
    moneyCol<Row>("credit_minor", "Credit activity", (r) => r.credit_minor, () => p),
    moneyCol<Row>("net_debit_minor", "Net debit", (r) => r.net_debit_minor, () => p),
  ];
  const balanced = !!trial && trial.debit_minor === trial.credit_minor;
  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">FINANCIAL REPORTS</div>
          <h1>Trial balance</h1>
          <p>Posted ledger balances, in functional currency. Leave "From" empty for balances since the beginning.</p>
        </div>
        <form
          className="inline-form"
          onSubmit={(e) => {
            e.preventDefault();
            void loadTrial();
          }}
        >
          <label>
            From
            <input aria-label="From date" type="date" value={from} max={asof} onChange={(e) => setFrom(e.target.value)} />
          </label>
          <label>
            As of
            <input aria-label="As of date" type="date" value={asof} onChange={(e) => setAsof(e.target.value)} />
          </label>
          <button className="primary" disabled={busy}>
            Run report
          </button>
        </form>
      </div>
      {trial && (
        <>
          <div className="report-caption">
            <strong>{companyName}</strong>
            <span>
              {trial.currency} · {trial.from ? trial.from + " to " : "as of "}
              {trial.as_of}
            </span>
          </div>
          <DataTable<Row>
            label="Trial balance"
            rows={trial.rows}
            columns={columns}
            getRowId={(r) => r.account_id}
            loading={busy}
            initialState={{ sorting: { sortModel: [{ field: "code", sort: "asc" }] } }}
            fileName={"trial-balance-" + trial.as_of}
            pageSize={100}
            height={540}
          />
          <section className="panel totals-panel">
            <div className="table-wrap">
              <table>
                <tfoot>
                  <tr>
                    <td>Total activity</td>
                    <td className="numeric">Debits {money(trial.debit_minor, p)}</td>
                    <td className="numeric">Credits {money(trial.credit_minor, p)}</td>
                    <td className="numeric">Difference {money((BigInt(trial.debit_minor) - BigInt(trial.credit_minor)).toString(), p)}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
            <div className={"report-check" + (balanced ? "" : " warn")}>
              {balanced ? <Check size={17} /> : <AlertCircle size={17} />}
              {balanced ? "Debits and credits reconcile." : "A reconciliation difference requires review."}
            </div>
          </section>
        </>
      )}
    </>
  );
}
