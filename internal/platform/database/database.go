package database

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"serk.finance/internal/platform/config"
)

type Pool struct {
	*pgxpool.Pool
	TestRole string
}

func Open(ctx context.Context, dsn, role string) (*Pool, error) {
	environment, e := config.Environment()
	if e != nil {
		return nil, e
	}
	if role != "serk_api" && role != "serk_auth" {
		return nil, errors.New("invalid runtime role")
	}
	if dsn == "" {
		return nil, errors.New("database configuration required")
	}
	c, e := pgxpool.ParseConfig(dsn)
	if e != nil {
		return nil, errors.New("invalid database configuration")
	}
	c.MaxConns = 10
	c.MinConns = 0
	c.MaxConnLifetime = 30 * time.Minute
	c.ConnConfig.ConnectTimeout = 5 * time.Second
	c.ConnConfig.RuntimeParams["statement_timeout"] = "10000"
	c.ConnConfig.RuntimeParams["lock_timeout"] = "5000"
	c.ConnConfig.RuntimeParams["idle_in_transaction_session_timeout"] = "15000"
	testRole := ""
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		if environment != "development" {
			return nil, errors.New("test role override forbidden outside development")
		}
		if role != "serk_api" && role != "serk_auth" {
			return nil, errors.New("invalid test role")
		}
		testRole = role
		c.MaxConns = 1
		c.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	}
	if e := RequireTLS(environment, &c.ConnConfig.Config); e != nil {
		return nil, e
	}
	p, e := pgxpool.NewWithConfig(ctx, c)
	if e != nil {
		return nil, e
	}
	if e = p.Ping(ctx); e != nil {
		p.Close()
		return nil, e
	}
	result := &Pool{p, testRole}
	if testRole == "" {
		var unsafe bool
		opposite := "serk_auth"
		if role == "serk_auth" {
			opposite = "serk_api"
		}
		e = p.QueryRow(ctx, `SELECT rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb OR rolreplication
		 OR pg_has_role(current_user,'serk_owner','MEMBER')
		 OR NOT pg_has_role(current_user,$1,'USAGE') OR pg_has_role(current_user,$2,'MEMBER')
		 OR has_schema_privilege(current_user,'public','CREATE')
   OR pg_has_role(current_user,'pg_database_owner','USAGE')
   OR EXISTS(SELECT FROM pg_roles dangerous WHERE dangerous.rolname IN
    ('pg_read_all_data','pg_write_all_data','pg_read_server_files','pg_write_server_files','pg_execute_server_program','pg_signal_backend')
    AND pg_has_role(current_user,dangerous.oid,'MEMBER'))
		 FROM pg_roles WHERE rolname=current_user`, role, opposite).Scan(&unsafe)
		if e != nil || unsafe {
			p.Close()
			return nil, errors.New("runtime database identity must be an unprivileged non-owner")
		}
	}
	var version string
	e = result.Transaction(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT security.release_version()`).Scan(&version)
	})
	if e != nil || version != ReleaseVersion {
		p.Close()
		return nil, errors.New("database migration version does not match this release")
	}
	return result, nil
}

// ReleaseVersion is the schema marker this binary requires (security.release_version()).
const ReleaseVersion = "0.4.0-rc1"

func (p *Pool) Transaction(ctx context.Context, fn func(pgx.Tx) error) error {
	tx, e := p.BeginTx(ctx, pgx.TxOptions{})
	if e != nil {
		return e
	}
	defer tx.Rollback(context.WithoutCancel(ctx))
	if p.TestRole != "" {
		if _, e = tx.Exec(ctx, "SET LOCAL ROLE "+p.TestRole); e != nil {
			return e
		}
	}
	if e = fn(tx); e != nil {
		return e
	}
	return tx.Commit(ctx)
}
func (p *Pool) Scoped(ctx context.Context, token, company, csrf string, meta map[string]string, fn func(pgx.Tx) error) error {
	return p.Transaction(ctx, func(tx pgx.Tx) error {
		var csrfArg any
		if csrf != "" {
			csrfArg = csrf
		}
		b, _ := json.Marshal(meta)
		_, e := tx.Exec(ctx, `SELECT security.bind($1,$2::uuid,$3,$4::jsonb)`, token, company, csrfArg, string(b))
		if e != nil {
			return e
		}
		return fn(tx)
	})
}

// RedactedError is appropriate for operational logs, which must not contain DSNs or SQL parameters.
func RedactedError(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	if strings.Contains(s, "password") || strings.Contains(s, "postgres://") {
		return "database_error"
	}
	return s
}
