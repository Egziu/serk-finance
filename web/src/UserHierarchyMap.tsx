import { useMemo, useState, useRef } from "react";
import { 
  Shield, 
  User, 
  Users, 
  CheckCircle2, 
  XCircle, 
  Lock, 
  Key, 
  Search, 
  Copy, 
  Check, 
  ArrowRight,
  ArrowUpRight, 
  Layers, 
  ExternalLink,
  ChevronRight,
  Info,
  GitBranch,
  Network,
  LayoutGrid,
  Filter,
  Maximize2,
  ZoomIn,
  ZoomOut,
  RotateCcw,
  Sparkles,
  ArrowDownRight,
  AlertCircle
} from "lucide-react";
import type { AdminCatalog, AdminRole, AdminUser, Grant, PermissionInfo } from "./types";
import { money } from "./api";

type Props = {
  catalog: AdminCatalog;
  currencyPlaces: number;
  onSelectUser?: (user: AdminUser) => void;
};

type TierLevel = 1 | 2 | 3 | 0;

interface TierMeta {
  level: TierLevel;
  title: string;
  stageName: string;
  shortTitle: string;
  subtitle: string;
  flowRole: string;
  accentColor: string;
  bgLight: string;
  borderClass: string;
  badgeClass: string;
}

const TIERS: Record<TierLevel, TierMeta> = {
  3: {
    level: 3,
    title: "Executive & System Governance",
    stageName: "STAGE 3 · GOVERNANCE",
    shortTitle: "Tier 3 · Governance",
    subtitle: "Super Administrators overseeing accounting policies, role access, and audit trail",
    flowRole: "System Oversight & Final Audit",
    accentColor: "#6366f1",
    bgLight: "rgba(99, 102, 241, 0.08)",
    borderClass: "tier-card-admin",
    badgeClass: "tier-badge-admin",
  },
  2: {
    level: 2,
    title: "Financial Control & Approvals",
    stageName: "STAGE 2 · APPROVALS",
    shortTitle: "Tier 2 · Approvers",
    subtitle: "Finance Controllers & Approvers authorized to review and approve transactions",
    flowRole: "Validates & Approves Submissions",
    accentColor: "#10b981",
    bgLight: "rgba(16, 185, 129, 0.08)",
    borderClass: "tier-card-approver",
    badgeClass: "tier-badge-approver",
  },
  1: {
    level: 1,
    title: "Operational Entry & Accounting",
    stageName: "STAGE 1 · DATA ENTRY",
    shortTitle: "Tier 1 · Preparers",
    subtitle: "Accountants & Clerks who prepare draft journals, invoices, and purchase bills",
    flowRole: "Prepares & Initiates Transactions",
    accentColor: "#0284c7",
    bgLight: "rgba(2, 132, 199, 0.08)",
    borderClass: "tier-card-clerk",
    badgeClass: "tier-badge-clerk",
  },
  0: {
    level: 0,
    title: "Unassigned Tenant Users",
    stageName: "UNASSIGNED",
    shortTitle: "Unassigned",
    subtitle: "Accounts registered without active company role assignments",
    flowRole: "Pending Role Assignment",
    accentColor: "#94a3b8",
    bgLight: "rgba(148, 163, 184, 0.08)",
    borderClass: "tier-card-none",
    badgeClass: "tier-badge-none",
  },
};

function determineUserTier(user: AdminUser, rolesMap: Map<string, AdminRole>): TierLevel {
  if (!user.grants || user.grants.length === 0) return 0;

  let hasAdmin = false;
  let hasApprover = false;
  let hasEntry = false;

  for (const g of user.grants) {
    const role = rolesMap.get(g.role_id);
    if (!role) continue;
    const nameLower = (role.name || "").toLowerCase();
    const perms = role.permissions || [];

    if (
      nameLower.includes("admin") ||
      perms.includes("user.manage") ||
      perms.includes("role.manage") ||
      perms.includes("configuration.manage")
    ) {
      hasAdmin = true;
    } else if (
      nameLower.includes("approv") ||
      nameLower.includes("finance") ||
      nameLower.includes("manager") ||
      perms.includes("journal.approve") ||
      perms.includes("journal.post") ||
      perms.includes("period.close") ||
      perms.includes("sales.manage") ||
      perms.includes("purchases.manage") ||
      perms.includes("payroll.manage") ||
      perms.includes("taxes.manage")
    ) {
      hasApprover = true;
    } else {
      hasEntry = true;
    }
  }

  if (hasAdmin) return 3;
  if (hasApprover) return 2;
  if (hasEntry) return 1;
  return 1;
}

