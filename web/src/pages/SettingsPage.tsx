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
      {canConfigure && <AISettings company={company} csrf={csrf} />}
    </>
  );
}

type AIConfig = { provider: string; model: string; base_url: string | null; key_set: boolean; updated_at: string } | null;

// Provider for the AI assistant. The key is sent once, encrypted by the server and never shown again.
function AISettings({ company, csrf }: { company: string; csrf: string }) {
  const [config, setConfig] = useState<AIConfig>(null);
  const [status, setStatus] = useState<{ available: boolean; configured_by?: string; model?: string; reason?: string } | null>(null);
  const [provider, setProvider] = useState("anthropic");
  const [model, setModel] = useState("");
  const [baseURL, setBaseURL] = useState("");
  const [key, setKey] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  async function refresh() {
    try {
      const c = await api<AIConfig>("/assistant/settings", company);
      setConfig(c);
      if (c) { setProvider(c.provider); setModel(c.model); setBaseURL(c.base_url ?? ""); }
    } catch (e) { setError(e instanceof Error ? e.message : "Could not load"); }
    api<any>("/assistant/status", company).then(setStatus).catch(() => setStatus(null));
  }
  useEffect(() => { void refresh(); }, [company]);
  async function save(clear = false) {
    setBusy(true); setError(""); setMessage("");
    try {
      await api("/assistant/settings", company, { method: "POST", csrf, body: { provider, model, base_url: baseURL, api_key: key, clear_key: clear, reason } });
      setKey(""); setReason(""); setMessage(clear ? "API key removed." : "Assistant settings saved.");
      await refresh();
    } catch (e) { setError(e instanceof Error ? e.message : "Could not save"); } finally { setBusy(false); }
  }
  return (
    <section className="panel" aria-label="AI assistant provider">
      <div className="panel-heading"><h2>AI assistant provider</h2>
        <span>{status?.available ? `Active · ${status.model} (${status.configured_by === "company" ? "company settings" : "server settings"})` : "Not active"}</span></div>
      <p className="muted panel-note">
        The assistant reads the books as the signed-in user and only prepares drafts. Questions and the figures it looks up are sent to the provider you choose.
        Use Claude (Anthropic) with an API key, or an OpenAI-compatible model server inside your office (for example Ollama) so data stays on your network.
      </p>
      {error && <div className="error" role="alert">{error}</div>}
      {message && <div className="notice success" role="status">{message}</div>}
      <div className="form-grid">
        <label>Provider<select aria-label="AI provider" value={provider} onChange={(e) => setProvider(e.target.value)}>
          <option value="anthropic">Claude (Anthropic)</option><option value="openai">OpenAI-compatible / office model server</option></select></label>
        <label>Model<input aria-label="AI model" value={model} placeholder={provider === "anthropic" ? "claude-sonnet-5-5" : "llama3.1"} onChange={(e) => setModel(e.target.value)} /></label>
        {provider === "openai" && <label>Server address<input aria-label="AI server address" value={baseURL} placeholder="http://localhost:11434/v1" onChange={(e) => setBaseURL(e.target.value)} /></label>}
        <label>API key {config?.key_set && <small>(a key is stored; leave empty to keep it)</small>}<input aria-label="AI API key" type="password" autoComplete="off" value={key} onChange={(e) => setKey(e.target.value)} /></label>
        <label style={{ gridColumn: "1 / -1" }}>Reason<input aria-label="AI settings reason" value={reason} maxLength={1000} onChange={(e) => setReason(e.target.value)} /></label>
      </div>
      <div className="detail-footer"><div>
        <button className="primary" disabled={busy || reason.trim().length < 3} onClick={() => void save()}>Save assistant settings</button>
        {config?.key_set && <button className="secondary" disabled={busy || reason.trim().length < 3} onClick={() => void save(true)}>Remove stored key</button>}
      </div></div>
    </section>
  );
}
