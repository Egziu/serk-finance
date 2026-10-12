import { useState, useMemo, useEffect } from "react";
import type { GridColDef } from "@mui/x-data-grid";
import { DataTable } from "../DataTable";
import { AccountForm, REPORTING_CATEGORIES_BY_TYPE } from "../AccountForm";
import { BranchForm } from "../BranchForm";
import { DimensionForm } from "../DimensionForm";
import { api } from "../api";
import {
  ChevronRight,
  ChevronDown,
  Folder,
  FolderOpen,
  FileText,
  Plus,
  Search,
  X,
  Check,
  Download,
  ChevronsDown,
  ChevronsRight,
} from "lucide-react";
import type { Account, Dimension, Reference } from "../types";

type Props = {
  company: string;
  csrf: string;
  reference: Reference | null;
  onLedger: (id: string) => void;
  refreshReference: () => void;
};

type Branch = Reference["branches"][number];

type AccountNode = Account & {
  children: AccountNode[];
  depth: number;
};

const use = (a: Account) =>
  !a.active ? "INACTIVE" : a.control_account ? "CONTROL" : a.posting_allowed ? "POSTING" : "HEADING";

const lower = (v: unknown) => (v ? String(v).replaceAll("_", " ").toLowerCase() : "—");

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

function getSuggestedSubCode(parentAcc: Account, existingAccounts: Account[]): string {
  const siblings = existingAccounts.filter((a) => a.parent_id === parentAcc.id);
  if (siblings.length === 0) {
    if (parentAcc.code.endsWith("00") || parentAcc.code.endsWith("000")) {
      const num = parseInt(parentAcc.code, 10);
      if (!isNaN(num)) return String(num + 1);
    }
    return `${parentAcc.code}01`;
  }
  const numericSiblings = siblings
    .map((s) => parseInt(s.code, 10))
    .filter((n) => !isNaN(n));
  if (numericSiblings.length > 0) {
    const maxCode = Math.max(...numericSiblings);
    return String(maxCode + 1);
  }
  return `${parentAcc.code}${siblings.length + 1}`;
}

function getTypeBg(t: string): string {
  switch (t) {
    case "ASSET":
      return "rgba(16, 185, 129, 0.12)";
    case "LIABILITY":
      return "rgba(245, 158, 11, 0.12)";
    case "EQUITY":
      return "rgba(59, 130, 246, 0.12)";
    case "REVENUE":
      return "rgba(20, 184, 166, 0.12)";
    case "COST_OF_SALES":
      return "rgba(236, 72, 153, 0.12)";
    case "EXPENSE":
      return "rgba(239, 68, 68, 0.12)";
    default:
      return "rgba(100, 116, 139, 0.12)";
  }
}

function getTypeColor(t: string): string {
  switch (t) {
    case "ASSET":
      return "#065f46";
    case "LIABILITY":
      return "#92400e";
    case "EQUITY":
      return "#1e40af";
    case "REVENUE":
      return "#0f766e";
    case "COST_OF_SALES":
      return "#9d174d";
    case "EXPENSE":
      return "#991b1b";
    default:
      return "#334155";
  }
}

function buildAccountTree(accounts: Account[]): AccountNode[] {
  const map = new Map<string, AccountNode>();
  for (const a of accounts) {
    map.set(a.id, { ...a, children: [], depth: 0 });
  }

  const roots: AccountNode[] = [];
  for (const a of accounts) {
    const node = map.get(a.id)!;
    if (a.parent_id && map.has(a.parent_id)) {
      map.get(a.parent_id)!.children.push(node);
    } else {
      roots.push(node);
    }
  }

  function setup(nodes: AccountNode[], depth: number) {
    nodes.sort((x, y) => x.code.localeCompare(y.code, undefined, { numeric: true }));
    for (const n of nodes) {
      n.depth = depth;
      setup(n.children, depth + 1);
    }
  }

  setup(roots, 0);
  return roots;
}

