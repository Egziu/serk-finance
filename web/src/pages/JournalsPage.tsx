import { useState } from "react";
import { BookOpen, ShieldCheck, RefreshCw, ArrowUpRight } from "lucide-react";
import type { GridColDef, GridFilterModel } from "@mui/x-data-grid";
import { DataTable } from "../DataTable";
import { dateCol, dateTimeCol, moneyCol, statusCol } from "../columns";
import type { Reference, Journal } from "../types";
type Props = {
  reference: Reference | null;
  online: boolean;
  busy: boolean;
  navigate: (v: string) => void;
  reload: () => Promise<void>;
  journals: Journal[];
  capped: boolean;
  open: (j: Journal) => Promise<void>;
  places: (c: string) => number;
};
const STATES = ["DRAFT", "SUBMITTED", "APPROVED", "POSTED", "REVERSED", "VOIDED"];
const TABS: [string, string, string[]][] = [
  ["", "All journals", []],
  ["DRAFT", "Draft", ["DRAFT"]],
  ["SUBMITTED", "For review", ["SUBMITTED"]],
  ["APPROVED", "To post", ["APPROVED"]],
  ["POSTED", "Posted", ["POSTED", "REVERSED"]],
  ["VOIDED", "Voided", ["VOIDED"]],
];
const tabModel = (states: string[]): GridFilterModel =>
  states.length ? { items: [{ id: "tab", field: "effective_state", operator: "isAnyOf", value: states }] } : { items: [] };
export function JournalsPage({ reference, online, busy, navigate, reload, journals, capped, open, places }: Props) {
  const [filterModel, setFilterModel] = useState<GridFilterModel>({ items: [] });
  const [tab, setTab] = useState("");
  const columns: GridColDef<Journal>[] = [
    {
      field: "number",
      headerName: "Journal",
      minWidth: 170,
      renderCell: (p) => (
        <button className="journal-link" onClick={() => open(p.row)}>
          {p.row.number}
        </button>
      ),
    },
    { field: "description", headerName: "Description", flex: 2, minWidth: 220 },
    dateCol<Journal>("accounting_date", "Date"),
    statusCol<Journal>("effective_state", "Status", STATES),
    moneyCol<Journal>("debit_minor", "Debit total", (r) => r.debit_minor ?? "0", (r) => places(r.currency)),
    { field: "currency", headerName: "Currency", width: 100 },
    dateTimeCol<Journal>("created_at", "Created at"),
    {
      field: "open",
      headerName: "Open",
      width: 70,
      sortable: false,
      filterable: false,
      disableColumnMenu: true,
      disableExport: true,
      renderCell: (p) => (
        <button className="icon-button" aria-label={"Open " + p.row.number} onClick={() => open(p.row)}>
          <ArrowUpRight size={17} />
        </button>
      ),
    },
  ];
  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">GENERAL LEDGER</div>
          <h1>Journal workspace</h1>
          <p>Prepare with confidence. Review with clarity.</p>
        </div>
        <button className="secondary" aria-label="Refresh journals" disabled={busy} onClick={() => reload()}>
          <RefreshCw size={16} />
          Refresh
        </button>
      </div>
      <div className="intro-strip">
        <div className="intro-icon">
          <BookOpen size={22} />
        </div>
        <div>
          <strong>A clear path from entry to ledger.</strong>
          <p>Draft → Submit → Approve → Post</p>
        </div>
        <span className="strip-right">
          <ShieldCheck size={16} />
          Approval before posting
        </span>
      </div>
      <div className="tabs grid-tabs" aria-label="Journal status">
        {TABS.map(([v, label, states]) => (
          <button
            key={v}
            className={tab === v ? "tab chosen" : "tab"}
            onClick={() => {
              setTab(v);
              setFilterModel(tabModel(states));
            }}
          >
            {label}
          </button>
        ))}
      </div>
      <DataTable<Journal>
        label="Journals"
        rows={journals}
        columns={columns}
        loading={busy && !journals.length}
        filterModel={filterModel}
        onFilterModelChange={(m) => {
          setFilterModel(m);
          // A hand-made filter no longer matches a status tab.
          if (!(m.items.length === 1 && m.items[0].id === "tab")) setTab(m.items.length ? "-" : "");
        }}
        initialState={{ sorting: { sortModel: [{ field: "created_at", sort: "desc" }] } }}
        onAdd={reference?.permissions.create && online ? () => navigate("new") : undefined}
        addLabel="New journal"
        fileName="journals"
        footerNote={
          capped
            ? "Showing the newest 5,000 journals. Use the status tabs or filters to narrow the list."
            : "Amounts shown in original currency. Posted entries preserve their history; corrections use a linked reversal."
        }
      />
    </>
  );
}
