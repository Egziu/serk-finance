package tests

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"github.com/pquerna/otp/totp"
	"net/http"
	"net/http/httptest"
	"serk.finance/internal/auth"
	"serk.finance/internal/mfa"
	"serk.finance/internal/platform/httpapi"
	"serk.finance/internal/provisioning"
	"strings"
	"testing"
	"time"
)

func (f *fixture) request(t *testing.T, user, method, path, key string, body any, status int) *httptest.ResponseRecorder {
	t.Helper()
	raw, _ := json.Marshal(body)
	r := httptest.NewRequest(method, path, bytes.NewReader(raw))
	r.Header.Set("Origin", "http://localhost:8080")
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-Company-ID", f.data.Companies["A"])
	r.Header.Set("X-CSRF-Token", f.csrf[user])
	r.Header.Set("Idempotency-Key", key)
	r.AddCookie(&http.Cookie{Name: "serk_session", Value: f.tokens[user]})
	rr := httptest.NewRecorder()
	f.handler.ServeHTTP(rr, r)
	if rr.Code != status {
		t.Fatalf("%s %s wanted %d got %d %s", method, path, status, rr.Code, rr.Body.String())
	}
	return rr
}
func decodeObject(t *testing.T, rr *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var v map[string]any
	if e := json.Unmarshal(rr.Body.Bytes(), &v); e != nil {
		t.Fatal(e)
	}
	return v
}
func TestHTTPFinancialHandlers(t *testing.T) {
	f := setup(t)
	root := "/api/v1/accounting/"
	period := root + "periods/" + f.data.Periods["A:2026-09"]
	j := decodeObject(t, f.request(t, "maker", "POST", root+"journals", "http-create-01", f.payload, 201))
	transition := func(user, action, key string, status int) {
		rr := f.request(t, user, "POST", root+"journals/"+j["id"].(string)+"/"+action, key, map[string]any{"expected_version": j["version"], "reason": "HTTP lifecycle evidence", "accounting_date": "2026-09-15"}, status)
		if status == 200 || status == 201 {
			j = decodeObject(t, rr)
		}
	}
	preview := decodeObject(t, f.request(t, "checker", "GET", period+"/close-preview", "", nil, 200))
	if preview["can_close"] != false || preview["unfinished"].(map[string]any)["draft"] != float64(1) {
		t.Fatal(preview)
	}
	closeBody := map[string]any{"expected_version": 1, "reason": "Reviewed close request"}
	f.request(t, "checker", "POST", period+"/close", "http-close-01", closeBody, 409)
	transition("maker", "submit", "http-submit-01", 200)
	transition("maker", "approve", "http-self-approve", 403)
	transition("reader", "approve", "http-reader-approve", 403)
	transition("checker", "approve", "http-approve-01", 200)
	f.request(t, "checker", "POST", period+"/close", "http-close-01", closeBody, 409)
	transition("checker", "post", "http-post-01", 200)
	trial := decodeObject(t, f.request(t, "maker", "GET", "/api/v1/reports/trial-balance?as_of=2026-09-30&from=2026-09-01", "", nil, 200))
	if trial["debit_minor"] != "10000" || trial["credit_minor"] != "10000" {
		t.Fatal(trial)
	}
	f.request(t, "checker", "GET", "/api/v1/audit/events?after=0", "", nil, 200)
	f.request(t, "reader", "GET", "/api/v1/audit/events", "", nil, 403)
	original := j
	transition("maker", "reverse", "http-reverse-01", 201)
	transition("maker", "void", "http-void-01", 200)
	j = original
	f.request(t, "checker", "POST", root+"journals/"+j["id"].(string)+"/reverse", "http-backdate-01", map[string]any{"expected_version": j["version"], "reason": "Invalid backdating", "accounting_date": "2026-09-13"}, 422)
	f.request(t, "checker", "POST", period+"/close", "http-close-01", closeBody, 200)
	f.request(t, "checker", "POST", period+"/close", "http-close-01", closeBody, 200)
	f.request(t, "maker", "POST", root+"journals", "http-after-close", f.payload, 409)
	for _, path := range []string{"/api/v1/reports/trial-balance", "/api/v1/reports/trial-balance?as_of=bad", "/api/v1/reports/trial-balance?as_of=2026-09-30&from=bad", "/api/v1/audit/events?after=-1", root + "periods/not-an-id/close-preview"} {
		f.request(t, "checker", "GET", path, "", nil, 400)
	}
	f.request(t, "checker", "POST", period+"/close", "invalid-body", map[string]any{"expected_version": 0, "reason": "x"}, 400)
	f.request(t, "checker", "POST", root+"journals/bad/submit", "invalid-transition", map[string]any{"expected_version": 1, "reason": "Review"}, 400)
	f.request(t, "checker", "POST", root+"journals/"+j["id"].(string)+"/unknown", "unknown-action", map[string]any{"expected_version": 4, "reason": "Review"}, 404)
	csrf := f.csrf["checker"]
	f.csrf["checker"] = "wrong"
	f.request(t, "checker", "POST", "/api/v1/auth/logout", "", nil, 403)
	f.csrf["checker"] = csrf
	rr := f.request(t, "checker", "POST", "/api/v1/auth/logout", "", nil, 200)
	if rr.Result().Cookies()[0].MaxAge != -1 {
		t.Fatal("logout did not expire cookie")
	}
	f.request(t, "checker", "GET", "/api/v1/session", "", nil, 401)
}
func TestPersistentThrottleSourceIsolationAndReset(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	consume := func(source string) bool {
		var allowed bool
		e := f.adb.Transaction(ctx, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT security.consume_login_attempt($1,'maker@example.test',$2)`, f.slug, source).Scan(&allowed)
		})
		if e != nil {
			t.Fatal(e)
		}
		return allowed
	}
	for n := 0; n < 10; n++ {
		if !consume("192.0.2.1") {
			t.Fatal("premature throttle")
		}
	}
	if consume("192.0.2.1") {
		t.Fatal("no source/account throttle")
	}
	if !consume("198.51.100.2") {
		t.Fatal("attacker locked another source out")
	}
	// Valid logins reset the durable source/account counter, even across server instances.
	b, _ := json.Marshal(map[string]string{"tenant": f.slug, "email": "maker@example.test", "password": f.password})
	for i := 0; i < 12; i++ {
		r := httptest.NewRequest("POST", "/api/v1/auth/login", bytes.NewReader(b))
		r.RemoteAddr = "198.51.100.2:1234"
		r.Header.Set("Origin", "http://localhost:8080")
		r.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		f.handler.ServeHTTP(rr, r)
		if rr.Code != 200 {
			t.Fatalf("successful login %d locked out: %d %s", i, rr.Code, rr.Body.String())
		}
	}
	if consume("192.0.2.1") {
		t.Fatal("success reset unrelated attacker's quota")
	}
}
func TestFXRoundingAndExactReversal(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	var roundingID string
	e := f.admin.QueryRow(ctx, `INSERT INTO ledger.accounts(tenant_id,company_id,code,name,type,normal_balance,reporting_category) VALUES($1,$2,'7999','FX rounding','OTHER_EXPENSE','DEBIT','OTHER_EXPENSE') RETURNING id`, f.data.TenantID, f.data.Companies["A"]).Scan(&roundingID)
	if e != nil {
		t.Fatal(e)
	}
	configure := func(max int) {
		_, e := f.admin.Exec(ctx, `SELECT ledger.configure_fx_rounding($1::uuid,$2::uuid,$3,'Independent accounting test policy')`, f.data.Companies["A"], roundingID, max)
		if e != nil {
			t.Fatal(e)
		}
	}
	e = f.scope("maker", func(tx pgx.Tx) error {
		_, e := tx.Exec(ctx, `SELECT ledger.configure_fx_rounding($1::uuid,$2::uuid,2,'Unauthorized config')`, f.data.Companies["A"], roundingID)
		return e
	})
	wantCode(t, e, "42501")
	f.payload["currency"] = "USD"
	f.payload["fx_rate"] = "0.5"
	f.rate(t, "USD", "2026-09-01", "0.5")
	line := func(debit, credit string, account string) any {
		return map[string]any{"account_id": f.data.Accounts["A:"+account], "debit_minor": debit, "credit_minor": credit}
	}
	f.payload["lines"] = []any{line("1", "0", "1000"), line("1", "0", "1000"), line("0", "2", "4000")}
	_, e = f.cmd("maker", "fx-without-config", "create", f.payload)
	wantCode(t, e, "23514")
	configure(1)
	j := f.create(t, "fx-rounded-create")
	lines := j["lines"].([]any)
	r := lines[3].(map[string]any)
	if len(lines) != 4 || r["is_rounding"] != true || r["account_id"] != roundingID || r["debit_minor"] != "0" || r["credit_minor"] != "0" || r["functional_credit_minor"] != "1" {
		t.Fatal("incorrect rounding entry", j)
	}
	for _, a := range []string{"submit", "approve", "post"} {
		u := "checker"
		if a == "submit" {
			u = "maker"
		}
		x, e := f.move(u, "fx-stage-"+a, a, j)
		j = must(t, x, e)
	}
	x, e := f.move("maker", "fx-reversal", "reverse", j)
	reverse := must(t, x, e)
	for _, a := range []string{"submit", "approve", "post"} {
		u := "checker"
		if a == "submit" {
			u = "maker"
		}
		x, e := f.move(u, "fx-reverse-"+a, a, reverse)
		reverse = must(t, x, e)
	}
	rr := reverse["lines"].([]any)[3].(map[string]any)
	if rr["functional_debit_minor"] != "1" || rr["is_rounding"] != true {
		t.Fatal("rounding reversal mismatch", rr)
	}
	var net string
	e = f.scope("checker", func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT coalesce(sum(l.functional_debit_minor-l.functional_credit_minor),0)::text FROM ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id WHERE j.state='POSTED' AND l.account_id=$1`, roundingID).Scan(&net)
	})
	if e != nil || net != "0" {
		t.Fatal("rounding balance not reversed", net, e)
	}
	f.payload["lines"] = []any{line("1", "0", "1000"), line("1", "0", "1000"), line("1", "0", "1000"), line("1", "0", "1000"), line("0", "4", "4000")}
	_, e = f.cmd("maker", "fx-over-policy-limit", "create", f.payload)
	wantCode(t, e, "23514")
	configure(250)
	many := []any{}
	for i := 0; i < 499; i++ {
		many = append(many, line("1", "0", "1000"))
	}
	many = append(many, line("0", "499", "4000"))
	f.payload["lines"] = many
	j = f.create(t, "fx-500-source-lines")
	if len(j["lines"].([]any)) != 501 {
		t.Fatal("500-line input plus rounding not supported")
	}
}
func TestMFAEnforcementReplayAndRecovery(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	key := bytes.Repeat([]byte{42}, 32)
	k, e := mfa.Generate("maker@example.test")
	if e != nil {
		t.Fatal(e)
	}
	previous := time.Now().Add(-30 * time.Second)
	proof, _ := totp.GenerateCode(k.Secret(), previous)
	e = provisioning.EnrollMFA(ctx, f.admin, key, provisioning.MFARequest{Tenant: f.slug, Email: "maker@example.test", Secret: k.Secret(), Code: proof, Reason: "Verified enrollment acceptance"})
	if e != nil {
		t.Fatal(e)
	}
	s, e := httpapi.New(f.db, f.adb, httpapi.Config{Origin: "http://localhost:8080", MFAKey: key, RequireMFA: true})
	if e != nil {
		t.Fatal(e)
	}
	f.handler = s.Handler()
	f.request(t, "checker", "GET", "/api/v1/session", "", nil, 401)
	f.request(t, "checker", "GET", "/api/v1/accounting/reference", "", nil, 401)
	login := func(user, code string, status int) *httptest.ResponseRecorder {
		b, _ := json.Marshal(map[string]string{"tenant": f.slug, "email": user + "@example.test", "password": f.password, "code": code})
		r := httptest.NewRequest("POST", "/api/v1/auth/login", bytes.NewReader(b))
		r.Header.Set("Origin", "http://localhost:8080")
		r.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		f.handler.ServeHTTP(rr, r)
		if rr.Code != status {
			t.Fatalf("MFA login %s: %d %s", user, rr.Code, rr.Body.String())
		}
		return rr
	}
	login("checker", "", 401)
	// Without a code an enrolled user gets only a step-one challenge, never a session.
	if first := login("maker", "", 200); len(first.Result().Cookies()) != 0 || !strings.Contains(first.Body.String(), `"mfa_required":true`) {
		t.Fatal("password-only step issued a session", first.Body.String())
	}
	login("maker", "abcdef", 401)
	now := time.Now()
	code, _ := totp.GenerateCode(k.Secret(), now)
	rr := login("maker", code, 200)
	// Direct DB issue repeats the EXACT counter: deterministic across clock boundaries.
	var hash, version string
	e = f.admin.QueryRow(ctx, `SELECT u.password_hash,m.version FROM security.users u JOIN security.user_mfa m ON m.user_id=u.id WHERE u.id=$1`, f.data.Users["maker@example.test"]).Scan(&hash, &version)
	if e != nil {
		t.Fatal(e)
	}
	e = f.adb.Transaction(ctx, func(tx pgx.Tx) error {
		_, e := tx.Exec(ctx, `SELECT security.issue_verified_session($1::uuid,$2,$3,$4,$5::uuid,$6,true)`, f.data.Users["maker@example.test"], auth.Digest("replay-attempt"), f.csrf["maker"], hash, version, now.Unix()/30)
		return e
	})
	wantCode(t, e, "28000")
	e = f.adb.Transaction(ctx, func(tx pgx.Tx) error {
		_, e := tx.Exec(ctx, `SELECT security.issue_verified_session($1::uuid,$2,$3,$4)`, f.data.Users["maker@example.test"], auth.Digest("legacy-bypass"), f.csrf["maker"], hash)
		return e
	})
	wantCode(t, e, "42501")
	// Old session is usable only until authenticated operator recovery rotates the device.
	req := httptest.NewRequest("GET", "/api/v1/session", nil)
	req.AddCookie(rr.Result().Cookies()[0])
	check := httptest.NewRecorder()
	f.handler.ServeHTTP(check, req)
	if check.Code != 200 {
		t.Fatal(check.Code)
	}
	newer, _ := mfa.Generate("maker@example.test")
	proof, _ = totp.GenerateCode(newer.Secret(), time.Now())
	e = provisioning.EnrollMFA(ctx, f.admin, key, provisioning.MFARequest{Tenant: f.slug, Email: "maker@example.test", Secret: newer.Secret(), Code: proof, Reason: "Verified lost-device recovery"})
	if e != nil {
		t.Fatal(e)
	}
	check = httptest.NewRecorder()
	f.handler.ServeHTTP(check, req)
	if check.Code != 401 {
		t.Fatal("MFA recovery failed to revoke sessions")
	}
	var audit string
	e = f.admin.QueryRow(ctx, `SELECT jsonb_agg(to_jsonb(e))::text FROM security.admin_events e WHERE target_user_id=$1`, f.data.Users["maker@example.test"]).Scan(&audit)
	if e != nil || strings.Contains(audit, k.Secret()) || strings.Contains(audit, newer.Secret()) {
		t.Fatal("MFA secret leaked to audit", e)
	}
}
func TestPeriodCloseCannotIgnoreOtherBranches(t *testing.T) {
	f := setup(t)
	f.payload["branch_id"] = f.data.Branches["A:SECOND"]
	f.create(t, "other-branch-draft")
	e := f.scope("checker", func(tx pgx.Tx) error {
		_, e := tx.Exec(context.Background(), `SELECT ledger.close_period($1::uuid,1,'All branches checked')`, f.data.Periods["A:2026-09"])
		return e
	})
	wantCode(t, e, "55000")
	// A branch-only ledger reader cannot perform a company close even with a close grant.
	_, e = f.admin.Exec(context.Background(), `UPDATE security.memberships SET branch_id=$1 WHERE user_id=$2`, f.data.Branches["A:HQ"], f.data.Users["checker@example.test"])
	if e != nil {
		t.Fatal(e)
	}
	e = f.scope("checker", func(tx pgx.Tx) error {
		_, e := tx.Exec(context.Background(), `SELECT ledger.close_period($1::uuid,1,'Incomplete visibility')`, f.data.Periods["A:2026-09"])
		return e
	})
	wantCode(t, e, "42501")
}
