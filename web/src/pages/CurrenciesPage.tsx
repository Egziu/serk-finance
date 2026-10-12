import { useState, useEffect } from "react";
import type { GridColDef } from "@mui/x-data-grid";
import { DataTable } from "../DataTable";
import { api } from "../api";
import { AlertCircle } from "lucide-react";

type Currency = { code: string; name: string; symbol: string; active: boolean };
type ExchangeRate = { id: string; date: string; base_currency: string; foreign_currency: string; exchange_rate: string };

type Props = { company: string; csrf: string; currency?: string };

export function CurrenciesPage({ company, csrf, currency }: Props) {
  const functional = currency ?? "ETB";
  const [currencies, setCurrencies] = useState<Currency[]>([]);
  const [exchangeRates, setExchangeRates] = useState<ExchangeRate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const [isAddingRate, setIsAddingRate] = useState(false);
  const [date, setDate] = useState(new Date().toISOString().split('T')[0]);
  const [foreignCurrency, setForeignCurrency] = useState("");
  const [rate, setRate] = useState("");

  async function load() {
    setLoading(true);
    try {
      const [c, e] = await Promise.all([
        api<Currency[]>("/currencies", company),
        api<ExchangeRate[]>("/exchange-rates", company)
      ]);
      setCurrencies(c);
      setExchangeRates(e);
      if (c.length > 0 && !foreignCurrency) {
        setForeignCurrency(c.filter(cur => cur.code !== functional)[0]?.code || c[0].code);
      }
    } catch (e: any) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
  }, [company]);

  async function submitRate(e: React.FormEvent) {
    e.preventDefault();
    try {
      await api("/exchange-rates", company, {
        method: "POST",
        csrf,
        body: { date, foreign_currency: foreignCurrency, exchange_rate: rate }
      });
      setIsAddingRate(false);
      setRate("");
      void load();
    } catch (err: any) {
      setError(err.message);
    }
  }

  const rateCols: GridColDef<ExchangeRate>[] = [
    { field: "date", headerName: "Date", width: 120 },
    { field: "base_currency", headerName: "Base Currency", width: 120 },
    { field: "foreign_currency", headerName: "Foreign Currency", width: 150 },
    { field: "exchange_rate", headerName: "Exchange Rate", flex: 1 },
  ];

  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">SETUP & ADMIN</div>
          <h1>Currencies & Exchange Rates</h1>
          <p>Manage your foreign currencies and daily exchange rates.</p>
        </div>
        <div className="toolbar">
          <button className="btn-primary" onClick={() => setIsAddingRate(true)}>+ Add Daily Rate</button>
        </div>
      </div>

      {error && (
        <div className="error" role="alert">
          <AlertCircle size={18} />
          {error}
        </div>
      )}

      {isAddingRate && (
        <div className="overlay">
          <section className="modal" role="dialog" aria-label="New exchange rate" style={{ maxHeight: '90vh', overflowY: 'auto' }}>
            <h2>New Exchange Rate</h2>
            <form onSubmit={submitRate}>
              <label>Date<input aria-label="Rate date" type="date" required value={date} onChange={e => setDate(e.target.value)} /></label>
              <label>Foreign currency
                <select aria-label="Foreign currency" required value={foreignCurrency} onChange={e => setForeignCurrency(e.target.value)}>
                  {currencies.filter(c => c.code !== functional).map(c => <option key={c.code} value={c.code}>{c.code} - {c.name}</option>)}
                </select>
              </label>
              <label>{`Rate · ${functional} per 1 unit`}
                <input aria-label={`Rate · ${functional} per 1 unit`} type="number" step="any" min="0" required value={rate} onChange={e => setRate(e.target.value)} />
              </label>
              <div className="form-actions">
                <button type="button" onClick={() => setIsAddingRate(false)}>Cancel</button>
                <button type="submit" className="primary">Add Rate</button>
              </div>
            </form>
          </section>
        </div>
      )}

      <DataTable<ExchangeRate>
        label="Exchange Rates"
        columns={rateCols}
        rows={exchangeRates}
        loading={loading}
        getRowId={(r) => r.id}
        autoHeight
      />
    </>
  );
}
