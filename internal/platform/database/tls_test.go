package database

import (
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func TestOfficeAllowsOnlyLoopbackWithoutTLS(t *testing.T) {
	for host, ok := range map[string]bool{"127.0.0.1": true, "localhost": true, "::1": true, "192.168.1.5": false, "db.example.com": false} {
		c, e := pgconn.ParseConfig("postgres://u:p@" + map[bool]string{true: "[" + host + "]", false: host}[host == "::1"] + ":5432/d?sslmode=disable")
		if e != nil {
			t.Fatal(e)
		}
		if got := RequireTLS("office", c) == nil; got != ok {
			t.Errorf("%s: got %v", host, got)
		}
		if RequireTLS("production", c) == nil {
			t.Errorf("%s: production without TLS accepted", host)
		}
	}
}
