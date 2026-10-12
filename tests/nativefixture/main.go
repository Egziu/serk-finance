// Disposable test-cluster provisioning only; never imported by the API.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

func main() {
	if os.Getenv("SERK_DISPOSABLE_TEST_CLUSTER") != "1" || os.Getenv("SERK_ENV") != "development" {
		panic("disposable development cluster required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	db, err := pgx.Connect(ctx, os.Getenv("MIGRATOR_DATABASE_URL"))
	if err != nil {
		panic("test database unavailable")
	}
	defer db.Close(ctx)
	for _, r := range []struct{ name, base, key string }{{"serk_api_login", "serk_api", "SERK_API_PASSWORD"}, {"serk_auth_login", "serk_auth", "SERK_AUTH_PASSWORD"}} {
		password := os.Getenv(r.key)
		if len(password) < 32 {
			panic("test password required")
		}
		var sql string
		if err = db.QueryRow(ctx, `SELECT format('CREATE ROLE %I LOGIN IN ROLE %I PASSWORD %L',$1::text,$2::text,$3::text)`, r.name, r.base, password).Scan(&sql); err != nil {
			panic("role formatting failed")
		}
		if _, err = db.Exec(ctx, sql); err != nil {
			panic("test role creation failed")
		}
	}
	fmt.Println("PASS: distinct unprivileged API/authentication logins created in disposable test cluster")
}