export function UserHierarchyMap({ catalog, currencyPlaces, onSelectUser }: Props) {
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [tierFilter, setTierFilter] = useState<number | "ALL">("ALL");
  const [viewMode, setViewMode] = useState<"GRAPH" | "CARDS">("GRAPH");
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const [hoveredUserId, setHoveredUserId] = useState<string | null>(null);
  const [zoom, setZoom] = useState(1.0);
  const [permSearch, setPermSearch] = useState("");

  // Map roles and permissions for lookup
  const rolesMap = useMemo(() => {
    const m = new Map<string, AdminRole>();
    for (const r of catalog.roles) m.set(r.id, r);
    return m;
  }, [catalog.roles]);

  const permissionsMap = useMemo(() => {
    const m = new Map<string, PermissionInfo>();
    for (const p of catalog.permissions) m.set(p.code, p);
    return m;
  }, [catalog.permissions]);

  // Build classified user list with computed tiers
  const userTierList = useMemo(() => {
    return catalog.users.map((u) => {
      const tier = determineUserTier(u, rolesMap);
      const distinctPerms = new Set<string>();
      for (const g of u.grants) {
        const r = rolesMap.get(g.role_id);
        if (r && r.permissions) {
          for (const p of r.permissions) distinctPerms.add(p);
        }
      }
      return {
        user: u,
        tier,
        permissions: Array.from(distinctPerms).sort(),
      };
    });
  }, [catalog.users, rolesMap]);

  // Group by tier
  const tier1All = useMemo(() => userTierList.filter((u) => u.tier === 1), [userTierList]);
  const tier2All = useMemo(() => userTierList.filter((u) => u.tier === 2), [userTierList]);
  const tier3All = useMemo(() => userTierList.filter((u) => u.tier === 3), [userTierList]);
  const tier0All = useMemo(() => userTierList.filter((u) => u.tier === 0), [userTierList]);

  // Filter users by search & tier filter
  const filteredUsers = useMemo(() => {
    let list = userTierList;
    if (tierFilter !== "ALL") {
      list = list.filter((u) => u.tier === tierFilter);
    }
    const q = search.trim().toLowerCase();
    if (!q) return list;
    return list.filter(({ user, permissions }) => {
      const nameMatch = user.display_name.toLowerCase().includes(q);
      const emailMatch = user.email.toLowerCase().includes(q);
      const idMatch = user.id.toLowerCase().includes(q);
      const roleMatch = user.grants.some((g) => (g.role_name || "").toLowerCase().includes(q));
      const permMatch = permissions.some((p) => p.toLowerCase().includes(q));
      return nameMatch || emailMatch || idMatch || roleMatch || permMatch;
    });
  }, [userTierList, search, tierFilter]);

  const filteredTier1 = useMemo(() => filteredUsers.filter((u) => u.tier === 1), [filteredUsers]);
  const filteredTier2 = useMemo(() => filteredUsers.filter((u) => u.tier === 2), [filteredUsers]);
  const filteredTier3 = useMemo(() => filteredUsers.filter((u) => u.tier === 3), [filteredUsers]);
  const filteredTier0 = useMemo(() => filteredUsers.filter((u) => u.tier === 0), [filteredUsers]);

  const selectedUserData = useMemo(() => {
    if (!selectedUserId) return null;
    return userTierList.find((item) => item.user.id === selectedUserId) || null;
  }, [selectedUserId, userTierList]);

  // ----------------------------------------------------
  // GRAPH CANVAS METRICS & COORDINATE COMPUTATIONS
  // ----------------------------------------------------
  const NODE_WIDTH = 280;
  const NODE_HEIGHT = 104;
  const GAP_Y = 24;
  const COL_1_X = 40;   // Tier 1: Preparers
  const COL_2_X = 450;  // Tier 2: Approvers
  const COL_3_X = 860;  // Tier 3: Governance
  const CANVAS_WIDTH = 1180;

  // Total rows required based on maximum tier count
  const maxRowsInTier = Math.max(
    filteredTier1.length, 
    filteredTier2.length, 
    filteredTier3.length, 
    1
  );
  const canvasHeight = Math.max(maxRowsInTier * (NODE_HEIGHT + GAP_Y) + 90, 480);

  // Compute 2D node coordinates on the canvas
  const nodeCoords = useMemo(() => {
    const coords = new Map<string, { x: number; y: number; tier: TierLevel }>();

    const layoutColumn = (items: typeof userTierList, colX: number, tier: TierLevel) => {
      if (items.length === 0) return;
      const totalColHeight = items.length * NODE_HEIGHT + (items.length - 1) * GAP_Y;
      const startY = Math.max(50, (canvasHeight - totalColHeight) / 2);
      items.forEach((item, index) => {
        coords.set(item.user.id, {
          x: colX,
          y: startY + index * (NODE_HEIGHT + GAP_Y),
          tier,
        });
      });
    };

    layoutColumn(filteredTier1, COL_1_X, 1);
    layoutColumn(filteredTier2, COL_2_X, 2);
    layoutColumn(filteredTier3, COL_3_X, 3);
    return coords;
  }, [filteredTier1, filteredTier2, filteredTier3, canvasHeight]);

  // Dependency Edges (Prepares -> Approves -> Governs)
  const dependencyEdges = useMemo(() => {
    const edges: { 
      id: string; 
      fromId: string; 
      toId: string; 
      fromTier: TierLevel; 
      toTier: TierLevel; 
      type: "submission" | "governance" 
    }[] = [];

    // If both Tier 1 and Tier 2 exist: Tier 1 feeds to Tier 2
    if (filteredTier1.length > 0 && filteredTier2.length > 0) {
      for (const t1 of filteredTier1) {
        for (const t2 of filteredTier2) {
          edges.push({
            id: `edge-${t1.user.id}->${t2.user.id}`,
            fromId: t1.user.id,
            toId: t2.user.id,
            fromTier: 1,
            toTier: 2,
            type: "submission",
          });
        }
      }
    } else if (filteredTier1.length > 0 && filteredTier2.length === 0 && filteredTier3.length > 0) {
      // Fallback: If no dedicated approvers, Tier 1 feeds directly to Tier 3
      for (const t1 of filteredTier1) {
        for (const t3 of filteredTier3) {
          edges.push({
            id: `edge-${t1.user.id}->${t3.user.id}`,
            fromId: t1.user.id,
            toId: t3.user.id,
            fromTier: 1,
            toTier: 3,
            type: "submission",
          });
        }
      }
    }

    // Tier 2 approvers feed up to Tier 3 governance controllers
    if (filteredTier2.length > 0 && filteredTier3.length > 0) {
      for (const t2 of filteredTier2) {
        for (const t3 of filteredTier3) {
          edges.push({
            id: `edge-${t2.user.id}->${t3.user.id}`,
            fromId: t2.user.id,
            toId: t3.user.id,
            fromTier: 2,
            toTier: 3,
            type: "governance",
          });
        }
      }
    }

    return edges;
  }, [filteredTier1, filteredTier2, filteredTier3]);

  // Active focus: hovered or selected
  const activeFocusId = hoveredUserId || selectedUserId;

  // Determine all users connected to current active user
  const relatedUserIds = useMemo(() => {
    if (!activeFocusId) return new Set<string>();
    const set = new Set<string>([activeFocusId]);
    for (const e of dependencyEdges) {
      if (e.fromId === activeFocusId) set.add(e.toId);
      if (e.toId === activeFocusId) set.add(e.fromId);
    }
    return set;
  }, [activeFocusId, dependencyEdges]);

  // Compute Upstream & Downstream users for selected user inspector
  const inspectorUpstreamUsers = useMemo(() => {
    if (!selectedUserData) return [];
    if (selectedUserData.tier === 1) return tier2All.length > 0 ? tier2All : tier3All;
    if (selectedUserData.tier === 2) return tier3All;
    return [];
  }, [selectedUserData, tier2All, tier3All]);

  const inspectorDownstreamUsers = useMemo(() => {
    if (!selectedUserData) return [];
    if (selectedUserData.tier === 2) return tier1All;
    if (selectedUserData.tier === 3) return tier2All.length > 0 ? tier2All : tier1All;
    return [];
  }, [selectedUserData, tier1All, tier2All]);

  // Clipboard copy helper
  const copyToClipboard = (text: string) => {
    navigator.clipboard.writeText(text);
    setCopiedId(text);
    setTimeout(() => setCopiedId(null), 2000);
  };

  return (
    <section className="hierarchy-map-container" style={{ marginTop: 40, marginBottom: 50 }}>
      {/* HEADER SECTION */}
      <div className="hierarchy-map-header">
        <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
          <div className="hierarchy-icon-wrapper">
            <Network size={24} color="#166453" />
          </div>
          <div>
            <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
              <h2 style={{ fontSize: 21, fontWeight: 700, color: "#173b3c", margin: 0, letterSpacing: "-0.3px" }}>
                User Workflow & Dependency Graph
              </h2>
              <span className="live-pulse-badge">
                <span className="live-pulse-dot" /> Live ERP Topology
              </span>
            </div>
            <p style={{ margin: "5px 0 0", color: "#64748b", fontSize: 13, lineHeight: "1.4" }}>
              Visual workflow dependency graph showing how accounts feed transactions upward: <strong>Preparers ➔ Approvers ➔ Governance</strong>. Click any user node for full preview & permissions.
            </p>
          </div>
        </div>

        {/* TOOLBAR CONTROLS */}
        <div style={{ display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
          {/* Search box */}
          <div className="map-search-box">
            <Search size={16} color="#94a3b8" />
            <input
              type="text"
              placeholder="Search user, email, role, permission..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
            {search && (
              <button 
                type="button" 
                onClick={() => setSearch("")} 
                style={{ background: "none", border: "none", color: "#94a3b8", cursor: "pointer", padding: 0 }}
              >
                ✕
              </button>
            )}
          </div>

          {/* Tier Quick Filter Buttons */}
          <div className="map-filter-pills">
            <button
              type="button"
              className={`filter-pill ${tierFilter === "ALL" ? "active" : ""}`}
              onClick={() => setTierFilter("ALL")}
            >
              All ({catalog.users.length})
            </button>
            <button
              type="button"
              className={`filter-pill ${tierFilter === 1 ? "active" : ""}`}
              onClick={() => setTierFilter(1)}
            >
              Preparers ({tier1All.length})
            </button>
            <button
              type="button"
              className={`filter-pill ${tierFilter === 2 ? "active" : ""}`}
              onClick={() => setTierFilter(2)}
            >
              Approvers ({tier2All.length})
            </button>
            <button
              type="button"
              className={`filter-pill ${tierFilter === 3 ? "active" : ""}`}
              onClick={() => setTierFilter(3)}
            >
              Admins ({tier3All.length})
            </button>
          </div>

          {/* View Mode Toggle: Graph vs Cards */}
          <div className="view-mode-toggle">
            <button
              type="button"
              className={viewMode === "GRAPH" ? "view-toggle-btn active" : "view-toggle-btn"}
              onClick={() => setViewMode("GRAPH")}
              title="Interactive Flow & Dependency Network Graph"
            >
              <GitBranch size={15} /> Dependency Graph
            </button>
            <button
              type="button"
              className={viewMode === "CARDS" ? "view-toggle-btn active" : "view-toggle-btn"}
              onClick={() => setViewMode("CARDS")}
              title="Grouped Tier Cards Matrix"
            >
              <LayoutGrid size={15} /> Tier Cards
            </button>
          </div>
        </div>
      </div>

      {/* GRAPH CANVAS & COMPLETE PREVIEW SPLIT LAYOUT */}
      <div 
        className="hierarchy-body-layout"
        style={{
          display: "grid",
          gridTemplateColumns: selectedUserData ? "1fr 440px" : "1fr",
          gap: 24,
          marginTop: 20,
          transition: "grid-template-columns 0.25s ease",
        }}
      >
        {/* ==================================================== */}
        {/* GRAPH VIEW: INTERACTIVE NODE NETWORK CANVAS          */}
        {/* ==================================================== */}
        {viewMode === "GRAPH" && (
          <div className="graph-workspace-panel">
            {/* Top Column / Stage Lanes Banner */}
            <div className="graph-stages-banner">
              {/* STAGE 1 */}
              <div className="stage-banner-col stage-1-border">
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span className="stage-badge-indicator" style={{ background: TIERS[1].accentColor }} />
                  <div>
                    <span className="stage-pill-eyebrow">STAGE 1 · DATA ENTRY</span>
                    <h4 className="stage-col-title">Operational Preparers</h4>
                  </div>
                </div>
                <div className="stage-col-meta">
                  <span>Prepares & Submits Drafts</span>
                  <strong className="stage-count-pill">{filteredTier1.length} accounts</strong>
                </div>
              </div>

              {/* FLOW CONNECTOR 1 -> 2 */}
              <div className="stage-flow-indicator">
                <div className="flow-dash-line" />
                <div className="flow-label-badge">
                  <span>Submits For Review</span>
                  <ArrowRight size={14} />
                </div>
              </div>

              {/* STAGE 2 */}
              <div className="stage-banner-col stage-2-border">
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span className="stage-badge-indicator" style={{ background: TIERS[2].accentColor }} />
                  <div>
                    <span className="stage-pill-eyebrow">STAGE 2 · VERIFICATION</span>
                    <h4 className="stage-col-title">Financial Approvers</h4>
                  </div>
                </div>
                <div className="stage-col-meta">
                  <span>Reviews & Authorizes Entries</span>
                  <strong className="stage-count-pill">{filteredTier2.length} accounts</strong>
                </div>
              </div>

              {/* FLOW CONNECTOR 2 -> 3 */}
              <div className="stage-flow-indicator">
                <div className="flow-dash-line" />
                <div className="flow-label-badge">
                  <span>Feeds to Audit</span>
                  <ArrowRight size={14} />
                </div>
              </div>

              {/* STAGE 3 */}
              <div className="stage-banner-col stage-3-border">
                <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                  <span className="stage-badge-indicator" style={{ background: TIERS[3].accentColor }} />
                  <div>
                    <span className="stage-pill-eyebrow">STAGE 3 · GOVERNANCE</span>
                    <h4 className="stage-col-title">System Administrators</h4>
                  </div>
                </div>
                <div className="stage-col-meta">
                  <span>Enforces Rules & Oversees Audit</span>
                  <strong className="stage-count-pill">{filteredTier3.length} accounts</strong>
                </div>
              </div>
            </div>

            {/* Canvas Viewport Toolbar (Zoom & Legend) */}
            <div className="graph-viewport-toolbar">
              <div className="graph-legend-bar">
                <span style={{ fontSize: 11, fontWeight: 700, color: "#64748b", textTransform: "uppercase" }}>
                  Topology Legend:
                </span>
                <span className="legend-chip">
                  <span className="legend-dot" style={{ background: TIERS[1].accentColor }} /> Tier 1 Preparer
                </span>
                <span className="legend-chip">
                  <span className="legend-dot" style={{ background: TIERS[2].accentColor }} /> Tier 2 Approver
                </span>
                <span className="legend-chip">
                  <span className="legend-dot" style={{ background: TIERS[3].accentColor }} /> Tier 3 Governance
                </span>
                <span className="legend-chip">
                  <span className="legend-line-sample" /> Active Dependency Flow
                </span>
              </div>

              <div className="zoom-controls-box">
                <button
                  type="button"
                  className="zoom-btn"
                  onClick={() => setZoom((z) => Math.min(1.25, z + 0.1))}
                  title="Zoom In"
                >
                  <ZoomIn size={14} />
                </button>
                <span className="zoom-label">{Math.round(zoom * 100)}%</span>
                <button
                  type="button"
                  className="zoom-btn"
                  onClick={() => setZoom((z) => Math.max(0.75, z - 0.1))}
                  title="Zoom Out"
                >
                  <ZoomOut size={14} />
                </button>
                <button
                  type="button"
                  className="zoom-btn"
                  onClick={() => setZoom(1.0)}
                  title="Reset Zoom"
                >
                  <RotateCcw size={13} />
                </button>
              </div>
            </div>

            {/* INTERACTIVE SVG + HTML CANVAS CONTAINER */}
            <div className="graph-canvas-viewport-scroll">
              <div 
                className="graph-canvas-surface"
                style={{
                  width: CANVAS_WIDTH,
                  height: canvasHeight,
                  position: "relative",
                  transform: `scale(${zoom})`,
                  transformOrigin: "top left",
                  transition: "transform 0.15s ease-out",
                }}
              >
                {/* SVG CONNECTION LINKS LAYER */}
                <svg 
                  className="graph-svg-canvas-layer" 
                  width={CANVAS_WIDTH} 
                  height={canvasHeight} 
                  viewBox={`0 0 ${CANVAS_WIDTH} ${canvasHeight}`}
                >
                  <defs>
                    {/* Arrowhead Markers */}
                    <marker 
                      id="arrow-default" 
                      viewBox="0 0 10 10" 
                      refX="8" 
                      refY="5" 
                      markerWidth="6" 
                      markerHeight="6" 
                      orient="auto-start-reverse"
                    >
                      <path d="M 0 1.5 L 9 5 L 0 8.5 z" fill="#cbd5e1" />
                    </marker>
                    <marker 
                      id="arrow-active" 
                      viewBox="0 0 10 10" 
                      refX="9" 
                      refY="5" 
                      markerWidth="7" 
                      markerHeight="7" 
                      orient="auto-start-reverse"
                    >
                      <path d="M 0 1 L 10 5 L 0 9 z" fill="#10b981" />
                    </marker>
                    <marker 
                      id="arrow-governance" 
                      viewBox="0 0 10 10" 
                      refX="9" 
                      refY="5" 
                      markerWidth="7" 
                      markerHeight="7" 
                      orient="auto-start-reverse"
                    >
                      <path d="M 0 1 L 10 5 L 0 9 z" fill="#6366f1" />
                    </marker>
                    {/* Background Stage Lanes Guides */}
                    <pattern id="dot-grid" width="24" height="24" patternUnits="userSpaceOnUse">
                      <circle cx="2" cy="2" r="1" fill="#e2e8f0" />
                    </pattern>
                  </defs>

                  {/* Subtle Canvas Dot Grid Background */}
                  <rect width="100%" height="100%" fill="url(#dot-grid)" opacity="0.6" />

                  {/* Stage Boundary Columns in SVG */}
                  <line x1={COL_2_X - 50} y1="0" x2={COL_2_X - 50} y2={canvasHeight} stroke="#e2e8f0" strokeDasharray="4 4" />
                  <line x1={COL_3_X - 50} y1="0" x2={COL_3_X - 50} y2={canvasHeight} stroke="#e2e8f0" strokeDasharray="4 4" />

                  {/* RENDER BEZIER CONNECTION CABLES */}
                  {dependencyEdges.map((edge) => {
                    const from = nodeCoords.get(edge.fromId);
                    const to = nodeCoords.get(edge.toId);
                    if (!from || !to) return null;

                    // Source and Target Port Coordinates
                    const x1 = from.x + NODE_WIDTH;
                    const y1 = from.y + NODE_HEIGHT / 2;
                    const x2 = to.x;
                    const y2 = to.y + NODE_HEIGHT / 2;
                    const dx = x2 - x1;

                    const isConnectedToFocus = activeFocusId && (edge.fromId === activeFocusId || edge.toId === activeFocusId);
                    const isDimmed = activeFocusId && !isConnectedToFocus;

                    // Smooth S-Curve Cubic Bézier Path
                    const pathD = `M ${x1} ${y1} C ${x1 + dx * 0.45} ${y1}, ${x2 - dx * 0.45} ${y2}, ${x2} ${y2}`;

                    const strokeColor = isConnectedToFocus 
                      ? (edge.type === "governance" ? "#6366f1" : "#10b981") 
                      : "#cbd5e1";

                    const markerTarget = isConnectedToFocus 
                      ? (edge.type === "governance" ? "url(#arrow-governance)" : "url(#arrow-active)") 
                      : "url(#arrow-default)";

                    return (
                      <g key={edge.id} className="dependency-edge-group">
                        {/* Background thicker invisible path for easier hover interaction */}
                        <path
                          d={pathD}
                          fill="none"
                          stroke="transparent"
                          strokeWidth="16"
                          style={{ cursor: "pointer" }}
                          onMouseEnter={() => {
                            setHoveredUserId(edge.fromId);
                          }}
                          onMouseLeave={() => setHoveredUserId(null)}
                          onClick={() => setSelectedUserId(edge.fromId)}
                        />
                        {/* Visible Bézier Cable */}
                        <path
                          d={pathD}
                          fill="none"
                          stroke={strokeColor}
                          strokeWidth={isConnectedToFocus ? 3 : 1.5}
                          strokeDasharray={isConnectedToFocus ? "8 4" : undefined}
                          className={`graph-link-cable ${isConnectedToFocus ? "cable-active-pulse" : ""} ${isDimmed ? "cable-dimmed" : ""}`}
                          markerEnd={markerTarget}
                        />
                      </g>
                    );
                  })}
                </svg>

                {/* RENDER INTERACTIVE HTML USER NODE CARDS */}
                {Array.from(nodeCoords.entries()).map(([userId, pos]) => {
                  const item = userTierList.find((u) => u.user.id === userId);
                  if (!item) return null;
                  const { user, tier, permissions } = item;
                  const meta = TIERS[tier];
                  const isSelected = selectedUserId === user.id;
                  const isHovered = hoveredUserId === user.id;
                  const isRelated = relatedUserIds.has(user.id);
                  const isDimmed = activeFocusId && !isRelated;

                  const initials = user.display_name
                    .split(" ")
                    .map((p) => p[0])
                    .filter(Boolean)
                    .slice(0, 2)
                    .join("")
                    .toUpperCase() || "U";

                  const primaryRole = user.grants[0]?.role_name || catalog.roles.find((r) => r.id === user.grants[0]?.role_id)?.name || "User";
                  const additionalRolesCount = Math.max(0, user.grants.length - 1);

                  return (
                    <div
                      key={user.id}
                      className={`graph-node-box ${meta.borderClass} ${isSelected ? "selected-node" : ""} ${isHovered ? "hovered-node" : ""} ${isDimmed ? "dimmed-node" : ""}`}
                      style={{
                        left: pos.x,
                        top: pos.y,
                        width: NODE_WIDTH,
                        height: NODE_HEIGHT,
                        borderColor: isSelected ? meta.accentColor : undefined,
                      }}
                      onClick={() => setSelectedUserId(isSelected ? null : user.id)}
                      onMouseEnter={() => setHoveredUserId(user.id)}
                      onMouseLeave={() => setHoveredUserId(null)}
                      role="button"
                      tabIndex={0}
                    >
                      {/* Left Input Port Connector for Tiers 2 & 3 */}
                      {tier > 1 && (
                        <div 
                          className="node-port node-port-left" 
                          style={{ borderColor: meta.accentColor }} 
                          title="Receives prepared transactions"
                        />
                      )}

                      {/* Card Content Row */}
                      <div style={{ display: "flex", alignItems: "flex-start", gap: 10 }}>
                        {/* Avatar Circle */}
                        <div 
                          className="node-avatar-circle"
                          style={{ 
                            backgroundColor: isSelected ? meta.accentColor : meta.bgLight,
                            color: isSelected ? "#ffffff" : meta.accentColor,
                            borderColor: meta.accentColor
                          }}
                        >
                          {initials}
                        </div>

                        {/* Name & Email */}
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 6 }}>
                            <span className="node-user-name" title={user.display_name}>
                              {user.display_name}
                            </span>
                            <span 
                              className={`user-status-dot ${user.state === "ACTIVE" ? "active" : "disabled"}`} 
                              title={`Account Status: ${user.state}`} 
                            />
                          </div>

                          <div className="node-user-email" title={user.email}>
                            {user.email}
                          </div>
                        </div>
                      </div>

                      {/* Card Bottom Row: Role Badge & ID Preview */}
                      <div className="node-card-footer">
                        {/* Role Badge */}
                        <div className="node-role-pill" title={user.grants.map((g) => g.role_name).join(", ")}>
                          {primaryRole}
                          {additionalRolesCount > 0 && ` +${additionalRolesCount}`}
                        </div>

                        {/* User UUID Preview with 1-click Copy */}
                        <div 
                          className="node-uuid-preview-tag"
                          title={`System UUID: ${user.id} (Click to copy)`}
                          onClick={(e) => {
                            e.stopPropagation();
                            copyToClipboard(user.id);
                          }}
                        >
                          <span>ID: {user.id.slice(0, 6)}…</span>
                          {copiedId === user.id ? (
                            <Check size={11} color="#10b981" />
                          ) : (
                            <Copy size={11} />
                          )}
                        </div>
                      </div>

                      {/* Right Output Port Connector for Tiers 1 & 2 */}
                      {tier < 3 && tier > 0 && (
                        <div 
                          className="node-port node-port-right" 
                          style={{ borderColor: meta.accentColor }} 
                          title="Submits entries to next tier"
                        />
                      )}
                    </div>
                  );
                })}
              </div>
            </div>

            {/* UNASSIGNED TENANT USERS SECTION (If Any) */}
            {filteredTier0.length > 0 && (
              <div className="unassigned-dock-banner">
                <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <AlertCircle size={16} color="#e11d48" />
                  <strong style={{ fontSize: 13, color: "#1e293b" }}>
                    Unassigned Tenant Accounts ({filteredTier0.length})
                  </strong>
                  <span style={{ fontSize: 12, color: "#64748b" }}>
                    Registered users without active company roles:
                  </span>
                </div>
                <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginTop: 8 }}>
                  {filteredTier0.map(({ user }) => (
                    <button
                      key={user.id}
                      type="button"
                      className={`unassigned-user-btn ${selectedUserId === user.id ? "active" : ""}`}
                      onClick={() => setSelectedUserId(user.id)}
                    >
                      {user.display_name} ({user.email})
                    </button>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}

        {/* ==================================================== */}
        {/* CARDS MATRIX VIEW (ALTERNATIVE GROUPED VIEW)         */}
        {/* ==================================================== */}
        {viewMode === "CARDS" && (
          <div className="hierarchy-tiers-column" style={{ display: "flex", flexDirection: "column", gap: 20 }}>
            {([3, 2, 1, 0] as TierLevel[]).map((level) => {
              const meta = TIERS[level];
              const list = level === 3 ? filteredTier3 : level === 2 ? filteredTier2 : level === 1 ? filteredTier1 : filteredTier0;
              if (list.length === 0) return null;

              return (
                <div key={level} className={`hierarchy-tier-card ${meta.borderClass}`}>
                  <div className="tier-header-row" style={{ background: meta.bgLight }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                      <span className={`tier-level-badge ${meta.badgeClass}`}>
                        {meta.shortTitle}
                      </span>
                      <div>
                        <h3 style={{ fontSize: 15, fontWeight: 700, margin: 0, color: "#1e293b" }}>{meta.title}</h3>
                        <p style={{ margin: "2px 0 0", fontSize: 12, color: "#64748b" }}>{meta.subtitle}</p>
                      </div>
                    </div>
                    <span style={{ fontSize: 12, fontWeight: 600, color: meta.accentColor }}>{meta.flowRole}</span>
                  </div>

                  <div className="tier-users-grid">
                    {list.map(({ user, permissions }) => {
                      const isSelected = selectedUserId === user.id;
                      return (
                        <div
                          key={user.id}
                          className={`user-node-card ${isSelected ? "selected" : ""}`}
                          onClick={() => setSelectedUserId(isSelected ? null : user.id)}
                        >
                          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
                            <h4 className="user-node-name">{user.display_name}</h4>
                            <span className={`user-status-dot ${user.state === "ACTIVE" ? "active" : "disabled"}`} />
                          </div>
                          <div className="user-node-email">{user.email}</div>
                          <div className="node-uuid-preview-tag" onClick={(e) => { e.stopPropagation(); copyToClipboard(user.id); }}>
                            <span>ID: {user.id.slice(0, 8)}…</span>
                            {copiedId === user.id ? <Check size={12} color="#10b981" /> : <Copy size={12} />}
                          </div>
                          <div className="user-node-footer">
                            <span className="perms-count"><Key size={13} /> {permissions.length} perms</span>
                            <span className="click-inspect-hint">Inspect <ChevronRight size={14} /></span>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              );
            })}
          </div>
        )}

        {/* ==================================================== */}
        {/* COMPLETE PREVIEW & PERMISSION INSPECTOR PANEL        */}
        {/* ==================================================== */}
        {selectedUserData && (
          <aside className="hierarchy-inspector-panel">
            {/* INSPECTOR HEADER */}
            <div className="inspector-header">
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
                <span className={`tier-level-badge ${TIERS[selectedUserData.tier].badgeClass}`}>
                  {TIERS[selectedUserData.tier].shortTitle}
                </span>
                <button
                  type="button"
                  className="inspector-close-btn"
                  onClick={() => setSelectedUserId(null)}
                  title="Close preview panel"
                >
                  ✕
                </button>
              </div>

              <div style={{ display: "flex", alignItems: "center", gap: 12, marginTop: 12 }}>
                <div 
                  className="node-avatar-circle"
                  style={{ 
                    width: 46, 
                    height: 46, 
                    fontSize: 16,
                    backgroundColor: TIERS[selectedUserData.tier].bgLight,
                    color: TIERS[selectedUserData.tier].accentColor,
                    borderColor: TIERS[selectedUserData.tier].accentColor 
                  }}
                >
                  {selectedUserData.user.display_name
                    .split(" ")
                    .map((p) => p[0])
                    .filter(Boolean)
                    .slice(0, 2)
                    .join("")
                    .toUpperCase() || "U"}
                </div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <h3 style={{ fontSize: 18, fontWeight: 700, margin: 0, color: "#0f172a" }}>
                    {selectedUserData.user.display_name}
                  </h3>
                  <p style={{ margin: "2px 0 0", color: "#64748b", fontSize: 13, wordBreak: "break-all" }}>
                    {selectedUserData.user.email}
                  </p>
                </div>
              </div>
            </div>

            {/* IDENTITY & ACCOUNT METADATA */}
            <div className="inspector-section">
              <h4 className="inspector-section-title">Identity & Account Metadata</h4>
              <div className="inspector-meta-grid">
                <div className="meta-item">
                  <span className="meta-label">System User UUID</span>
                  <div className="uuid-copy-box">
                    <code>{selectedUserData.user.id}</code>
                    <button
                      type="button"
                      className="copy-btn"
                      onClick={() => copyToClipboard(selectedUserData.user.id)}
                      title="Copy full UUID"
                    >
                      {copiedId === selectedUserData.user.id ? <Check size={14} color="#10b981" /> : <Copy size={14} />}
                    </button>
                  </div>
                </div>

                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 8 }}>
                  <div>
                    <span className="meta-label">Status</span>
                    <span className={`badge ${selectedUserData.user.state === "ACTIVE" ? "open" : "voided"}`}>
                      {selectedUserData.user.state}
                    </span>
                  </div>
                  <div>
                    <span className="meta-label">MFA Enrolled</span>
                    <span className="meta-value">
                      {selectedUserData.user.mfa_enrolled ? (
                        <span style={{ color: "#059669", display: "inline-flex", alignItems: "center", gap: 3 }}>
                          <Lock size={12} /> Active
                        </span>
                      ) : (
                        <span style={{ color: "#94a3b8" }}>None</span>
                      )}
                    </span>
                  </div>
                  <div>
                    <span className="meta-label">Account Version</span>
                    <span className="meta-value">v{selectedUserData.user.version}</span>
                  </div>
                </div>
              </div>
            </div>

            {/* WORKFLOW DEPENDENCY & FEEDING PATH */}
            <div className="inspector-section">
              <h4 className="inspector-section-title">Workflow Dependency & Feeding Path</h4>
              <div className="dependency-summary-box">
                {/* UPSTREAM PATH */}
                {inspectorUpstreamUsers.length > 0 && (
                  <div className="dep-flow-item">
                    <span className="dep-badge upstream">
                      <ArrowRight size={12} /> Feeds Submissions Up To:
                    </span>
                    <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginTop: 6 }}>
                      {inspectorUpstreamUsers.map((up) => (
                        <button
                          key={up.user.id}
                          type="button"
                          className="connected-user-chip"
                          onClick={() => setSelectedUserId(up.user.id)}
                          title={`Click to inspect ${up.user.display_name}`}
                        >
                          <strong>{up.user.display_name}</strong>
                          <span style={{ fontSize: 10, color: "#64748b" }}>
                            ({up.user.grants[0]?.role_name || "Role"})
                          </span>
                        </button>
                      ))}
                    </div>
                  </div>
                )}

                {/* DOWNSTREAM PATH */}
                {inspectorDownstreamUsers.length > 0 && (
                  <div className="dep-flow-item" style={{ marginTop: 8 }}>
                    <span className="dep-badge downstream">
                      <ArrowDownRight size={12} /> Receives Submissions From:
                    </span>
                    <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginTop: 6 }}>
                      {inspectorDownstreamUsers.map((dn) => (
                        <button
                          key={dn.user.id}
                          type="button"
                          className="connected-user-chip"
                          onClick={() => setSelectedUserId(dn.user.id)}
                          title={`Click to inspect ${dn.user.display_name}`}
                        >
                          <strong>{dn.user.display_name}</strong>
                          <span style={{ fontSize: 10, color: "#64748b" }}>
                            ({dn.user.grants[0]?.role_name || "Role"})
                          </span>
                        </button>
                      ))}
                    </div>
                  </div>
                )}

                {/* GOVERNANCE ROLE STATEMENT */}
                <div style={{ marginTop: 10, fontSize: 12, color: "#475569", lineHeight: "1.45" }}>
                  {selectedUserData.tier === 1 && (
                    <p style={{ margin: 0 }}>
                      Operational preparer: generates draft invoices and vouchers. Transactions must be reviewed and authorized by Tier 2 Approvers before ledger posting.
                    </p>
                  )}
                  {selectedUserData.tier === 2 && (
                    <p style={{ margin: 0 }}>
                      Financial controller: holds signing authorization to verify and approve journals and invoices submitted by preparers.
                    </p>
                  )}
                  {selectedUserData.tier === 3 && (
                    <p style={{ margin: 0 }}>
                      Executive & System Governance: holds full administrative authority over tenant roles, approval limits, fiscal periods, and audit trail integrity.
                    </p>
                  )}
                  {selectedUserData.tier === 0 && (
                    <p style={{ margin: 0, color: "#e11d48" }}>
                      This account has no active company roles. Assign roles below to enable workflow participation.
                    </p>
                  )}
                </div>
              </div>
            </div>

            {/* ASSIGNED COMPANY ROLES */}
            <div className="inspector-section">
              <h4 className="inspector-section-title">Assigned Company Roles</h4>
              {selectedUserData.user.grants && selectedUserData.user.grants.length > 0 ? (
                <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                  {selectedUserData.user.grants.map((g) => {
                    const role = rolesMap.get(g.role_id);
                    return (
                      <div key={g.role_id} className="inspector-role-card">
                        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
                          <span style={{ fontWeight: 700, color: "#173b3c", fontSize: 13 }}>
                            {g.role_name || role?.name || "Role"}
                          </span>
                          {g.approval_limit_minor && (
                            <span className="limit-tag">
                              Limit: {money(g.approval_limit_minor, currencyPlaces)}
                            </span>
                          )}
                        </div>
                        {role?.description && (
                          <p style={{ margin: "4px 0 0", fontSize: 11, color: "#64748b" }}>
                            {role.description}
                          </p>
                        )}
                        {g.branch_code && (
                          <div style={{ marginTop: 4, fontSize: 11, color: "#0284c7" }}>
                            Scope: Branch {g.branch_code}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              ) : (
                <div style={{ fontSize: 12, color: "#94a3b8", fontStyle: "italic", padding: 8, background: "#f8fafc", borderRadius: 6 }}>
                  No company roles assigned to this account.
                </div>
              )}
            </div>

            {/* EFFECTIVE SYSTEM PERMISSIONS MATRIX */}
            <div className="inspector-section" style={{ flex: 1 }}>
              <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 6 }}>
                <h4 className="inspector-section-title" style={{ margin: 0 }}>
                  Active System Permissions ({selectedUserData.permissions.length})
                </h4>
              </div>

              {/* Permission Search Filter */}
              {selectedUserData.permissions.length > 5 && (
                <input
                  type="text"
                  placeholder="Filter permissions..."
                  value={permSearch}
                  onChange={(e) => setPermSearch(e.target.value)}
                  style={{
                    padding: "6px 10px",
                    fontSize: 12,
                    border: "1px solid #e2e8f0",
                    borderRadius: 6,
                    marginBottom: 8,
                    width: "100%",
                    outline: "none",
                  }}
                />
              )}

              {selectedUserData.permissions.length === 0 ? (
                <div style={{ fontSize: 12, color: "#94a3b8", fontStyle: "italic", padding: 10, background: "#f8fafc", borderRadius: 6 }}>
                  No permissions active for this account.
                </div>
              ) : (
                <div className="permissions-badge-flow">
                  {selectedUserData.permissions
                    .filter((code) => !permSearch || code.toLowerCase().includes(permSearch.toLowerCase()))
                    .map((code) => {
                      const info = permissionsMap.get(code);
                      const isElevated = code.includes("manage") || code.includes("approve") || code.includes("post") || code.includes("close");
                      return (
                        <div key={code} className={`permission-chip ${isElevated ? "elevated" : "standard"}`}>
                          <div className="perm-code">{code}</div>
                          {info?.label && <div className="perm-label">{info.label}</div>}
                        </div>
                      );
                    })}
                </div>
              )}
            </div>

            {/* EDIT USER ACTION */}
            {onSelectUser && (
              <div className="inspector-footer" style={{ marginTop: 10 }}>
                <button
                  type="button"
                  className="btn-edit-user-jump"
                  onClick={() => onSelectUser(selectedUserData.user)}
                >
                  <ExternalLink size={14} /> Open Full User Editor
                </button>
              </div>
            )}
          </aside>
        )}
      </div>
    </section>
  );
}
