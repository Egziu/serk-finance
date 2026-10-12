import { useState, useEffect } from "react";
import { AlertCircle, X, HelpCircle } from "lucide-react";
import { api } from "./api";
import type { Account, Reference } from "./types";

export const REPORTING_CATEGORIES_BY_TYPE: Record<string, string[]> = {
  ASSET: [
    "Cash & Cash Equivalents",
    "Accounts Receivable (Debtors)",
    "Inventory / Stock",
    "Prepaid Expenses & Advances",
    "Property, Plant & Equipment (Fixed Assets)",
    "Accumulated Depreciation",
    "Intangible Assets",
    "Short-Term Investments",
    "Other Current Assets",
    "Other Non-Current Assets",
  ],
  LIABILITY: [
    "Accounts Payable (Creditors)",
    "Accrued Expenses & Payroll",
    "Short-Term Borrowings",
    "Taxes & VAT Payable",
    "Unearned / Deferred Revenue",
    "Long-Term Debt & Loans",
    "Other Non-Current Liabilities",
  ],
  EQUITY: [
    "Share Capital / Owner Investment",
    "Retained Earnings",
    "Current Year Earnings",
    "Owner Drawings / Dividends",
    "Statutory & General Reserves",
  ],
  REVENUE: [
    "Operating Sales Revenue",
    "Service & Consultancy Revenue",
    "Discounts Allowed & Sales Returns",
    "Interest & Finance Income",
    "Other Operating Income",
  ],
  COST_OF_SALES: [
    "Cost of Goods Sold (COGS)",
    "Direct Materials",
    "Direct Labor",
    "Inbound Freight & Duties",
    "Production Overheads",
  ],
  EXPENSE: [
    "Salaries & Employee Benefits",
    "Rent & Facility Leases",
    "Utilities & Communications",
    "Advertising & Marketing",
    "Office Supplies & IT Subscriptions",
    "Professional, Legal & Audit Fees",
    "Travel & Entertainment",
    "Depreciation & Amortization Expense",
    "Insurance Expense",
    "Repairs & Maintenance",
    "Bank & Payment Processing Fees",
  ],
  OTHER_INCOME: [
    "Interest Income",
    "Foreign Exchange Gain",
    "Gain on Sale of Fixed Assets",
    "Miscellaneous Non-Operating Income",
  ],
  OTHER_EXPENSE: [
    "Interest & Financing Expense",
    "Foreign Exchange Loss",
    "Loss on Sale of Fixed Assets",
    "FX Rounding Difference",
    "Fines & Penalties",
  ],
};

function defaultNormalBalance(t: string): "DEBIT" | "CREDIT" {
  switch (t) {
    case "ASSET":
    case "COST_OF_SALES":
    case "EXPENSE":
    case "OTHER_EXPENSE":
      return "DEBIT";
    default:
      return "CREDIT";
  }
}

type Props = {
  company: string;
  csrf: string;
  reference: Reference;
  account?: Account | null;
  defaultParentId?: string | null;
  onClose: () => void;
  onSuccess: () => void;
};

