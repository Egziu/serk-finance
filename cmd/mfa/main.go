// MFA enrollment is offline and operator-only; never served by the API.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"serk.finance/internal/mfa"
	"serk.finance/internal/platform/config"
	"serk.finance/internal/platform/database"
	"serk.finance/internal/provisioning"
	"time"
)

func run() error {
	prepare := flag.String("prepare", "", "Generate a new secret/otpauth URI for this account (sensitive output)")
	flag.Parse()
	if *prepare != "" {
		key, e := mfa.Generate(*prepare)
		if e != nil {
			return e
		}
		return json.NewEncoder(os.Stdout).Encode(map[string]string{"secret": key.Secret(), "otpauth_uri": key.URL()})
	}
	var r provisioning.MFARequest
	d := json.NewDecoder(io.LimitReader(os.Stdin, 16385))
	d.DisallowUnknownFields()
	if d.Decode(&r) != nil || d.Decode(new(any)) != io.EOF {
		return errors.New("invalid enrollment JSON")
	}
	raw, e := config.Secret("SERK_MFA_KEY")
	if e != nil {
		return e
	}
	key, e := mfa.ParseKey(raw)
	if e != nil {
		return e
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, e := database.Operator(ctx)
	if e != nil {
		return e
	}
	defer db.Close(ctx)
	if e = provisioning.EnrollMFA(ctx, db, key, r); e != nil {
		return e
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]string{"status": "enrolled", "next": "Wait for the next authenticator code before signing in."})
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, "mfa_enrollment_failed:", database.RedactedError(e))
		os.Exit(1)
	}
}
