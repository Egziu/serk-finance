import { ArrowLeft, ShieldCheck } from "lucide-react";
import { Badge, person, when } from "../shared";
import { money } from "../api";
import type { Journal, Reference, Session } from "../types";
type Props = {
  selected: Journal;
  reference: Reference | null;
  me: Session;
  locked: boolean;
  busy: boolean;
  online: boolean;
  navigate: (v: string) => void;
  openJournal: (id: string) => void;
  places: (c: string) => number;
  setAction: (v: string) => void;
  setReason: (v: string) => void;
};
export function JournalDetail({
  selected,
  reference,
  me,
  locked,
  busy,
  online,
  navigate,
  openJournal,
  places,
  setAction,
  setReason,
}: Props) {
  const branch = reference?.branches.find((b) => b.id === selected.branch_id);
  const period = reference?.periods.find((p) => p.id === selected.period_id);
  const dimension = (id: string) => reference?.dimensions?.find((d) => d.id === id);
  const sum = (k: "debit_minor" | "credit_minor" | "functional_debit_minor" | "functional_credit_minor") =>
    (selected.lines ?? []).reduce((a, l) => a + BigInt(l[k]), 0n).toString();
  const actions = (["submit", "approve", "post", "reverse", "void"] as const).filter(
    (a) =>
      selected.permissions?.[a] &&
      {
        submit: selected.state === "DRAFT",
        approve: selected.state === "SUBMITTED",
        post: selected.state === "APPROVED",
        reverse: selected.state === "POSTED" && selected.effective_state !== "REVERSED",
        void: !["POSTED", "VOIDED"].includes(selected.state),
      }[a],
  );
  const source = selected.source_document;
  const sourceView: Record<string, [string, string]> = {
    INVOICE: ["sales", "sales invoice"], BILL: ["purchases", "supplier bill"], PAYROLL: ["payroll", "payroll run"],
    OPENING: ["inventory", "stock opening"], ADJUSTMENT: ["adjustments", "adjustment"], YEAR_CLOSE: ["period-end", "year-end close"],
  };
  const roleText: Record<string, string> = { payment: "the payment of ", reversal: "the reversal of ", payment_reversal: "the payment reversal of " };
  const moduleEntry = selected.source_type === "SYSTEM" || selected.source_type === "CLOSING" || (selected.source_type === "REVERSAL" && !!source);
  const ownSubmitted = selected.state === "SUBMITTED" && selected.created_by === me.user_id;
  const trail: [string, string | null | undefined][] = [
    ["Prepared by", selected.created_by],
    ["Submitted by", selected.submitted_by],
    ["Approved by", selected.approved_by],
    ["Posted by", selected.posted_by],
  ];
  return (
    <>
      <button className="back" onClick={() => navigate("journals")} disabled={locked}>
        <ArrowLeft size={15} />
        All journals
      </button>
      <div className="page-heading">
        <div>
          <div className="eyebrow">JOURNAL ENTRY</div>
          <h1>{selected.number}</h1>
          <p>{selected.description}</p>
        </div>
        <Badge state={selected.effective_state} />
      </div>
      <div className="journal-meta">
        <div>
          <small>ACCOUNTING DATE</small>
          <strong>{selected.accounting_date}</strong>
        </div>
        <div>
          <small>PERIOD</small>
          <strong>{period ? `${period.name} · ${period.state.toLowerCase()}` : "—"}</strong>
        </div>
        <div>
          <small>BRANCH</small>
          <strong>{branch ? branch.name : "—"}</strong>
        </div>
        <div>
          <small>CURRENCY</small>
          <strong>{selected.currency}</strong>
        </div>
        <div>
          <small>EXCHANGE RATE</small>
          <strong>{selected.fx_rate}</strong>
        </div>
        <div>
          <small>VERSION</small>
          <strong>{selected.version}</strong>
        </div>
      </div>
      <section className="panel">
        <div className="panel-heading">
          <h2>Journal lines</h2>
          <span>{selected.currency} · original currency</span>
        </div>
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Account</th>
                <th>Description</th>
                <th className="numeric">Debit</th>
                <th className="numeric">Credit</th>
                <th className="numeric">Debit ({selected.functional_currency})</th>
                <th className="numeric">Credit ({selected.functional_currency})</th>
              </tr>
            </thead>
            <tbody>
              {selected.lines?.map((l, i) => (
                <tr key={i}>
                  <td>
                    <strong>{l.account_code}</strong> {l.account_name}
                  </td>
                  <td>
                    {l.description || "—"}
                    {l.is_rounding && " · System rounding"}
                    {!!l.dimensions?.length && (
                      <small className="secondary-line">
                        {l.dimensions
                          .map((d) => {
                            const x = dimension(d.dimension_id);
                            return d.kind.replaceAll("_", " ").toLowerCase() + ": " + (x ? `${x.code} ${x.name}` : d.dimension_id.slice(0, 8));
                          })
                          .join(" · ")}
                      </small>
                    )}
                  </td>
                  <td className="numeric">{money(l.debit_minor, places(selected.currency))}</td>
                  <td className="numeric">{money(l.credit_minor, places(selected.currency))}</td>
                  <td className="numeric">{money(l.functional_debit_minor, places(selected.functional_currency))}</td>
                  <td className="numeric">{money(l.functional_credit_minor, places(selected.functional_currency))}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan={2}>Total</td>
                <td className="numeric">{money(sum("debit_minor"), places(selected.currency))}</td>
                <td className="numeric">{money(sum("credit_minor"), places(selected.currency))}</td>
                <td className="numeric">{money(sum("functional_debit_minor"), places(selected.functional_currency))}</td>
                <td className="numeric">{money(sum("functional_credit_minor"), places(selected.functional_currency))}</td>
              </tr>
            </tfoot>
          </table>
        </div>
      </section>
      <section className="panel">
        <div className="panel-heading">
          <h2>Control trail</h2>
          <span>
            {selected.source_type ? selected.source_type.toLowerCase() + " entry · " : ""}created {when(selected.created_at)}
          </span>
        </div>
        <dl className="control-trail">
          {trail.map(([label, id]) => (
            <div key={label}>
              <dt>{label}</dt>
              <dd>{person(id, me)}</dd>
            </div>
          ))}
          <div>
            <dt>Posted at</dt>
            <dd>{when(selected.posted_at)}</dd>
          </div>
        </dl>
      </section>
      <div className="detail-footer">
        <div>
          <small>Latest reason</small>
          <p>{selected.reason}</p>
          {selected.reversed_from && (
            <p>
              Reversal of{" "}
              <button className="report-link" disabled={locked} onClick={() => openJournal(selected.reversed_from!)}>
                the original journal
              </button>
            </p>
          )}
          {moduleEntry && (
            <p className="secondary-line" role="note">
              <ShieldCheck size={14} />{" "}
              {source && sourceView[source.kind]
                ? <>Posted by {roleText[source.role] ?? ""}{sourceView[source.kind][1]} <strong>{source.number}</strong>. Approve, reverse or void it from that screen.{" "}
                    <button className="report-link" disabled={locked} onClick={() => navigate(sourceView[source.kind][0])}>Open {sourceView[source.kind][1]}s</button></>
                : <>Posted by a module workflow (invoice, bill, payroll, adjustment or year-end close). Change it from that screen.</>}
            </p>
          )}
          {ownSubmitted && (
            <p className="secondary-line">
              <ShieldCheck size={14} /> You prepared this journal, so a different person must approve it.
            </p>
          )}
        </div>
        <div className="action-buttons">
          {actions.map((a) => (
            <button
              className={a === "void" ? "secondary" : "primary"}
              key={a}
              disabled={busy || !online || locked}
              onClick={() => {
                setAction(a);
                setReason("");
              }}
            >
              {a === "reverse" ? "Create reversal" : a[0].toUpperCase() + a.slice(1) + " journal"}
            </button>
          ))}
        </div>
      </div>
    </>
  );
}
