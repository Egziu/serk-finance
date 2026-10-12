import { RefreshCw } from "lucide-react";
import type { GridColDef } from "@mui/x-data-grid-pro";
import { DataTable } from "../DataTable";
import { dateTimeCol } from "../columns";
import { person } from "../shared";
import type { Audit, Session } from "../types";
type Props = {
  loadAudit: () => Promise<void>;
  busy: boolean;
  audit: Audit[];
  capped: boolean;
  me: Session;
  onOpen: (id: string) => void;
};
const change = (a: Audit) => {
  const from = a.previous_state?.state, to = a.new_state?.state;
  return from || to ? `${from ? from.toLowerCase() : "new"} → ${to ? to.toLowerCase() : "—"}` : "";
};
function Evidence({ a }: { a: Audit }) {
  const rows: [string, string | undefined][] = [
    ["Event hash", a.event_hash],
    ["Previous hash", a.previous_hash || "— (first event)"],
    ["Request", a.request_context?.request_id],
    ["Source address", a.request_context?.remote_ip],
    ["Browser", a.request_context?.user_agent],
    ["Record id", a.entity_id],
    ["Actor id", a.actor_id],
  ];
  return (
    <dl className="evidence-panel">
      {rows
        .filter(([, v]) => v)
        .map(([k, v]) => (
          <div key={k}>
            <dt>{k}</dt>
            <dd className={k === "Browser" ? "" : "mono"}>{v}</dd>
          </div>
        ))}
    </dl>
  );
}
export function AuditPage({ loadAudit, busy, audit, capped, me, onOpen }: Props) {
  const actions = [...new Set(audit.map((a) => a.action))].sort();
  const columns: GridColDef<Audit>[] = [
    {
      field: "sequence_no",
      headerName: "Event",
      type: "number",
      align: "left",
      headerAlign: "left",
      minWidth: 230,
      valueFormatter: (_v, a) => `#${a.sequence_no} · ${a.action}`,
      renderCell: (p) => <strong>{p.formattedValue}</strong>,
    },
    { field: "action", headerName: "Action", type: "singleSelect", valueOptions: actions, minWidth: 170 },
    {
      field: "record",
      headerName: "Record",
      minWidth: 170,
      valueGetter: (_v, a) => a.new_state?.number ?? a.previous_state?.number ?? a.entity_id.slice(0, 8),
      renderCell: (p) =>
        p.row.action.startsWith("journals.") && (p.row.new_state?.number || p.row.previous_state?.number) ? (
          <button className="report-link" onClick={() => onOpen(p.row.entity_id)}>
            {p.value}
          </button>
        ) : (
          <span className="mono">{p.value}</span>
        ),
    },
    { field: "change", headerName: "Change", minWidth: 170, valueGetter: (_v, a) => change(a) },
    { field: "actor", headerName: "By", minWidth: 150, valueGetter: (_v, a) => person(a.actor_id, me) },
    dateTimeCol<Audit>("recorded_at", "Recorded at"),
    { field: "reason", headerName: "Reason", flex: 2, minWidth: 220 },
    {
      field: "event_hash",
      headerName: "Evidence hash",
      minWidth: 150,
      renderCell: (p) => (
        <span className="mono" title={p.value}>
          {String(p.value).slice(0, 12)}…
        </span>
      ),
    },
  ];
  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">CONTROL & ASSURANCE</div>
          <h1>Audit history</h1>
          <p>Actor, reason, sequence, and evidence for each transition. Each event is chained to the one before it. Expand a row for its evidence.</p>
        </div>
        <button className="secondary" onClick={() => loadAudit()} disabled={busy}>
          <RefreshCw size={16} />
          Refresh
        </button>
      </div>
      <DataTable<Audit>
        label="Audit history"
        rows={audit}
        columns={columns}
        loading={busy && !audit.length}
        initialState={{
          sorting: { sortModel: [{ field: "sequence_no", sort: "desc" }] },
          pinnedColumns: { left: ["__detail_panel_toggle__", "sequence_no"] },
        }}
        detailPanel={(a) => <Evidence a={a} />}
        fileName="audit-history"
        footerNote={capped ? "Showing the first 10,000 events. Use filters to find older records." : undefined}
      />
    </>
  );
}
