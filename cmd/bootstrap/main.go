package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"serk.finance/internal/platform/database"
	"serk.finance/internal/provisioning"
	"time"
)

func run() error {
	path := flag.String("file", "", "operator provisioning JSON (contains initial passwords; protect and delete after handover)")
	flag.Parse()
	if *path == "" {
		return fmt.Errorf("--file required")
	}
	f := os.Stdin
	var e error
	if *path != "-" && *path != "/dev/stdin" {
		f, e = os.Open(*path)
		if e != nil {
			return e
		}
		defer f.Close()
	}
	var cfg provisioning.Config
	decoder := json.NewDecoder(io.LimitReader(f, 2<<20))
	decoder.DisallowUnknownFields()
	if e = decoder.Decode(&cfg); e != nil {
		return e
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	if decoder.Decode(new(any)) != io.EOF {
		return fmt.Errorf("expected one provisioning object")
	}
	db, e := database.Operator(ctx)
	if e != nil {
		return e
	}
	defer db.Close(ctx)
	r, e := provisioning.Create(ctx, db, cfg)
	if e != nil {
		return e
	}
	return json.NewEncoder(os.Stdout).Encode(r)
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, database.RedactedError(e))
		os.Exit(1)
	}
}
