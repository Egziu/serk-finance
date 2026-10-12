// configure applies offline company configuration using operator credentials.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"serk.finance/internal/platform/database"
	"time"
)

func run() error {
	var r struct {
		Company string `json:"company_id"`
		Account string `json:"account_id"`
		Max     int    `json:"max_difference_minor"`
		Reason  string `json:"reason"`
	}
	d := json.NewDecoder(io.LimitReader(os.Stdin, 16385))
	d.DisallowUnknownFields()
	if e := d.Decode(&r); e != nil {
		return errors.New("invalid configuration JSON")
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("expected one JSON object")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, e := database.Operator(ctx)
	if e != nil {
		return e
	}
	defer db.Close(ctx)
	_, e = db.Exec(ctx, `SELECT ledger.configure_fx_rounding($1::uuid,$2::uuid,$3,$4)`, r.Company, r.Account, r.Max, r.Reason)
	return e
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, "configuration_failed:", database.RedactedError(e))
		os.Exit(1)
	}
	fmt.Println(`{"status":"configured"}`)
}
