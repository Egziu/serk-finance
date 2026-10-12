package tests

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"serk.finance/internal/auth"
	"serk.finance/internal/provisioning"
)

// login uses the public login flow and stores the session under name for f.request.
func (f *fixture) login(t *testing.T, name, email, password string, status int) {
	t.Helper()
	b, _ := json.Marshal(map[string]string{"tenant": f.slug, "email": email, "password": password})
	r := httptest.NewRequest("POST", "/api/v1/auth/login", bytes.NewReader(b))
	r.Header.Set("Origin", "http://localhost:8080")
	r.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	f.handler.ServeHTTP(rr, r)
	if rr.Code != status {
		t.Fatalf("login %s wanted %d got %d %s", email, status, rr.Code, rr.Body.String())
	}
	if status != 200 {
		return
	}
	var v struct {
		CSRF string `json:"csrf_token"`
	}
	if json.Unmarshal(rr.Body.Bytes(), &v) != nil || len(rr.Result().Cookies()) != 1 {
		t.Fatal("login returned no session", rr.Body.String())
	}
	f.tokens[name] = rr.Result().Cookies()[0].Value
	f.csrf[name] = v.CSRF
}

func errorCode(t *testing.T, rr *httptest.ResponseRecorder) string {
	t.Helper()
	var v struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	_ = json.Unmarshal(rr.Body.Bytes(), &v)
	return v.Error.Code
}

func wantError(t *testing.T, rr *httptest.ResponseRecorder, code string) {
	t.Helper()
	if got := errorCode(t, rr); got != code {
		t.Fatalf("wanted error %s, got %s: %s", code, got, rr.Body.String())
	}
}