export function AccountForm({ company, csrf, reference, account, defaultParentId, onClose, onSuccess }: Props) {
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const initialParent = account
    ? (account.parent_id ? reference.accounts.find((a) => a.id === account.parent_id) : null)
    : (defaultParentId ? reference.accounts.find((a) => a.id === defaultParentId) : null);

  const getSuggestedCode = (pAcc: Account | null | undefined): string => {
    if (!pAcc) return "";
    const siblings = reference.accounts.filter((a) => a.parent_id === pAcc.id);
    if (siblings.length === 0) {
      if (pAcc.code.endsWith("00") || pAcc.code.endsWith("000")) {
        const num = parseInt(pAcc.code, 10);
        if (!isNaN(num)) return String(num + 1);
      }
      return `${pAcc.code}01`;
    }
    const numericSiblings = siblings
      .map((s) => parseInt(s.code, 10))
      .filter((n) => !isNaN(n));
    if (numericSiblings.length > 0) {
      const maxCode = Math.max(...numericSiblings);
      return String(maxCode + 1);
    }
    return `${pAcc.code}${siblings.length + 1}`;
  };

  const [parentId, setParentId] = useState<string>(account?.parent_id || defaultParentId || "");
  const [code, setCode] = useState(account?.code || (initialParent ? getSuggestedCode(initialParent) : ""));
  const [name, setName] = useState(account?.name || "");
  const [type, setType] = useState(account?.type || initialParent?.type || "ASSET");
  const [normalBalance, setNormalBalance] = useState(
    account?.normal_balance || initialParent?.normal_balance || defaultNormalBalance(account?.type || initialParent?.type || "ASSET")
  );
  const [postingAllowed, setPostingAllowed] = useState(account ? account.posting_allowed : true);
  const [controlAccount, setControlAccount] = useState(account ? account.control_account : false);
  const [active, setActive] = useState(account ? account.active : true);

  const availableCategories = REPORTING_CATEGORIES_BY_TYPE[type] || [];
  const initialCategory = account?.reporting_category || initialParent?.reporting_category || availableCategories[0] || "Uncategorized";
  const isInitialCustom = !!(account?.reporting_category || initialParent?.reporting_category) && !availableCategories.includes(initialCategory);

  const [selectedCategoryOption, setSelectedCategoryOption] = useState<string>(
    isInitialCustom ? "__custom__" : initialCategory
  );
  const [customCategoryText, setCustomCategoryText] = useState<string>(
    isInitialCustom ? initialCategory : ""
  );

  // Direct Reporting & Analytics State
  const [statementType, setStatementType] = useState<string>(() => {
    if (["ASSET", "LIABILITY", "EQUITY"].includes(account?.type || initialParent?.type || "ASSET")) return "BALANCE_SHEET";
    return "PROFIT_LOSS";
  });
  const [analyticsTag, setAnalyticsTag] = useState<string>("");
  const [dimensionId, setDimensionId] = useState<string>("");

  const reportingCategory = selectedCategoryOption === "__custom__" ? customCategoryText.trim() : selectedCategoryOption;

  const handleTypeChange = (newType: string) => {
    setType(newType);
    if (!account) {
      setNormalBalance(defaultNormalBalance(newType));
      const cats = REPORTING_CATEGORIES_BY_TYPE[newType] || [];
      if (cats.length > 0) {
        setSelectedCategoryOption(cats[0]);
      }
      if (["ASSET", "LIABILITY", "EQUITY"].includes(newType)) {
        setStatementType("BALANCE_SHEET");
      } else {
        setStatementType("PROFIT_LOSS");
      }
    }
  };

  const handleParentChange = (newParentId: string) => {
    setParentId(newParentId);
    if (!account && newParentId) {
      const parentAcc = reference.accounts.find((a) => a.id === newParentId);
      if (parentAcc) {
        setType(parentAcc.type);
        setNormalBalance(parentAcc.normal_balance || defaultNormalBalance(parentAcc.type));
        const suggested = getSuggestedCode(parentAcc);
        if (!code || code === "" || (initialParent && code === getSuggestedCode(initialParent))) {
          setCode(suggested);
        }
        if (parentAcc.reporting_category && availableCategories.includes(parentAcc.reporting_category)) {
          setSelectedCategoryOption(parentAcc.reporting_category);
        }
      }
    }
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!reportingCategory) {
      setError("Please choose or enter a reporting category.");
      return;
    }
    setError("");
    setBusy(true);

    const finalReportingCategory = analyticsTag ? `${reportingCategory} [${analyticsTag}]` : reportingCategory;

    try {
      if (account) {
        await api(`/accounting/accounts/${account.id}`, company, {
          method: "PUT",
          csrf,
          body: {
            name,
            parent_id: parentId || null,
            active,
            posting_allowed: postingAllowed,
            reporting_category: finalReportingCategory,
          }
        });
      } else {
        await api("/accounting/accounts", company, {
          method: "POST",
          csrf,
          body: {
            code,
            name,
            type,
            normal_balance: normalBalance,
            parent_id: parentId || null,
            posting_allowed: postingAllowed,
            control_account: controlAccount,
            reporting_category: finalReportingCategory,
          }
        });
      }
      onSuccess();
    } catch (err: any) {
      setError(err.message || "Failed to create account");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="overlay modal-overlay" onClick={onClose}>
      <div className="modal account-modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-header">
          <h2>
            {account
              ? "Edit account"
              : parentId && reference.accounts.find((a) => a.id === parentId)
              ? `Add Sub-Account under ${reference.accounts.find((a) => a.id === parentId)?.code} (${reference.accounts.find((a) => a.id === parentId)?.name})`
              : "Create account"}
          </h2>
          <button type="button" className="icon-btn" onClick={onClose} aria-label="Close">
            <X size={20} />
          </button>
        </div>
        <form onSubmit={submit} className="stack">
          {error && <div className="alert alert-error"><AlertCircle size={16} />{error}</div>}
          
          <div className="input-group">
            <label>Parent Account</label>
            <select value={parentId} onChange={(e) => handleParentChange(e.target.value)}>
              <option value="">-- No Parent (Root Level Top-Group) --</option>
              {reference.accounts
                .filter((a) => (!type || a.type === type) && !a.control_account && a.id !== account?.id)
                .sort((a, b) => a.code.localeCompare(b.code, undefined, { numeric: true }))
                .map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.code} · {a.name} ({a.posting_allowed ? "📝 Standard Account" : "📁 Group Header"})
                  </option>
                ))}
            </select>
            {parentId ? (
              <span className="field-tip" style={{ color: "var(--ink)" }}>
                💡 Selected Parent: <strong>{reference.accounts.find((a) => a.id === parentId)?.code} - {reference.accounts.find((a) => a.id === parentId)?.name}</strong>.
                {reference.accounts.find((a) => a.id === parentId)?.posting_allowed && (
                  <span style={{ display: "block", color: "#b45309", marginTop: "3px" }}>
                    ⚠️ Note: This parent will automatically be converted to a Group Header (summary) account so sub-accounts can hold postings.
                  </span>
                )}
              </span>
            ) : (
              <span className="field-tip">
                Leave as "Root Level" for top-level headers (e.g. 1000 Assets). Sub-accounts should select their parent heading account.
              </span>
            )}
          </div>

          <div className="two-panels">
            <div className="input-group">
              <label>Account Code</label>
              <input
                required
                maxLength={32}
                placeholder="e.g. 1010, 100101, 2100"
                value={code}
                onChange={(e) => setCode(e.target.value)}
                disabled={!!account}
              />
              <span className="field-tip">
                {parentId
                  ? "Suggested sequential sub-account number under parent."
                  : "Standard numbering: 1xxx Assets, 2xxx Liabilities, 3xxx Equity, 4xxx Revenue, 5xxx Cost of Sales, 6xxx Expenses."}
              </span>
            </div>

            <div className="input-group">
              <label>Account Name</label>
              <input
                required
                maxLength={200}
                placeholder="e.g. CBE Checking, Wegagen Savings, Petty Cash"
                value={name}
                onChange={(e) => setName(e.target.value)}
              />
            </div>
          </div>

          <div className="two-panels">
            <div className="input-group">
              <label>Type</label>
              <select value={type} onChange={(e) => handleTypeChange(e.target.value)} disabled={!!account || !!parentId}>
                <option value="ASSET">Asset (1xxx)</option>
                <option value="LIABILITY">Liability (2xxx)</option>
                <option value="EQUITY">Equity (3xxx)</option>
                <option value="REVENUE">Revenue (4xxx)</option>
                <option value="COST_OF_SALES">Cost of Sales (5xxx)</option>
                <option value="EXPENSE">Expense (6xxx)</option>
                <option value="OTHER_INCOME">Other Income (7xxx)</option>
                <option value="OTHER_EXPENSE">Other Expense (8xxx)</option>
              </select>
              {parentId && <span className="field-tip">Inherited from parent account.</span>}
            </div>
            <div className="input-group">
              <label>Normal Balance</label>
              <select value={normalBalance} onChange={(e) => setNormalBalance(e.target.value)} disabled={!!account || !!parentId}>
                <option value="DEBIT">Debit</option>
                <option value="CREDIT">Credit</option>
              </select>
              <span className="field-tip">
                Increases on {normalBalance.toLowerCase()}s (standard for {type.replaceAll("_", " ").toLowerCase()}).
              </span>
            </div>
          </div>
          
          <div className="input-group">
            <label>Account Role & Capabilities</label>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "0.75rem" }}>
              <label
                className="checkbox-card"
                style={{
                  border: postingAllowed ? "2px solid var(--green, #1b6a4f)" : "1px solid var(--line, #e2e8f0)",
                  background: postingAllowed ? "rgba(27, 106, 79, 0.04)" : "#fff",
                  cursor: "pointer",
                  padding: "0.75rem",
                  borderRadius: "8px",
                  display: "flex",
                  gap: "0.5rem"
                }}
              >
                <input
                  type="radio"
                  name="account_role"
                  checked={postingAllowed}
                  onChange={() => setPostingAllowed(true)}
                />
                <div className="checkbox-card-content">
                  <span className="checkbox-card-title" style={{ fontWeight: 600 }}>📝 Posting Sub-Account</span>
                  <span className="checkbox-card-desc" style={{ fontSize: "0.78rem", color: "var(--muted)" }}>
                    Transactional leaf: debits, credits, vouchers, and journals post directly to this account.
                  </span>
                </div>
              </label>

              <label
                className="checkbox-card"
                style={{
                  border: !postingAllowed ? "2px solid var(--green, #1b6a4f)" : "1px solid var(--line, #e2e8f0)",
                  background: !postingAllowed ? "rgba(27, 106, 79, 0.04)" : "#fff",
                  cursor: "pointer",
                  padding: "0.75rem",
                  borderRadius: "8px",
                  display: "flex",
                  gap: "0.5rem"
                }}
              >
                <input
                  type="radio"
                  name="account_role"
                  checked={!postingAllowed}
                  onChange={() => setPostingAllowed(false)}
                />
                <div className="checkbox-card-content">
                  <span className="checkbox-card-title" style={{ fontWeight: 600 }}>📁 Group / Header Account</span>
                  <span className="checkbox-card-desc" style={{ fontSize: "0.78rem", color: "var(--muted)" }}>
                    Summary heading: acts as a parent for further sub-accounts. Direct posting disallowed.
                  </span>
                </div>
              </label>
            </div>
          </div>

          <label className="checkbox-card">
            <input
              type="checkbox"
              checked={controlAccount}
              onChange={(e) => setControlAccount(e.target.checked)}
              disabled={!!account}
            />
            <div className="checkbox-card-content">
              <span className="checkbox-card-title">Control Account</span>
              <span className="checkbox-card-desc">
                {controlAccount
                  ? "Control: Managed exclusively by sub-ledgers (e.g. AR, AP, or Inventory)."
                  : "Standard general ledger account."}
              </span>
            </div>
          </label>
          
          {/* Direct Reporting & Financial Analytics Section */}
          <div style={{
            background: "linear-gradient(135deg, rgba(246, 248, 247, 0.8) 0%, rgba(232, 243, 238, 0.6) 100%)",
            border: "1px solid #c2ded3",
            borderRadius: "8px",
            padding: "1rem",
            display: "flex",
            flexDirection: "column",
            gap: "0.85rem"
          }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <div style={{ display: "flex", alignItems: "center", gap: "0.4rem", fontWeight: 700, color: "var(--ink)", fontSize: "0.95rem" }}>
                <span>📊</span>
                <span>Reporting & Financial Analytics</span>
              </div>
              <span style={{ fontSize: "0.75rem", background: "var(--mint)", color: "var(--green)", padding: "2px 8px", borderRadius: "12px", fontWeight: 600, border: "1px solid #b2d8c9" }}>
                Live BI & Ratios
              </span>
            </div>

            {/* Target Financial Statement Classification */}
            <div className="input-group" style={{ margin: 0 }}>
              <label style={{ fontSize: "0.8rem", fontWeight: 600 }}>Financial Statement Mapping</label>
              <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: "0.5rem" }}>
                {[
                  { id: "BALANCE_SHEET", label: "Balance Sheet", icon: "🏛️" },
                  { id: "PROFIT_LOSS", label: "Profit & Loss (P&L)", icon: "📈" },
                  { id: "CASH_FLOW", label: "Cash Flow", icon: "💵" }
                ].map(st => {
                  const isAutoSelected = 
                    (st.id === "BALANCE_SHEET" && ["ASSET", "LIABILITY", "EQUITY"].includes(type)) ||
                    (st.id === "PROFIT_LOSS" && ["REVENUE", "EXPENSE", "COST_OF_SALES", "OTHER_INCOME", "OTHER_EXPENSE"].includes(type)) ||
                    (st.id === "CASH_FLOW" && (name.toLowerCase().includes("cash") || name.toLowerCase().includes("bank")));
                  const isSelected = statementType ? statementType === st.id : isAutoSelected;

                  return (
                    <button
                      key={st.id}
                      type="button"
                      onClick={() => setStatementType(st.id)}
                      style={{
                        padding: "0.4rem 0.5rem",
                        borderRadius: "6px",
                        fontSize: "0.75rem",
                        fontWeight: isSelected ? 700 : 500,
                        border: isSelected ? "2px solid var(--green)" : "1px solid var(--line)",
                        background: isSelected ? "#fff" : "rgba(255,255,255,0.6)",
                        color: isSelected ? "var(--green)" : "var(--muted)",
                        cursor: "pointer",
                        display: "flex",
                        alignItems: "center",
                        justifyContent: "center",
                        gap: "0.25rem",
                        boxShadow: isSelected ? "0 2px 4px rgba(0,0,0,0.05)" : "none",
                        transition: "all 0.15s ease"
                      }}
                    >
                      <span>{st.icon}</span>
                      <span>{st.label}</span>
                    </button>
                  );
                })}
              </div>
            </div>

            {/* Reporting Category Dropdown */}
            <div className="input-group" style={{ margin: 0 }}>
              <label style={{ fontSize: "0.8rem", fontWeight: 600 }}>Reporting Category</label>
              <select
                value={selectedCategoryOption}
                onChange={(e) => {
                  setSelectedCategoryOption(e.target.value);
                  if (e.target.value !== "__custom__") {
                    setCustomCategoryText("");
                  }
                }}
              >
                <optgroup label={`Standard ${type.replaceAll("_", " ")} Categories`}>
                  {availableCategories.map((cat) => (
                    <option key={cat} value={cat}>
                      {cat}
                    </option>
                  ))}
                </optgroup>
                <option value="__custom__">-- Custom (Enter manually) --</option>
              </select>
              
              {selectedCategoryOption === "__custom__" && (
                <input
                  style={{ marginTop: "6px" }}
                  required
                  maxLength={100}
                  placeholder="Enter custom reporting category name"
                  value={customCategoryText}
                  onChange={(e) => setCustomCategoryText(e.target.value)}
                />
              )}
            </div>

            {/* Analytics KPI Tag & Cost Center Dimensions */}
            <div className="two-panels" style={{ gap: "0.75rem" }}>
              <div className="input-group" style={{ margin: 0 }}>
                <label style={{ fontSize: "0.8rem", fontWeight: 600 }}>Analytics KPI Tag</label>
                <select
                  value={analyticsTag}
                  onChange={(e) => setAnalyticsTag(e.target.value)}
                  style={{ fontSize: "0.85rem" }}
                >
                  <option value="">-- Standard (Auto-tagged) --</option>
                  <option value="Working Capital">Working Capital Asset</option>
                  <option value="Liquid Reserves">Cash & Liquid Reserves</option>
                  <option value="Operating Revenue">Core Operating Revenue</option>
                  <option value="Direct Cost (COGS)">Direct Cost (COGS)</option>
                  <option value="Operating Overhead">Operating Overhead (OPEX)</option>
                  <option value="Fixed Asset Register">Fixed Asset / Capex</option>
                  <option value="Statutory Tax">Statutory / Tax Obligation</option>
                  <option value="Financing Cash Flow">Financing / Equity Flow</option>
                </select>
              </div>

              <div className="input-group" style={{ margin: 0 }}>
                <label style={{ fontSize: "0.8rem", fontWeight: 600 }}>Analytical Dimension / Cost Center</label>
                <select
                  value={dimensionId}
                  onChange={(e) => setDimensionId(e.target.value)}
                  style={{ fontSize: "0.85rem" }}
                >
                  <option value="">-- Company-Wide / Universal --</option>
                  {reference.dimensions?.filter(d => d.active).map(d => (
                    <option key={d.id} value={d.id}>
                      {d.code} - {d.name} ({d.kind})
                    </option>
                  ))}
                </select>
              </div>
            </div>

            <span className="field-tip" style={{ margin: 0, fontSize: "0.75rem", color: "var(--muted)" }}>
              Directly connects this account to Balance Sheet, P&L reports, cashflow forecasting, and multi-dimensional cost center analytics.
            </span>
          </div>

          {account && (
            <label style={{ display: 'flex', alignItems: 'center', gap: '8px', padding: '4px 0' }}>
              <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} />
              <span>Active account</span>
            </label>
          )}

          <div className="modal-footer">
            <button type="button" className="btn-secondary" onClick={onClose} disabled={busy}>Cancel</button>
            <button type="submit" className="btn-primary" disabled={busy}>{account ? "Save Changes" : "Create Account"}</button>
          </div>
        </form>
      </div>
    </div>
  );
}

