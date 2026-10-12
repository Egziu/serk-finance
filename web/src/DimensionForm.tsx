import { useState } from "react";
import { AlertCircle, X } from "lucide-react";
import { api } from "./api";

type Props = {
  company: string;
  csrf: string;
  onClose: () => void;
  onSuccess: () => void;
};

export function DimensionForm({ company, csrf, onClose, onSuccess }: Props) {
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  
  const [kind, setKind] = useState("COST_CENTER");
  const [code, setCode] = useState("");
  const [name, setName] = useState("");

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!code.trim() || !name.trim()) return;
    setBusy(true);
    setError("");
    try {
      await api("/organization/dimensions", company, { 
        method: "POST", 
        body: { kind: kind, code: code.trim(), name: name.trim() }, 
        csrf 
      });
      onSuccess();
    } catch (err: any) {
      setError(err.message || "An error occurred");
      setBusy(false);
    }
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2>New dimension</h2>
          <button type="button" className="icon-btn" onClick={onClose}><X size={20} /></button>
        </div>
        
        {error && (
          <div className="alert error">
            <AlertCircle size={16} />
            {error}
          </div>
        )}

        <form onSubmit={submit} className="form-stack">
          <label>
            Kind
            <select value={kind} onChange={(e) => setKind(e.target.value)} disabled={busy}>
              <option value="DEPARTMENT">Department</option>
              <option value="COST_CENTER">Cost Center</option>
              <option value="PROJECT">Project</option>
              <option value="CONTRACT">Contract</option>
            </select>
          </label>
          <label>
            Code
            <input type="text" required value={code} onChange={(e) => setCode(e.target.value)} disabled={busy} placeholder="e.g. MKT01" />
          </label>
          <label>
            Name
            <input type="text" required value={name} onChange={(e) => setName(e.target.value)} disabled={busy} placeholder="e.g. Marketing Department" />
          </label>
          
          <div className="form-actions">
            <button type="button" className="btn-secondary" onClick={onClose} disabled={busy}>Cancel</button>
            <button type="submit" className="btn-primary" disabled={busy || !code.trim() || !name.trim()}>Create Dimension</button>
          </div>
        </form>
      </div>
    </div>
  );
}

