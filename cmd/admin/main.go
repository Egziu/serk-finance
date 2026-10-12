// admin is an offline operator command. It is absent from the runtime image.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	"serk.finance/internal/platform/database"
	"serk.finance/internal/provisioning"
)

func run() error {
	var r provisioning.AdminRequest
	d := json.NewDecoder(io.LimitReader(os.Stdin, 16385))
	d.DisallowUnknownFields()
	if err := d.Decode(&r); err != nil {
		return fmt.Errorf("invalid administration JSON")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("expected one JSON object")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, err := database.Operator(ctx)
	if err != nil {
		return err
	}
	defer db.Close(ctx)
	if err = provisioning.Administer(ctx, db, r); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]string{"status": "completed", "action": r.Action})
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "administration_failed:", database.RedactedError(err))
		os.Exit(1)
	}
}
