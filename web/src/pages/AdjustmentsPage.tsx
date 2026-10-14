import { useEffect, useMemo, useState } from "react";
import { Plus, RefreshCw, Trash2 } from "lucide-react";
import { api, minor, money } from "../api";
import { Badge, person, today, when } from "../shared";
import type { Reference, Session } from "../types";

type Adjustment = {
  id: string; number: string; purpose: string; accounting_date: string; description: string; state: string; version: number;
  total_minor: string; created_by: string; submitted_by: string | null; approved_by: string | null; created_at: string; journal_id: string | null;
};
type Item = { id: string; name: string; type: string; asset_account_id: string | null; stock_quantity?: string; stock_value_minor?: string; reserved_quantity?: string; reserved_minor?: string };
type Line = { account_id: string; debit: string; credit: string; description: string; item_id: string; quantity_delta: string };

const purposes: [string, string, string][] = [
  ["TAX_SETTLEMENT", "VAT / tax settlement", "Remit output VAT, offset input VAT, or pay withholding tax to the tax authority."],
  ["PAYROLL_SETTLEMENT", "Payroll remittance", "Pay net salaries, PAYE and pension contributions that payroll recorded as liabilities."],
  ["RECEIVABLE_ADJUSTMENT", "Receivable write-off", "Write off an uncollectible customer balance or record an expected credit loss."],
  ["PAYABLE_ADJUSTMENT", "Payable adjustment", "Correct or settle a supplier balance outside a bill payment."],
  ["INVENTORY_ADJUSTMENT", "Inventory adjustment", "Stock count differences and write-downs to net realisable value (IAS 2). Quantity and value move together."],
  ["OPENING_BALANCE", "Opening balances", "Enter receivable, payable and tax balances when you start using the system."],
];
const blank = (account_id = ""): Line => ({ account_id, debit: "", credit: "", description: "", item_id: "", quantity_delta: "" });
// Control purposes each kind may touch (finance.adjustment_controls in the database).
const allowedControls: Record<string, string[]> = {
  TAX_SETTLEMENT: ["output_tax", "input_tax"], PAYROLL_SETTLEMENT: ["payroll_payable", "payroll_tax", "pension_payable"],
  RECEIVABLE_ADJUSTMENT: ["receivable"], PAYABLE_ADJUSTMENT: ["payable"], INVENTORY_ADJUSTMENT: ["inventory"],
  OPENING_BALANCE: ["receivable", "payable", "output_tax", "input_tax", "payroll_payable", "payroll_tax", "pension_payable"],
};
type Settings = { accounts?: Record<string, any>; reserved_accounts?: { purpose: string; account_id: string }[] };

type Props = { company: string; csrf: string; reference: Reference | null; me: Session; places: number; currency: string };

