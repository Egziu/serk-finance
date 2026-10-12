import { useEffect, useState } from "react";
import { ArrowLeft, ArrowUpRight, ShieldCheck } from "lucide-react";
import { api } from "./api";
import { Icon } from "./shared";
type Challenge = { token: string; expires: number; devCode?: string };
export function Login({ onLogin }: { onLogin: (who: { tenant: string; email: string; mfa: boolean }) => Promise<void> }) {
  const [tenant, setTenant] = useState(""),
    [email, setEmail] = useState(""),
    [password, setPassword] = useState(""),
    [code, setCode] = useState(""),
    [challenge, setChallenge] = useState<Challenge | null>(null),
    [left, setLeft] = useState(0),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  // Step two is only valid while the server's challenge lives (5 minutes).
  useEffect(() => {
    if (!challenge) return;
    const tick = () => {
      const s = Math.max(0, Math.round((challenge.expires - Date.now()) / 1000));
      setLeft(s);
      if (s === 0) {
        setChallenge(null);
        setCode("");
        setError("The sign-in step expired. Enter your password again.");
      }
    };
    tick();
    const t = setInterval(tick, 1000);
    return () => clearInterval(t);
  }, [challenge]);
  async function run(step: () => Promise<void>) {
    setBusy(true);
    setError("");
    try {
      await step();
    } catch (e) {
      setError(e instanceof Error ? e.message : "Sign-in failed.");
    } finally {
      setBusy(false);
    }
  }
  const start = () =>
    run(async () => {
      const res = await api<{ mfa_required?: boolean; mfa_token?: string; expires_in?: number; dev_code?: string }>("/auth/login", undefined, {
        method: "POST",
        body: { tenant, email, password },
      });
      setPassword("");
      if (res.mfa_required && res.mfa_token) {
        setChallenge({ token: res.mfa_token, expires: Date.now() + (res.expires_in ?? 300) * 1000, devCode: res.dev_code });
        return;
      }
      await onLogin({ tenant, email, mfa: false });
    });
  const verify = () =>
    run(async () => {
      if (!challenge) return;
      try {
        await api("/auth/login/mfa", undefined, {
          method: "POST",
          body: { mfa_token: challenge.token, code },
        });
      } finally {
        setCode("");
      }
      setChallenge(null);
      await onLogin({ tenant, email, mfa: true });
    });
  const restart = () => {
    setChallenge(null);
    setCode("");
    setError("");
  };
  return (
    <div className="login-page">
      <div className="login-story">
        <div className="brand">
          <Icon size={24} />
          <span>
            SERK <b>Finance</b>
          </span>
        </div>
        <div className="login-statement">
          <div className="eyebrow">CLARITY. CONTROL. CONFIDENCE.</div>
          <h1>
            Every decision
            <br />
            starts with
            <br />
            <em>financial truth.</em>
          </h1>
          <p>The Financial Operating System for Africa.</p>
        </div>
        <div className="login-bottom">
          <ShieldCheck size={18} />A clear record. A stronger business.
        </div>
      </div>
      <main className="login-main">
        {!challenge ? (
          <form
            className="login-form"
            onSubmit={(e) => {
              e.preventDefault();
              void start();
            }}
          >
            <div className="eyebrow">YOUR FINANCIAL WORKSPACE</div>
            <h2>Welcome back.</h2>
            <p>Sign in to SERK Finance.</p>
            {error && (
              <div className="error" role="alert">
                {error}
              </div>
            )}
            <label>
              Workspace
              <input
                name="tenant"
                autoComplete="organization"
                required
                maxLength={63}
                value={tenant}
                onChange={(e) => setTenant(e.target.value)}
                placeholder="Company workspace"
              />
            </label>
            <label>
              Email
              <input
                name="email"
                type="email"
                autoComplete="username"
                required
                maxLength={254}
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </label>
            <label>
              Password
              <input
                name="password"
                type="password"
                autoComplete="current-password"
                required
                maxLength={256}
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
            </label>
            <button className="primary wide" disabled={busy}>
              {busy ? "Signing in…" : "Sign in"}
              <ArrowUpRight size={17} />
            </button>
            <div className="login-help">
              Access is assigned by your company administrator.
            </div>
          </form>
        ) : (
          <form
            className="login-form"
            onSubmit={(e) => {
              e.preventDefault();
              void verify();
            }}
          >
            <div className="eyebrow">TWO-STEP VERIFICATION</div>
            <h2>Enter your code.</h2>
            <p>
              Open your authenticator app and enter the 6-digit code for <strong>{email}</strong>.
            </p>
            {error && (
              <div className="error" role="alert">
                {error}
              </div>
            )}
            {challenge.devCode && (
              <div className="dev-code" role="status">
                <span>
                  <strong>Development mode</strong> — your current code is
                </span>
                <b>{challenge.devCode.slice(0, 3) + " " + challenge.devCode.slice(3)}</b>
                <button type="button" className="text-button" onClick={() => setCode(challenge.devCode!)}>
                  Use this code
                </button>
                <small>Shown because the server runs with SERK_DEV_SHOW_OTP. Codes change every 30 seconds; if it is refused, go back and sign in again.</small>
              </div>
            )}
            <label>
              Authenticator code
              <input
                name="code"
                autoFocus
                required
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="[0-9]{6}"
                maxLength={6}
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                placeholder="6-digit code"
              />
            </label>
            <button className="primary wide" disabled={busy || code.length !== 6}>
              {busy ? "Verifying…" : "Verify code"}
              <ArrowUpRight size={17} />
            </button>
            <div className="login-help">
              This step expires in {Math.floor(left / 60)}:{String(left % 60).padStart(2, "0")}. Each code works once; after five
              wrong codes, start again.
            </div>
            <button type="button" className="text-button" disabled={busy} onClick={restart}>
              <ArrowLeft size={15} />
              Use a different account
            </button>
          </form>
        )}
      </main>
    </div>
  );
}
