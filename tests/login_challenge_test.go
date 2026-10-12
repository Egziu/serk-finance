package tests

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/pquerna/otp/totp"
	"serk.finance/internal/auth"
	"serk.finance/internal/mfa"
	"serk.finance/internal/platform/httpapi"
	"serk.finance/internal/provisioning"
)

func TestTwoStepMFALogin(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	key := bytes.Repeat([]byte{42}, 32)
	k, e := mfa.Generate("maker@example.test")
	if e != nil {
		t.Fatal(e)
	}
	proof, _ := totp.GenerateCode(k.Secret(), time.Now().Add(-30*time.Second))
	if e = provisioning.EnrollMFA(ctx, f.admin, key, provisioning.MFARequest{Tenant: f.slug, Email: "maker@example.test", Secret: k.Secret(), Code: proof, Reason: "Verified enrollment acceptance"}); e != nil {
		t.Fatal(e)
	}
	s, e := httpapi.New(f.db, f.adb, httpapi.Config{Origin: "http://localhost:8080", MFAKey: key, RequireMFA: true})
	if e != nil {
		t.Fatal(e)
	}
	h := s.Handler()
	post := func(path string, body any, status int) *httptest.ResponseRecorder {
		t.Helper()
		b, _ := json.Marshal(body)
		r := httptest.NewRequest("POST", path, bytes.NewReader(b))
		r.Header.Set("Origin", "http://localhost:8080")
		r.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, r)
		if rr.Code != status {
			t.Fatalf("POST %s wanted %d got %d %s", path, status, rr.Code, rr.Body.String())
		}
		return rr
	}
	start := func() string {
		t.Helper()
		rr := post("/api/v1/auth/login", map[string]string{"tenant": f.slug, "email": "maker@example.test", "password": f.password}, 200)
		var v struct {
			Required bool   `json:"mfa_required"`
			Token    string `json:"mfa_token"`
		}
		if json.Unmarshal(rr.Body.Bytes(), &v) != nil || !v.Required || len(v.Token) != 43 || len(rr.Result().Cookies()) != 0 {
			t.Fatal("step one must return a challenge and no session", rr.Body.String())
		}
		return v.Token
	}
	second := func(token, code string, status int) *httptest.ResponseRecorder {
		t.Helper()
		return post("/api/v1/auth/login/mfa", map[string]string{"mfa_token": token, "code": code}, status)
	}
	code := func(at time.Time) string { c, _ := totp.GenerateCode(k.Secret(), at); return c }

	// Wrong password never reaches the challenge step.
	post("/api/v1/auth/login", map[string]string{"tenant": f.slug, "email": "maker@example.test", "password": "wrong-password-value"}, 401)
	// Unknown field and malformed input.
	post("/api/v1/auth/login/mfa", map[string]string{"mfa_token": "x", "code": "123456", "user_id": "x"}, 400)
	second("short", "123456", 400)

	token := start()
	second(token, "12345", 400)
	second(token, "000000", 401)
	now := time.Now()
	rr := second(token, code(now), 200)
	cookies := rr.Result().Cookies()
	if len(cookies) != 1 {
		t.Fatal("step two must issue exactly one session cookie")
	}
	req := httptest.NewRequest("GET", "/api/v1/session", nil)
	req.AddCookie(cookies[0])
	check := httptest.NewRecorder()
	h.ServeHTTP(check, req)
	if check.Code != 200 {
		t.Fatal("two-step session is not MFA-verified", check.Code, check.Body.String())
	}
	// Single use: the consumed challenge cannot issue a second session.
	second(token, code(now.Add(30*time.Second)), 401)
	// The same TOTP time step cannot be replayed through a new challenge.
	second(start(), code(now), 401)

	// A new challenge replaces the open one.
	stale := start()
	fresh := start()
	second(stale, code(now.Add(30*time.Second)), 401)

	// Five wrong codes exhaust the challenge; a correct code afterwards is refused.
	for i := 0; i < 5; i++ {
		second(fresh, "000000", 401)
	}
	second(fresh, code(now.Add(30*time.Second)), 401)

	// Throttle windows were used above; clear them so the remaining cases test the challenge only.
	if _, e = f.admin.Exec(ctx, `DELETE FROM security.login_windows`); e != nil {
		t.Fatal(e)
	}
	// Expired challenge.
	expired := start()
	if _, e = f.admin.Exec(ctx, `UPDATE security.login_challenges SET expires_at=clock_timestamp()-interval '1 second' WHERE token_hash=$1`, auth.Digest(expired)); e != nil {
		t.Fatal(e)
	}
	second(expired, code(now.Add(30*time.Second)), 401)

	// A password change after step one invalidates the challenge.
	changed := start()
	if _, e = f.admin.Exec(ctx, `UPDATE security.users SET password_hash=password_hash||'x' WHERE id=$1`, f.data.Users["maker@example.test"]); e != nil {
		t.Fatal(e)
	}
	second(changed, code(now.Add(30*time.Second)), 401)

	// The runtime authentication role cannot read or alter challenges directly.
	e = f.adb.Transaction(ctx, func(tx pgx.Tx) error {
		var n int
		return tx.QueryRow(ctx, `SELECT count(*) FROM security.login_challenges`).Scan(&n)
	})
	wantCode(t, e, "42501")
}

func TestDevShowOTPOnlyInDevelopment(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	key := bytes.Repeat([]byte{42}, 32)
	if _, e := httpapi.New(f.db, f.adb, httpapi.Config{Origin: "https://finance.example.test", MFAKey: key, SecureCookies: true, DevShowOTP: true}); e == nil {
		t.Fatal("secure (non-development) server accepted SERK_DEV_SHOW_OTP")
	}
	k, _ := mfa.Generate("maker@example.test")
	proof, _ := totp.GenerateCode(k.Secret(), time.Now().Add(-30*time.Second))
	if e := provisioning.EnrollMFA(ctx, f.admin, key, provisioning.MFARequest{Tenant: f.slug, Email: "maker@example.test", Secret: k.Secret(), Code: proof, Reason: "Verified enrollment acceptance"}); e != nil {
		t.Fatal(e)
	}
	s, e := httpapi.New(f.db, f.adb, httpapi.Config{Origin: "http://localhost:8080", MFAKey: key, DevShowOTP: true})
	if e != nil {
		t.Fatal(e)
	}
	h := s.Handler()
	post := func(path string, body any) *httptest.ResponseRecorder {
		b, _ := json.Marshal(body)
		r := httptest.NewRequest("POST", path, bytes.NewReader(b))
		r.Header.Set("Origin", "http://localhost:8080")
		r.Header.Set("Content-Type", "application/json")
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, r)
		return rr
	}
	var v struct {
		Token string `json:"mfa_token"`
		Code  string `json:"dev_code"`
	}
	rr := post("/api/v1/auth/login", map[string]string{"tenant": f.slug, "email": "maker@example.test", "password": f.password})
	if rr.Code != 200 || json.Unmarshal(rr.Body.Bytes(), &v) != nil || len(v.Code) != 6 || len(rr.Result().Cookies()) != 0 {
		t.Fatal("development step one must return a code and no session", rr.Code, rr.Body.String())
	}
	if rr = post("/api/v1/auth/login/mfa", map[string]string{"mfa_token": v.Token, "code": v.Code}); rr.Code != 200 {
		t.Fatal("displayed development code was not accepted", rr.Code, rr.Body.String())
	}
}
