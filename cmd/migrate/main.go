// migrate is an operator tool, never served by the financial API.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

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
	return database.Migrate(ctx, db, migrations.Files, os.Stdout)
}

func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, database.RedactedError(e))
		os.Exit(1)
	}
}
