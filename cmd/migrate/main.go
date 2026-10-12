// migrate is an operator tool, never served by the financial API.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"regexp"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/platform/database"
	"serk.finance/migrations"
)

func run() error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	db, e := database.Operator(ctx)
	if e != nil {
		return e
	}
	defer db.Close(ctx)
	if _, e = db.Exec(ctx, `SELECT pg_advisory_lock(734920162); CREATE TABLE IF NOT EXISTS public.serk_migrations(name text PRIMARY KEY,sha256 text NOT NULL,applied_at timestamptz NOT NULL DEFAULT now())`); e != nil {
		return e
	}
	defer db.Exec(context.Background(), `SELECT pg_advisory_unlock(734920162)`)
	files, e := migrations.Files.ReadDir(".")
	if e != nil {
		return e
	}
	for _, f := range files {
		if !regexp.MustCompile(`^[0-9]{3}_[a-z0-9_]+\.sql$`).MatchString(f.Name()) {
			return fmt.Errorf("unexpected embedded migration: %s", f.Name())
		}
		data, e := migrations.Files.ReadFile(f.Name())
		if e != nil {
			return e
		}
		h := sha256.Sum256(data)
		sum := hex.EncodeToString(h[:])
		var prior string
		e = db.QueryRow(ctx, `SELECT sha256 FROM public.serk_migrations WHERE name=$1`, f.Name()).Scan(&prior)
		if e == nil {
			if sum != prior {
				return fmt.Errorf("migration checksum mismatch: %s", f.Name())
			}
			fmt.Println("verified", f.Name())
			continue
		}
		if e != pgx.ErrNoRows {
			return e
		}
		tx, e := db.Begin(ctx)
		if e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, string(data)); e == nil {
			_, e = tx.Exec(ctx, `RESET ROLE;`)
		}
		if e == nil {
			_, e = tx.Exec(ctx, `INSERT INTO public.serk_migrations(name,sha256) VALUES($1,$2)`, f.Name(), sum)
		}
		if e != nil {
			tx.Rollback(ctx)
			return fmt.Errorf("migration %s: %w", f.Name(), e)
		}
		if e = tx.Commit(ctx); e != nil {
			return e
		}
		fmt.Println("applied", f.Name(), sum)
	}
	return nil
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, database.RedactedError(e))
		os.Exit(1)
	}
}
