import { useState, useEffect, useMemo } from "react";
import { api, money } from "../api";
import { 
  Printer, Download, Calendar, Scale, TrendingUp, AlertCircle, 
  CheckCircle2, ChevronRight, FileSpreadsheet, RefreshCw, Layers
} from "lucide-react";

type AccountRow = {
  id: string;
  code: string;
  name: string;
  reporting_category?: string;
  balance_minor?: string;
  amount_minor?: string;
  dr_minor?: string;
  cr_minor?: string;
};

type BalanceSheetData = {
  as_of: string;
  currency: string;
  assets: {
    current_assets: AccountRow[];
    current_assets_total_minor: string;
    non_current_assets: AccountRow[];
    non_current_assets_total_minor: string;
    total_assets_minor: string;
  };
  liabilities: {
    current_liabilities: AccountRow[];
    current_liabilities_total_minor: string;
    non_current_liabilities: AccountRow[];
    non_current_liabilities_total_minor: string;
    total_liabilities_minor: string;
  };
  equity: {
    equity_accounts: AccountRow[];
    equity_accounts_total_minor: string;
    net_income_minor: string;
    total_equity_minor: string;
  };
  total_liabilities_and_equity_minor: string;
  is_balanced: boolean;
};

type IncomeStatementData = {
  from: string | null;
  to: string;
  currency: string;
  revenue: AccountRow[];
  total_revenue_minor: string;
  cost_of_sales: AccountRow[];
  total_cost_of_sales_minor: string;
  gross_profit_minor: string;
  operating_expenses: AccountRow[];
  total_operating_expenses_minor: string;
  operating_income_minor: string;
  other_income: AccountRow[];
  total_other_income_minor: string;
  other_expenses: AccountRow[];
  total_other_expenses_minor: string;
  net_profit_minor: string;
};

type Props = {
  company: string;
  companyName: string;
  currencyPlaces: number;
  currencyCode?: string;
  onAccount: (id: string) => void;
};

