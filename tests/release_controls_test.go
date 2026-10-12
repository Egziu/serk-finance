package tests

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"serk.finance/internal/platform/database"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/auth"
	"serk.finance/internal/provisioning"
)

func TestApprovalRevocationPreventsPosting(t *testing.T) {
	f := setup(t)
	j := f.create(t, "revocation-create")
	x, e := f.move("maker", "revocation-submit", "submit", j)
	j = must(t, x, e)
	x, e = f.move("checker", "revocation-approve", "approve", j)
	j = must(t, x, e)
	_, e = f.admin.Exec(context.Background(), `UPDATE security.memberships SET approval_limit_minor=1 WHERE user_id=$1`, f.data.Users["checker@example.test"])
	if e != nil {
		t.Fatal(e)
	}
	_, e = f.move("maker", "revocation-post", "post", j)
	wantCode(t, e, "42501")
	var state string
	if e = f.admin.QueryRow(context.Background(), `SELECT state FROM ledger.journals WHERE id=$1`, j["id"]).Scan(&state); e != nil || state != "APPROVED" {
		t.Fatal("unexpected financial effect", state, e)
	}
}
func TestDefinitionsCannotReinterpretHistory(t *testing.T) {
	f := setup(t)
	f.create(t, "currency-history")
	for _, q := range []string{
		`UPDATE organization.companies SET functional_currency='USD' WHERE id=$1`,
		`UPDATE ledger.fiscal_years SET end_date='2026-11-30' WHERE company_id=$1`,
	} {
		_, e := f.admin.Exec(context.Background(), q, f.data.Companies["A"])
		wantCode(t, e, "55000")
	}
	_, e := f.admin.Exec(context.Background(), `UPDATE organization.currencies SET minor_units=0 WHERE code='ETB'`)
	wantCode(t, e, "55000")
}
func TestPeriodCloseDurableReplay(t *testing.T) {
	f := setup(t)
	var first, second string
	call := func(reason string, out *string) error {
		return f.scope("checker", func(tx pgx.Tx) error {
			return tx.QueryRow(context.Background(), `SELECT ledger.close_period_command('close-once-01',$1::uuid,1,$2)::text`, f.data.Periods["A:2026-09"], reason).Scan(out)
		})
	}
	if e := call("Reviewed September close", &first); e != nil {
		t.Fatal(e)
	}
	if e := call("Reviewed September close", &second); e != nil || first != second {
		t.Fatal("replay mismatch", e)
	}
	wantCode(t, call("Changed request", &second), "22000")
	var n int
	e := f.admin.QueryRow(context.Background(), `SELECT count(*) FROM audit.events WHERE entity_id=$1`, f.data.Periods["A:2026-09"]).Scan(&n)
	if e != nil || n != 1 {
		t.Fatal("duplicate period effect", n, e)
	}
}
func TestPasswordResetAndOperatorAudit(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	var slug, oldHash string
	if e := f.admin.QueryRow(ctx, `SELECT t.slug,u.password_hash FROM security.tenants t JOIN security.users u ON u.tenant_id=t.id WHERE u.id=$1`, f.data.Users["maker@example.test"]).Scan(&slug, &oldHash); e != nil {
		t.Fatal(e)
	}
	password, _ := auth.Token()
	e := provisioning.Administer(ctx, f.admin, provisioning.AdminRequest{Tenant: slug, Email: "maker@example.test", Action: "reset_password", Reason: "Verified operator recovery", Password: password})
	if e != nil {
		t.Fatal(e)
	}
	wantCode(t, f.scope("maker", func(tx pgx.Tx) error { return nil }), "28000")
	e = f.adb.Transaction(ctx, func(tx pgx.Tx) error {
		_, e := tx.Exec(ctx, `SELECT security.issue_verified_session($1::uuid,$2,$3,$4,NULL,-1,false)`, f.data.Users["maker@example.test"], auth.Digest("stale-login"), f.csrf["maker"], oldHash)
		return e
	})
	wantCode(t, e, "28000")
	e = f.adb.Transaction(ctx, func(tx pgx.Tx) error {
		_, e := tx.Exec(ctx, `SELECT security.issue_session($1::uuid,$2,$3)`, f.data.Users["maker@example.test"], auth.Digest("bypass"), f.csrf["maker"])
		return e
	})
	wantCode(t, e, "42501")
	var audit string
	e = f.admin.QueryRow(ctx, `SELECT row_to_json(e)::text FROM security.admin_events e WHERE target_user_id=$1`, f.data.Users["maker@example.test"]).Scan(&audit)
	if e != nil || strings.Contains(audit, password) || strings.Contains(audit, "argon2") {
		t.Fatal("operator audit contains secret or missing", e)
	}
	// Fresh password completes the public login flow, setting a revocable session cookie.
	b, _ := json.Marshal(map[string]string{"tenant": slug, "email": "maker@example.test", "password": password})
	req := httptest.NewRequest("POST", "http://localhost:8080/api/v1/auth/login", bytes.NewReader(b))
	req.Header.Set("Origin", "http://localhost:8080")
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	f.handler.ServeHTTP(rr, req)
	if rr.Code != 200 || len(rr.Result().Cookies()) != 1 {
		t.Fatalf("login failed %d %s", rr.Code, rr.Body.String())
	}
	if e = provisioning.Administer(ctx, f.admin, provisioning.AdminRequest{Tenant: slug, Email: "maker@example.test", Action: "disable_user", Reason: "Terminated access"}); e != nil {
		t.Fatal(e)
	}
	session := httptest.NewRequest("GET", "/api/v1/session", nil)
	session.AddCookie(rr.Result().Cookies()[0])
	rr = httptest.NewRecorder()
	f.handler.ServeHTTP(rr, session)
	if rr.Code != http.StatusUnauthorized {
		t.Fatal("disabled user session active", rr.Code)
	}
}
func TestPersistentLoginThrottle(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	key, _ := auth.Token()
	for n := 1; n <= 12; n++ {
		var allowed bool
		e := f.adb.Transaction(ctx, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT security.consume_login_attempt($1,'reader@example.test','192.0.2.1')`, key).Scan(&allowed)
		})
		if e != nil || allowed != (n <= 10) {
			t.Fatal("unexpected throttle decision", n, allowed, e)
		}
	}
}
func TestReadinessRequiresAuthenticationDatabase(t *testing.T) {
	f := setup(t)
	f.adb.Close()
	rr := httptest.NewRecorder()
	f.handler.ServeHTTP(rr, httptest.NewRequest("GET", "/health/ready", nil))
	if rr.Code != 503 {
		t.Fatal("ready with authentication unavailable", rr.Code)
	}
}
func TestJournalBatchLatencyEvidence(t *testing.T) {
	if testing.Short() {
		t.Skip("batch evidence excluded by short mode")
	}
	f := setup(t)
	start := time.Now()
	for i := 0; i < 50; i++ {
		f.create(t, fmt.Sprintf("batch-evidence-%04d", i))
	}
	t.Logf("50 sequential two-line journal creates: %s (includes DB validation, audit and outbox; this is not an enterprise load benchmark)", time.Since(start))
}

func TestNativeRuntimeIdentityBoundaries(t *testing.T) {
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		t.Skip("native login identities required")
	}
	f := setup(t)
	for _, test := range []struct{ dsn, role string }{
		{os.Getenv("TEST_DATABASE_URL"), "serk_api"},
		{os.Getenv("TEST_AUTH_DATABASE_URL"), "serk_api"},
		{os.Getenv("TEST_API_DATABASE_URL"), "serk_auth"},
	} {
		if pool, e := database.Open(context.Background(), test.dsn, test.role); e == nil {
			pool.Close()
			t.Fatal("unsafe runtime identity accepted")
		}
	}
	var login string
	if e := f.db.QueryRow(context.Background(), `SELECT current_user`).Scan(&login); e != nil {
		t.Fatal(e)
	}
	identifier := pgx.Identifier{login}.Sanitize()
	if _, e := f.admin.Exec(context.Background(), `GRANT pg_read_all_data TO `+identifier); e != nil {
		t.Fatal(e)
	}
	defer f.admin.Exec(context.Background(), `REVOKE pg_read_all_data FROM `+identifier)
	if pool, e := database.Open(context.Background(), os.Getenv("TEST_API_DATABASE_URL"), "serk_api"); e == nil {
		pool.Close()
		t.Fatal("dangerous inherited data access accepted")
	}
}
