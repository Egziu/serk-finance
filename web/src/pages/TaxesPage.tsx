import { useState, useEffect } from "react";
import type { GridColDef } from "@mui/x-data-grid";
import { DataTable } from "../DataTable";
import { api, money } from "../api";
import { AlertCircle } from "lucide-react";

type TaxAgency = { id: string; name: string; code: string };
type TaxRate = { id: string; agency_id: string; agency_name: string; name: string; code: string; rate_percent: string; active: boolean; effective_from: string };

type Props = { company: string; csrf: string; currencyPlaces?: number; currency?: string };

export function TaxesPage({ company, csrf, currencyPlaces=2, currency="ETB" }: Props) {
  const [agencies, setAgencies] = useState<TaxAgency[]>([]);
  const [rates, setRates] = useState<TaxRate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [liability, setLiability] = useState("0");

  const [isCreatingAgency, setIsCreatingAgency] = useState(false);
  const [isCreatingRate, setIsCreatingRate] = useState(false);

  const [agencyName, setAgencyName] = useState("");
  const [agencyCode, setAgencyCode] = useState("");

  const [rateName, setRateName] = useState("");
  const [rateCode, setRateCode] = useState("");
  const [ratePercent, setRatePercent] = useState("");
  const [rateEffective, setRateEffective] = useState("");
  const [rateAgency, setRateAgency] = useState("");

  async function load() {
    setLoading(true);
    try {
      const a = await api<TaxAgency[]>("/taxes/agencies", company);
      const r = await api<TaxRate[]>("/taxes/rates", company);
      const l = await api<{total_tax_liability: string}>("/taxes/liability", company);
      setAgencies(a);
      setRates(r);
      setLiability(l.total_tax_liability);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
  }, [company]);

  async function submitAgency(e: React.FormEvent) {
    e.preventDefault();
    try {
      await api("/taxes/agencies", company, {
        method: "POST",
        csrf,
        body: { name: agencyName, code: agencyCode }
      });
      setIsCreatingAgency(false);
      setAgencyName("");
      setAgencyCode("");
      void load();
    } catch (err: any) {
      setError(err.message);
    }
  }

  async function submitRate(e: React.FormEvent) {
    e.preventDefault();
    try {
      await api("/taxes/rates", company, {
        method: "POST",
        csrf,
        body: { agency_id: rateAgency, name: rateName, code: rateCode, rate_percent: ratePercent, effective_from: rateEffective }
      });
      setIsCreatingRate(false);
      setRateName("");
      setRateCode("");
      setRatePercent("");
      setRateEffective("");
      setRateAgency("");
      void load();
    } catch (err: any) {
      setError(err.message);
    }
  }

  const agencyCols: GridColDef<TaxAgency>[] = [
    { field: "code", headerName: "Code", width: 110, cellClassName: "mono-cell" },
    { field: "name", headerName: "Name", flex: 1, minWidth: 200 }
  ];

  const rateCols: GridColDef<TaxRate>[] = [
    { field: "code", headerName: "Code", width: 110, cellClassName: "mono-cell" },
    { field: "name", headerName: "Name", flex: 1, minWidth: 200 },
    { field: "agency_name", headerName: "Agency", width: 180 },
    { field: "rate_percent", headerName: "Rate %", width: 110, type: "number", valueFormatter: (v) => `${v}%` },
    { field: "effective_from", headerName: "Effective", width: 120 },
    { field: "active", headerName: "Active", type: "boolean", width: 100 }
  ];

  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">CONFIGURATION</div>
          <h1>Taxes & Rates</h1>
          <p>Manage tax authorities and calculation rates used for invoicing and bills.</p>
        </div>
      </div>

      {error && (
        <div className="error" role="alert">
          <AlertCircle size={18} />
          {error}
        </div>
      )}

      <div style={{ marginBottom: 32, padding: 24, background: 'var(--surface)', border: '1px solid var(--border)', borderRadius: 8, display: 'flex', flexDirection: 'column', gap: 8 }}>
        <h2 style={{ margin: 0, fontSize: 16, color: 'var(--text-muted)' }}>Current Tax Liability</h2>
        <div style={{ fontSize: 32, fontWeight: 600, color: 'var(--text)' }}>
          {currency} {money(liability,currencyPlaces)}
        </div>
        <p style={{ margin: 0, fontSize: 14, color: 'var(--text-muted)' }}>This is the total net balance of the Sales Tax Payable ledger account.</p>
      </div>

      {isCreatingAgency && (
        <div className="overlay">
          <section className="modal" role="dialog">
            <h2>New Tax Agency</h2>
            <form onSubmit={submitAgency}>
              <label>Name<input required value={agencyName} onChange={e => setAgencyName(e.target.value)} /></label>
              <label>Code<input required value={agencyCode} onChange={e => setAgencyCode(e.target.value)} /></label>
              <div className="form-actions">
                <button type="button" onClick={() => setIsCreatingAgency(false)}>Cancel</button>
                <button type="submit" className="primary">Create Agency</button>
              </div>
            </form>
          </section>
        </div>
      )}

      {isCreatingRate && (
        <div className="overlay">
          <section className="modal" role="dialog">
            <h2>New Tax Rate</h2>
            <form onSubmit={submitRate}>
              <label>Agency
                <select required value={rateAgency} onChange={e => setRateAgency(e.target.value)}>
                  <option value="" disabled>Select Agency...</option>
                  {agencies.map(a => <option key={a.id} value={a.id}>{a.name}</option>)}
                </select>
              </label>
              <label>Name<input required value={rateName} onChange={e => setRateName(e.target.value)} /></label>
              <label>Code<input required value={rateCode} onChange={e => setRateCode(e.target.value)} /></label>
              <label>Rate %<input type="number" step="0.01" required value={ratePercent} onChange={e => setRatePercent(e.target.value)} /></label>
              <label>Effective From<input type="date" required value={rateEffective} onChange={e => setRateEffective(e.target.value)} /></label>
              <div className="form-actions">
                <button type="button" onClick={() => setIsCreatingRate(false)}>Cancel</button>
                <button type="submit" className="primary">Create Rate</button>
              </div>
            </form>
          </section>
        </div>
      )}

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 24, marginBottom: 12 }}>
        <h2 style={{ fontSize: 16, margin: 0 }}>Tax Rates</h2>
        <button className="btn-primary" onClick={() => setIsCreatingRate(true)}>+ New Rate</button>
      </div>
      <DataTable<TaxRate>
        label="Tax Rates"
        columns={rateCols}
        rows={rates}
        loading={loading}
        getRowId={(r) => r.id}
        autoHeight
      />

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 40, marginBottom: 12 }}>
        <h2 style={{ fontSize: 16, margin: 0 }}>Tax Agencies</h2>
        <button className="btn-secondary" onClick={() => setIsCreatingAgency(true)}>+ New Agency</button>
      </div>
      <DataTable<TaxAgency>
        label="Tax Agencies"
        columns={agencyCols}
        rows={agencies}
        loading={loading}
        getRowId={(r) => r.id}
        autoHeight
      />
    </>
  );
}
