package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDeploymentConfigurationFailsClosed(t *testing.T) {
	for _, env := range []string{"", "prod", "Production", "test"} {
		t.Setenv("SERK_ENV", env)
		if _, e := Environment(); e == nil {
			t.Fatalf("accepted environment %q", env)
		}
	}
	for _, env := range []string{"development", "staging", "production", "office"} {
		t.Setenv("SERK_ENV", env)
		if _, e := Environment(); e != nil {
			t.Fatal(e)
		}
	}
	for _, raw := range []string{"http://finance.example", "https://user:pass@finance.example", "https://finance.example/", "https://finance.example?", "https://finance.example?q=1", "https://finance.example/#x", "https://finance.example#", "https:///missing"} {
		if Origin(raw, true) == nil {
			t.Fatalf("accepted unsafe origin %s", raw)
		}
	}
	if e := Origin("https://finance.example:8443", true); e != nil {
		t.Fatal(e)
	}
	if e := Origin("http://localhost:8080", false); e != nil {
		t.Fatal(e)
	}
	if Origin("http://0.0.0.0:8080", false) == nil {
		t.Fatal("non-loopback development origin")
	}
}
func TestMountedSecretsRejectAmbiguity(t *testing.T) {
	p := filepath.Join(t.TempDir(), "secret")
	if e := os.WriteFile(p, []byte("example-secret\n"), 0600); e != nil {
		t.Fatal(e)
	}
	t.Setenv("SERK_TEST_SECRET_FILE", p)
	t.Setenv("SERK_TEST_SECRET", "")
	if v, e := Secret("SERK_TEST_SECRET"); e != nil || v != "example-secret" {
		t.Fatal(v, e)
	}
	t.Setenv("SERK_TEST_SECRET", "conflicting")
	if _, e := Secret("SERK_TEST_SECRET"); e == nil {
		t.Fatal("ambiguous source accepted")
	}
}

func TestOfficeOrigins(t *testing.T) {
	if e := OfficeOrigins([]string{"http://localhost:8080", "http://192.168.1.20:8080", "https://finance.office.lan"}); e != nil {
		t.Fatal(e)
	}
	for _, bad := range [][]string{nil, {"http://x/"}, {"ftp://x"}, {"http://u:p@x"}, {"http://x?q"}} {
		if OfficeOrigins(bad) == nil {
			t.Fatalf("accepted %v", bad)
		}
	}
}
