import { useEffect, useState } from "react";
import { api } from "../api";
import { when } from "../shared";

type Feature = { code: string; label: string; description: string; enabled: boolean; version: number; reason: string | null; updated_at: string | null };

// Company-level module switches. Who may use an enabled module is decided by roles
// (Users & roles); a switched-off module is refused for everyone, in the database.
export function SettingsPage({ company, csrf, canConfigure, onChanged }: { company: string; csrf: string; canConfigure: boolean; onChanged: () => Promise<void> }) {
  const [features, setFeatures] = useState<Feature[]>([]);
  const [pending, setPending] = useState<Feature | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [done, setDone] = useState("");
  useEffect(() => {
    api<Feature[]>("/organization/features", company).then(setFeatures).catch((e) => setError(e.message));
  }, [company]);
  async function save() {
    if (!pending) return;
    setBusy(true);
    setError("");
    try {
      setFeatures(await api<Feature[]>("/organization/features", company, { method: "POST", csrf, body: { feature: pending.code, enabled: !pending.enabled, reason } }));
      setDone(`${pending.label} is now ${pending.enabled ? "off" : "on"}.`);
      setPending(null);
      setReason("");
      await onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Change failed");
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">COMPANY SETTINGS</div>
          <h1>Modules &amp; features</h1>
          <p>
            Turn modules on or off for this company. Who can use an enabled module is set per role under Users &amp; roles. A module that is off is hidden and refused for
            everyone; its records are kept and return when it is switched back on. Every change needs a reason and is recorded in the audit history.
          </p>
        </div>
      </div>
      {error && <div className="error" role="alert">{error}</div>}
      {done && <div className="notice success" role="status">{done}</div>}
      <section className="panel">
        <div className="table-wrap">
          <table className="simple-table">
            <thead><tr><th>Module</th><th>What it covers</th><th>Status</th><th>Last change</th><th /></tr></thead>
            <tbody>
              {features.map((f) => (
                <tr key={f.code}>
                  <td><strong>{f.label}</strong></td>
                  <td>{f.description}</td>
                  <td><span className={"badge " + (f.enabled ? "posted" : "voided")}><i />{f.enabled ? "on" : "off"}</span></td>
                  <td className="muted">{f.updated_at ? `${when(f.updated_at)} · ${f.reason}` : "Default"}</td>
                  <td>
                    {canConfigure && (
                      <button className="secondary compact" aria-label={`${f.enabled ? "Turn off" : "Turn on"} ${f.label}`} disabled={busy} onClick={() => { setPending(f); setReason(""); }}>
                        {f.enabled ? "Turn off" : "Turn on"}
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
      {pending && (
        <section className="panel" aria-label="Confirm module change">
          <div className="detail-footer">
            <div>
              <p>
                {pending.enabled ? "Turn off" : "Turn on"} <strong>{pending.label}</strong> for this company?
                {pending.enabled ? " Open documents in this module stay as they are but cannot be continued until it is turned back on." : ""}
              </p>
              <label>Reason<input aria-label="Change reason" value={reason} maxLength={1000} onChange={(e) => setReason(e.target.value)} /></label>
              <button className="primary" disabled={busy || reason.trim().length < 3} onClick={() => void save()}>Confirm</button>
              <button className="secondary" disabled={busy} onClick={() => setPending(null)}>Cancel</button>
            </div>
          </div>
        </section>
      )}
    </>
  );
}
