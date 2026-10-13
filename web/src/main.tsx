const DashboardPage = lazy(() => import("./pages/DashboardPage").then(m=>({default:m.DashboardPage})));
const FinancialStatementsPage = lazy(() => import("./pages/FinancialStatementsPage").then(m=>({default:m.FinancialStatementsPage})));
const AccessPage = lazy(() => import("./pages/AccessPage").then(m=>({default:m.AccessPage})));
const SalesPage = lazy(() => import("./pages/InvoicingPages").then(m=>({default:m.SalesPage})));
const PurchasesPage = lazy(() => import("./pages/InvoicingPages").then(m=>({default:m.PurchasesPage})));
const AccountsPage = lazy(() => import("./pages/AccountsPage").then(m=>({default:m.AccountsPage})));
const TaxesPage = lazy(() => import("./pages/TaxesPage").then(m=>({default:m.TaxesPage})));
const PayrollPage = lazy(() => import("./pages/PayrollPage").then(m=>({default:m.PayrollPage})));
const InventoryPage = lazy(() => import("./pages/InventoryPage").then(m=>({default:m.InventoryPage})));
const AuditPage = lazy(() => import("./pages/AuditPage").then(m=>({default:m.AuditPage})));
const GeneralLedgerPage = lazy(() => import("./pages/GeneralLedgerPage").then(m=>({default:m.GeneralLedgerPage})));
const IntegrityPage = lazy(() => import("./pages/IntegrityPage").then(m=>({default:m.IntegrityPage})));
const PeriodsPage = lazy(() => import("./pages/PeriodsPage").then(m=>({default:m.PeriodsPage})));
const TrialBalancePage = lazy(() => import("./pages/TrialBalancePage").then(m=>({default:m.TrialBalancePage})));
const CurrenciesPage = lazy(() => import("./pages/CurrenciesPage").then(m=>({default:m.CurrenciesPage})));
const JournalDetail = lazy(() => import("./pages/JournalDetail").then(m=>({default:m.JournalDetail})));
const SettingsPage = lazy(() => import("./pages/SettingsPage").then(m=>({default:m.SettingsPage})));
const PeriodEndPage = lazy(() => import("./pages/PeriodEndPage").then(m=>({default:m.PeriodEndPage})));
const AdjustmentsPage = lazy(() => import("./pages/AdjustmentsPage").then(m=>({default:m.AdjustmentsPage})));
const JournalsPage = lazy(() => import("./pages/JournalsPage").then(m=>({default:m.JournalsPage})));
import { Login } from "./Login";
import { JournalForm } from "./JournalForm";
import { ProfileModal, clearIdentity, loadIdentity, saveIdentity, type Identity } from "./Profile";
import { Icon, today } from "./shared";
import React, { useEffect, useState, useRef, lazy, Suspense } from "react";
import { createRoot } from "react-dom/client";
import { ThemeProvider, createTheme } from "@mui/material/styles";
import createCache from "@emotion/cache";
import { CacheProvider } from "@emotion/react";
import { nonce } from "./csp";
import {
  BookOpen,
  Calculator,
  Users,
  Package,
  Search,
  ShieldCheck,
  ChevronRight,
  Command,
  FileText,
  FileSpreadsheet,
  X,
  CalendarDays,
  AlertCircle,
  ListTree,
  History,
  BookOpenText,
  UserRound,
  UserCog,
  Scale,
  CalendarCheck2,
  Settings2,
} from "lucide-react";
import { api, APIError } from "./api";
import type { Session, Reference, Journal, Trial, Audit } from "./types";
import "./style.css";

