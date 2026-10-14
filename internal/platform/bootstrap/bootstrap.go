// Package bootstrap prepares a database for the API: it applies the embedded migrations and
// creates or updates the two unprivileged runtime logins. The managed-platform launcher
// (cmd/platform) and the office installer (cmd/serk-server) both use it.
package bootstrap

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/platform/database"
	"serk.finance/migrations"
)

// Logins are the runtime credentials the API connects with.
type Logins struct{ API, Auth string }

// Validate requires two distinct passwords of at least 24 characters.
func (l Logins) Validate() error {
	if len(l.API) < 24 || len(l.Auth) < 24 || l.API == l.Auth {
		return errors.New("runtime passwords must be distinct and at least 24 characters")
	}
	return nil
}

// Prepare migrates the database over the operator connection and sets up the runtime logins.
func Prepare(ctx context.Context, db *pgx.Conn, l Logins, log io.Writer) error {
	if e := l.Validate(); e != nil {
		return e
	}
	if e := database.Migrate(ctx, db, migrations.Files, log); e != nil {
		return e
	}
	for _, r := range []struct{ login, role, pass string }{{"serk_api_login", "serk_api", l.API}, {"serk_auth_login", "serk_auth", l.Auth}} {
		var sql string
		if e := db.QueryRow(ctx, `SELECT CASE WHEN EXISTS(SELECT FROM pg_roles WHERE rolname=$1)
			THEN format('ALTER ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L',$1,$3)
			ELSE format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS IN ROLE %I PASSWORD %L',$1,$2,$3) END`,
			r.login, r.role, r.pass).Scan(&sql); e != nil {
			return e
		}
		if _, e := db.Exec(ctx, sql); e != nil {
			return fmt.Errorf("runtime role %s: %s", r.login, database.RedactedError(e))
		}
		if _, e := db.Exec(ctx, fmt.Sprintf(`GRANT %s TO %s`, pgx.Identifier{r.role}.Sanitize(), pgx.Identifier{r.login}.Sanitize())); e != nil {
			return e
		}
	}
	return nil
}

// RuntimeURLs derives the API and authentication connection URLs from the operator URL.
func RuntimeURLs(operator string, l Logins) (api, auth string, err error) {
	u, e := url.Parse(operator)
	if e != nil || u.Host == "" {
		return "", "", errors.New("invalid operator URL")
	}
	u.User = url.UserPassword("serk_api_login", l.API)
	api = u.String()
	u.User = url.UserPassword("serk_auth_login", l.Auth)
	return api, u.String(), nil
}