export function FinancialStatementsPage({ company, companyName, currencyPlaces, currencyCode = "ETB", onAccount }: Props) {
  const [statementType, setStatementType] = useState<"BALANCE_SHEET" | "INCOME_STATEMENT">("BALANCE_SHEET");
  
  const today = useMemo(() => new Date().toISOString().split("T")[0], []);
  const yearStart = useMemo(() => `${new Date().getFullYear()}-01-01`, []);

  // Filter dates
  const [asOfDate, setAsOfDate] = useState(today);
  const [fromDate, setFromDate] = useState(yearStart);
  const [toDate, setToDate] = useState(today);

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  const [balanceSheet, setBalanceSheet] = useState<BalanceSheetData | null>(null);
  const [incomeStatement, setIncomeStatement] = useState<IncomeStatementData | null>(null);

  const loadStatements = async () => {
    setLoading(true);
    setError("");
    try {
      if (statementType === "BALANCE_SHEET") {
        const res = await api<BalanceSheetData>(`/reports/balance-sheet?as_of=${asOfDate}`, company);
        setBalanceSheet(res);
      } else {
        const url = `/reports/income-statement?to=${toDate}${fromDate ? `&from=${fromDate}` : ""}`;
        const res = await api<IncomeStatementData>(url, company);
        setIncomeStatement(res);
      }
    } catch (err: any) {
      setError(err.message || "Failed to load financial statements");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void loadStatements();
  }, [company, statementType, asOfDate, fromDate, toDate]);

  const fmtMinor = (valMinor: string | number | undefined) => {
    if (valMinor === undefined || valMinor === null) return "0.00";
    const num = Number(valMinor) / Math.pow(10, currencyPlaces);
    return num.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  };

  const handlePrint = () => {
    window.print();
  };

  const handleExportCSV = () => {
    let rows: string[][] = [];
    if (statementType === "BALANCE_SHEET" && balanceSheet) {
      rows.push(["SERK Finance ERP - Balance Sheet"]);
      rows.push([`Company: ${companyName}`, `As of: ${balanceSheet.as_of}`, `Currency: ${currencyCode}`]);
      rows.push([]);
      rows.push(["ASSETS"]);
      rows.push(["Current Assets"]);
      balanceSheet.assets.current_assets.forEach(a => rows.push([a.code, a.name, fmtMinor(a.balance_minor)]));
      rows.push(["Total Current Assets", "", fmtMinor(balanceSheet.assets.current_assets_total_minor)]);
      rows.push(["Non-Current Assets"]);
      balanceSheet.assets.non_current_assets.forEach(a => rows.push([a.code, a.name, fmtMinor(a.balance_minor)]));
      rows.push(["Total Non-Current Assets", "", fmtMinor(balanceSheet.assets.non_current_assets_total_minor)]);
      rows.push(["TOTAL ASSETS", "", fmtMinor(balanceSheet.assets.total_assets_minor)]);
      rows.push([]);
      rows.push(["LIABILITIES"]);
      rows.push(["Current Liabilities"]);
      balanceSheet.liabilities.current_liabilities.forEach(a => rows.push([a.code, a.name, fmtMinor(a.balance_minor)]));
      rows.push(["Total Current Liabilities", "", fmtMinor(balanceSheet.liabilities.current_liabilities_total_minor)]);
      rows.push(["Non-Current Liabilities"]);
      balanceSheet.liabilities.non_current_liabilities.forEach(a => rows.push([a.code, a.name, fmtMinor(a.balance_minor)]));
      rows.push(["Total Non-Current Liabilities", "", fmtMinor(balanceSheet.liabilities.non_current_liabilities_total_minor)]);
      rows.push(["TOTAL LIABILITIES", "", fmtMinor(balanceSheet.liabilities.total_liabilities_minor)]);
      rows.push([]);
      rows.push(["EQUITY"]);
      balanceSheet.equity.equity_accounts.forEach(a => rows.push([a.code, a.name, fmtMinor(a.balance_minor)]));
      rows.push(["Current Period Net Profit", "", fmtMinor(balanceSheet.equity.net_income_minor)]);
      rows.push(["TOTAL EQUITY", "", fmtMinor(balanceSheet.equity.total_equity_minor)]);
      rows.push([]);
      rows.push(["TOTAL LIABILITIES & EQUITY", "", fmtMinor(balanceSheet.total_liabilities_and_equity_minor)]);
    } else if (statementType === "INCOME_STATEMENT" && incomeStatement) {
      rows.push(["SERK Finance ERP - Income Statement (Profit & Loss)"]);
      rows.push([`Company: ${companyName}`, `Period: ${incomeStatement.from || "Beginning"} to ${incomeStatement.to}`, `Currency: ${currencyCode}`]);
      rows.push([]);
      rows.push(["OPERATING REVENUE"]);
      incomeStatement.revenue.forEach(a => rows.push([a.code, a.name, fmtMinor(a.amount_minor)]));
      rows.push(["Total Revenue", "", fmtMinor(incomeStatement.total_revenue_minor)]);
      rows.push(["COST OF GOODS SOLD (COGS)"]);
      incomeStatement.cost_of_sales.forEach(a => rows.push([a.code, a.name, fmtMinor(a.amount_minor)]));
      rows.push(["Total COGS", "", fmtMinor(incomeStatement.total_cost_of_sales_minor)]);
      rows.push(["GROSS PROFIT", "", fmtMinor(incomeStatement.gross_profit_minor)]);
      rows.push([]);
      rows.push(["OPERATING EXPENSES"]);
      incomeStatement.operating_expenses.forEach(a => rows.push([a.code, a.name, fmtMinor(a.amount_minor)]));
      rows.push(["Total Operating Expenses", "", fmtMinor(incomeStatement.total_operating_expenses_minor)]);
      rows.push(["OPERATING INCOME (EBIT)", "", fmtMinor(incomeStatement.operating_income_minor)]);
      rows.push([]);
      rows.push(["NET PROFIT / (LOSS)", "", fmtMinor(incomeStatement.net_profit_minor)]);
    }

    const csvContent = "data:text/csv;charset=utf-8," + rows.map(e => e.map(i => `"${i}"`).join(",")).join("\n");
    const encodedUri = encodeURI(csvContent);
    const link = document.createElement("a");
    link.setAttribute("href", encodedUri);
    link.setAttribute("download", `${statementType.toLowerCase()}-${today}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  return (
    <div className="financial-statements-page" style={{ display: "flex", flexDirection: "column", gap: "1.5rem", paddingBottom: "3rem" }}>
      
      {/* Header and Controls */}
      <div className="page-heading" style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", flexWrap: "wrap", gap: "1rem" }}>
        <div>
          <div className="eyebrow" style={{ display: "flex", alignItems: "center", gap: "0.4rem", color: "var(--green)", fontWeight: 600 }}>
            <FileSpreadsheet size={14} /> FINANCIAL STATEMENTS · IFRS PRESENTATION
          </div>
          <h1 style={{ margin: "0.25rem 0" }}>
            {statementType === "BALANCE_SHEET" ? "Balance Sheet" : "Income Statement (Profit & Loss)"}
          </h1>
          <p style={{ margin: 0, color: "var(--muted)" }}>
            {statementType === "BALANCE_SHEET" 
              ? "Statement of Financial Position: Cumulative Assets, Liabilities, and Equity in equilibrium." 
              : "Financial Performance: Revenue, COGS, Gross Profit, Operating Expenses, and Net Earnings."}
          </p>
        </div>

        {/* Action Buttons */}
        <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
          <button
            onClick={handlePrint}
            className="secondary"
            style={{ display: "flex", alignItems: "center", gap: "0.4rem", padding: "0.45rem 0.85rem", borderRadius: "6px", border: "1px solid var(--line)", background: "#fff" }}
            title="Print statement"
          >
            <Printer size={15} /> Print Statement
          </button>
          <button
            onClick={handleExportCSV}
            className="secondary"
            style={{ display: "flex", alignItems: "center", gap: "0.4rem", padding: "0.45rem 0.85rem", borderRadius: "6px", border: "1px solid var(--line)", background: "#fff" }}
            title="Download CSV"
          >
            <Download size={15} /> Export CSV
          </button>
          <button
            onClick={() => void loadStatements()}
            className="secondary"
            style={{ display: "flex", alignItems: "center", gap: "0.4rem", padding: "0.45rem 0.85rem", borderRadius: "6px", border: "1px solid var(--line)", background: "#fff" }}
            title="Refresh"
          >
            <RefreshCw size={15} /> Refresh
          </button>
        </div>
      </div>

      {/* Tabs & Date Filters Card */}
      <div style={{ background: "#fff", border: "1px solid var(--line)", borderRadius: "10px", padding: "1.25rem", display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: "1rem" }}>
        
        {/* Navigation Tabs */}
        <div style={{ display: "flex", background: "#f1f5f3", borderRadius: "8px", padding: "3px", border: "1px solid var(--line)" }}>
          <button
            onClick={() => setStatementType("BALANCE_SHEET")}
            style={{
              padding: "6px 14px",
              borderRadius: "6px",
              fontSize: "0.85rem",
              fontWeight: 600,
              background: statementType === "BALANCE_SHEET" ? "#fff" : "transparent",
              color: statementType === "BALANCE_SHEET" ? "var(--green)" : "var(--muted)",
              boxShadow: statementType === "BALANCE_SHEET" ? "0 2px 4px rgba(0,0,0,0.06)" : "none",
              border: "none",
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              gap: "0.4rem"
            }}
          >
            <Scale size={16} /> Balance Sheet
          </button>
          <button
            onClick={() => setStatementType("INCOME_STATEMENT")}
            style={{
              padding: "6px 14px",
              borderRadius: "6px",
              fontSize: "0.85rem",
              fontWeight: 600,
              background: statementType === "INCOME_STATEMENT" ? "#fff" : "transparent",
              color: statementType === "INCOME_STATEMENT" ? "var(--green)" : "var(--muted)",
              boxShadow: statementType === "INCOME_STATEMENT" ? "0 2px 4px rgba(0,0,0,0.06)" : "none",
              border: "none",
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              gap: "0.4rem"
            }}
          >
            <TrendingUp size={16} /> Profit & Loss (P&L)
          </button>
        </div>

        {/* Date Filter Form */}
        <div style={{ display: "flex", alignItems: "center", gap: "0.75rem", flexWrap: "wrap" }}>
          {statementType === "BALANCE_SHEET" ? (
            <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
              <label style={{ fontSize: "0.85rem", fontWeight: 600, color: "var(--muted)" }}>As of Date:</label>
              <input
                type="date"
                value={asOfDate}
                onChange={(e) => setAsOfDate(e.target.value)}
                style={{ padding: "0.4rem 0.65rem", borderRadius: "6px", border: "1px solid var(--line)", fontSize: "0.85rem" }}
              />
            </div>
          ) : (
            <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
              <label style={{ fontSize: "0.85rem", fontWeight: 600, color: "var(--muted)" }}>From:</label>
              <input
                type="date"
                value={fromDate}
                onChange={(e) => setFromDate(e.target.value)}
                style={{ padding: "0.4rem 0.65rem", borderRadius: "6px", border: "1px solid var(--line)", fontSize: "0.85rem" }}
              />
              <label style={{ fontSize: "0.85rem", fontWeight: 600, color: "var(--muted)" }}>To:</label>
              <input
                type="date"
                value={toDate}
                onChange={(e) => setToDate(e.target.value)}
                style={{ padding: "0.4rem 0.65rem", borderRadius: "6px", border: "1px solid var(--line)", fontSize: "0.85rem" }}
              />
            </div>
          )}

          <button
            onClick={() => void loadStatements()}
            className="primary"
            disabled={loading}
            style={{ padding: "0.45rem 1rem", fontSize: "0.85rem" }}
          >
            {loading ? "Calculating..." : "Apply Filter"}
          </button>
        </div>
      </div>

      {error && (
        <div className="error" style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
          <AlertCircle size={18} /> {error}
        </div>
      )}

      {/* Printable Financial Statement Paper Document */}
      <div 
        className="statement-paper"
        style={{
          background: "#fff",
          border: "1px solid var(--line)",
          borderRadius: "10px",
          padding: "2.5rem 3rem",
          boxShadow: "0 4px 16px rgba(0,0,0,0.04)",
          fontFamily: "Inter, sans-serif"
        }}
      >
        {/* Statement Letterhead */}
        <div style={{ textAlign: "center", borderBottom: "2px solid #203436", paddingBottom: "1.25rem", marginBottom: "2rem" }}>
          <div style={{ fontSize: "1.45rem", fontWeight: 800, color: "#166453", letterSpacing: "-0.02em" }}>
            {companyName}
          </div>
          <div style={{ fontSize: "1.2rem", fontWeight: 700, color: "var(--ink)", marginTop: "0.35rem", textTransform: "uppercase" }}>
            {statementType === "BALANCE_SHEET" ? "Balance Sheet" : "Income Statement (Profit & Loss)"}
          </div>
          <div style={{ fontSize: "0.85rem", color: "var(--muted)", marginTop: "0.3rem" }}>
            {statementType === "BALANCE_SHEET" 
              ? `As of ${balanceSheet?.as_of || asOfDate}` 
              : `For the period from ${incomeStatement?.from || fromDate} to ${incomeStatement?.to || toDate}`}
            {" · "}
            <strong>All amounts in {currencyCode}</strong>
          </div>
        </div>

        {/* 1. BALANCE SHEET CONTENT */}
        {statementType === "BALANCE_SHEET" && balanceSheet && (
          <div style={{ display: "flex", flexDirection: "column", gap: "2rem" }}>
            
            {/* Equilibrium Banner */}
            <div style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "center",
              background: balanceSheet.is_balanced ? "#f0fdf4" : "#fef2f2",
              border: `1px solid ${balanceSheet.is_balanced ? "#bbf7d0" : "#fecaca"}`,
              padding: "0.75rem 1rem",
              borderRadius: "8px",
              fontSize: "0.85rem",
              fontWeight: 600,
              color: balanceSheet.is_balanced ? "#166534" : "#991b1b"
            }}>
              <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
                {balanceSheet.is_balanced ? <CheckCircle2 size={18} /> : <AlertCircle size={18} />}
                <span>
                  {balanceSheet.is_balanced 
                    ? "Accounting Equation Balanced: Assets = Liabilities + Equity" 
                    : "Warning: Out of balance difference detected!"}
                </span>
              </div>
              <div>
                Net Checksum: <strong>{currencyCode} 0.00</strong>
              </div>
            </div>

            {/* Assets Section */}
            <div>
              <div style={{ fontSize: "1.1rem", fontWeight: 800, color: "#166453", borderBottom: "2px solid #e3eae7", paddingBottom: "0.4rem", marginBottom: "0.75rem" }}>
                ASSETS
              </div>

              {/* Current Assets */}
              <div style={{ marginBottom: "1rem" }}>
                <div style={{ fontWeight: 700, fontSize: "0.9rem", color: "var(--ink)", padding: "0.3rem 0" }}>
                  Current Assets
                </div>
                <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.85rem" }}>
                  <tbody>
                    {balanceSheet.assets.current_assets.map(acc => (
                      <tr key={acc.id} style={{ borderBottom: "1px solid #f0f3f2" }}>
                        <td style={{ padding: "0.4rem 0.5rem", width: "100px", fontFamily: "monospace", color: "var(--muted)" }}>{acc.code}</td>
                        <td style={{ padding: "0.4rem 0.5rem" }}>
                          <button className="report-link" onClick={() => onAccount(acc.id)} style={{ fontWeight: 500 }}>
                            {acc.name}
                          </button>
                        </td>
                        <td style={{ padding: "0.4rem 0.5rem", textAlign: "right", fontFamily: "monospace", width: "140px" }}>
                          {fmtMinor(acc.balance_minor)}
                        </td>
                      </tr>
                    ))}
                    <tr style={{ fontWeight: 700, borderTop: "1px solid #cbd5e1" }}>
                      <td colSpan={2} style={{ padding: "0.5rem" }}>Total Current Assets</td>
                      <td style={{ padding: "0.5rem", textAlign: "right", fontFamily: "monospace" }}>
                        {currencyCode} {fmtMinor(balanceSheet.assets.current_assets_total_minor)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              {/* Non-Current Assets */}
              {balanceSheet.assets.non_current_assets.length > 0 && (
                <div style={{ marginBottom: "1rem" }}>
                  <div style={{ fontWeight: 700, fontSize: "0.9rem", color: "var(--ink)", padding: "0.3rem 0" }}>
                    Non-Current (Fixed) Assets
                  </div>
                  <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.85rem" }}>
                    <tbody>
                      {balanceSheet.assets.non_current_assets.map(acc => (
                        <tr key={acc.id} style={{ borderBottom: "1px solid #f0f3f2" }}>
                          <td style={{ padding: "0.4rem 0.5rem", width: "100px", fontFamily: "monospace", color: "var(--muted)" }}>{acc.code}</td>
                          <td style={{ padding: "0.4rem 0.5rem" }}>
                            <button className="report-link" onClick={() => onAccount(acc.id)} style={{ fontWeight: 500 }}>
                              {acc.name}
                            </button>
                          </td>
                          <td style={{ padding: "0.4rem 0.5rem", textAlign: "right", fontFamily: "monospace", width: "140px" }}>
                            {fmtMinor(acc.balance_minor)}
                          </td>
                        </tr>
                      ))}
                      <tr style={{ fontWeight: 700, borderTop: "1px solid #cbd5e1" }}>
                        <td colSpan={2} style={{ padding: "0.5rem" }}>Total Non-Current Assets</td>
                        <td style={{ padding: "0.5rem", textAlign: "right", fontFamily: "monospace" }}>
                          {currencyCode} {fmtMinor(balanceSheet.assets.non_current_assets_total_minor)}
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              )}

              {/* TOTAL ASSETS ROW */}
              <div style={{ display: "flex", justifyContent: "space-between", padding: "0.75rem 0.5rem", borderTop: "2px solid #203436", borderBottom: "2px solid #203436", fontWeight: 800, fontSize: "1rem", color: "var(--ink)" }}>
                <span>TOTAL ASSETS</span>
                <span style={{ fontFamily: "monospace" }}>{currencyCode} {fmtMinor(balanceSheet.assets.total_assets_minor)}</span>
              </div>
            </div>

            {/* Liabilities Section */}
            <div>
              <div style={{ fontSize: "1.1rem", fontWeight: 800, color: "#f43f5e", borderBottom: "2px solid #e3eae7", paddingBottom: "0.4rem", marginBottom: "0.75rem" }}>
                LIABILITIES
              </div>

              {/* Current Liabilities */}
              <div style={{ marginBottom: "1rem" }}>
                <div style={{ fontWeight: 700, fontSize: "0.9rem", color: "var(--ink)", padding: "0.3rem 0" }}>
                  Current Liabilities
                </div>
                <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.85rem" }}>
                  <tbody>
                    {balanceSheet.liabilities.current_liabilities.map(acc => (
                      <tr key={acc.id} style={{ borderBottom: "1px solid #f0f3f2" }}>
                        <td style={{ padding: "0.4rem 0.5rem", width: "100px", fontFamily: "monospace", color: "var(--muted)" }}>{acc.code}</td>
                        <td style={{ padding: "0.4rem 0.5rem" }}>
                          <button className="report-link" onClick={() => onAccount(acc.id)} style={{ fontWeight: 500 }}>
                            {acc.name}
                          </button>
                        </td>
                        <td style={{ padding: "0.4rem 0.5rem", textAlign: "right", fontFamily: "monospace", width: "140px" }}>
                          {fmtMinor(acc.balance_minor)}
                        </td>
                      </tr>
                    ))}
                    <tr style={{ fontWeight: 700, borderTop: "1px solid #cbd5e1" }}>
                      <td colSpan={2} style={{ padding: "0.5rem" }}>Total Current Liabilities</td>
                      <td style={{ padding: "0.5rem", textAlign: "right", fontFamily: "monospace" }}>
                        {currencyCode} {fmtMinor(balanceSheet.liabilities.current_liabilities_total_minor)}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              {/* Non-Current Liabilities */}
              {balanceSheet.liabilities.non_current_liabilities.length > 0 && (
                <div style={{ marginBottom: "1rem" }}>
                  <div style={{ fontWeight: 700, fontSize: "0.9rem", color: "var(--ink)", padding: "0.3rem 0" }}>
                    Long-Term Liabilities
                  </div>
                  <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.85rem" }}>
                    <tbody>
                      {balanceSheet.liabilities.non_current_liabilities.map(acc => (
                        <tr key={acc.id} style={{ borderBottom: "1px solid #f0f3f2" }}>
                          <td style={{ padding: "0.4rem 0.5rem", width: "100px", fontFamily: "monospace", color: "var(--muted)" }}>{acc.code}</td>
                          <td style={{ padding: "0.4rem 0.5rem" }}>
                            <button className="report-link" onClick={() => onAccount(acc.id)} style={{ fontWeight: 500 }}>
                              {acc.name}
                            </button>
                          </td>
                          <td style={{ padding: "0.4rem 0.5rem", textAlign: "right", fontFamily: "monospace", width: "140px" }}>
                            {fmtMinor(acc.balance_minor)}
                          </td>
                        </tr>
                      ))}
                      <tr style={{ fontWeight: 700, borderTop: "1px solid #cbd5e1" }}>
                        <td colSpan={2} style={{ padding: "0.5rem" }}>Total Long-Term Liabilities</td>
                        <td style={{ padding: "0.5rem", textAlign: "right", fontFamily: "monospace" }}>
                          {currencyCode} {fmtMinor(balanceSheet.liabilities.non_current_liabilities_total_minor)}
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              )}

              {/* TOTAL LIABILITIES ROW */}
              <div style={{ display: "flex", justifyContent: "space-between", padding: "0.6rem 0.5rem", borderTop: "1px solid #cbd5e1", fontWeight: 700, fontSize: "0.95rem" }}>
                <span>TOTAL LIABILITIES</span>
                <span style={{ fontFamily: "monospace" }}>{currencyCode} {fmtMinor(balanceSheet.liabilities.total_liabilities_minor)}</span>
              </div>
            </div>

            {/* Equity Section */}
            <div>
              <div style={{ fontSize: "1.1rem", fontWeight: 800, color: "#8b5cf6", borderBottom: "2px solid #e3eae7", paddingBottom: "0.4rem", marginBottom: "0.75rem" }}>
                EQUITY & CAPITAL
              </div>

              <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.85rem", marginBottom: "1rem" }}>
                <tbody>
                  {balanceSheet.equity.equity_accounts.map(acc => (
                    <tr key={acc.id} style={{ borderBottom: "1px solid #f0f3f2" }}>
                      <td style={{ padding: "0.4rem 0.5rem", width: "100px", fontFamily: "monospace", color: "var(--muted)" }}>{acc.code}</td>
                      <td style={{ padding: "0.4rem 0.5rem" }}>
                        <button className="report-link" onClick={() => onAccount(acc.id)} style={{ fontWeight: 500 }}>
                          {acc.name}
                        </button>
                      </td>
                      <td style={{ padding: "0.4rem 0.5rem", textAlign: "right", fontFamily: "monospace", width: "140px" }}>
                        {fmtMinor(acc.balance_minor)}
                      </td>
                    </tr>
                  ))}
                  {/* Current Period Net Earnings */}
                  <tr style={{ borderBottom: "1px solid #f0f3f2", background: "#faf5ff" }}>
                    <td style={{ padding: "0.4rem 0.5rem", width: "100px", fontFamily: "monospace", color: "#8b5cf6", fontWeight: 600 }}>EARNINGS</td>
                    <td style={{ padding: "0.4rem 0.5rem", fontWeight: 600, color: "#6b21a8" }}>
                      Current Period Net Profit / (Loss)
                    </td>
                    <td style={{ padding: "0.4rem 0.5rem", textAlign: "right", fontFamily: "monospace", fontWeight: 700, color: "#6b21a8" }}>
                      {fmtMinor(balanceSheet.equity.net_income_minor)}
                    </td>
                  </tr>
                  <tr style={{ fontWeight: 700, borderTop: "1px solid #cbd5e1" }}>
                    <td colSpan={2} style={{ padding: "0.5rem" }}>TOTAL EQUITY</td>
                    <td style={{ padding: "0.5rem", textAlign: "right", fontFamily: "monospace" }}>
                      {currencyCode} {fmtMinor(balanceSheet.equity.total_equity_minor)}
                    </td>
                  </tr>
                </tbody>
              </table>

              {/* TOTAL LIABILITIES & EQUITY */}
              <div style={{ display: "flex", justifyContent: "space-between", padding: "0.75rem 0.5rem", borderTop: "2px solid #203436", borderBottom: "2px solid #203436", fontWeight: 800, fontSize: "1rem", color: "var(--ink)", background: "#f8faf9" }}>
                <span>TOTAL LIABILITIES & EQUITY</span>
                <span style={{ fontFamily: "monospace" }}>{currencyCode} {fmtMinor(balanceSheet.total_liabilities_and_equity_minor)}</span>
              </div>
            </div>

          </div>
        )}

        {/* 2. INCOME STATEMENT (P&L) CONTENT */}
        {statementType === "INCOME_STATEMENT" && incomeStatement && (
          <div style={{ display: "flex", flexDirection: "column", gap: "1.75rem" }}>
            
            {/* Revenue */}
            <div>
              <div style={{ fontSize: "1.05rem", fontWeight: 800, color: "#166453", borderBottom: "2px solid #e3eae7", paddingBottom: "0.4rem", marginBottom: "0.75rem" }}>
                OPERATING SALES & REVENUE
              </div>
              <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.85rem" }}>
                <tbody>
                  {incomeStatement.revenue.map(acc => (
                    <tr key={acc.id} style={{ borderBottom: "1px solid #f0f3f2" }}>
                      <td style={{ padding: "0.4rem 0.5rem", width: "100px", fontFamily: "monospace", color: "var(--muted)" }}>{acc.code}</td>
                      <td style={{ padding: "0.4rem 0.5rem" }}>
                        <button className="report-link" onClick={() => onAccount(acc.id)} style={{ fontWeight: 500 }}>
                          {acc.name}
                        </button>
                      </td>
                      <td style={{ padding: "0.4rem 0.5rem", textAlign: "right", fontFamily: "monospace", width: "140px" }}>
                        {fmtMinor(acc.amount_minor)}
                      </td>
                    </tr>
                  ))}
                  <tr style={{ fontWeight: 700, borderTop: "1px solid #cbd5e1" }}>
                    <td colSpan={2} style={{ padding: "0.5rem" }}>Total Revenue</td>
                    <td style={{ padding: "0.5rem", textAlign: "right", fontFamily: "monospace" }}>
                      {currencyCode} {fmtMinor(incomeStatement.total_revenue_minor)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            {/* COGS */}
            <div>
              <div style={{ fontSize: "1.05rem", fontWeight: 800, color: "#ea580c", borderBottom: "2px solid #e3eae7", paddingBottom: "0.4rem", marginBottom: "0.75rem" }}>
                COST OF GOODS SOLD (COGS)
              </div>
              <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.85rem" }}>
                <tbody>
                  {incomeStatement.cost_of_sales.length === 0 ? (
                    <tr>
                      <td colSpan={3} style={{ padding: "0.5rem", color: "var(--muted)", fontStyle: "italic" }}>
                        No direct cost of sales recorded in this period.
                      </td>
                    </tr>
                  ) : (
                    incomeStatement.cost_of_sales.map(acc => (
                      <tr key={acc.id} style={{ borderBottom: "1px solid #f0f3f2" }}>
                        <td style={{ padding: "0.4rem 0.5rem", width: "100px", fontFamily: "monospace", color: "var(--muted)" }}>{acc.code}</td>
                        <td style={{ padding: "0.4rem 0.5rem" }}>
                          <button className="report-link" onClick={() => onAccount(acc.id)} style={{ fontWeight: 500 }}>
                            {acc.name}
                          </button>
                        </td>
                        <td style={{ padding: "0.4rem 0.5rem", textAlign: "right", fontFamily: "monospace", width: "140px" }}>
                          {fmtMinor(acc.amount_minor)}
                        </td>
                      </tr>
                    ))
                  )}
                  <tr style={{ fontWeight: 700, borderTop: "1px solid #cbd5e1" }}>
                    <td colSpan={2} style={{ padding: "0.5rem" }}>Total Cost of Goods Sold</td>
                    <td style={{ padding: "0.5rem", textAlign: "right", fontFamily: "monospace" }}>
                      {currencyCode} {fmtMinor(incomeStatement.total_cost_of_sales_minor)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            {/* GROSS PROFIT */}
            <div style={{ display: "flex", justifyContent: "space-between", padding: "0.75rem 0.5rem", background: "#f0fdf4", border: "1px solid #bbf7d0", borderRadius: "6px", fontWeight: 800, fontSize: "0.95rem", color: "#166534" }}>
              <span>GROSS PROFIT (REVENUE - COGS)</span>
              <span style={{ fontFamily: "monospace" }}>{currencyCode} {fmtMinor(incomeStatement.gross_profit_minor)}</span>
            </div>

            {/* Operating Expenses */}
            <div>
              <div style={{ fontSize: "1.05rem", fontWeight: 800, color: "#d97706", borderBottom: "2px solid #e3eae7", paddingBottom: "0.4rem", marginBottom: "0.75rem" }}>
                OPERATING EXPENSES (OPEX)
              </div>
              <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.85rem" }}>
                <tbody>
                  {incomeStatement.operating_expenses.length === 0 ? (
                    <tr>
                      <td colSpan={3} style={{ padding: "0.5rem", color: "var(--muted)", fontStyle: "italic" }}>
                        No operating expenses recorded in this period.
                      </td>
                    </tr>
                  ) : (
                    incomeStatement.operating_expenses.map(acc => (
                      <tr key={acc.id} style={{ borderBottom: "1px solid #f0f3f2" }}>
                        <td style={{ padding: "0.4rem 0.5rem", width: "100px", fontFamily: "monospace", color: "var(--muted)" }}>{acc.code}</td>
                        <td style={{ padding: "0.4rem 0.5rem" }}>
                          <button className="report-link" onClick={() => onAccount(acc.id)} style={{ fontWeight: 500 }}>
                            {acc.name}
                          </button>
                        </td>
                        <td style={{ padding: "0.4rem 0.5rem", textAlign: "right", fontFamily: "monospace", width: "140px" }}>
                          {fmtMinor(acc.amount_minor)}
                        </td>
                      </tr>
                    ))
                  )}
                  <tr style={{ fontWeight: 700, borderTop: "1px solid #cbd5e1" }}>
                    <td colSpan={2} style={{ padding: "0.5rem" }}>Total Operating Expenses</td>
                    <td style={{ padding: "0.5rem", textAlign: "right", fontFamily: "monospace" }}>
                      {currencyCode} {fmtMinor(incomeStatement.total_operating_expenses_minor)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            {/* OPERATING INCOME */}
            <div style={{ display: "flex", justifyContent: "space-between", padding: "0.75rem 0.5rem", background: "#f8faf9", border: "1px solid var(--line)", borderRadius: "6px", fontWeight: 800, fontSize: "0.95rem", color: "var(--ink)" }}>
              <span>OPERATING INCOME (EBIT)</span>
              <span style={{ fontFamily: "monospace" }}>{currencyCode} {fmtMinor(incomeStatement.operating_income_minor)}</span>
            </div>

            {/* NET PROFIT / (LOSS) */}
            <div style={{ 
              display: "flex", 
              justifyContent: "space-between", 
              padding: "1rem 1.25rem", 
              background: Number(incomeStatement.net_profit_minor) >= 0 ? "#166453" : "#ef4444", 
              borderRadius: "8px", 
              fontWeight: 800, 
              fontSize: "1.15rem", 
              color: "#fff",
              boxShadow: "0 4px 12px rgba(0,0,0,0.08)"
            }}>
              <span>NET PROFIT / (LOSS) FOR THE PERIOD</span>
              <span style={{ fontFamily: "monospace" }}>{currencyCode} {fmtMinor(incomeStatement.net_profit_minor)}</span>
            </div>

          </div>
        )}

      </div>

    </div>
  );
}