func TestAccessManagement(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	// Before bootstrap nobody can administer.
	wantError(t, f.request(t, "checker", "GET", "/api/v1/admin/catalog", "", nil, 403), "permission_denied")

	// Operator bootstrap: an existing user becomes super admin in every company.
	if e := provisioning.Administer(ctx, f.admin, provisioning.AdminRequest{Tenant: f.slug, Email: "checker@example.test", Action: "grant_super_admin", Reason: "Pilot administrator appointed"}); e != nil {
		t.Fatal(e)
	}
	// A new super admin can also be created by the operator; wrong combinations are refused.
	adminPassword, _ := auth.Token()
	if e := provisioning.Administer(ctx, f.admin, provisioning.AdminRequest{Tenant: f.slug, Email: "Boss@Example.test", Action: "grant_super_admin", Name: "Boss", Password: adminPassword, Reason: "Second administrator"}); e != nil {
		t.Fatal(e)
	}
	if e := provisioning.Administer(ctx, f.admin, provisioning.AdminRequest{Tenant: f.slug, Email: "boss@example.test", Action: "grant_super_admin", Name: "Again", Password: adminPassword, Reason: "Duplicate create"}); e == nil {
		t.Fatal("existing user accepted a new password through grant_super_admin")
	}
	f.login(t, "boss", "boss@example.test", adminPassword, 200)

	catalog := decodeObject(t, f.request(t, "checker", "GET", "/api/v1/admin/catalog", "", nil, 200))
	if len(catalog["permissions"].([]any)) != 12 || !catalog["me"].(map[string]any)["can_manage_users"].(bool) {
		t.Fatal("catalog", catalog["me"])
	}
	ref := decodeObject(t, f.request(t, "checker", "GET", "/api/v1/accounting/reference", "", nil, 200))
	if p := ref["permissions"].(map[string]any); p["users"] != true || p["roles"] != true {
		t.Fatal("reference permissions", p)
	}
	wantError(t, f.request(t, "reader", "GET", "/api/v1/admin/catalog", "", nil, 403), "permission_denied")
	wantError(t, f.request(t, "reader", "POST", "/api/v1/admin/roles", "", map[string]any{"name": "X role", "description": "", "permissions": []string{"ledger.read"}, "reason": "Not allowed"}, 403), "permission_denied")

	// Roles: create at any time with ticked permissions.
	clerk := decodeObject(t, f.request(t, "checker", "POST", "/api/v1/admin/roles", "", map[string]any{
		"name": "Clerk", "description": "Prepares journals", "permissions": []string{"ledger.read", "journal.create", "journal.submit"}, "reason": "Pilot clerk role"}, 201))
	clerkID := clerk["id"].(string)
	f.request(t, "checker", "POST", "/api/v1/admin/roles", "", map[string]any{"name": "Clerk", "description": "", "permissions": []string{"ledger.read"}, "reason": "Duplicate"}, 409)
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/roles", "", map[string]any{"name": "Bad", "description": "", "permissions": []string{"nope.perm"}, "reason": "Unknown permission"}, 422), "invalid_permission")
	f.request(t, "checker", "POST", "/api/v1/admin/roles", "", map[string]any{"name": "Bad", "description": "", "permissions": []string{"ledger.read"}, "reason": "Bad", "extra": 1}, 400)

	// Users: create with a role; the new user works with exactly those permissions.
	clerkPassword, _ := auth.Token()
	user := decodeObject(t, f.request(t, "checker", "POST", "/api/v1/admin/users", "", map[string]any{
		"email": "Clerk@Example.test", "display_name": "Clerk One", "password": clerkPassword,
		"grants": []any{map[string]any{"role_id": clerkID}}, "reason": "New pilot clerk"}, 201))
	if user["email"] != "clerk@example.test" || user["version"].(float64) != 1 || strings.Contains(string(mustJSON(user)), "argon2") {
		t.Fatal("created user", user)
	}
	uid := user["id"].(string)
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/users", "", map[string]any{"email": "x@example.test", "display_name": "X", "password": "short", "grants": []any{}, "reason": "Weak password"}, 422), "weak_password")
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/users", "", map[string]any{"email": "clerk@example.test", "display_name": "Dup", "password": clerkPassword, "grants": []any{}, "reason": "Duplicate email"}, 409), "duplicate_record")
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/users", "", map[string]any{"email": "not-an-email", "display_name": "X", "password": clerkPassword, "grants": []any{}, "reason": "Bad email"}, 422), "invalid_email")

	f.login(t, "clerk", "clerk@example.test", clerkPassword, 200)
	j := decodeObject(t, f.request(t, "clerk", "POST", "/api/v1/accounting/journals", "clerk-journal-1", f.payload, 201))
	f.request(t, "clerk", "POST", "/api/v1/accounting/journals/"+j["id"].(string)+"/void", "clerk-void-1", map[string]any{"expected_version": j["version"], "reason": "Clerk cannot void"}, 403)
	f.request(t, "clerk", "GET", "/api/v1/admin/catalog", "", nil, 403)

	// Tick one more permission on the role: effective immediately.
	clerk = decodeObject(t, f.request(t, "checker", "POST", "/api/v1/admin/roles/"+clerkID+"/update", "", map[string]any{
		"expected_version": 1, "name": "Clerk", "description": "Prepares and voids journals",
		"permissions": []string{"ledger.read", "journal.create", "journal.submit", "journal.void"}, "reason": "Clerks may void drafts"}, 200))
	f.request(t, "clerk", "POST", "/api/v1/accounting/journals/"+j["id"].(string)+"/void", "clerk-void-2", map[string]any{"expected_version": j["version"], "reason": "Now allowed"}, 200)
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/roles/"+clerkID+"/update", "", map[string]any{
		"expected_version": 1, "name": "Clerk", "description": "", "permissions": []string{"ledger.read"}, "reason": "Stale edit"}, 409), "version_conflict")

	// Branch scope and approval limit on a grant.
	user = decodeObject(t, f.request(t, "checker", "POST", "/api/v1/admin/users/"+uid+"/grants", "", map[string]any{
		"expected_version": 1, "grants": []any{map[string]any{"role_id": clerkID, "branch_id": f.data.Branches["A:SECOND"]}}, "reason": "Limit clerk to SECOND branch"}, 200))
	if g := user["grants"].([]any)[0].(map[string]any); g["branch_code"] != "SECOND" || user["version"].(float64) != 2 {
		t.Fatal("grants", user)
	}
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/users/"+uid+"/grants", "", map[string]any{
		"expected_version": 2, "grants": []any{map[string]any{"role_id": clerkID}, map[string]any{"role_id": clerkID}}, "reason": "Duplicate role"}, 422), "invalid_grant")

	// Safety rules.
	var superRole string
	for _, r := range catalog["roles"].([]any) {
		if r.(map[string]any)["name"] == provisioning.SuperAdminRole {
			superRole = r.(map[string]any)["id"].(string)
		}
	}
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/roles/"+clerkID+"/delete", "", map[string]any{"expected_version": 2, "reason": "Role still used"}, 409), "role_in_use")
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/users/"+f.data.Users["checker@example.test"]+"/update", "", map[string]any{
		"expected_version": 2, "display_name": "checker", "active": false, "reason": "Disable myself"}, 409), "cannot_change_self")
	// Disabling the other super admin is allowed, but removing the last one is not.
	var bossID, bossVersion = "", 0.0
	for _, u := range catalog["users"].([]any) {
		if u.(map[string]any)["email"] == "boss@example.test" {
			bossID, bossVersion = u.(map[string]any)["id"].(string), u.(map[string]any)["version"].(float64)
		}
	}
	f.request(t, "checker", "POST", "/api/v1/admin/users/"+bossID+"/update", "", map[string]any{"expected_version": bossVersion, "display_name": "Boss", "active": false, "reason": "Boss leaves"}, 200)
	f.request(t, "boss", "GET", "/api/v1/session", "", nil, 401)
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/roles/"+superRole+"/update", "", map[string]any{
		"expected_version": 2, "name": provisioning.SuperAdminRole, "description": "", "permissions": []string{"ledger.read"}, "reason": "Strip the last admin"}, 409), "last_administrator")
	wantError(t, f.request(t, "checker", "POST", "/api/v1/admin/users/"+f.data.Users["checker@example.test"]+"/grants", "", map[string]any{
		"expected_version": 2, "grants": []any{}, "reason": "Remove my own admin role"}, 409), "last_administrator")

	// No privilege escalation: a user administrator without journal permissions.
	lite := decodeObject(t, f.request(t, "checker", "POST", "/api/v1/admin/roles", "", map[string]any{
		"name": "User admin", "description": "", "permissions": []string{"ledger.read", "user.manage", "role.manage"}, "reason": "Delegated administration"}, 201))
	litePassword, _ := auth.Token()
	f.request(t, "checker", "POST", "/api/v1/admin/users", "", map[string]any{"email": "lite@example.test", "display_name": "Lite", "password": litePassword,
		"grants": []any{map[string]any{"role_id": lite["id"]}}, "reason": "Delegated administrator"}, 201)
	f.login(t, "lite", "lite@example.test", litePassword, 200)
	wantError(t, f.request(t, "lite", "POST", "/api/v1/admin/roles", "", map[string]any{"name": "Poster", "description": "", "permissions": []string{"journal.post"}, "reason": "Escalate"}, 403), "privilege_escalation")
	wantError(t, f.request(t, "lite", "POST", "/api/v1/admin/users/"+uid+"/grants", "", map[string]any{"expected_version": 2, "grants": []any{map[string]any{"role_id": clerkID}}, "reason": "Grant clerk"}, 403), "privilege_escalation")
	wantError(t, f.request(t, "lite", "POST", "/api/v1/admin/users/"+f.data.Users["checker@example.test"]+"/password", "", map[string]any{"expected_version": 2, "password": litePassword, "reason": "Take over"}, 403), "privilege_escalation")
	wantError(t, f.request(t, "lite", "POST", "/api/v1/admin/roles/"+superRole+"/delete", "", map[string]any{"expected_version": 2, "reason": "Delete super role"}, 403), "privilege_escalation")

	// A delegated administrator cannot hand out approval rights they do not hold.
	approver := decodeObject(t, f.request(t, "checker", "POST", "/api/v1/admin/roles", "", map[string]any{
		"name": "Approver", "description": "", "permissions": []string{"ledger.read", "journal.approve"}, "reason": "Approver role"}, 201))
	wantError(t, f.request(t, "lite", "POST", "/api/v1/admin/users", "", map[string]any{"email": "appr@example.test", "display_name": "Appr", "password": litePassword,
		"grants": []any{map[string]any{"role_id": approver["id"], "approval_limit_minor": "100"}}, "reason": "Escalate approval"}, 403), "privilege_escalation")

	// Password reset revokes sessions; disable blocks login.
	newPassword, _ := auth.Token()
	f.request(t, "checker", "POST", "/api/v1/admin/users/"+uid+"/password", "", map[string]any{"expected_version": 2, "password": newPassword, "reason": "Forgotten password"}, 200)
	f.request(t, "clerk", "GET", "/api/v1/session", "", nil, 401)
	f.login(t, "clerk", "clerk@example.test", clerkPassword, 401)
	f.login(t, "clerk", "clerk@example.test", newPassword, 200)
	f.request(t, "checker", "POST", "/api/v1/admin/users/"+uid+"/update", "", map[string]any{"expected_version": 3, "display_name": "Clerk One", "active": false, "reason": "Left the company"}, 200)
	f.request(t, "clerk", "GET", "/api/v1/session", "", nil, 401)
	f.login(t, "clerk2", "clerk@example.test", newPassword, 401)

	// Unused role can be deleted.
	f.request(t, "checker", "POST", "/api/v1/admin/roles/"+approver["id"].(string)+"/delete", "", map[string]any{"expected_version": 1, "reason": "Not needed"}, 200)

	// Every change is on the audit chain, without secrets, and the ledger still verifies.
	integrity := decodeObject(t, f.request(t, "checker", "GET", "/api/v1/accounting/integrity", "", nil, 200))
	if integrity["ok"] != true {
		t.Fatal("integrity after administration", integrity)
	}
	var actions []string
	rows, e := f.admin.Query(ctx, `SELECT action, new_state::text FROM audit.events WHERE company_id=$1 AND action ~ '^(user|role)\.' ORDER BY sequence_no`, f.data.Companies["A"])
	if e != nil {
		t.Fatal(e)
	}
	for rows.Next() {
		var a, state string
		if e = rows.Scan(&a, &state); e != nil {
			t.Fatal(e)
		}
		if strings.Contains(state, "argon2") || strings.Contains(state, newPassword) {
			t.Fatal("audit contains a secret")
		}
		actions = append(actions, a)
	}
	got := strings.Join(actions, ",")
	for _, want := range []string{"role.created", "user.created", "role.updated", "user.roles_changed", "user.disabled", "user.password_reset", "role.deleted"} {
		if !strings.Contains(got, want) {
			t.Fatalf("audit missing %s in %s", want, got)
		}
	}
}

func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }
