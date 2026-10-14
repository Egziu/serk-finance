package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestProductionCookieBoundary(t *testing.T) {
	s := &Server{Config: Config{SecureCookies: true}}
	rr := httptest.NewRecorder()
	s.cookie(rr, "value", 60)
	c := rr.Result().Cookies()[0]
	if c.Name != "__Host-serk_session" || !c.Secure || !c.HttpOnly || c.Path != "/" || c.Domain != "" || c.SameSite != http.SameSiteStrictMode {
		t.Fatal(c)
	}
	req := httptest.NewRequest("GET", "https://finance.example", nil)
	req.AddCookie(&http.Cookie{Name: "serk_session", Value: "injected"})
	if s.token(req) != "" {
		t.Fatal("accepted non-host-bound production cookie")
	}
}
func TestJSONEncodingAndLimits(t *testing.T) {
	for _, body := range [][]byte{[]byte("{\"x\":\"\xff\"}"), []byte(`{"a":1,"a":2}`), []byte(`{} {}`), []byte(strings.Repeat("[", 34) + "0" + strings.Repeat("]", 34))} {
		if validateJSON(body) == nil {
			t.Fatalf("invalid input accepted %q", body)
		}
	}
	rr := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/", strings.NewReader(`{"x":"`+strings.Repeat("a", 513<<10)+`"}`))
	req.Header.Set("Content-Type", "application/json")
	var value any
	if decode(rr, req, &value) == nil {
		t.Fatal("oversized body accepted")
	}
}
func TestHealthProbesAreNotRateLimited(t *testing.T) {
	s := &Server{limits: &limiter{entries: map[string]window{}}}
	for i := 0; i < 601; i++ {
		s.limits.Allow("all:192.0.2.1", 600)
	}
	h := s.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	for _, p := range []struct {
		path   string
		status int
	}{{"/health/ready", 200}, {"/api/v1/session", 429}} {
		req := httptest.NewRequest("GET", p.path, nil)
		req.RemoteAddr = "192.0.2.1:8080"
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		if rr.Code != p.status {
			t.Fatal(p.path, rr.Code)
		}
	}
}

func TestForwardedAddressTrustBoundary(t *testing.T) {
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:1000"
	req.Header.Set("X-Real-IP", "198.51.100.2")
	s := &Server{}
	if s.clientIP(req) != "127.0.0.1" {
		t.Fatal("trusted unsolicited header")
	}
	server, e := New(nil, nil, Config{Origin: "http://localhost:8080", TrustedProxyCIDRs: []string{"127.0.0.1/32"}})
	if e != nil {
		t.Fatal(e)
	}
	if server.clientIP(req) != "198.51.100.2" {
		t.Fatal("configured proxy not recognized")
	}
	req.Header.Set("X-Real-IP", "198.51.100.2, 127.0.0.1")
	if server.clientIP(req) != "127.0.0.1" {
		t.Fatal("accepted ambiguous header")
	}
	if _, e = New(nil, nil, Config{Origin: "http://localhost:8080", TrustedProxyCIDRs: []string{"0.0.0.0/0"}}); e == nil {
		t.Fatal("unrestricted proxy trust")
	}
}

func TestEffectiveRequireMFA(t *testing.T) {
	cases := []struct {
		c    Config
		want bool
	}{
		{Config{}, false},                                       // development
		{Config{SecureCookies: true}, true},                     // staging/production default
		{Config{SecureCookies: true, OptionalMFA: true}, false}, // staging with SERK_REQUIRE_MFA=false
		{Config{SecureCookies: true, OptionalMFA: true, RequireMFA: true}, true},
		{Config{RequireMFA: true}, true},
	}
	for i, tc := range cases {
		if got := effectiveRequireMFA(tc.c); got != tc.want {
			t.Fatalf("case %d: got %v want %v", i, got, tc.want)
		}
	}
}

func TestOfficeOriginsAndCrossSiteWrites(t *testing.T) {
	s := &Server{Config: Config{Office: true, Origin: "http://localhost:8080", ExtraOrigins: []string{"http://192.168.1.20:8080"}}, limits: &limiter{entries: map[string]window{}}}
	h := s.middleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	for origin, want := range map[string]int{"http://localhost:8080": 204, "http://192.168.1.20:8080": 204, "http://evil.example": 403, "": 403} {
		rr := httptest.NewRecorder()
		req := httptest.NewRequest("POST", "/api/v1/x", nil)
		req.Header.Set("Origin", origin)
		h.ServeHTTP(rr, req)
		if rr.Code != want {
			t.Errorf("%q: got %d", origin, rr.Code)
		}
	}
	if _, e := New(nil, nil, Config{Origin: "https://a.example", ExtraOrigins: []string{"https://b.example"}, SecureCookies: true, MFAKey: make([]byte, 32)}); e == nil {
		t.Error("extra origins accepted outside office mode")
	}
}
