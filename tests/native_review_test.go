package tests

import (
	"bytes"
	"context"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/pquerna/otp/totp"
	"os"
	"serk.finance/internal/auth"
	"serk.finance/internal/mfa"
	"serk.finance/internal/provisioning"
	"sync"
	"testing"
	"time"
)

func TestNativeMFAReplaySerialization(t *testing.T) {
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		t.Skip("native PostgreSQL required for concurrent MFA counter proof")
	}
	f := setup(t)
	ctx := context.Background()
	secret, _ := mfa.Generate("maker@example.test")
	code, _ := totp.GenerateCode(secret.Secret(), time.Now().Add(-30*time.Second))
	if e := provisioning.EnrollMFA(ctx, f.admin, bytes.Repeat([]byte{42}, 32), provisioning.MFARequest{Tenant: f.slug, Email: "maker@example.test", Secret: secret.Secret(), Code: code, Reason: "Concurrent replay proof"}); e != nil {
		t.Fatal(e)
	}
	var hash, version string
	if e := f.admin.QueryRow(ctx, `SELECT u.password_hash,m.version FROM security.users u JOIN security.user_mfa m ON m.user_id=u.id WHERE u.id=$1`, f.data.Users["maker@example.test"]).Scan(&hash, &version); e != nil {
		t.Fatal(e)
	}
	step := time.Now().Unix() / 30
	start := make(chan struct{})
	results := make(chan error, 8)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			token, _ := auth.Token()
			e := f.adb.Transaction(ctx, func(tx pgx.Tx) error {
				_, e := tx.Exec(ctx, `SELECT security.issue_verified_session($1::uuid,$2,$3,$4,$5::uuid,$6,true)`, f.data.Users["maker@example.test"], auth.Digest(token), f.csrf["maker"], hash, version, step)
				return e
			})
			results <- e
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	success, denied := 0, 0
	for e := range results {
		if e == nil {
			success++
		} else if p, ok := e.(*pgconn.PgError); ok && p.Code == "28000" {
			denied++
		} else {
			t.Fatal(e)
		}
	}
	if success != 1 || denied != 7 {
		t.Fatal("MFA replay admitted", success, denied)
	}
}
func TestNativeCloseSerializesWithCreation(t *testing.T) {
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		t.Skip("native PostgreSQL required for close/create lock proof")
	}
	f := setup(t)
	ctx := context.Background()
	tx, e := f.admin.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(ctx)
	_, e = tx.Exec(ctx, `SELECT security.bind($1,$2::uuid,$3,'{}');SELECT 1 FROM ledger.periods WHERE id=$4::uuid FOR UPDATE`, f.tokens["checker"], f.data.Companies["A"], f.csrf["checker"], f.data.Periods["A:2026-09"])
	if e != nil {
		t.Fatal(e)
	}
	done := make(chan error, 1)
	go func() { _, e := f.cmd("maker", "close-create-race", "create", f.payload); done <- e }()
	waiting := false
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, e = tx.Exec(ctx, `SELECT pg_stat_clear_snapshot()`); e != nil {
			t.Fatal(e)
		}
		if e = tx.QueryRow(ctx, `SELECT EXISTS(SELECT FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%ledger.command%')`).Scan(&waiting); e != nil {
			t.Fatal(e)
		}
		if waiting {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !waiting {
		t.Fatal("creation did not wait for period lock")
	}
	_, e = tx.Exec(ctx, `SELECT ledger.close_period($1::uuid,1,'No unfinished journals before close')`, f.data.Periods["A:2026-09"])
	if e != nil {
		t.Fatal(e)
	}
	if e = tx.Commit(ctx); e != nil {
		t.Fatal(e)
	}
	wantCode(t, <-done, "55000")
	var n int
	if e = f.admin.QueryRow(ctx, `SELECT count(*) FROM ledger.journals WHERE period_id=$1`, f.data.Periods["A:2026-09"]).Scan(&n); e != nil || n != 0 {
		t.Fatal("close stranded concurrent creation", n, e)
	}
}
