package tests

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestNativeDimensionChangeSerializesWithPosting(t *testing.T) {
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		t.Skip("native PostgreSQL required for dimension/posting lock proof")
	}
	f := setup(t)
	ctx := context.Background()
	var dimension string
	err := f.admin.QueryRow(ctx, `INSERT INTO ledger.dimensions(tenant_id,company_id,kind,code,name) VALUES($1,$2,'PROJECT','RACE','Native race fixture') RETURNING id`, f.data.TenantID, f.data.Companies["A"]).Scan(&dimension)
	if err != nil {
		t.Fatal(err)
	}
	f.payload["lines"].([]any)[0].(map[string]any)["dimensions"] = []any{map[string]any{"kind": "PROJECT", "dimension_id": dimension}}
	j := f.create(t, "dimension-race-create")
	for _, action := range []string{"submit", "approve"} {
		user := "checker"
		if action == "submit" {
			user = "maker"
		}
		next, e := f.move(user, "dimension-race-"+action, action, j)
		j = must(t, next, e)
	}
	tx, err := f.admin.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `UPDATE ledger.dimensions SET active=false WHERE id=$1`, dimension); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, e := f.move("checker", "dimension-race-post", "post", j); done <- e }()
	deadline := time.Now().Add(3 * time.Second)
	waiting := false
	for time.Now().Before(deadline) {
		if _, err = tx.Exec(ctx, `SELECT pg_stat_clear_snapshot()`); err != nil {
			t.Fatal(err)
		}
		if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE '%ledger.command%')`).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !waiting {
		t.Fatal("posting did not wait for dimension update")
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	wantCode(t, <-done, "23514")
	var state string
	if err = f.admin.QueryRow(ctx, `SELECT state FROM ledger.journals WHERE id=$1`, j["id"]).Scan(&state); err != nil || state != "APPROVED" {
		t.Fatal(state, err)
	}
}

func TestNativeChartCycleSnapshotConflict(t *testing.T) {
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		t.Skip("native PostgreSQL required for chart snapshot write-skew proof")
	}
	f := setup(t)
	ctx := context.Background()
	var a, b string
	for _, item := range []struct {
		code string
		id   *string
	}{{"GROUP-A", &a}, {"GROUP-B", &b}} {
		if e := f.admin.QueryRow(ctx, `INSERT INTO ledger.accounts(tenant_id,company_id,code,name,type,normal_balance,reporting_category,posting_allowed) VALUES($1,$2,$3,$3,'ASSET','DEBIT','ASSET',false) RETURNING id`, f.data.TenantID, f.data.Companies["A"], item.code).Scan(item.id); e != nil {
			t.Fatal(e)
		}
	}
	other, e := pgx.Connect(ctx, os.Getenv("TEST_DATABASE_URL"))
	if e != nil {
		t.Fatal(e)
	}
	defer other.Close(ctx)
	tx1, e := f.admin.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if e != nil {
		t.Fatal(e)
	}
	defer tx1.Rollback(ctx)
	tx2, e := other.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if e != nil {
		t.Fatal(e)
	}
	defer tx2.Rollback(ctx)
	// Establish both snapshots before the first committed graph write.
	if _, e = tx2.Exec(ctx, `SELECT revision FROM ledger.account_tree_versions WHERE company_id=$1`, f.data.Companies["A"]); e != nil {
		t.Fatal(e)
	}
	if _, e = tx1.Exec(ctx, `UPDATE ledger.accounts SET parent_id=$1 WHERE id=$2`, b, a); e != nil {
		t.Fatal(e)
	}
	if e = tx1.Commit(ctx); e != nil {
		t.Fatal(e)
	}
	_, e = tx2.Exec(ctx, `UPDATE ledger.accounts SET parent_id=$1 WHERE id=$2`, a, b)
	wantCode(t, e, "40001")
}