// Inline Sub-Account Creation Row placed at exact table position
function InlineSubAccountRow({
  parentAccount,
  depth,
  company,
  csrf,
  existingAccounts,
  onCancel,
  onSuccess,
}: {
  parentAccount: Account;
  depth: number;
  company: string;
  csrf: string;
  existingAccounts: Account[];
  onCancel: () => void;
  onSuccess: () => void;
}) {
  const suggestedCode = getSuggestedSubCode(parentAccount, existingAccounts);
  const [code, setCode] = useState(suggestedCode);
  const [name, setName] = useState("");
  const [postingAllowed, setPostingAllowed] = useState(true);
  const defaultCategory =
    parentAccount.reporting_category ||
    REPORTING_CATEGORIES_BY_TYPE[parentAccount.type]?.[0] ||
    "Cash & Cash Equivalents";
  const [reportingCategory, setReportingCategory] = useState(defaultCategory);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const categories = REPORTING_CATEGORIES_BY_TYPE[parentAccount.type] || [];

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      setError("Please enter a name for the sub-account.");
      return;
    }
    setError("");
    setBusy(true);

    try {
      await api("/accounting/accounts", company, {
        method: "POST",
        csrf,
        body: {
          code: code.trim(),
          name: name.trim(),
          type: parentAccount.type,
          normal_balance:
            parentAccount.normal_balance || defaultNormalBalance(parentAccount.type),
          parent_id: parentAccount.id,
          posting_allowed: postingAllowed,
          control_account: false,
          reporting_category: reportingCategory,
        },
      });
      onSuccess();
    } catch (err: any) {
      setError(err.message || "Failed to create sub-account");
    } finally {
      setBusy(false);
    }
  };

  return (
    <tr
      style={{
        background: "linear-gradient(90deg, #ecfdf5 0%, #f0fdf4 100%)",
        borderTop: "2px solid #6ee7b7",
        borderBottom: "2px solid #6ee7b7",
      }}
    >
      <td colSpan={8} style={{ padding: "14px 18px" }}>
        <form onSubmit={handleSave}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              marginBottom: "10px",
              paddingLeft: `${(depth + 1) * 22}px`,
            }}
          >
            <div style={{ display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap" }}>
              <span style={{ color: "#065f46", fontWeight: 700, fontSize: "0.88rem" }}>
                ↳ ➕ New Sub-Account directly under:
              </span>
              <strong style={{ color: "#047857", fontSize: "0.9rem" }}>
                {parentAccount.code} · {parentAccount.name}
              </strong>
              {parentAccount.posting_allowed && (
                <span
                  style={{
                    fontSize: "0.74rem",
                    background: "#fef3c7",
                    color: "#92400e",
                    padding: "2px 8px",
                    borderRadius: "4px",
                    border: "1px solid #fde68a",
                  }}
                >
                  Parent will automatically become a Group Header summary account
                </span>
              )}
            </div>
            <button
              type="button"
              onClick={onCancel}
              style={{
                background: "transparent",
                border: "none",
                cursor: "pointer",
                color: "#64748b",
                padding: "4px",
              }}
              title="Cancel"
            >
              <X size={16} />
            </button>
          </div>

          {error && (
            <div
              style={{
                color: "#991b1b",
                fontSize: "0.8rem",
                marginBottom: "8px",
                padding: "6px 10px",
                background: "#fee2e2",
                borderRadius: "4px",
                marginLeft: `${(depth + 1) * 22}px`,
              }}
            >
              {error}
            </div>
          )}

          <div
            style={{
              display: "grid",
              gridTemplateColumns: "120px 2fr 1.3fr 1.5fr auto",
              gap: "10px",
              alignItems: "center",
              paddingLeft: `${(depth + 1) * 22}px`,
            }}
          >
            <div>
              <label style={{ fontSize: "0.72rem", color: "#475569", display: "block", marginBottom: "3px", fontWeight: 600 }}>
                Code
              </label>
              <input
                required
                maxLength={32}
                value={code}
                onChange={(e) => setCode(e.target.value)}
                placeholder="Code"
                style={{
                  width: "100%",
                  padding: "6px 8px",
                  fontSize: "0.82rem",
                  fontFamily: "monospace",
                  border: "1px solid #a7f3d0",
                  borderRadius: "6px",
                  background: "#fff",
                }}
              />
            </div>

            <div>
              <label style={{ fontSize: "0.72rem", color: "#475569", display: "block", marginBottom: "3px", fontWeight: 600 }}>
                Sub-Account Name
              </label>
              <input
                required
                autoFocus
                maxLength={200}
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="e.g. Commercial Bank of Ethiopia (CBE), Checking Account..."
                style={{
                  width: "100%",
                  padding: "6px 10px",
                  fontSize: "0.82rem",
                  border: "1px solid #a7f3d0",
                  borderRadius: "6px",
                  background: "#fff",
                }}
              />
            </div>

            <div>
              <label style={{ fontSize: "0.72rem", color: "#475569", display: "block", marginBottom: "3px", fontWeight: 600 }}>
                Role
              </label>
              <div style={{ display: "flex", gap: "6px" }}>
                <button
                  type="button"
                  onClick={() => setPostingAllowed(true)}
                  style={{
                    flex: 1,
                    padding: "5px 6px",
                    fontSize: "0.72rem",
                    borderRadius: "5px",
                    border: postingAllowed ? "2px solid #059669" : "1px solid #cbd5e1",
                    background: postingAllowed ? "#ecfdf5" : "#fff",
                    color: postingAllowed ? "#065f46" : "#64748b",
                    fontWeight: postingAllowed ? 700 : 500,
                    cursor: "pointer",
                    whiteSpace: "nowrap",
                  }}
                  title="Direct transactions post here"
                >
                  📝 Posting
                </button>
                <button
                  type="button"
                  onClick={() => setPostingAllowed(false)}
                  style={{
                    flex: 1,
                    padding: "5px 6px",
                    fontSize: "0.72rem",
                    borderRadius: "5px",
                    border: !postingAllowed ? "2px solid #059669" : "1px solid #cbd5e1",
                    background: !postingAllowed ? "#ecfdf5" : "#fff",
                    color: !postingAllowed ? "#065f46" : "#64748b",
                    fontWeight: !postingAllowed ? 700 : 500,
                    cursor: "pointer",
                    whiteSpace: "nowrap",
                  }}
                  title="Group header for deeper sub-accounts"
                >
                  📁 Header
                </button>
              </div>
            </div>

            <div>
              <label style={{ fontSize: "0.72rem", color: "#475569", display: "block", marginBottom: "3px", fontWeight: 600 }}>
                Reporting Category
              </label>
              <select
                value={reportingCategory}
                onChange={(e) => setReportingCategory(e.target.value)}
                style={{
                  width: "100%",
                  padding: "6px 8px",
                  fontSize: "0.82rem",
                  border: "1px solid #a7f3d0",
                  borderRadius: "6px",
                  background: "#fff",
                }}
              >
                {categories.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </div>

            <div style={{ display: "flex", gap: "6px", alignItems: "flex-end", height: "100%", paddingTop: "14px" }}>
              <button
                type="submit"
                disabled={busy}
                className="btn-primary"
                style={{
                  padding: "6px 12px",
                  fontSize: "0.78rem",
                  minHeight: "unset",
                  display: "inline-flex",
                  alignItems: "center",
                  gap: "4px",
                  background: "#059669",
                  borderColor: "#059669",
                }}
              >
                <Check size={14} />
                {busy ? "Saving…" : "Save"}
              </button>
              <button
                type="button"
                onClick={onCancel}
                disabled={busy}
                className="btn-secondary"
                style={{ padding: "6px 10px", fontSize: "0.78rem", minHeight: "unset" }}
              >
                Cancel
              </button>
            </div>
          </div>
        </form>
      </td>
    </tr>
  );
}

// Single Account Row in the Tree Grid
function AccountRow({
  node,
  parentName,
  isExpanded,
  hasChildren,
  onToggleExpand,
  onAddSubAccount,
  onEdit,
  onLedger,
}: {
  node: AccountNode;
  parentName?: string;
  isExpanded: boolean;
  hasChildren: boolean;
  onToggleExpand: () => void;
  onAddSubAccount: () => void;
  onEdit: () => void;
  onLedger: (id: string) => void;
}) {
  const isGroupHeader = !node.posting_allowed || hasChildren;
  const depthPadding = node.depth * 22;

  return (
    <tr
      key={node.id}
      className={`account-tree-row depth-${node.depth}`}
      style={{
        background: isGroupHeader ? (node.depth === 0 ? "rgba(240, 244, 242, 0.4)" : "rgba(248, 250, 249, 0.5)") : undefined,
        fontWeight: isGroupHeader ? 600 : 400,
        transition: "background 0.15s ease",
      }}
    >
      {/* Code */}
      <td style={{ fontFamily: "monospace", fontSize: "0.85rem", color: "var(--ink)", width: "110px", whiteSpace: "nowrap" }}>
        {node.code}
      </td>

      {/* Account Name with tree toggle, depth, icon, and hover dropdown */}
      <td>
        <div style={{ display: "flex", alignItems: "center", paddingLeft: `${depthPadding}px` }}>
          {/* Roll-down toggle or tree connector */}
          {hasChildren ? (
            <button
              type="button"
              onClick={onToggleExpand}
              style={{
                background: "transparent",
                border: "none",
                cursor: "pointer",
                padding: "2px",
                marginRight: "4px",
                display: "inline-flex",
                alignItems: "center",
                color: isExpanded ? "var(--green, #1b6a4f)" : "#64748b",
              }}
              title={isExpanded ? "Collapse sub-accounts roll-down" : "Expand sub-accounts roll-down"}
            >
              {isExpanded ? <ChevronDown size={16} /> : <ChevronRight size={16} />}
            </button>
          ) : node.depth > 0 ? (
            <span
              style={{
                color: "#94a3b8",
                marginRight: "6px",
                fontFamily: "monospace",
                fontSize: "0.95rem",
                userSelect: "none",
              }}
            >
              ↳
            </span>
          ) : (
            <span style={{ width: "20px", display: "inline-block" }} />
          )}

          {/* Folder / File icon */}
          <span
            style={{
              marginRight: "8px",
              fontSize: "0.95rem",
              display: "inline-flex",
              alignItems: "center",
              color: isGroupHeader ? "#1b6a4f" : "#64748b",
            }}
          >
            {isGroupHeader ? (isExpanded ? <FolderOpen size={16} /> : <Folder size={16} />) : <FileText size={15} />}
          </span>

          {/* Account Name Link */}
          <button
            type="button"
            className="report-link"
            style={{
              fontWeight: isGroupHeader ? 700 : 500,
              color: isGroupHeader ? "var(--ink)" : "var(--green)",
              fontSize: "0.85rem",
              textAlign: "left",
            }}
            onClick={() => onLedger(node.id)}
            aria-label={`View ledger for ${node.code} ${node.name}`}
          >
            {node.name}
          </button>

          {/* Sub-account pill with hover dropdown */}
          {hasChildren && (
            <div className="sub-preview-wrapper" style={{ position: "relative", marginLeft: "8px" }}>
              <button
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  onToggleExpand();
                }}
                style={{
                  fontSize: "0.72rem",
                  padding: "1px 7px",
                  borderRadius: "10px",
                  background: isExpanded ? "rgba(27, 106, 79, 0.15)" : "rgba(27, 106, 79, 0.08)",
                  color: "var(--green, #1b6a4f)",
                  fontWeight: 600,
                  border: "1px solid rgba(27, 106, 79, 0.2)",
                  cursor: "pointer",
                  display: "inline-flex",
                  alignItems: "center",
                  gap: "2px",
                }}
                title="Hover to preview sub-accounts or click to roll down"
              >
                <span>{node.children.length} sub</span>
                <span style={{ fontSize: "0.65rem" }}>▾</span>
              </button>

              {/* Hover Dropdown */}
              <div className="sub-preview-dropdown">
                <div
                  style={{
                    fontWeight: 700,
                    fontSize: "0.8rem",
                    color: "var(--ink)",
                    paddingBottom: "6px",
                    borderBottom: "1px solid #f1f5f9",
                    marginBottom: "6px",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "space-between",
                  }}
                >
                  <span>📁 Sub-accounts under {node.code}</span>
                  <span style={{ fontSize: "0.72rem", color: "var(--muted)" }}>{node.children.length} total</span>
                </div>
                <div style={{ maxHeight: "180px", overflowY: "auto", display: "flex", flexDirection: "column", gap: "4px" }}>
                  {node.children.map((ch) => (
                    <div
                      key={ch.id}
                      style={{
                        display: "flex",
                        alignItems: "center",
                        justifyContent: "space-between",
                        padding: "4px 6px",
                        borderRadius: "4px",
                        fontSize: "0.78rem",
                        background: "#f8fafc",
                      }}
                    >
                      <div style={{ display: "flex", alignItems: "center", gap: "6px" }}>
                        <span style={{ fontFamily: "monospace", color: "#64748b" }}>{ch.code}</span>
                        <strong style={{ color: "var(--ink)" }}>{ch.name}</strong>
                      </div>
                      <span style={{ fontSize: "0.7rem", color: "#64748b" }}>
                        {ch.posting_allowed ? "📝" : "📁"}
                      </span>
                    </div>
                  ))}
                </div>
                <div style={{ borderTop: "1px solid #f1f5f9", paddingTop: "6px", marginTop: "6px", textAlign: "right" }}>
                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      onAddSubAccount();
                    }}
                    style={{
                      background: "none",
                      border: "none",
                      color: "var(--green, #1b6a4f)",
                      fontSize: "0.75rem",
                      fontWeight: 600,
                      cursor: "pointer",
                      padding: "2px 4px",
                    }}
                  >
                    + Add sub-account directly under this
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>
      </td>

      {/* Type */}
      <td style={{ width: "130px" }}>
        <span
          className="badge"
          style={{
            fontSize: "0.72rem",
            textTransform: "capitalize",
            background: getTypeBg(node.type),
            color: getTypeColor(node.type),
            fontWeight: 600,
          }}
        >
          {node.type.replaceAll("_", " ").toLowerCase()}
        </span>
      </td>

      {/* Normal Balance */}
      <td style={{ textTransform: "capitalize", fontSize: "0.82rem", color: "var(--muted)", width: "120px" }}>
        {node.normal_balance?.toLowerCase() || defaultNormalBalance(node.type).toLowerCase()}
      </td>

      {/* Reporting Category */}
      <td style={{ fontSize: "0.82rem", color: "var(--ink)", width: "160px" }}>
        {node.reporting_category || "—"}
      </td>

      {/* Parent */}
      <td style={{ fontSize: "0.82rem", color: "var(--muted)", width: "150px" }}>
        {parentName || "—"}
      </td>

      {/* Use Badge */}
      <td style={{ width: "130px" }}>
        <span
          className={
            "badge " +
            (!node.active
              ? "voided"
              : node.control_account
              ? "submitted"
              : node.posting_allowed
              ? "open"
              : "draft")
          }
        >
          <i />
          {!node.active
            ? "inactive"
            : node.control_account
            ? "control account"
            : node.posting_allowed
            ? "posting"
            : "heading only"}
        </span>
      </td>

      {/* Actions */}
      <td style={{ width: "160px", textAlign: "right" }}>
        <div style={{ display: "flex", gap: "6px", alignItems: "center", justifyContent: "flex-end" }}>
          <button
            type="button"
            className="btn-secondary"
            style={{ padding: "3px 8px", minHeight: "unset", fontSize: "0.78rem" }}
            onClick={onEdit}
            title="Edit account properties"
          >
            Edit
          </button>
          <button
            type="button"
            className="btn-secondary"
            style={{
              padding: "3px 8px",
              minHeight: "unset",
              fontSize: "0.78rem",
              color: "var(--green, #1b6a4f)",
              borderColor: "rgba(27, 106, 79, 0.35)",
              background: "rgba(27, 106, 79, 0.06)",
              fontWeight: 600,
              display: "inline-flex",
              alignItems: "center",
              gap: "3px",
            }}
            onClick={onAddSubAccount}
            title={`Add sub-account directly under ${node.code} · ${node.name}`}
          >
            <Plus size={12} />
            <span>Sub-account</span>
          </button>
        </div>
      </td>
    </tr>
  );
}