export function AdjustmentsPage({ company, csrf, reference, me, places, currency }: Props) {
  const [rows, setRows] = useState<Adjustment[]>([]);
  const [items, setItems] = useState<Item[]>([]);
  const [open, setOpen] = useState(false);
  const [purpose, setPurpose] = useState("TAX_SETTLEMENT");
  const [branch, setBranch] = useState("");
  const [date, setDate] = useState(today());
  const [number, setNumber] = useState("");
  const [description, setDescription] = useState("");
  const [reason, setReason] = useState("");
  const [lines, setLines] = useState<Line[]>([blank(), blank()]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [done, setDone] = useState("");
  const [settings, setSettings] = useState<Settings>({});
  const usable = (reference?.accounts ?? []).filter((a) => a.active && a.posting_allowed);
  // Only accounts this kind of adjustment may use: ordinary accounts plus its own control accounts.
  const accounts = useMemo(() => {
    const allowed = allowedControls[purpose] ?? [];
    const reserved = (settings.reserved_accounts ?? []).filter((r) => r.purpose !== "cash");
    return usable.filter((a) => {
      const purposes = reserved.filter((r) => r.account_id === a.id).map((r) => r.purpose);
      return purposes.length ? purposes.some((p) => allowed.includes(p)) : !a.control_account;
    }).sort((a, b) => a.code.localeCompare(b.code));
  }, [usable, settings, purpose]);
  // A starting layout for each kind; the preparer still enters amounts and may change accounts.
  function template(kind: string): Line[] {
    const m = settings.accounts ?? {}, cash = (m.cash_accounts ?? [])[0] ?? "";
    const find = (re: RegExp, types: string[]) => usable.find((a) => types.includes(a.type) && re.test(a.name))?.id ?? "";
    const inventory = items.find((i) => i.type === "PRODUCT" && i.asset_account_id)?.asset_account_id ?? "";
    switch (kind) {
      case "TAX_SETTLEMENT": return [blank(m.output_tax), blank(m.input_tax), blank(cash)];
      case "PAYROLL_SETTLEMENT": return [blank(m.payroll_payable), blank(m.payroll_tax), blank(m.pension_payable), blank(cash)];
      case "RECEIVABLE_ADJUSTMENT": return [blank(find(/impair|bad debt|doubtful|credit loss/i, ["EXPENSE", "OTHER_EXPENSE"])), blank(m.receivable)];
      case "PAYABLE_ADJUSTMENT": return [blank(m.payable), blank(find(/other income/i, ["OTHER_INCOME", "REVENUE"]))];
      case "INVENTORY_ADJUSTMENT": return [blank(find(/write-down|shrink|inventory loss|stock loss/i, ["COST_OF_SALES", "EXPENSE", "OTHER_EXPENSE"])), blank(inventory)];
      case "OPENING_BALANCE": return [blank(m.receivable), blank(m.opening_equity)];
      default: return [blank(), blank()];
    }
  }
  const choose = (kind: string) => { setPurpose(kind); setLines(template(kind)); };
  const inventoryAccounts = useMemo(() => new Set(items.filter((i) => i.type === "PRODUCT" && i.asset_account_id).map((i) => i.asset_account_id as string)), [items]);

  async function load() {
    try {
      setRows(await api<Adjustment[]>("/finance/adjustments", company));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load adjustments");
    }
    try {
      setItems(await api<Item[]>("/inventory/items", company));
    } catch {
      setItems([]);
    }
    try {
      setSettings(await api<Settings>("/finance/settings", company));
    } catch {
      setSettings({});
    }
  }
  useEffect(() => {
    void load();
    setBranch(reference?.branches[0]?.id ?? "");
  }, [company, reference]);

  const totals = useMemo(() => {
    let d = 0n, c = 0n, ok = true;
    for (const l of lines) {
      try {
        if (l.debit) d += BigInt(minor(l.debit, places));
        if (l.credit) c += BigInt(minor(l.credit, places));
      } catch {
        ok = false;
      }
    }
    return { d, c, ok };
  }, [lines, places]);

  async function act(label: string, fn: () => Promise<unknown>) {
    setBusy(true);
    setError("");
    setDone("");
    try {
      await fn();
      setDone(label);
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Action failed");
    } finally {
      setBusy(false);
    }
  }
  const post = (path: string, body: unknown) => api<Adjustment>(path, company, { method: "POST", csrf, key: crypto.randomUUID(), body });
  const step = (a: Adjustment, action: string, why: string) => post(`/finance/adjustments/${action}`, { id: a.id, expected_version: a.version, reason: why });
  const set = (i: number, patch: Partial<Line>) => setLines(lines.map((l, n) => (n === i ? { ...l, ...patch } : l)));
  // Counted stock moves at moving weighted-average cost (IAS 2); suggest exactly what the server
  // recomputes at approval: unreserved value / unreserved quantity, the exact remainder when the
  // whole unreserved balance is removed. Found stock with no average yet keeps a typed cost.
  function suggestCost(i: number, qtyText: string) {
    const l = lines[i], item = items.find((it) => it.id === l.item_id), q = Number(qtyText);
    if (!item || !q || !Number.isFinite(q) || item.stock_value_minor === undefined) return set(i, { quantity_delta: qtyText });
    const availQty = Number(item.stock_quantity ?? 0) - Number(item.reserved_quantity ?? 0);
    const availValue = BigInt(item.stock_value_minor) - BigInt(item.reserved_minor ?? "0");
    if (availQty <= 0) return set(i, { quantity_delta: qtyText });
    const minorCost = -q === availQty ? availValue : BigInt(Math.round((Number(availValue) * Math.abs(q)) / availQty));
    const major = (Number(minorCost) / 10 ** places).toFixed(places);
    set(i, q < 0 ? { quantity_delta: qtyText, credit: major, debit: "" } : { quantity_delta: qtyText, debit: major, credit: "" });
  }

  async function create() {
    const payload = lines.map((l) => {
      const out: Record<string, string> = {
        account_id: l.account_id,
        debit_minor: l.debit ? minor(l.debit, places) : "0",
        credit_minor: l.credit ? minor(l.credit, places) : "0",
        description: l.description,
      };
      if (inventoryAccounts.has(l.account_id)) {
        out.item_id = l.item_id;
        out.quantity_delta = l.quantity_delta || "0";
      }
      return out;
    });
    await post("/finance/adjustments/create", { purpose, branch_id: branch, accounting_date: date, number, description, reason, lines: payload });
    setOpen(false);
    setLines(template(purpose));
    setNumber("");
    setDescription("");
    setReason("");
  }

  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">CONTROLLED ACCOUNTS</div>
          <h1>Adjustments &amp; settlements</h1>
          <p>
            Receivable, payable, VAT, payroll and inventory accounts only accept entries from their own modules. Use an adjustment to remit taxes and payroll liabilities,
            write off receivables, write down inventory or enter opening balances. A second person approves every adjustment.
          </p>
        </div>
        <div className="toolbar">
          <button className="secondary" onClick={() => void load()} disabled={busy}><RefreshCw size={16} />Refresh</button>
          <button className="primary" onClick={() => { if (!open) setLines(template(purpose)); setOpen(!open); }} disabled={busy}><Plus size={16} />New adjustment</button>
        </div>
      </div>
      {error && <div className="error" role="alert">{error}</div>}
      {done && <div className="notice success" role="status">{done}</div>}

      {open && (
        <section className="panel" aria-label="New adjustment">
          <div className="panel-heading"><h2>New adjustment</h2></div>
          <p className="muted panel-note">{purposes.find((p) => p[0] === purpose)?.[2]} The usual accounts are filled in; enter the amounts and check each line.</p>
          <div className="form-grid">
            <label>Kind<select aria-label="Adjustment kind" value={purpose} onChange={(e) => choose(e.target.value)}>{purposes.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
            <label>Branch<select aria-label="Branch" value={branch} onChange={(e) => setBranch(e.target.value)}>{(reference?.branches ?? []).map((b) => <option key={b.id} value={b.id}>{b.code} · {b.name}</option>)}</select></label>
            <label>Accounting date<input aria-label="Accounting date" type="date" value={date} onChange={(e) => setDate(e.target.value)} /></label>
            <label>Reference number<input aria-label="Reference number" value={number} maxLength={100} onChange={(e) => setNumber(e.target.value)} placeholder="e.g. VAT-2026-09" /></label>
            <label style={{ gridColumn: "1 / -1" }}>Description<input aria-label="Adjustment description" value={description} maxLength={500} onChange={(e) => setDescription(e.target.value)} /></label>
          </div>
          <div className="line-editor">
            <div className="line-row head"><span>Account</span><span>Debit</span><span>Credit</span><span>Item (inventory only)</span><span>Qty change</span><span /></div>
            {lines.map((l, i) => {
              const inventory = inventoryAccounts.has(l.account_id);
              return (
                <div className="line-row" key={i}>
                  <select aria-label={`Adjustment account ${i + 1}`} value={l.account_id} onChange={(e) => set(i, { account_id: e.target.value, item_id: "", quantity_delta: "" })}>
                    <option value="">Choose account</option>
                    {accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
                  </select>
                  <input aria-label={`Adjustment debit ${i + 1}`} inputMode="decimal" value={l.debit} onChange={(e) => set(i, { debit: e.target.value, credit: e.target.value ? "" : l.credit })} />
                  <input aria-label={`Adjustment credit ${i + 1}`} inputMode="decimal" value={l.credit} onChange={(e) => set(i, { credit: e.target.value, debit: e.target.value ? "" : l.debit })} />
                  <select aria-label={`Adjustment item ${i + 1}`} disabled={!inventory} value={l.item_id} onChange={(e) => set(i, { item_id: e.target.value })}>
                    <option value="">{inventory ? "Choose item" : "—"}</option>
                    {items.filter((it) => it.asset_account_id === l.account_id).map((it) => <option key={it.id} value={it.id}>{it.name}</option>)}
                  </select>
                  <input aria-label={`Adjustment quantity ${i + 1}`} disabled={!inventory} inputMode="decimal" placeholder={inventory ? "0" : ""} value={l.quantity_delta} onChange={(e) => suggestCost(i, e.target.value)} />
                  <button className="icon-btn" aria-label={`Remove line ${i + 1}`} disabled={lines.length <= 2} onClick={() => setLines(lines.filter((_, n) => n !== i))}><Trash2 size={16} /></button>
                </div>
              );
            })}
            <button className="secondary compact" onClick={() => setLines([...lines, blank()])}><Plus size={14} />Add line</button>
          </div>
          <div className="totals-row">
            <span>Debits {currency} {money(totals.d.toString(), places)}</span>
            <span>Credits {currency} {money(totals.c.toString(), places)}</span>
            <span className={totals.ok && totals.d === totals.c && totals.d > 0n ? "" : "bad"}>
              {!totals.ok ? "Check amounts" : totals.d === 0n && totals.c === 0n ? "Enter amounts" : totals.d === totals.c ? "Balanced" : "Difference " + money((totals.d - totals.c).toString(), places)}
            </span>
          </div>
          <div className="form-grid">
            <label style={{ gridColumn: "1 / -1" }}>Reason / supporting reference<input aria-label="Adjustment reason" value={reason} maxLength={1000} onChange={(e) => setReason(e.target.value)} /></label>
          </div>
          <div className="detail-footer">
            <div>
              <button className="primary" disabled={busy || !totals.ok || totals.d !== totals.c || totals.d === 0n || !number.trim() || !description.trim() || reason.trim().length < 3}
                onClick={() => void act("Adjustment saved as draft. Submit it for approval.", create)}>Save draft</button>
              <button className="secondary" onClick={() => setOpen(false)}>Cancel</button>
            </div>
          </div>
        </section>
      )}

      <section className="panel">
        <div className="table-wrap">
          <table className="simple-table">
            <thead><tr><th>Number</th><th>Kind</th><th>Date</th><th>Description</th><th className="num">Amount</th><th>Status</th><th>Prepared</th><th /></tr></thead>
            <tbody>
              {rows.length === 0 && <tr><td colSpan={8} className="muted">No adjustments yet.</td></tr>}
              {rows.map((a) => (
                <tr key={a.id}>
                  <td><strong>{a.number}</strong></td>
                  <td>{purposes.find((p) => p[0] === a.purpose)?.[1] ?? a.purpose}</td>
                  <td>{a.accounting_date}</td>
                  <td>{a.description}</td>
                  <td className="num">{money(a.total_minor, places)}</td>
                  <td><Badge state={a.state} /></td>
                  <td>{person(a.created_by, me)} · {when(a.created_at)}</td>
                  <td>
                    {a.state === "DRAFT" && a.created_by === me.user_id && (
                      <button className="primary compact" disabled={busy} onClick={() => void act("Adjustment submitted for approval.", () => step(a, "submit", "Prepared with supporting documents"))}>Submit</button>
                    )}
                    {a.state === "SUBMITTED" && a.created_by !== me.user_id && a.submitted_by !== me.user_id && (
                      <button className="primary compact" disabled={busy} onClick={() => void act("Adjustment approved and posted.", () => step(a, "approve", "Reviewed supporting documents"))}>Approve &amp; post</button>
                    )}
                    {["DRAFT", "SUBMITTED"].includes(a.state) && a.created_by === me.user_id && (
                      <button className="secondary compact" disabled={busy} onClick={() => void act("Adjustment voided.", () => step(a, "void", "Withdrawn by preparer"))}>Void</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </>
  );
}
