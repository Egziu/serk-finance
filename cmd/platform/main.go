// platform is the single-container entry point for managed platforms such as Railway.
//
// On every start it, in order:
//  1. applies the embedded migrations with the operator (owner) connection;
//  2. creates or updates the two unprivileged runtime logins (serk_api_login, serk_auth_login);
//  3. optionally provisions the Ethiopian accountant test workspace (SERK_DEMO_SEED=ethiopia),
//     only when it does not exist yet;
//  4. starts the API using the unprivileged runtime logins — never the operator connection.
//
// Required environment:
//
//	OPERATOR_DATABASE_URL  owner/superuser URL (Railway: ${{Postgres.DATABASE_URL}} + ?sslmode=disable on the private network)
//	SERK_API_PASSWORD, SERK_AUTH_PASSWORD   runtime login passwords (24+ random characters, kept stable)
//	SERK_ENV               staging or production
//	SERK_ORIGIN            https://<public domain>  (defaults to https://$RAILWAY_PUBLIC_DOMAIN)
//	SERK_MFA_KEY           32-byte base64 key that encrypts authenticator secrets (keep stable)
//
// Optional: SERK_DEMO_SEED=ethiopia with SERK_DEMO_PASSWORD; PORT (default 8080).
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"

	"serk.finance/internal/demo"
	"serk.finance/internal/platform/bootstrap"
	"serk.finance/internal/platform/config"
	"serk.finance/internal/platform/database"
	"serk.finance/internal/platform/httpapi"
)

func prepare(ctx context.Context) error {
	operator, e := config.Secret("OPERATOR_DATABASE_URL")
	if e != nil {
		return e
	}
	apiPass, e := config.Secret("SERK_API_PASSWORD")
	if e != nil {
		return e
	}
	authPass, e := config.Secret("SERK_AUTH_PASSWORD")
	if e != nil {
		return e
	}
	logins := bootstrap.Logins{API: apiPass, Auth: authPass}
	if e = logins.Validate(); e != nil {
		return e
	}
	os.Setenv("MIGRATOR_DATABASE_URL", operator)
	db, e := database.Operator(ctx)
	if e != nil {
		return fmt.Errorf("operator connection: %w", e)
	}
	defer db.Close(ctx)
	if e = bootstrap.Prepare(ctx, db, logins, os.Stdout); e != nil {
		return e
	}
	if os.Getenv("SERK_DEMO_SEED") == "ethiopia" {
		pass, e := config.Secret("SERK_DEMO_PASSWORD")
		if e != nil {
			return e
		}
		exists, e := demo.Exists(ctx, db)
		if e != nil {
			return e
		}
		if !exists {
			if e = demo.Seed(ctx, db, pass, time.Now().UTC()); e != nil {
				return fmt.Errorf("demo seed: %w", e)
			}
			slog.Info("demo_workspace_created", "workspace", demo.Slug, "users", len(demo.Users))
		} else if e = demo.Upgrade(ctx, db); e != nil {
			return fmt.Errorf("demo upgrade: %w", e)
		}
	}
	// The API connects with the unprivileged logins only.
	apiURL, authURL, e := bootstrap.RuntimeURLs(operator, logins)
	if e != nil {
		return e
	}
	os.Setenv("DATABASE_URL", apiURL)
	os.Setenv("AUTH_DATABASE_URL", authURL)
	os.Unsetenv("OPERATOR_DATABASE_URL")
	os.Unsetenv("MIGRATOR_DATABASE_URL")
	if os.Getenv("SERK_ORIGIN") == "" && os.Getenv("RAILWAY_PUBLIC_DOMAIN") != "" {
		os.Setenv("SERK_ORIGIN", "https://"+os.Getenv("RAILWAY_PUBLIC_DOMAIN"))
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	os.Setenv("SERK_LISTEN", "0.0.0.0:"+port)
	return nil
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	e := prepare(ctx)
	cancel()
	if e != nil {
		slog.Error("platform_prepare_failed", "error", database.RedactedError(e))
		os.Exit(1)
	}
	if e = httpapi.Run(); e != nil {
		var detail *httpapi.StartupError
		if errors.As(e, &detail) {
			slog.Error("startup_failed", "stage", detail.Stage, "code", detail.Code)
		} else {
			slog.Error("startup_failed", "code", "unexpected_startup_failure")
		}
		os.Exit(1)
	}
}
