package database

import (
	"context"
	"testing"
)

func TestRuntimeRejectsUnsafeConfigurationBeforeConnecting(t *testing.T) {
	for _, env := range []string{"staging", "production"} {
		t.Setenv("SERK_ENV", env)
		for _, mode := range []string{"disable", "prefer", "allow", "require", "verify-ca"} {
			if p, e := Open(context.Background(), "postgres://user:password@localhost:1/serk?sslmode="+mode, "serk_api"); e == nil {
				p.Close()
				t.Fatalf("%s accepted %s", env, mode)
			}
		}
		t.Setenv("SERK_TEST_ROLE_OVERRIDE", "1")
		if p, e := Open(context.Background(), "postgres://localhost:1/serk?sslmode=disable", "serk_api"); e == nil {
			p.Close()
			t.Fatal("test override accepted")
		}
		t.Setenv("SERK_TEST_ROLE_OVERRIDE", "")
	}
	t.Setenv("SERK_ENV", "development")
	if p, e := Open(context.Background(), "postgres://localhost:1/serk", "serk_owner"); e == nil {
		p.Close()
		t.Fatal("owner role accepted")
	}
}
