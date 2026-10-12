import { useState } from "react";
import { AlertCircle, X } from "lucide-react";
import { api } from "./api";

type Props = {
  company: string;
  csrf: string;
  onClose: () => void;
  onSuccess: () => void;
};

export function BranchForm({ company, csrf, onClose, onSuccess }: Props) {
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  
  const [code, setCode] = useState("");
  const [name, setName] = useState("");

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!code.trim() || !name.trim()) return;
    setBusy(true);
    setError("");
    try {
      await api("/organization/branches", company, { 
        method: "POST", 
        body: { code: code.trim(), name: name.trim() }, 
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
          <h2>New branch</h2>
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
            Branch Code
            <input type="text" required value={code} onChange={(e) => setCode(e.target.value)} disabled={busy} placeholder="e.g. B01" />
          </label>
          <label>
            Name
            <input type="text" required value={name} onChange={(e) => setName(e.target.value)} disabled={busy} placeholder="e.g. HQ" />
          </label>
          
          <div className="form-actions">
            <button type="button" className="btn-secondary" onClick={onClose} disabled={busy}>Cancel</button>
            <button type="submit" className="btn-primary" disabled={busy || !code.trim() || !name.trim()}>Create Branch</button>
          </div>
        </form>
      </div>
    </div>
  );
}