const JOURNAL_CAP = 5000, AUDIT_CAP = 10000;
const styleCache = createCache({ key: "css", nonce, prepend: true });
const theme = createTheme({
  palette: { primary: { main: "#166453" }, text: { primary: "#203436", secondary: "#758584" }, divider: "#e3eae7" },
  typography: { fontFamily: 'Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif', fontSize: 13, button: { textTransform: "none", fontWeight: 500 } },
  shape: { borderRadius: 6 },
});
function App() {
  const [session, setSession] = useState<Session | null>(null),
    [company, setCompany] = useState(""),
    [loading, setLoading] = useState(true),
    [ref, setRef] = useState<Reference | null>(null);
  const [view, setView] = useState("journals"),
    [journals, setJournals] = useState<Journal[]>([]),
    [selected, setSelected] = useState<Journal | null>(null),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false),
    [palette, setPalette] = useState(false),
    [profileOpen, setProfileOpen] = useState(false),
    [identity, setIdentity] = useState<Identity | null>(loadIdentity),
    [online, setOnline] = useState(navigator.onLine);
  const [trial, setTrial] = useState<Trial | null>(null),
    [asof, setAsof] = useState(today()),
    [from, setFrom] = useState(""),
    [serverUp, setServerUp] = useState(true),
    [audit, setAudit] = useState<Audit[]>([]),
    [journalsCapped, setJournalsCapped] = useState(false),
    [auditCapped, setAuditCapped] = useState(false);
  const [action, setAction] = useState(""),
    [reason, setReason] = useState(""),
    [reversalDate, setReversalDate] = useState(today());
  const [pending, setPending] = useState<{
    path: string;
    body: unknown;
    key: string;
    company: string;
    csrf: string;
  } | null>(null);
  const scopeRef = useRef(company);
  const [ledgerAccount, setLedgerAccount] = useState("");
  scopeRef.current = company;
  const current = session?.companies.find((c) => c.id === company),
    places = (curr: string) =>
      ref?.currencies.find((c) => c.code === curr)?.minor_units ?? 2;
  function report(e: unknown) {
    setError(e instanceof Error ? e.message : "Request failed.");
    if (e instanceof APIError && e.status === 401) {
      setSession(null);
      setCompany("");
      setRef(null);
      setJournals([]);
      setSelected(null);
      setTrial(null);
      setAudit([]);
    }
  }
  async function loadSession() {
    try {
      const s = await api<Session>("/session");
      setSession(s);
      setCompany(s.companies[0]?.id ?? "");
    } catch (e) {
      if (!(e instanceof APIError && e.status === 401)) report(e);
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => {
    void loadSession();
    const update = () => setOnline(navigator.onLine);
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
    };
  }, []);
  // Readiness probe: shows when the API or its database is unavailable.
  useEffect(() => {
    let active = true;
    const probe = () =>
      fetch("/health/ready", { cache: "no-store", signal: AbortSignal.timeout(5000) })
        .then((r) => active && setServerUp(r.ok))
        .catch(() => active && setServerUp(false));
    void probe();
    const t = setInterval(probe, 30000);
    const again = () => void probe();
    window.addEventListener("online", again);
    return () => {
      active = false;
      clearInterval(t);
      window.removeEventListener("online", again);
    };
  }, []);
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key === "k") {
        e.preventDefault();
        setPalette((p) => !p);
      }
      if (e.key === "Escape" && !busy && !pending) {
        setPalette(false);
        setAction("");
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [busy, pending]);
  useEffect(() => {
    if (!pending) return;
    const guard = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };
    window.addEventListener("beforeunload", guard);
    return () => window.removeEventListener("beforeunload", guard);
  }, [pending]);
  useEffect(() => {
    if (!company) return;
    let active = true;
    setRef(null);
    setJournals([]);
    setTrial(null);
    setAudit([]);
    setSelected(null);
    setView("journals");
    setError("");
    api<Reference>("/accounting/reference", company)
      .then((r) => {
        if (active) setRef(r);
      })
      .catch((e) => { if (active) report(e); });
    return () => {
      active = false;
    };
  }, [company]);
  // The grids sort and filter in the browser, so every page of the server cursor is loaded (up to a cap).
  async function reload() {
    if (!company) return;
    const scope = company;
    setBusy(true);
    setError("");
    try {
      const rows: Journal[] = [];
      for (;;) {
        const last = rows.at(-1);
        const page = await api<Journal[]>(
          "/accounting/journals?limit=100" + (last ? "&before=" + encodeURIComponent(last.created_at) + "&before_id=" + last.id : ""),
          scope,
        );
        if (scopeRef.current !== scope) return;
        rows.push(...page);
        if (page.length < 100 || rows.length >= JOURNAL_CAP) break;
      }
      setJournals(rows);
      setJournalsCapped(rows.length >= JOURNAL_CAP);
    } catch (e) {
      report(e);
    } finally {
      setBusy(false);
    }
  }
  useEffect(() => {
    if (company && ref) void reload();
  }, [company, ref]);
  async function open(j: Pick<Journal, "id">) {
    setBusy(true);
    setError("");
    try {
      const data = await api<Journal>("/accounting/journals/" + j.id, company);
      if (scopeRef.current !== company) return;
      setSelected(data);
      setView("detail");
    } catch (e) {
      report(e);
    } finally {
      setBusy(false);
    }
  }
  async function loadTrial() {
    setBusy(true);
    try {
      const data = await api<Trial>(
        "/reports/trial-balance?as_of=" + asof + (from ? "&from=" + from : ""),
        company,
      );
      if (scopeRef.current === company) setTrial(data);
    } catch (e) {
      report(e);
    } finally {
      setBusy(false);
    }
  }
  async function loadAudit() {
    const scope = company;
    setBusy(true);
    try {
      const rows: Audit[] = [];
      for (;;) {
        const page = await api<Audit[]>("/audit/events?after=" + (rows.at(-1)?.sequence_no ?? 0), scope);
        if (scopeRef.current !== scope) return;
        rows.push(...page);
        if (page.length < 100 || rows.length >= AUDIT_CAP) break;
      }
      setAudit(rows);
      setAuditCapped(rows.length >= AUDIT_CAP);
    } catch (e) {
      report(e);
    } finally {
      setBusy(false);
    }
  }
  useEffect(() => {
    if (view === "trial") void loadTrial();
    if (view === "audit") void loadAudit();
  }, [view]);
  function navigate(v: string) {
    if (pending) return;
    setSelected(null);
    setError("");
    setView(v);
    setPalette(false);
  }
  async function mutate(path: string, body: unknown) {
    if (!session) return;
    setBusy(true);
    setError("");
    const request = pending ?? { path, body, key: crypto.randomUUID(), company, csrf: session.csrf_token };
    setPending(request);
    try {
      const j = await api<Journal>(request.path, request.company, {
        method: "POST",
        body: request.body,
        key: request.key,
        csrf: request.csrf,
      });
      setPending(null);
      if (scopeRef.current !== request.company) return;
      setSelected(j);
      setView("detail");
      setAction("");
      setReason("");
      await reload();
    } catch (e) {
      if (e instanceof APIError && e.status < 500) {
        setPending(null);
        report(e);
      } else {
        setError(
          "The response was interrupted. Retry the same action to confirm its result.",
        );
      }
    } finally {
      setBusy(false);
    }
  }
  async function logout() {
    if (!session || pending) return;
    try {
      await api("/auth/logout", undefined, {
        method: "POST",
        csrf: session.csrf_token,
      });
      setSession(null);
      setCompany("");
      setRef(null);
      setJournals([]);
      setTrial(null);
      setAudit([]);
      setSelected(null);
      setProfileOpen(false);
      clearIdentity();
      setIdentity(null);
    } catch (e) {
      report(e);
    }
  }
  if (loading)
    return (
      <div className="loading">
        <Icon />
        Opening your workspace…
      </div>
    );
  if (!session)
    return (
      <Login
        onLogin={async (who) => {
          const id = { ...who, signedInAt: new Date().toISOString() };
          saveIdentity(id);
          setIdentity(id);
          await loadSession();
        }}
      />
    );
  // Navigation follows the caller's effective permissions and the company's module switches.
  const held = (p: string) => !!ref?.held?.includes(p);
  const feature = (f: string) => ref?.features?.[f] !== false;
  const mod = (f: string, p: string) => feature(f) && held(p);
  const navItem = (v: string, label: string, Icon: any, active: string[] = [v], onClick?: () => void) => (
    <button
      key={v}
      disabled={!!pending}
      className={"nav" + (active.includes(view) ? " active" : "")}
      aria-current={active.includes(view) ? "page" : undefined}
      onClick={onClick ?? (() => navigate(v))}
    >
      <Icon size={18} />
      {label}
    </button>
  );
  return (
    <div className="app">
      <aside className="sidebar">
        <a
          className="brand"
          href="#"
          onClick={(e) => {
            e.preventDefault();
            navigate("journals");
          }}
        >
          <Icon size={23} />
          <span>
            SERK <b>Finance</b>
          </span>
        </a>
        <select
          className="company-select"
          aria-label="Company"
          value={company}
          disabled={!!pending || busy}
          onChange={(e) => setCompany(e.target.value)}
        >
          {session.companies.map((c) => (
            <option key={c.id} value={c.id}>
              {c.name}
            </option>
          ))}
        </select>
        <nav aria-label="Main navigation">
          <div className="nav-group">Operate</div>
          {navItem("dashboard", "Dashboard", Command)}
          {navItem("journals", "Journals", BookOpen, ["journals", "detail", "new"])}
          {mod("sales", "sales.read") && navItem("sales", "Sales & AR", FileText)}
          {mod("purchases", "purchases.read") && navItem("purchases", "Purchases & AP", FileText)}
          {mod("payroll", "payroll.read") && navItem("payroll", "Payroll & HR", Users)}
          {mod("inventory", "inventory.read") && navItem("inventory", "Inventory & Items", Package)}
          {feature("adjustments") && ["taxes.manage", "payroll.manage", "sales.manage", "purchases.manage", "inventory.manage", "configuration.manage"].some(held) && navItem("adjustments", "Adjustments", Scale)}
          <div className="nav-group">Report</div>
          {navItem("statements", "Financial statements", FileSpreadsheet)}
          {navItem("trial", "Trial balance", FileText)}
          {navItem("ledger", "General ledger", BookOpenText, ["ledger"], () => {
            setLedgerAccount("");
            navigate("ledger");
          })}
          <div className="nav-group">Control</div>
          {navItem("periods", "Fiscal periods", CalendarDays)}
          {ref?.permissions.close && navItem("period-end", "Year-end & reopen", CalendarCheck2)}
          {feature("multi_currency") && navItem("currencies", "Currencies & Rates", Calculator)}
          {mod("taxes", "taxes.read") && navItem("taxes", "Taxes & Rates", Calculator)}
          {navItem("accounts", "Chart of accounts", ListTree)}
          {ref?.permissions.audit && navItem("integrity", "Ledger integrity", ShieldCheck)}
          {ref?.permissions.audit && navItem("audit", "Audit history", History)}
          {(ref?.permissions.users || ref?.permissions.roles || ref?.permissions.configure) && <div className="nav-group">Administer</div>}
          {(ref?.permissions.users || ref?.permissions.roles) && navItem("access", "Users & roles", UserCog)}
          {ref?.permissions.configure && navItem("settings", "Modules & features", Settings2)}
        </nav>
        <div className="sidebar-foot">
          <div className="control-mark">
            <ShieldCheck size={18} />
            <span>
              Every entry.
              <br />
              <strong>Accounted for.</strong>
            </span>
          </div>
          <button className="profile" onClick={() => setProfileOpen(true)} aria-label={"Open profile for " + session.name}>
            <span className="avatar">{session.name.slice(0, 1).toUpperCase()}</span>
            <span>
              {session.name}
              <small>View profile</small>
            </span>
            <UserRound size={16} />
          </button>
        </div>
      </aside>
      <div className="main">
        <header className="topbar">
          <div className="breadcrumbs">
            Workspace <ChevronRight size={14} />
            <strong>
              {(
                {
                  dashboard: "Dashboard",
                  statements: "Financial statements",
                  journals: "Journals",
                  new: "New journal",
                  detail: selected?.number ?? "Journal",
                  trial: "Trial balance",
                  periods: "Fiscal periods",
                  accounts: "Chart of accounts",
                  currencies: "Currencies & Rates",
                  ledger: "General ledger",
                  integrity: "Ledger integrity",
                  audit: "Audit history",
                  access: "Users & roles",
                  sales: "Sales & AR",
                  purchases: "Purchases & AP",
                  payroll: "Payroll & HR",
                  inventory: "Inventory & Items",
                  taxes: "Taxes & Rates",
                  adjustments: "Adjustments",
                  "period-end": "Year-end & reopen",
                  settings: "Modules & features",
                } as Record<string, any>
              )[view] ?? "Workspace"}
            </strong>
          </div>
          <div className="top-actions">
            <button
              className="command"
              aria-label="Open command palette"
              onClick={() => setPalette(true)}
            >
              <Search size={16} />
              <kbd>Ctrl K</kbd>
            </button>
            <span className={"connection " + (!online || !serverUp ? "offline" : "")} role="status">
              <i />
              {!online ? "Offline" : serverUp ? "Connected" : "Server unavailable"}
            </span>
            <button className="top-profile" onClick={() => setProfileOpen(true)} aria-label="Your profile" title={session.name}>
              <span className="avatar">{session.name.slice(0, 1).toUpperCase()}</span>
            </button>
          </div>
        </header>
        <main>
          {!online && (
            <div className="notice">
              Connection lost. Financial actions will resume when you reconnect.
            </div>
          )}
          {online && !serverUp && (
            <div className="notice">
              The finance server is not ready. Your work is safe; try again shortly.
            </div>
          )}
          {error && (
            <div className="error" role="alert">
              <AlertCircle size={18} />
              {error}
              {pending && (
                <button
                  disabled={busy}
                  onClick={() => mutate(pending.path, pending.body)}
                >
                  Retry action
                </button>
              )}
            </div>
          )}
          {!current && (
            <div className="empty">
              <h2>No company access</h2>
              <p>Ask your administrator to assign a company and role.</p>
            </div>
          )}
          {current && view === "journals" && (
            <JournalsPage
              reference={ref}
              online={online}
              busy={busy}
              navigate={navigate}
              reload={reload}
              journals={journals}
              open={open}
              places={places}
              capped={journalsCapped}
            />
          )}
          {current && view === "new" && ref && (
            <JournalForm
              company={company}
              reference={ref}
              currency={current.currency}
              busy={busy}
              locked={!!pending}
              onCancel={() => navigate("journals")}
              onSave={(p) => mutate("/accounting/journals", p)}
            />
          )}
          {view === "detail" && selected && (
            <JournalDetail
              selected={selected}
              reference={ref}
              me={session}
              openJournal={(id) => void open({ id })}
              locked={!!pending}
              busy={busy}
              online={online}
              navigate={navigate}
              places={places}
              setAction={setAction}
              setReason={setReason}
            />
          )}
          {view === "trial" && (
            <TrialBalancePage
              asof={asof}
              setAsof={setAsof}
              from={from}
              setFrom={setFrom}
              loadTrial={loadTrial}
              busy={busy}
              trial={trial}
              companyName={current?.name ?? ""}
              places={places}
              onAccount={(id) => { setLedgerAccount(id); navigate("ledger"); }}
            />
          )}
          {current && view === "dashboard" && (
            <DashboardPage 
              company={company} 
              currencyPlaces={places(current.currency)} 
              currencyCode={current.currency}
              onAccount={(id) => { setLedgerAccount(id); navigate("ledger"); }}
            />
          )}
          {current && view === "statements" && (
            <FinancialStatementsPage 
              company={company} 
              companyName={current.name}
              currencyPlaces={places(current.currency)} 
              currencyCode={current.currency}
              onAccount={(id) => { setLedgerAccount(id); navigate("ledger"); }}
            />
          )}
          {current && ref && view === "ledger" && <GeneralLedgerPage key={company + ledgerAccount} company={company} reference={ref} initialAccount={ledgerAccount} asOf={asof} onOpen={(id) => void open({ id })} onError={report} />}
          {current && view === "sales" && <SalesPage currencyPlaces={places(current.currency)} currency={current.currency} userId={session.user_id} company={company} csrf={session.csrf_token} />}
            {current && view === "purchases" && <PurchasesPage currencyPlaces={places(current.currency)} currency={current.currency} userId={session.user_id} company={company} csrf={session.csrf_token} />}
            {current && view === "integrity" && <IntegrityPage key={company} company={company} onError={report} />}
          {current && view === "accounts" && <AccountsPage company={company} csrf={session.csrf_token} reference={ref} onLedger={(id) => { setLedgerAccount(id); navigate("ledger"); }} refreshReference={async () => { const scope = company; const updated = await api<Reference>("/accounting/reference", scope); if (scope === company) setRef(updated); }} />}
          {current && view === "inventory" && <InventoryPage currency={current.currency} userId={session.user_id} company={company} csrf={session.csrf_token} currencyPlaces={places(current.currency)} />}
          {current && view === "payroll" && <PayrollPage currency={current.currency} userId={session.user_id} company={company} csrf={session.csrf_token} currencyPlaces={places(current.currency)} />}
          {current && view === "taxes" && <TaxesPage currency={current.currency} currencyPlaces={places(current.currency)} company={company} csrf={session.csrf_token} />}
          {current && view === "currencies" && <CurrenciesPage company={company} csrf={session.csrf_token} currency={current.currency} />}
          {current && view === "settings" && <SettingsPage company={company} csrf={session.csrf_token} canConfigure={!!ref?.permissions.configure} onChanged={async () => { const scope = company; const updated = await api<Reference>("/accounting/reference", scope); if (scopeRef.current === scope) setRef(updated); }} />}
          {current && view === "adjustments" && <AdjustmentsPage company={company} csrf={session.csrf_token} reference={ref} me={session} places={places(current.currency)} currency={current.currency} />}
          {current && view === "period-end" && <PeriodEndPage key={company} company={company} csrf={session.csrf_token} reference={ref} me={session} places={places(current.currency)} currency={current.currency} onChanged={async () => { const scope = company; const updated = await api<Reference>("/accounting/reference", scope); if (scopeRef.current === scope) setRef(updated); }} />}
          {view === "periods" && <PeriodsPage key={company} reference={ref} company={company} csrf={session.csrf_token} onClosed={async () => { const scope = company; const updated = await api<Reference>("/accounting/reference", scope); if (scopeRef.current === scope) setRef(updated); }} refreshReference={async () => { const scope = company; const updated = await api<Reference>("/accounting/reference", scope); if (scopeRef.current === scope) setRef(updated); }} />}
          {current && view === "access" && (
            <AccessPage
              key={company}
              company={company}
              csrf={session.csrf_token}
              currencyPlaces={places(current.currency)}
              onSessionEnd={(e) => {
                if (e instanceof APIError && e.status === 401) report(e);
              }}
            />
          )}
          {view === "audit" && (
            <AuditPage
              loadAudit={loadAudit}
              busy={busy}
              audit={audit}
              capped={auditCapped}
              me={session}
              onOpen={(id) => void open({ id })}
            />
          )}
        </main>
        <footer className="app-footer">
          <span>SERK Finance</span>
          <span>The Financial Operating System for Africa.</span>
        </footer>
      </div>
      {action && selected && (
        <div className="overlay">
          <section
            role="dialog"
            aria-modal="true"
            aria-labelledby="action-title"
            className="modal"
          >
            <button
              className="modal-close"
              aria-label="Close"
              disabled={busy || !!pending}
              onClick={() => setAction("")}
            >
              <X size={20} />
            </button>
            <div className="eyebrow">FINANCIAL CONTROL</div>
            <h2 id="action-title">
              {action[0].toUpperCase() + action.slice(1)} {selected.number}
            </h2>
            {error && (
              <div className="error" role="alert">
                {error}
              </div>
            )}
            <p>
              {action === "post"
                ? "Posting makes this journal immutable."
                : action === "reverse"
                  ? "A separate reversing journal will be prepared for approval."
                  : "Your identity and reason will be recorded in the audit history."}
            </p>
            <form
              onSubmit={(e) => {
                e.preventDefault();
                void mutate(
                  "/accounting/journals/" + selected.id + "/" + action,
                  {
                    expected_version: selected.version,
                    reason,
                    accounting_date:
                      action === "reverse" ? reversalDate : undefined,
                  },
                );
              }}
            >
              <label>
                Reason
                <textarea
                  autoFocus
                  required
                  minLength={3}
                  maxLength={1000}
                  value={reason}
                  disabled={busy || !!pending}
                  onChange={(e) => setReason(e.target.value)}
                />
              </label>
              {action === "reverse" && (
                <label>
                  Reversal date
                  <input
                    type="date"
                    required
                    value={reversalDate}
                    onChange={(e) => setReversalDate(e.target.value)}
                    disabled={busy || !!pending}
                  />
                </label>
              )}
              <button className="primary wide" disabled={busy || !online}>
                {busy
                  ? "Processing…"
                  : pending
                    ? "Retry same action"
                    : "Confirm " + action}
              </button>
            </form>
          </section>
        </div>
      )}
      {profileOpen && (
        <ProfileModal
          session={session}
          identity={identity}
          company={company}
          reference={ref}
          locked={!!pending}
          onClose={() => setProfileOpen(false)}
          onSignOut={() => void logout()}
        />
      )}
      {palette && (
        <div className="overlay" onClick={() => setPalette(false)}>
          <section
            className="palette"
            role="dialog"
            aria-modal="true"
            aria-label="Command palette"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="palette-title">
              <Command size={19} />
              Go to
              <button
                aria-label="Close commands"
                onClick={() => setPalette(false)}
              >
                <X size={18} />
              </button>
            </div>
            {[
              ["statements", "Financial statements (Balance Sheet & P&L)"],
              ["journals", "Open journals"],
              ...(ref?.permissions.create ? [["new", "Create journal"]] : []),
              ["trial", "Run trial balance"],
              ["ledger", "Open general ledger"],
              ["periods", "View fiscal periods"],
              ["accounts", "View chart of accounts"],
              ...(ref?.permissions.audit
                ? [["integrity", "Check ledger integrity"], ["audit", "Open audit history"]]
                : []),
              ...(ref?.permissions.users || ref?.permissions.roles ? [["access", "Manage users and roles"]] : []),
            ].map(([v, label]) => (
              <button key={v} disabled={!!pending} onClick={() => { if (v === "ledger") setLedgerAccount(""); navigate(v); }}>
                {label}
                <ChevronRight size={17} />
              </button>
            ))}
          </section>
        </div>
      )}
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <CacheProvider value={styleCache}>
      <ThemeProvider theme={theme}>
        <Suspense fallback={<div className="loading" role="status">Loading workspace…</div>}><App /></Suspense>
      </ThemeProvider>
    </CacheProvider>
  </React.StrictMode>,
);


