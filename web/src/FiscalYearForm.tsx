import { useState } from "react";
import { AlertCircle, X } from "lucide-react";
import { api } from "./api";

type Props = {
  company: string;
  csrf: string;
  onClose: () => void;
  onSuccess: () => void;
};

export function FiscalYearForm({ company, csrf, onClose, onSuccess }: Props) {
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  
  const [name, setName] = useState(new Date().getFullYear().toString());
  const [startDate, setStartDate] = useState(`${new Date().getFullYear()}-01-01`);
  const [endDate, setEndDate] = useState(`${new Date().getFullYear()}-12-31`);

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError("");
    setBusy(true);

    try {
      await api("/accounting/fiscal-years", company, {
        method: "POST",
        csrf,
        body: {
          name,
          start_date: startDate,
          end_date: endDate,
        }
      });
      onSuccess();
    } catch (err: any) {
      setError(err.message || "Failed to create fiscal year");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="modal-overlay">
      <div className="modal">
        <div className="modal-header">
          <h2>Create Fiscal Year</h2>
          <button className="icon-button" onClick={onClose}><X size={20} /></button>
        </div>
        <form onSubmit={submit} className="stack">
          {error && <div className="alert alert-error"><AlertCircle size={16} />{error}</div>}
          
          <div className="input-group">
            <label>Fiscal Year Name</label>
            <input required maxLength={200} value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. FY 2026" />
          </div>
          
          <div className="two-panels">
            <div className="input-group">
              <label>Start Date</label>
              <input required type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)} />
            </div>
            <div className="input-group">
              <label>End Date</label>
              <input required type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)} min={startDate} />
            </div>
          </div>
          
          <div className="alert alert-info">
            <strong>Note:</strong> 12 standard monthly periods will be automatically generated between the start and end dates you choose.
          </div>

          <div className="modal-footer">
            <button type="button" className="btn-secondary" onClick={onClose} disabled={busy}>Cancel</button>
            <button type="submit" className="btn-primary" disabled={busy}>Create Fiscal Year</button>
          </div>
        </form>
      </div>
    </div>
  );
}
