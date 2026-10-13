package tests

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Self-service password change: the current password is required, weak or unchanged passwords
// are refused, a change revokes every session, and only the new password signs in afterwards.
func TestProfilePasswordChange(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	path := "/api/v1/profile/password"
	newPassword := "Changed-Password-2026-" + f.slug
	wantError(t, f.request(t, "reader", "POST", path, "", map[string]any{"current_password": "wrong-password-value", "new_password": newPassword}, 401), "invalid_credentials")
	wantError(t, f.request(t, "reader", "POST", path, "", map[string]any{"current_password": f.password, "new_password": "short"}, 422), "weak_password")
	wantError(t, f.request(t, "reader", "POST", path, "", map[string]any{"current_password": f.password, "new_password": f.password}, 422), "weak_password")
	f.login(t, "reader2", "reader@example.test", f.password, 200)
	res := decodeObject(t, f.request(t, "reader", "POST", path, "", map[string]any{"current_password": f.password, "new_password": newPassword}, 200))
	if res["reauthentication_required"] != true {
		t.Fatal("password change result", res)
	}
	// Both sessions of the user are revoked.
	f.request(t, "reader", "GET", "/api/v1/session", "", nil, 401)
	f.request(t, "reader2", "GET", "/api/v1/session", "", nil, 401)
	f.login(t, "old", "reader@example.test", f.password, 401)
	f.login(t, "reader3", "reader@example.test", newPassword, 200)
	f.request(t, "reader3", "GET", "/api/v1/session", "", nil, 200)
	// Other users are unaffected, and the change is recorded.
	f.request(t, "maker", "GET", "/api/v1/session", "", nil, 200)
	var n int
	if e := f.admin.QueryRow(ctx, `SELECT count(*) FROM security.admin_events WHERE target_user_id=$1::uuid AND action='change_own_password'`, f.data.Users["reader@example.test"]).Scan(&n); e != nil || n != 1 {
		t.Fatal("admin event", n, e)
	}
	// The runtime API role cannot call the database function directly.
	if e := f.db.Transaction(ctx, func(tx pgx.Tx) error {
		_, e := tx.Exec(ctx, `SELECT security.change_own_password('x','y','z')`)
		return e
	}); e == nil {
		t.Fatal("serk_api must not change passwords")
	}
}
