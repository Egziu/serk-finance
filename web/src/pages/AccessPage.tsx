import { useEffect, useMemo, useState } from "react";
import type { GridColDef } from "@mui/x-data-grid-pro";
import { Plus, Trash2, X } from "lucide-react";
import { DataTable } from "../DataTable";
import { dateTimeCol, statusCol } from "../columns";
import { api, minor, money } from "../api";
import type { AdminCatalog, AdminRole, AdminUser, Grant, PermissionInfo } from "../types";
import { UserHierarchyMap } from "../UserHierarchyMap";

type Props = { company: string; csrf: string; currencyPlaces: number; onSessionEnd: (e: unknown) => void };
type Tab = "users" | "roles";
type GrantDraft = { role_id: string; branch_id: string; limit: string };
type Editor =
  | { kind: "new-user" }
  | { kind: "user"; user: AdminUser }
  | { kind: "new-role" }
  | { kind: "role"; role: AdminRole };

const reasonOk = (r: string) => r.trim().length >= 3;

export function AccessPage({ company, csrf, currencyPlaces, onSessionEnd }: Props) {
  const [catalog, setCatalog] = useState<AdminCatalog | null>(null),
    [tab, setTab] = useState<Tab>("users"),
    [editor, setEditor] = useState<Editor | null>(null),
    [error, setError] = useState(""),
    [notice, setNotice] = useState(""),
    [busy, setBusy] = useState(false);

  async function load() {
    try {
      const c = await api<AdminCatalog>("/admin/catalog", company);
      setCatalog(c);
      if (!c.me.can_manage_users) setTab("roles");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not load users and roles.");
      onSessionEnd(e);
    }
  }
  useEffect(() => {
    void load();
  }, [company]);

  // Every write is a POST with CSRF; the server re-checks every permission.
  async function send<T>(path: string, body: unknown, done: string): Promise<T | null> {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const result = await api<T>(path, company, { method: "POST", csrf, body });
      setNotice(done);
      await load();
      return result;
    } catch (e) {
      setError(e instanceof Error ? e.message : "The change was not saved.");
      onSessionEnd(e);
      return null;
    } finally {
      setBusy(false);
    }
  }

  const roleName = (id: string) => catalog?.roles.find((r) => r.id === id)?.name ?? "Unknown role";
  const grantText = (g: Grant) =>
    (g.role_name ?? roleName(g.role_id)) +
    (g.branch_code ? " · " + g.branch_code : "") +
    (g.approval_limit_minor ? " · up to " + money(g.approval_limit_minor, currencyPlaces) : "");

  const userCols: GridColDef<AdminUser>[] = [
    {
      field: "display_name",
      headerName: "Name",
      flex: 1,
      minWidth: 160,
      renderCell: (p) => (
        <button className="report-link" onClick={() => setEditor({ kind: "user", user: p.row })} aria-label={"Manage " + p.row.email}>
          {p.row.display_name}
        </button>
      ),
    },
    { field: "email", headerName: "Email", flex: 1, minWidth: 200 },
    {
      field: "roles",
      headerName: "Roles in this company",
      flex: 2,
      minWidth: 240,
      sortable: false,
      valueGetter: (_v, u) => u.grants.map(grantText).join(", "),
      renderCell: (p) =>
        p.row.grants.length ? (
          <span className="chip-list">{p.row.grants.map((g) => <span className="chip" key={g.role_id}>{grantText(g)}</span>)}</span>
        ) : (
          <span className="muted">No access to this company</span>
        ),
    },
    statusCol<AdminUser>("state", "Status", ["ACTIVE", "DISABLED"], {
      renderCell: (p) => <span className={"badge " + (p.value === "ACTIVE" ? "open" : "voided")}><i />{String(p.value).toLowerCase()}</span>,
    }),
    { field: "mfa_enrolled", headerName: "MFA", type: "boolean", width: 80 },
    dateTimeCol<AdminUser>("created_at", "Created"),
  ];
  const roleCols: GridColDef<AdminRole>[] = [
    {
      field: "name",
      headerName: "Role",
      flex: 1,
      minWidth: 160,
      renderCell: (p) => (
        <button className="report-link" onClick={() => setEditor({ kind: "role", role: p.row })} aria-label={"Edit role " + p.row.name}>
          {p.row.name}
        </button>
      ),
    },
    { field: "description", headerName: "Description", flex: 2, minWidth: 200 },
    { field: "count", headerName: "Permissions", type: "number", width: 120, valueGetter: (_v, r) => r.permissions.length },
    { field: "members", headerName: "Users", type: "number", width: 90 },
  ];

  if (!catalog)
    return (
      <>
        {error && <div className="error" role="alert">{error}</div>}
        <div className="empty"><h2>Loading users and roles…</h2></div>
      </>
    );
  const me = catalog.me;
  return (
    <>
      <div className="page-heading">
        <div>
          <div className="eyebrow">ACCESS CONTROL</div>
          <h1>Users & roles</h1>
          <p>Create roles, tick what each role may do, and give people roles in this company. Every change is recorded in the audit history.</p>
        </div>
      </div>
      {error && !editor && <div className="error" role="alert">{error}</div>}
      {notice && !editor && <div className="notice success" role="status">{notice}</div>}
      <div className="tabs grid-tabs" aria-label="Access management">
        {me.can_manage_users && (
          <button className={tab === "users" ? "tab chosen" : "tab"} onClick={() => setTab("users")}>
            Users ({catalog.users.length})
          </button>
        )}
        <button className={tab === "roles" ? "tab chosen" : "tab"} onClick={() => setTab("roles")}>
          Roles ({catalog.roles.length})
        </button>
      </div>
      {tab === "users" && me.can_manage_users && (
        <>
          <DataTable<AdminUser>
            label="Users"
            rows={catalog.users}
            columns={userCols}
            onAdd={() => setEditor({ kind: "new-user" })}
            addLabel="New user"
            fileName="users"
            autoHeight
            initialState={{ sorting: { sortModel: [{ field: "display_name", sort: "asc" }] } }}
          />
          <UserHierarchyMap
            catalog={catalog}
            currencyPlaces={currencyPlaces}
            onSelectUser={(u) => setEditor({ kind: "user", user: u })}
          />
        </>
      )}
      {tab === "roles" && (
        <DataTable<AdminRole>
          label="Roles"
          rows={catalog.roles}
          columns={roleCols}
          onAdd={me.can_manage_roles ? () => setEditor({ kind: "new-role" }) : undefined}
          addLabel="New role"
          fileName="roles"
          autoHeight
          initialState={{ sorting: { sortModel: [{ field: "name", sort: "asc" }] } }}
        />
      )}
      {editor && (
        <div className="overlay">
          <section role="dialog" aria-modal="true" aria-labelledby="access-title" className="modal modal-large">
            <button className="modal-close" aria-label="Close" disabled={busy} onClick={() => { setEditor(null); setError(""); }}>
              <X size={20} />
            </button>
            {error && <div className="error" role="alert">{error}</div>}
            {notice && <div className="notice success" role="status">{notice}</div>}
            {(editor.kind === "new-role" || editor.kind === "role") && (
              <RoleEditor
                key={editor.kind === "role" ? editor.role.id + editor.role.version : "new"}
                role={editor.kind === "role" ? catalog.roles.find((r) => r.id === editor.role.id) ?? editor.role : null}
                permissions={catalog.permissions}
                held={me.permissions}
                canEdit={me.can_manage_roles}
                busy={busy}
                onSave={async (body, id) => {
                  const r = await send<AdminRole>(id ? `/admin/roles/${id}/update` : "/admin/roles", body, id ? "Role saved." : "Role created.");
                  if (r) setEditor({ kind: "role", role: r });
                }}
                onDelete={async (id, body) => {
                  if (await send(`/admin/roles/${id}/delete`, body, "Role deleted.")) setEditor(null);
                }}
              />
            )}
            {(editor.kind === "new-user" || editor.kind === "user") && (
              <UserEditor
                key={editor.kind === "user" ? editor.user.id : "new"}
                user={editor.kind === "user" ? catalog.users.find((u) => u.id === editor.user.id) ?? editor.user : null}
                catalog={catalog}
                places={currencyPlaces}
                busy={busy}
                onCreate={async (body) => {
                  const u = await send<AdminUser>("/admin/users", body, "User created.");
                  if (u) setEditor({ kind: "user", user: u });
                }}
                onAction={async (id, action, body, done) => {
                  await send<AdminUser>(`/admin/users/${id}/${action}`, body, done);
                }}
                onError={setError}
              />
            )}
          </section>
        </div>
      )}
    </>
  );
}

function RoleEditor({
  role, permissions, held, canEdit, busy, onSave, onDelete,
}: {
  role: AdminRole | null;
  permissions: PermissionInfo[];
  held: string[];
  canEdit: boolean;
  busy: boolean;
  onSave: (body: unknown, id?: string) => Promise<void>;
  onDelete: (id: string, body: unknown) => Promise<void>;
}) {
  const [name, setName] = useState(role?.name ?? ""),
    [description, setDescription] = useState(role?.description ?? ""),
    [ticked, setTicked] = useState<Set<string>>(new Set(role?.permissions ?? ["ledger.read"])),
    [reason, setReason] = useState("");
  const groups = useMemo(() => {
    const m = new Map<string, PermissionInfo[]>();
    for (const p of permissions) m.set(p.category, [...(m.get(p.category) ?? []), p]);
    return [...m.entries()];
  }, [permissions]);
  // Anti-escalation mirrors the server: you can only tick or untick permissions you hold.
  const locked = (code: string) => !canEdit || !held.includes(code);
  const toggle = (code: string) =>
    setTicked((s) => {
      const n = new Set(s);
      if (n.has(code)) n.delete(code);
      else n.add(code);
      return n;
    });
  const body = { name: name.trim(), description: description.trim(), permissions: [...ticked].sort(), reason: reason.trim() };
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        void onSave(role ? { ...body, expected_version: role.version } : body, role?.id);
      }}
    >
      <div className="eyebrow">ROLE</div>
      <h2 id="access-title">{role ? "Edit role · " + role.name : "New role"}</h2>
      <p>Tick what people with this role may do. Changes apply immediately to everyone who has the role.</p>
      <div className="form-grid two">
        <label>
          Role name
          <input required minLength={2} maxLength={80} value={name} disabled={!canEdit || busy} onChange={(e) => setName(e.target.value)} />
        </label>
        <label>
          Description
          <input maxLength={500} value={description} disabled={!canEdit || busy} onChange={(e) => setDescription(e.target.value)} />
        </label>
      </div>
      <div className="perm-groups">
        {groups.map(([category, list]) => (
          <fieldset key={category} className="perm-group">
            <legend>{category}</legend>
            {list.map((p) => (
              <label key={p.code} className={"check-row" + (locked(p.code) ? " disabled" : "")} title={locked(p.code) ? "You can only grant permissions you hold yourself." : p.code}>
                <input type="checkbox" checked={ticked.has(p.code)} disabled={locked(p.code) || busy} onChange={() => toggle(p.code)} />
                <span>
                  {p.label}
                  <small>{p.code}</small>
                </span>
              </label>
            ))}
          </fieldset>
        ))}
      </div>
      {canEdit && (
        <>
          <label>
            Reason for this change
            <input required minLength={3} maxLength={1000} value={reason} disabled={busy} onChange={(e) => setReason(e.target.value)} placeholder="For example: approved by the CFO, ticket ACC-12" />
          </label>
          <div className="modal-actions">
            <button className="primary" disabled={busy || !reasonOk(reason) || name.trim().length < 2}>
              {busy ? "Saving…" : role ? "Save role" : "Create role"}
            </button>
            {role && (
              <button
                type="button"
                className="secondary danger"
                disabled={busy || role.members > 0 || !reasonOk(reason)}
                title={role.members > 0 ? "Remove this role from all users first." : "Delete this role"}
                onClick={() => void onDelete(role.id, { expected_version: role.version, reason: reason.trim() })}
              >
                <Trash2 size={15} /> Delete role
              </button>
            )}
          </div>
          {role && role.members > 0 && <small className="field-hint">{role.members} user(s) have this role, so it cannot be deleted.</small>}
        </>
      )}
    </form>
  );
}

function UserEditor({
  user, catalog, places, busy, onCreate, onAction, onError,
}: {
  user: AdminUser | null;
  catalog: AdminCatalog;
  places: number;
  busy: boolean;
  onCreate: (body: unknown) => Promise<void>;
  onAction: (id: string, action: "update" | "grants" | "password", body: unknown, done: string) => Promise<void>;
  onError: (m: string) => void;
}) {
  const toDraft = (g: Grant): GrantDraft => ({
    role_id: g.role_id,
    branch_id: g.branch_id ?? "",
    limit: g.approval_limit_minor ? money(g.approval_limit_minor, places).replaceAll(",", "") : "",
  });
  const [email, setEmail] = useState(""),
    [name, setName] = useState(user?.display_name ?? ""),
    [active, setActive] = useState(user?.active ?? true),
    [password, setPassword] = useState(""),
    [grants, setGrants] = useState<GrantDraft[]>(user ? user.grants.map(toDraft) : []),
    [reason, setReason] = useState("");
  useEffect(() => {
    if (!user) return;
    setName(user.display_name);
    setActive(user.active);
    setGrants(user.grants.map(toDraft));
  }, [user?.version]);
  const self = user?.id === catalog.me.user_id;
  const approves = (roleId: string) => !!catalog.roles.find((r) => r.id === roleId)?.permissions.includes("journal.approve");
  const grantable = (r: AdminRole) => r.permissions.every((p) => catalog.me.permissions.includes(p));
  function grantBody() {
    return grants
      .filter((g) => g.role_id)
      .map((g) => ({
        role_id: g.role_id,
        branch_id: g.branch_id || null,
        approval_limit_minor: approves(g.role_id) && g.limit.trim() ? minor(g.limit.trim(), places) : null,
      }));
  }
  function withGrants(fn: (g: ReturnType<typeof grantBody>) => void) {
    try {
      fn(grantBody());
    } catch (e) {
      onError(e instanceof Error ? e.message : "Check the approval limits.");
    }
  }
  const grantEditor = (
    <div className="grant-list">
      {grants.length === 0 && <p className="muted">No roles in this company yet. The user cannot open this company.</p>}
      {grants.map((g, i) => (
        <div className="grant-row" key={i}>
          <label>
            Role
            <select
              aria-label={"Role " + (i + 1)}
              value={g.role_id}
              disabled={busy}
              onChange={(e) => setGrants(grants.map((x, j) => (j === i ? { ...x, role_id: e.target.value } : x)))}
            >
              <option value="">Select role</option>
              {catalog.roles.map((r) => (
                <option key={r.id} value={r.id} disabled={!grantable(r)}>
                  {r.name}
                  {grantable(r) ? "" : " (needs permissions you do not hold)"}
                </option>
              ))}
            </select>
          </label>
          <label>
            Branch
            <select
              aria-label={"Branch " + (i + 1)}
              value={g.branch_id}
              disabled={busy}
              onChange={(e) => setGrants(grants.map((x, j) => (j === i ? { ...x, branch_id: e.target.value } : x)))}
            >
              <option value="">All branches</option>
              {catalog.branches.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.code} · {b.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Approval limit
            <input
              aria-label={"Approval limit " + (i + 1)}
              inputMode="decimal"
              placeholder={approves(g.role_id) ? "No limit" : "Not an approver role"}
              disabled={busy || !approves(g.role_id)}
              value={approves(g.role_id) ? g.limit : ""}
              onChange={(e) => setGrants(grants.map((x, j) => (j === i ? { ...x, limit: e.target.value } : x)))}
            />
          </label>
          <button type="button" className="icon-button" aria-label={"Remove role " + (i + 1)} disabled={busy} onClick={() => setGrants(grants.filter((_, j) => j !== i))}>
            <X size={16} />
          </button>
        </div>
      ))}
      <button type="button" className="secondary compact" disabled={busy} onClick={() => setGrants([...grants, { role_id: "", branch_id: "", limit: "" }])}>
        <Plus size={15} /> Add role
      </button>
    </div>
  );
  const reasonField = (
    <label>
      Reason for this change
      <input required minLength={3} maxLength={1000} value={reason} disabled={busy} onChange={(e) => setReason(e.target.value)} placeholder="For example: new hire approved by HR, ticket IAM-7" />
    </label>
  );

  if (!user)
    return (
      <form
        onSubmit={(e) => {
          e.preventDefault();
          withGrants((g) => void onCreate({ email: email.trim(), display_name: name.trim(), password, grants: g, reason: reason.trim() }));
        }}
      >
        <div className="eyebrow">USER</div>
        <h2 id="access-title">New user</h2>
        <p>Give the person a temporary password through a safe channel. Roles apply to the company selected in the sidebar.</p>
        <div className="form-grid two">
          <label>
            Email
            <input type="email" required maxLength={254} value={email} disabled={busy} onChange={(e) => setEmail(e.target.value)} />
          </label>
          <label>
            Full name
            <input required maxLength={200} value={name} disabled={busy} onChange={(e) => setName(e.target.value)} />
          </label>
          <label className="full">
            Temporary password
            <input type="password" autoComplete="new-password" required minLength={14} maxLength={256} value={password} disabled={busy} onChange={(e) => setPassword(e.target.value)} />
            <small className="field-hint">At least 14 characters.</small>
          </label>
        </div>
        <h3>Roles in this company</h3>
        {grantEditor}
        {reasonField}
        <div className="modal-actions">
          <button className="primary" disabled={busy || !reasonOk(reason) || password.length < 14}>
            {busy ? "Saving…" : "Create user"}
          </button>
        </div>
      </form>
    );

  return (
    <div className="user-editor">
      <div className="eyebrow">USER</div>
      <h2 id="access-title">{user.display_name}</h2>
      <p>
        {user.email} · {user.active ? "active" : "disabled"} · MFA {user.mfa_enrolled ? "enrolled" : "not enrolled"}
        {self && " · this is you"}
      </p>
      {reasonField}
      <section className="editor-section">
        <h3>Details</h3>
        <div className="form-grid two">
          <label>
            Full name
            <input required maxLength={200} value={name} disabled={busy} onChange={(e) => setName(e.target.value)} />
          </label>
          <label className="check-row">
            <input type="checkbox" checked={active} disabled={busy || self} onChange={(e) => setActive(e.target.checked)} />
            <span>
              Account active
              <small>{self ? "You cannot disable your own account." : "Disabling signs the user out everywhere."}</small>
            </span>
          </label>
        </div>
        <button
          className="primary compact"
          disabled={busy || !reasonOk(reason) || !name.trim()}
          onClick={() => void onAction(user.id, "update", { expected_version: user.version, display_name: name.trim(), active, reason: reason.trim() }, "User details saved.")}
        >
          Save details
        </button>
      </section>
      <section className="editor-section">
        <h3>Roles in this company</h3>
        {grantEditor}
        <button
          className="primary compact"
          disabled={busy || !reasonOk(reason)}
          onClick={() => withGrants((g) => void onAction(user.id, "grants", { expected_version: user.version, grants: g, reason: reason.trim() }, "Roles saved."))}
        >
          Save roles
        </button>
      </section>
      {!self && (
        <section className="editor-section">
          <h3>Reset password</h3>
          <label>
            New temporary password
            <input type="password" autoComplete="new-password" minLength={14} maxLength={256} value={password} disabled={busy} onChange={(e) => setPassword(e.target.value)} />
            <small className="field-hint">At least 14 characters. The user is signed out everywhere.</small>
          </label>
          <button
            className="secondary compact"
            disabled={busy || !reasonOk(reason) || password.length < 14}
            onClick={() => {
              void onAction(user.id, "password", { expected_version: user.version, password, reason: reason.trim() }, "Password reset. The user must sign in again.");
              setPassword("");
            }}
          >
            Reset password
          </button>
        </section>
      )}
    </div>
  );
}
