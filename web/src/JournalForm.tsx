import { useEffect, useState } from "react";
import {
  ArrowLeft,
  Plus,
  X,
  Check,
  AlertCircle,
  ChevronRight,
} from "lucide-react";
import { api, minor, money } from "./api";
import type { Reference } from "./types";
import { Badge, today } from "./shared";
type DraftLine = {
  account_id: string;
  description: string;
  debit: string;
  credit: string;
  dims: string[];
};
export function JournalForm({
  reference,
  currency,
  busy,
  locked,
  onSave,
  onCancel,
  company,
}: {
  company?: string;
  reference: Reference;
  currency: string;
  busy: boolean;
  locked: boolean;
  onSave: (p: unknown) => Promise<void>;
  onCancel: () => void;
}) {
  const [branch, setBranch] = useState(reference.branches.find((b) => b.active !== false)?.id ?? ""),
    [date, setDate] = useState(today()),
    [desc, setDesc] = useState(""),
    [reason, setReason] = useState(""),
    [curr, setCurr] = useState(currency),
    [rate, setRate] = useState("1"),
    [recorded, setRecorded] = useState<string | null>(null),
    [error, setError] = useState("");
  // Foreign-currency journals are checked against the recorded rate for their date (IAS 21),
  // so the form starts from that rate and says when none is recorded.
  useEffect(() => {
    if (!company || curr === currency) return;
    let live = true;
    api<{ rate: string | null }>(`/exchange-rates/recorded?currency=${curr}&date=${date}`, company)
      .then((r) => {
        if (!live) return;
        setRecorded(r.rate);
        if (r.rate) setRate(r.rate);
      })
      .catch(() => live && setRecorded(null));
    return () => {
      live = false;
    };
  }, [company, curr, date, currency]);
  const blank = (): DraftLine => ({
    account_id: "",
    description: "",
    debit: "",
    credit: "",
    dims: [],
  });
  const [lines, setLines] = useState<DraftLine[]>([blank(), blank()]);
  const places =
    reference.currencies.find((c) => c.code === curr)?.minor_units ?? 2;
  const update = (i: number, k: Exclude<keyof DraftLine, "dims">, v: string) =>
    setLines((ls) => ls.map((l, n) => (n === i ? { ...l, [k]: v } : l)));
  const dims = (reference.dimensions ?? []).filter((d) => d.active);
  const kinds = [...new Set(dims.map((d) => d.kind))];
  const setDims = (i: number, f: (d: string[]) => string[]) =>
    setLines((ls) => ls.map((l, n) => (n === i ? { ...l, dims: f(l.dims) } : l)));
  const period = reference.periods.find((p) => p.start_date <= date && date <= p.end_date);
  let dr = 0n,
    cr = 0n;
  try {
    for (const l of lines) {
      dr += BigInt(minor(l.debit || "0", places));
      cr += BigInt(minor(l.credit || "0", places));
    }
  } catch {}
  return (
    <>
      <button className="back" onClick={onCancel} disabled={locked || busy}>
        <ArrowLeft size={15} />
        All journals
      </button>
      <div className="page-heading">
        <div>
          <div className="eyebrow">GENERAL LEDGER</div>
          <h1>New journal</h1>
          <p>Record the entry. Add context. Send for review.</p>
        </div>
        <Badge state="DRAFT" />
      </div>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          setError("");
          try {
            if (curr !== currency && !/^(0|[1-9][0-9]{0,11})(\.[0-9]{1,12})?$/.test(rate))
              throw new Error("Enter the exchange rate as a number, for example 56.25.");
            lines.forEach((l, i) => {
              const d = BigInt(minor(l.debit || "0", places)), c = BigInt(minor(l.credit || "0", places));
              if (d > 0n && c > 0n) throw new Error(`Line ${i + 1} has both a debit and a credit. Use one side per line.`);
              if (d === 0n && c === 0n) throw new Error(`Line ${i + 1} has no amount.`);
            });
            if (dr !== cr) throw new Error("Debits and credits must be equal before saving.");
            const payload = {
              branch_id: branch,
              accounting_date: date,
              description: desc,
              currency: curr,
              fx_rate: curr === currency ? "1" : rate,
              reason,
              lines: lines.map((l) => ({
                account_id: l.account_id,
                description: l.description,
                debit_minor: minor(l.debit || "0", places),
                credit_minor: minor(l.credit || "0", places),
                ...(l.dims.length
                  ? { dimensions: l.dims.map((id) => ({ kind: dims.find((d) => d.id === id)!.kind, dimension_id: id })) }
                  : {}),
              })),
            };
            void onSave(payload);
          } catch (e) {
            setError(e instanceof Error ? e.message : "Check amounts.");
          }
        }}
      >
        {error && (
          <div className="error" role="alert">
            {error}
          </div>
        )}
        <fieldset disabled={busy || locked}>
          <section className="panel form-panel">
            <div className="form-grid">
              <label>
                Accounting date
                <input
                  type="date"
                  required
                  value={date}
                  onChange={(e) => setDate(e.target.value)}
                  aria-label="Accounting date"
                  aria-describedby="period-hint"
                />
                <small id="period-hint" className={"field-hint" + (period?.state === "OPEN" ? "" : " warn")}>
                  {period
                    ? `Period ${period.name} · ${period.state.toLowerCase()}` + (period.state === "OPEN" ? "" : " — this date cannot be used")
                    : "No accounting period covers this date"}
                </small>
              </label>
              <label>
                Branch
                <select
                  value={branch}
                  onChange={(e) => setBranch(e.target.value)}
                >
                  {reference.branches.filter((b) => b.active !== false).map((b) => (
                    <option key={b.id} value={b.id}>
                      {b.name}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Currency
                <select aria-label="Currency" value={curr} onChange={(e) => setCurr(e.target.value)}>
                  {reference.currencies.map((c) => (
                    <option key={c.code}>{c.code}</option>
                  ))}
                </select>
              </label>
              {curr !== currency && (
                <label>
                  Rate · {currency} per {curr}
                  <input
                    required
                    aria-label={`Rate · ${currency} per ${curr}`}
                    value={rate}
                    onChange={(e) => setRate(e.target.value)}
                  />
                  <small className="muted">
                    {recorded ? `Recorded rate for ${date}: ${recorded}` : `No ${curr} rate is recorded on or before ${date}. Add one under Currencies & Rates.`}
                  </small>
                </label>
              )}
              <label className="full">
                Description
                <input
                  required
                  maxLength={1000}
                  placeholder="What does this journal record?"
                  value={desc}
                  onChange={(e) => setDesc(e.target.value)}
                />
              </label>
            </div>
          </section>
          <section className="panel line-panel">
            <div className="panel-heading">
              <h2>Journal lines</h2>
              <span>{curr}</span>
            </div>
            <div className="table-wrap">
              <table className="entry-table">
                <thead>
                  <tr>
                    <th>Account</th>
                    <th>Description</th>
                    <th className="numeric">Debit</th>
                    <th className="numeric">Credit</th>
                    {kinds.length > 0 && <th>Dimensions</th>}
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {lines.map((l, i) => (
                    <tr key={i}>
                      <td>
                        <select
                          aria-label={"Account line " + (i + 1)}
                          required
                          value={l.account_id}
                          onChange={(e) =>
                            update(i, "account_id", e.target.value)
                          }
                        >
                          <option value="">Select account</option>
                          {reference.accounts
                            .filter(
                              (a) =>
                                a.active &&
                                a.posting_allowed &&
                                !a.control_account,
                            )
                            .map((a) => (
                              <option value={a.id} key={a.id}>
                                {a.code} · {a.name}
                              </option>
                            ))}
                        </select>
                      </td>
                      <td>
                        <input
                          aria-label={"Description line " + (i + 1)}
                          placeholder="Optional detail"
                          value={l.description}
                          onChange={(e) =>
                            update(i, "description", e.target.value)
                          }
                        />
                      </td>
                      <td>
                        <input
                          aria-label={"Debit line " + (i + 1)}
                          inputMode="decimal"
                          placeholder="0.00"
                          value={l.debit}
                          onChange={(e) => update(i, "debit", e.target.value)}
                        />
                      </td>
                      <td>
                        <input
                          aria-label={"Credit line " + (i + 1)}
                          inputMode="decimal"
                          placeholder="0.00"
                          value={l.credit}
                          onChange={(e) => update(i, "credit", e.target.value)}
                        />
                      </td>
                      {kinds.length > 0 && (
                        <td>
                          {l.dims.map((id) => {
                            const d = dims.find((x) => x.id === id)!;
                            return (
                              <button type="button" className="chip" key={id} aria-label={"Remove " + d.name} onClick={() => setDims(i, (ds) => ds.filter((x) => x !== id))}>
                                {d.code} <X size={12} />
                              </button>
                            );
                          })}
                          {l.dims.length < kinds.length && (
                            <select
                              aria-label={"Dimension line " + (i + 1)}
                              value=""
                              onChange={(e) => e.target.value && setDims(i, (ds) => [...ds, e.target.value])}
                            >
                              <option value="">Add…</option>
                              {kinds
                                .filter((k) => !l.dims.some((id) => dims.find((d) => d.id === id)?.kind === k))
                                .map((k) => (
                                  <optgroup key={k} label={k.replaceAll("_", " ").toLowerCase()}>
                                    {dims.filter((d) => d.kind === k).map((d) => (
                                      <option key={d.id} value={d.id}>
                                        {d.code} · {d.name}
                                      </option>
                                    ))}
                                  </optgroup>
                                ))}
                            </select>
                          )}
                        </td>
                      )}
                      <td>
                        <button
                          type="button"
                          className="icon-button"
                          aria-label={"Remove line " + (i + 1)}
                          disabled={lines.length <= 2}
                          onClick={() =>
                            setLines((ls) => ls.filter((_, n) => n !== i))
                          }
                        >
                          <X size={16} />
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr>
                    <td colSpan={2}>
                      <button
                        className="text-button"
                        type="button"
                        onClick={() => setLines((ls) => [...ls, blank()])}
                        disabled={lines.length >= 500}
                      >
                        <Plus size={16} />
                        Add line
                      </button>
                    </td>
                    <td className="numeric">{money(dr.toString(), places)}</td>
                    <td className="numeric">{money(cr.toString(), places)}</td>
                    {kinds.length > 0 && <td />}
                    <td />
                  </tr>
                </tfoot>
              </table>
            </div>
            <div
              className={
                "balance-check " + (dr === cr && dr > 0n ? "balanced" : "")
              }
            >
              <span>
                {dr === cr && dr > 0n ? (
                  <Check size={17} />
                ) : (
                  <AlertCircle size={17} />
                )}
              </span>
              {dr === cr && dr > 0n
                ? "Debits and credits balance."
                : "Difference: " +
                  money((dr - cr).toString(), places) +
                  " " +
                  curr}
            </div>
          </section>
          <label className="reason-field">
            Reason / supporting reference
            <textarea
              required
              minLength={3}
              maxLength={1000}
              placeholder="Explain the business purpose and reference the supporting record."
              value={reason}
              onChange={(e) => setReason(e.target.value)}
            />
          </label>
        </fieldset>
        <div className="form-actions">
          <span>Independent approval is required before posting.</span>
          <button className="primary" disabled={busy || !navigator.onLine}>
            {busy ? "Saving…" : locked ? "Retry same entry" : "Save draft"}
            <ChevronRight size={17} />
          </button>
        </div>
      </form>
    </>
  );
}
