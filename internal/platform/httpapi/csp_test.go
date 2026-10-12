package httpapi

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestIndexStyleNonce(t *testing.T) {
	dir := t.TempDir()
	if e := os.WriteFile(filepath.Join(dir, "index.html"), []byte("<!doctype html><html><head><title>x</title></head><body></body></html>"), 0o600); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(dir, "app.css"), []byte("body{}"), 0o600); e != nil {
		t.Fatal(e)
	}
	s, e := New(nil, nil, Config{Origin: "http://localhost:8080", StaticDir: dir})
	if e != nil {
		t.Fatal(e)
	}
	h := s.Handler()
	meta := regexp.MustCompile(`<meta name="csp-nonce" content="([A-Za-z0-9_-]{24})"/>`)
	get := func(path string) (string, string) {
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, httptest.NewRequest("GET", path, nil))
		if rr.Code != 200 {
			t.Fatalf("GET %s: %d", path, rr.Code)
		}
		return rr.Header().Get("Content-Security-Policy"), rr.Body.String()
	}
	policy, body := get("/")
	m := meta.FindStringSubmatch(body)
	if m == nil || !strings.Contains(policy, "style-src 'self' 'nonce-"+m[1]+"'") || !strings.Contains(policy, "script-src 'self';") {
		t.Fatalf("page and policy must share one style nonce; scripts stay self-only: %q %q", policy, body)
	}
	if _, again := get("/"); meta.FindStringSubmatch(again)[1] == m[1] {
		t.Fatal("style nonce must change on every response")
	}
	if other, _ := get("/app.css"); strings.Contains(other, "nonce-") {
		t.Fatal("assets must not carry a nonce", other)
	}
}