export function AccountsPage({ company, csrf, reference, onLedger, refreshReference }: Props) {
  const [editingAccount, setEditingAccount] = useState<Account | null>(null);
  const [isCreatingRoot, setIsCreatingRoot] = useState(false);
  const [inlineParentId, setInlineParentId] = useState<string | null>(null);
  const [searchTerm, setSearchTerm] = useState("");
  const [typeFilter, setTypeFilter] = useState("");
  const [isCreatingBranch, setIsCreatingBranch] = useState(false);
  const [isCreatingDimension, setIsCreatingDimension] = useState(false);

  // Build tree from reference accounts
  const treeRoots = useMemo(() => {
    if (!reference) return [];
    return buildAccountTree(reference.accounts);
  }, [reference]);

  // Expanded accounts set
  const [expandedIds, setExpandedIds] = useState<Set<string>>(() => {
    const set = new Set<string>();
    if (reference) {
      for (const a of reference.accounts) {
        if (a.parent_id) set.add(a.parent_id);
      }
    }
    return set;
  });

  // When reference accounts change, ensure parents with children are expanded
  useEffect(() => {
    if (reference) {
      setExpandedIds((prev) => {
        const next = new Set(prev);
        for (const a of reference.accounts) {
          if (a.parent_id) next.add(a.parent_id);
        }
        return next;
      });
    }
  }, [reference]);

  if (!reference) return <div className="empty"><h2>Loading chart of accounts…</h2></div>;

  const toggleExpand = (id: string) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const expandAll = () => {
    const allParentIds = new Set<string>();
    for (const a of reference.accounts) {
      if (reference.accounts.some((child) => child.parent_id === a.id)) {
        allParentIds.add(a.id);
      }
    }
    setExpandedIds(allParentIds);
  };

  const collapseAll = () => {
    setExpandedIds(new Set());
  };

  const openInlineSubAccount = (parentId: string) => {
    setInlineParentId(parentId);
    setExpandedIds((prev) => new Set(prev).add(parentId));
  };

  const isMatching = (node: AccountNode): boolean => {
    const t = searchTerm.toLowerCase().trim();
    const matchSearch =
      !t ||
      node.code.toLowerCase().includes(t) ||
      node.name.toLowerCase().includes(t) ||
      (node.reporting_category || "").toLowerCase().includes(t);
    const matchType = !typeFilter || node.type === typeFilter;
    return matchSearch && matchType;
  };

  const hasMatchingDescendant = (node: AccountNode): boolean => {
    if (isMatching(node)) return true;
    return node.children.some((c) => hasMatchingDescendant(c));
  };

  // Render tree node and its roll-down children recursively
  const renderNode = (node: AccountNode, parentName?: string): React.ReactNode[] => {
    if ((searchTerm || typeFilter) && !hasMatchingDescendant(node)) {
      return [];
    }

    const elements: React.ReactNode[] = [];
    const isExpanded = expandedIds.has(node.id) || !!searchTerm;
    const hasChildren = node.children.length > 0;

    // 1. Render the account row itself
    elements.push(
      <AccountRow
        key={node.id}
        node={node}
        parentName={parentName}
        isExpanded={isExpanded}
        hasChildren={hasChildren}
        onToggleExpand={() => toggleExpand(node.id)}
        onAddSubAccount={() => openInlineSubAccount(node.id)}
        onEdit={() => setEditingAccount(node)}
        onLedger={onLedger}
      />
    );

    // 2. If inline creating under this node, render inline creation row right under it!
    if (inlineParentId === node.id) {
      elements.push(
        <InlineSubAccountRow
          key={`inline-add-${node.id}`}
          parentAccount={node}
          depth={node.depth}
          company={company}
          csrf={csrf}
          existingAccounts={reference.accounts}
          onCancel={() => setInlineParentId(null)}
          onSuccess={() => {
            setInlineParentId(null);
            refreshReference();
          }}
        />
      );
    }

    // 3. If expanded, render children rows immediately below it!
    if (isExpanded && hasChildren) {
      for (const child of node.children) {
        elements.push(...renderNode(child, `${node.code} · ${node.name}`));
      }
    }

    return elements;
  };

  const exportCsv = () => {
    const headers = ["Code", "Name", "Type", "Normal Balance", "Reporting Category", "Parent Code", "Use"];
    const rows = reference.accounts
      .slice()
      .sort((a, b) => a.code.localeCompare(b.code, undefined, { numeric: true }))
      .map((a) => {
        const p = reference.accounts.find((x) => x.id === a.parent_id);
        return [
          `"${a.code}"`,
          `"${a.name.replaceAll('"', '""')}"`,
          `"${a.type}"`,
          `"${a.normal_balance || defaultNormalBalance(a.type)}"`,
          `"${(a.reporting_category || "").replaceAll('"', '""')}"`,
          `"${p ? p.code : ""}"`,
          `"${use(a)}"`,
        ].join(",");
      });
    const csvContent = [headers.join(","), ...rows].join("\n");
    const blob = new Blob([csvContent], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.setAttribute("href", url);
    link.setAttribute("download", `chart-of-accounts-${new Date().toISOString().slice(0, 10)}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
  };

  const branchCols: GridColDef<Branch>[] = [
    { field: "code", headerName: "Code", width: 110, cellClassName: "mono-cell" },
    { field: "name", headerName: "Name", flex: 1, minWidth: 140 },
    { field: "active", headerName: "Status", type: "boolean", width: 110, valueGetter: (v) => v !== false },
  ];

  const dimensionCols: GridColDef<Dimension>[] = [
    {
      field: "kind",
      headerName: "Kind",
      type: "singleSelect",
      minWidth: 140,
      valueFormatter: lower,
      valueOptions: [
        "DEPARTMENT",
        "COST_CENTER",
        "PROJECT",
        "CONTRACT",
        "WBS",
        "FUNDING_SOURCE",
        "EMPLOYEE",
        "CUSTOMER",
        "SUPPLIER",
        "WAREHOUSE",
        "ASSET",
      ],
    },
    { field: "code", headerName: "Code", width: 110, cellClassName: "mono-cell" },
    { field: "name", headerName: "Name", flex: 1, minWidth: 140 },
    { field: "active", headerName: "Active", type: "boolean", width: 100 },
  ];

  const types = [...new Set(reference.accounts.map((a) => a.type))];

  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">MASTER DATA</div>
          <h1>Chart of accounts</h1>
          <p>Hierarchical multi-level chart of accounts, branches and dimensions for this company.</p>
        </div>
        <div className="toolbar">
          <button
            className="btn-primary"
            onClick={() => {
              setIsCreatingRoot(true);
            }}
          >
            + New root account
          </button>
        </div>
      </div>

      {(isCreatingRoot || editingAccount) && (
        <AccountForm
          company={company}
          csrf={csrf}
          reference={reference}
          account={editingAccount}
          onClose={() => {
            setIsCreatingRoot(false);
            setEditingAccount(null);
          }}
          onSuccess={() => {
            setIsCreatingRoot(false);
            setEditingAccount(null);
            refreshReference();
          }}
        />
      )}

      {/* Main Accounts Hierarchical Tree DataGrid */}
      <section className="account-tree-table-wrap">
        <div style={{ padding: "16px 20px", borderBottom: "1px solid var(--line)", background: "var(--surface-50, #fbfcfb)" }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", flexWrap: "wrap", gap: "10px" }}>
            <div>
              <h2 style={{ margin: 0, fontSize: 16, fontWeight: 600, color: "var(--ink)" }}>Main Accounts Hierarchy</h2>
              <p style={{ margin: "4px 0 0 0", color: "#64748b", fontSize: 13 }}>
                Multi-level accounts tree with inline sub-account creation, roll-down accordions, and hover previews.
              </p>
            </div>
            <div style={{ display: "flex", gap: "8px", alignItems: "center" }}>
              <button
                type="button"
                className="btn-secondary"
                style={{ padding: "4px 10px", fontSize: "0.78rem", minHeight: "unset", display: "inline-flex", gap: "4px", alignItems: "center" }}
                onClick={expandAll}
                title="Expand all parent accounts"
              >
                <ChevronsDown size={14} />
                <span>Expand All</span>
              </button>
              <button
                type="button"
                className="btn-secondary"
                style={{ padding: "4px 10px", fontSize: "0.78rem", minHeight: "unset", display: "inline-flex", gap: "4px", alignItems: "center" }}
                onClick={collapseAll}
                title="Collapse all parent accounts"
              >
                <ChevronsRight size={14} />
                <span>Collapse All</span>
              </button>
              <button
                type="button"
                className="btn-secondary"
                style={{ padding: "4px 10px", fontSize: "0.78rem", minHeight: "unset", display: "inline-flex", gap: "4px", alignItems: "center" }}
                onClick={exportCsv}
                title="Export Chart of Accounts as CSV"
              >
                <Download size={14} />
                <span>Export CSV</span>
              </button>
            </div>
          </div>
        </div>

        {/* Toolbar with Search and Type Filter */}
        <div className="account-tree-toolbar">
          <div className="account-tree-search">
            <Search size={15} color="#94a3b8" />
            <input
              type="text"
              placeholder="Search by code, account name, category…"
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
            />
            {searchTerm && (
              <button
                type="button"
                onClick={() => setSearchTerm("")}
                style={{ background: "transparent", border: "none", cursor: "pointer", color: "#94a3b8", padding: 0 }}
              >
                <X size={14} />
              </button>
            )}
          </div>

          <div className="account-tree-filters">
            <span style={{ fontSize: "0.78rem", color: "#64748b", fontWeight: 600 }}>Filter Type:</span>
            <select
              value={typeFilter}
              onChange={(e) => setTypeFilter(e.target.value)}
              style={{
                fontSize: "0.8rem",
                padding: "4px 10px",
                border: "1px solid #cbd5e1",
                borderRadius: "6px",
                background: "#fff",
              }}
            >
              <option value="">All Types ({reference.accounts.length})</option>
              {types.map((t) => (
                <option key={t} value={t}>
                  {t.replaceAll("_", " ")} ({reference.accounts.filter((a) => a.type === t).length})
                </option>
              ))}
            </select>
          </div>
        </div>

        {/* The Tree Table */}
        <div style={{ overflowX: "auto" }}>
          <table className="account-tree-table">
            <thead>
              <tr>
                <th>Code</th>
                <th>Account</th>
                <th>Type</th>
                <th>Normal Balance</th>
                <th>Reporting Category</th>
                <th>Parent</th>
                <th>Use</th>
                <th style={{ textAlign: "right" }}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {treeRoots.length === 0 ? (
                <tr>
                  <td colSpan={8} style={{ textAlign: "center", padding: "30px", color: "var(--muted)" }}>
                    No accounts found in this company.
                  </td>
                </tr>
              ) : (
                treeRoots.flatMap((root) => renderNode(root))
              )}
            </tbody>
          </table>
        </div>
      </section>

      <div className="two-panels">
        <DataTable<Branch>
          label="Branches"
          title="Branches & Locations"
          description="Geographical or organizational divisions that can host independent sub-ledgers."
          rows={reference.branches}
          columns={branchCols}
          fileName="branches"
          autoHeight
          pageSize={10}
          onAdd={() => setIsCreatingBranch(true)}
          addLabel="New branch"
        />
        <DataTable<Dimension>
          label="Dimensions"
          title="Analytical Dimensions"
          description="Tags and cost centers used for detailed managerial reporting and analytics."
          rows={reference.dimensions ?? []}
          columns={dimensionCols}
          fileName="dimensions"
          autoHeight
          pageSize={10}
          onAdd={() => setIsCreatingDimension(true)}
          addLabel="New dimension"
        />
      </div>

      {isCreatingDimension && (
        <DimensionForm
          company={company}
          csrf={csrf}
          onClose={() => setIsCreatingDimension(false)}
          onSuccess={() => {
            setIsCreatingDimension(false);
            refreshReference();
          }}
        />
      )}

      {isCreatingBranch && (
        <BranchForm
          company={company}
          csrf={csrf}
          onClose={() => setIsCreatingBranch(false)}
          onSuccess={() => {
            setIsCreatingBranch(false);
            refreshReference();
          }}
        />
      )}
    </>
  );
}
