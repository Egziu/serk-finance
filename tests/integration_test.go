package tests

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"serk.finance/internal/auth"
	"serk.finance/internal/platform/database"
	"serk.finance/internal/platform/httpapi"
	"serk.finance/internal/provisioning"
)

type fixture struct {
	admin          *pgx.Conn
	db, adb        *database.Pool
	data, other    provisioning.Result
	tokens, csrf   map[string]string
	handler        http.Handler
	payload        map[string]any
	password, slug string
}

func setup(t *testing.T) *fixture {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		if os.Getenv("CI") == "true" {
			t.Fatal("TEST_DATABASE_URL required in CI")
		}
		t.Skip("integration requires TEST_DATABASE_URL (run make verify)")
	}
	ctx := context.Background()
	cfg, e := pgx.ParseConfig(dsn)
	if e != nil {
		t.Fatal(e)
	}
	cfg.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	a, e := pgx.ConnectConfig(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { a.Close(ctx) })
	apiDSN := os.Getenv("TEST_API_DATABASE_URL")
	authDSN := os.Getenv("TEST_AUTH_DATABASE_URL")
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		apiDSN, authDSN = dsn, dsn
	}
	db, e := database.Open(ctx, apiDSN, "serk_api")
	if e != nil {
		t.Fatal(e)
	}
	ad, e := database.Open(ctx, authDSN, "serk_auth")
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(db.Close)
	t.Cleanup(ad.Close)
	f := &fixture{admin: a, db: db, adb: ad, tokens: map[string]string{}, csrf: map[string]string{}}
	all := []string{"ledger.read", "journal.create", "journal.submit", "journal.approve", "journal.post", "journal.reverse", "journal.void", "period.close", "audit.read"}
	co := provisioning.Company{Code: "A", Name: "Acceptance Company A", Currency: "ETB", Country: "ET", Branches: []string{"HQ", "SECOND"}, YearName: "FY2026", YearStart: "2026-01-01", YearEnd: "2026-12-31", Accounts: []provisioning.Account{{Code: "1000", Name: "Bank", Type: "ASSET", Normal: "DEBIT"}, {Code: "4000", Name: "Revenue", Type: "REVENUE", Normal: "CREDIT"}, {Code: "5000", Name: "Expense", Type: "EXPENSE", Normal: "DEBIT"}, {Code: "1200", Name: "AR control", Type: "ASSET", Normal: "DEBIT", Control: true}}}
	b := co
	b.Code = "B"
	b.Name = "Acceptance Company B"
	nonce, _ := auth.Token()
	slug := "accept-" + strings.ToLower(nonce[:8])
	slug = strings.ReplaceAll(slug, "_", "x")
	c := provisioning.Config{Slug: slug, Name: "Acceptance fixture", Companies: []provisioning.Company{co, b}, Roles: []provisioning.Role{{Name: "all", Permissions: all}, {Name: "reader", Permissions: []string{"ledger.read"}}}}
	limit := "500"
	fixturePassword, _ := auth.Token()
	f.password, f.slug = fixturePassword, slug
	for _, u := range []string{"maker", "checker", "limited", "branch", "reader"} {
		role := "all"
		if u == "reader" {
			role = "reader"
		}
		g := provisioning.Grant{Company: "A", Role: role}
		if u == "limited" {
			g.ApprovalLimit = &limit
		}
		if u == "branch" {
			g.Branch = "SECOND"
		}
		c.Users = append(c.Users, provisioning.User{Email: u + "@example.test", Name: u, Password: fixturePassword, Grants: []provisioning.Grant{g}})
	}
	f.data, e = provisioning.Create(ctx, a, c)
	if e != nil {
		t.Fatal("provision", e)
	}
	c.Slug += "-other"
	c.Companies = []provisioning.Company{co}
	c.Users = c.Users[:1]
	f.other, e = provisioning.Create(ctx, a, c)
	if e != nil {
		t.Fatal(e)
	}
	for email, id := range f.data.Users {
		u := strings.Split(email, "@")[0]
		token, _ := auth.Token()
		csrf, _ := auth.Token()
		f.tokens[u] = token
		f.csrf[u] = csrf
		if _, e = a.Exec(ctx, `SELECT security.issue_session($1::uuid,$2,$3)`, id, auth.Digest(token), csrf); e != nil {
			t.Fatal(e)
		}
	}
	s, e := httpapi.New(db, ad, httpapi.Config{Origin: "http://localhost:8080", SecureCookies: false})
	if e != nil {
		t.Fatal(e)
	}
	f.handler = s.Handler()
	f.payload = map[string]any{"branch_id": f.data.Branches["A:HQ"], "accounting_date": "2026-09-14", "description": "Acceptance opening cash receipt", "currency": "ETB", "fx_rate": "1", "reason": "Acceptance evidence", "lines": []any{map[string]any{"account_id": f.data.Accounts["A:1000"], "debit_minor": "10000", "credit_minor": "0"}, map[string]any{"account_id": f.data.Accounts["A:4000"], "debit_minor": "0", "credit_minor": "10000"}}}
	return f
}

// rate records an exchange rate (functional per one unit of currency) for company A through
// the runtime API role, as a user holding configuration.manage (granted here to "all").
func (f *fixture) rate(t *testing.T, currency, date, rate string) {
	t.Helper()
	ctx := context.Background()
	if _, e := f.admin.Exec(ctx, `INSERT INTO security.role_permissions(tenant_id,role_id,permission)
		SELECT r.tenant_id,r.id,'configuration.manage' FROM security.roles r WHERE r.tenant_id=$1::uuid AND r.name='all' ON CONFLICT DO NOTHING`, f.data.TenantID); e != nil {
		t.Fatal(e)
	}
	if e := f.scope("maker", func(tx pgx.Tx) error {
		_, e := tx.Exec(ctx, `INSERT INTO core.exchange_rates(tenant_id,company_id,date,base_currency,foreign_currency,exchange_rate)
			SELECT tenant_id,id,$1::date,functional_currency,$2,$3::numeric FROM organization.companies WHERE id=(SELECT security.company())`, date, currency, rate)
		return e
	}); e != nil {
		t.Fatal(e)
	}
}
func (f *fixture) scope(user string, fn func(pgx.Tx) error) error {
	return f.db.Scoped(context.Background(), f.tokens[user], f.data.Companies["A"], f.csrf[user], map[string]string{"request_id": "integration"}, fn)
}
func (f *fixture) cmd(user, key, action string, p any) (map[string]any, error) {
	b, _ := json.Marshal(p)
	var raw []byte
	e := f.scope(user, func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT ledger.command($1,$2,$3::jsonb)`, key, action, string(b)).Scan(&raw)
	})
	var result map[string]any
	if e == nil {
		e = json.Unmarshal(raw, &result)
	}
	return result, e
}
func (f *fixture) create(t *testing.T, key string) map[string]any {
	t.Helper()
	j, e := f.cmd("maker", key, "create", f.payload)
	if e != nil {
		t.Fatal(e)
	}
	return j
}
func (f *fixture) move(user, key, action string, j map[string]any) (map[string]any, error) {
	return f.cmd(user, key, action, map[string]any{"id": j["id"], "expected_version": j["version"], "reason": "Reviewed supporting evidence", "accounting_date": "2026-09-15"})
}
func must(t *testing.T, j map[string]any, e error) map[string]any {
	t.Helper()
	if e != nil {
		t.Fatal(e)
	}
	return j
}
func wantCode(t *testing.T, e error, code string) {
	t.Helper()
	p, ok := e.(*pgconn.PgError)
	if !ok || p.Code != code {
		t.Fatalf("wanted SQLSTATE %s, got %v", code, e)
	}
}

func TestFinancialLifecycle(t *testing.T) {
	f := setup(t)
	t.Run("atomic_creation_idempotent_replay", func(t *testing.T) {
		j := f.create(t, "receipt-0001")
		again, e := f.cmd("maker", "receipt-0001", "create", f.payload)
		if e != nil || again["id"] != j["id"] {
			t.Fatal(e)
		}
		bad := map[string]any{"changed": true}
		_, e = f.cmd("maker", "receipt-0001", "create", bad)
		wantCode(t, e, "22000")
	})
	t.Run("reject_unbalanced_at_database", func(t *testing.T) {
		b, _ := json.Marshal(f.payload)
		var p map[string]any
		json.Unmarshal(b, &p)
		p["lines"].([]any)[1].(map[string]any)["credit_minor"] = "9999"
		_, e := f.cmd("maker", "unbalanced-0001", "create", p)
		wantCode(t, e, "23514")
		var count int
		e = f.admin.QueryRow(context.Background(), `SELECT count(*) FROM ledger.idempotency WHERE company_id=$1 AND key='unbalanced-0001'`, f.data.Companies["A"]).Scan(&count)
		if e != nil || count != 0 {
			t.Fatal("partial write", e, count)
		}
	})
	t.Run("reject_fractional_minor_units", func(t *testing.T) {
		b, _ := json.Marshal(f.payload)
		var p map[string]any
		json.Unmarshal(b, &p)
		p["lines"].([]any)[0].(map[string]any)["debit_minor"] = "10000.1"
		_, e := f.cmd("maker", "fractional-001", "create", p)
		wantCode(t, e, "23514")
	})
	t.Run("foreign_currency_snapshot_and_rounding_guard", func(t *testing.T) {
		b, _ := json.Marshal(f.payload)
		var p map[string]any
		json.Unmarshal(b, &p)
		p["currency"] = "USD"
		p["fx_rate"] = "125.75"
		f.rate(t, "USD", "2026-09-13", "125.75")
		j, e := f.cmd("maker", "fx-exact-0001", "create", p)
		if e != nil {
			t.Fatal(e)
		}
		line := j["lines"].([]any)[0].(map[string]any)
		if line["debit_minor"] != "10000" || line["functional_debit_minor"] != "1257500" {
			t.Fatal("lost currency evidence", line)
		}
		p["fx_rate"] = "0.5"
		f.rate(t, "USD", "2026-09-14", "0.5")
		p["lines"] = []any{
			map[string]any{"account_id": f.data.Accounts["A:1000"], "debit_minor": "1", "credit_minor": "0"},
			map[string]any{"account_id": f.data.Accounts["A:1000"], "debit_minor": "1", "credit_minor": "0"},
			map[string]any{"account_id": f.data.Accounts["A:4000"], "debit_minor": "0", "credit_minor": "2"},
		}
		_, e = f.cmd("maker", "fx-rounding-mismatch", "create", p)
		wantCode(t, e, "23514")
	})
	t.Run("manual_control_account_posting_rejected", func(t *testing.T) {
		b, _ := json.Marshal(f.payload)
		var p map[string]any
		json.Unmarshal(b, &p)
		p["lines"].([]any)[0].(map[string]any)["account_id"] = f.data.Accounts["A:1200"]
		_, e := f.cmd("maker", "control-account-01", "create", p)
		wantCode(t, e, "23514")
	})
	t.Run("maker_checker_version_and_approval_ceiling", func(t *testing.T) {
		j := f.create(t, "workflow-0001")
		x, e := f.move("maker", "submit-0001", "submit", j)
		j = must(t, x, e)
		_, e = f.move("maker", "self-approve-1", "approve", j)
		wantCode(t, e, "42501")
		_, e = f.move("limited", "limit-approve-1", "approve", j)
		wantCode(t, e, "42501")
		x, e = f.move("checker", "approve-0001", "approve", j)
		j = must(t, x, e)
		stale := map[string]any{"id": j["id"], "expected_version": 1, "reason": "Stale request"}
		_, e = f.cmd("checker", "stale-post-1", "post", stale)
		wantCode(t, e, "40001")
		x, e = f.move("checker", "post-0001", "post", j)
		j = must(t, x, e)
		if j["state"] != "POSTED" {
			t.Fatal(j)
		}
		t.Run("runtime_no_direct_writes", func(t *testing.T) {
			e := f.scope("maker", func(tx pgx.Tx) error {
				_, e := tx.Exec(context.Background(), `UPDATE ledger.lines SET debit_minor=1 WHERE journal_id=$1`, j["id"])
				return e
			})
			wantCode(t, e, "42501")
		})
		t.Run("owner_trigger_denies_posted_mutation", func(t *testing.T) {
			for _, sql := range []string{`UPDATE ledger.lines SET debit_minor=1 WHERE journal_id=$1`, `DELETE FROM ledger.journals WHERE id=$1`} {
				tx, err := f.admin.Begin(context.Background())
				if err != nil {
					t.Fatal(err)
				}
				_, err = tx.Exec(context.Background(), `SELECT security.bind($1,$2::uuid,$3,'{}'); SET LOCAL ROLE serk_owner`, f.tokens["maker"], f.data.Companies["A"], f.csrf["maker"])
				if err != nil {
					tx.Rollback(context.Background())
					t.Fatal(err)
				}
				_, err = tx.Exec(context.Background(), sql, j["id"])
				tx.Rollback(context.Background())
				wantCode(t, err, "55000")
			}
		})
		t.Run("correction_by_separately_approved_reversal", func(t *testing.T) {
			r, e := f.move("maker", "reverse-0001", "reverse", j)
			r = must(t, r, e)
			if r["reversed_from"] != j["id"] {
				t.Fatal(r)
			}
			_, e = f.move("maker", "reverse-duplicate", "reverse", j)
			wantCode(t, e, "23505")
			x, e = f.move("maker", "reverse-submit", "submit", r)
			r = must(t, x, e)
			x, e = f.move("checker", "reverse-approve", "approve", r)
			r = must(t, x, e)
			x, e = f.move("checker", "reverse-post", "post", r)
			r = must(t, x, e)
			var bal []byte
			e = f.scope("maker", func(tx pgx.Tx) error {
				return tx.QueryRow(context.Background(), `SELECT ledger.trial_balance('2026-09-30')`).Scan(&bal)
			})
			if e != nil {
				t.Fatal(e)
			}
			var tb struct {
				Rows []struct {
					Net string `json:"net_debit_minor"`
				}
			}
			json.Unmarshal(bal, &tb)
			for _, row := range tb.Rows {
				if row.Net != "0" {
					t.Fatal("reversal imbalance", string(bal))
				}
			}
		})
	})
	t.Run("period_close_refuses_to_strand_preapproved_journal", func(t *testing.T) {
		j := f.create(t, "close-draft-1")
		x, e := f.move("maker", "close-submit", "submit", j)
		j = must(t, x, e)
		x, e = f.move("checker", "close-approve", "approve", j)
		j = must(t, x, e)
		e = f.scope("checker", func(tx pgx.Tx) error {
			_, e := tx.Exec(context.Background(), `SELECT ledger.close_period($1::uuid,1,'All ledger balances reviewed')`, f.data.Periods["A:2026-09"])
			return e
		})
		wantCode(t, e, "55000")
		_, e = f.move("checker", "closed-post-1", "post", j)
		if e != nil {
			t.Fatal("blocked close must leave posting possible", e)
		}
	})
	t.Run("audit_chain_and_outbox_atomicity", func(t *testing.T) {
		var invalid int
		e := f.admin.QueryRow(context.Background(), `SELECT count(*) FROM (SELECT sequence_no,previous_hash,event_hash,canonical_payload,lag(event_hash,1,'') OVER(ORDER BY sequence_no) predecessor FROM audit.events WHERE company_id=$1) a WHERE previous_hash<>predecessor OR event_hash<>encode(sha256(convert_to(previous_hash||canonical_payload,'UTF8')),'hex')`, f.data.Companies["A"]).Scan(&invalid)
		if e != nil || invalid != 0 {
			t.Fatal(e, invalid)
		}
		var a, b int
		e = f.admin.QueryRow(context.Background(), `SELECT (SELECT count(*) FROM audit.events WHERE company_id=$1),(SELECT count(*) FROM integration.outbox WHERE company_id=$1)`, f.data.Companies["A"]).Scan(&a, &b)
		if e != nil || a == 0 || a != b {
			t.Fatal(e, a, b)
		}
		_, e = f.admin.Exec(context.Background(), `UPDATE audit.events SET reason='tampered' WHERE company_id=$1`, f.data.Companies["A"])
		wantCode(t, e, "55000")
	})
}

func TestIsolationAndHTTP(t *testing.T) {
	f := setup(t)
	j := f.create(t, "isolation-journal")
	t.Run("other_company_denied", func(t *testing.T) {
		e := f.db.Scoped(context.Background(), f.tokens["maker"], f.data.Companies["B"], "", nil, func(tx pgx.Tx) error { return nil })
		wantCode(t, e, "42501")
	})
	t.Run("other_tenant_denied", func(t *testing.T) {
		e := f.db.Scoped(context.Background(), f.tokens["maker"], f.other.Companies["A"], "", nil, func(tx pgx.Tx) error { return nil })
		wantCode(t, e, "42501")
	})
	t.Run("branch_isolation", func(t *testing.T) {
		e := f.scope("branch", func(tx pgx.Tx) error {
			_, e := tx.Exec(context.Background(), `SELECT ledger.get_journal($1::uuid)`, j["id"])
			return e
		})
		wantCode(t, e, "P0002")
	})
	t.Run("composite_foreign_key", func(t *testing.T) {
		b, _ := json.Marshal(f.payload)
		var p map[string]any
		json.Unmarshal(b, &p)
		p["lines"].([]any)[0].(map[string]any)["account_id"] = f.data.Accounts["B:1000"]
		_, e := f.cmd("maker", "bad-company-account", "create", p)
		wantCode(t, e, "23503")
	})
	t.Run("role_cannot_mint_session", func(t *testing.T) {
		e := f.scope("maker", func(tx pgx.Tx) error {
			_, e := tx.Exec(context.Background(), `SELECT security.issue_session($1::uuid,$2,$3)`, f.data.Users["checker@example.test"], strings.Repeat("0", 64), "fake")
			return e
		})
		wantCode(t, e, "42501")
	})
	t.Run("forged_context_denied", func(t *testing.T) {
		e := f.scope("maker", func(tx pgx.Tx) error {
			_, e := tx.Exec(context.Background(), `SELECT set_config('serk.token_hash',$1,true);SELECT ledger.get_journal($2::uuid)`, strings.Repeat("0", 64), j["id"])
			return e
		})
		if e == nil {
			t.Fatal("forged context accepted")
		}
	})
	t.Run("session_context_resets", func(t *testing.T) {
		e := f.db.Transaction(context.Background(), func(tx pgx.Tx) error {
			var a *string
			if e := tx.QueryRow(context.Background(), `SELECT security.actor()::text`).Scan(&a); e != nil {
				return e
			}
			if a != nil {
				return fmt.Errorf("identity leaked across transactions")
			}
			return nil
		})
		if e != nil {
			t.Fatal(e)
		}
	})
	for _, test := range []struct {
		name, method, path, company, user, origin, csrf string
		body                                            any
		status                                          int
	}{
		{"unauthenticated", "GET", "/api/v1/accounting/reference", "A", "", "", "", nil, 401},
		{"read_reference", "GET", "/api/v1/accounting/reference", "A", "maker", "", "", nil, 200},
		{"csrf_origin", "POST", "/api/v1/accounting/journals", "A", "maker", "https://evil.test", "maker", f.payload, 403},
		{"missing_csrf", "POST", "/api/v1/accounting/journals", "A", "maker", "http://localhost:8080", "", f.payload, 403},
		{"read_only_role", "POST", "/api/v1/accounting/journals", "A", "reader", "http://localhost:8080", "reader", f.payload, 403},
		{"post_success", "POST", "/api/v1/accounting/journals", "A", "maker", "http://localhost:8080", "maker", f.payload, 201},
		{"cross_company_http", "GET", "/api/v1/accounting/reference", "B", "maker", "", "", nil, 403},
		{"unknown_json_field", "POST", "/api/v1/accounting/journals", "A", "maker", "http://localhost:8080", "maker", map[string]any{"hacked": true}, 400},
		{"injection_in_uuid", "GET", "/api/v1/accounting/journals/1%27%20OR%201=1--", "A", "maker", "", "", nil, 400},
		{"pagination_bound", "GET", "/api/v1/accounting/journals?limit=999999", "A", "maker", "", "", nil, 400},
	} {
		t.Run(test.name, func(t *testing.T) {
			b, _ := json.Marshal(test.body)
			req := httptest.NewRequest(test.method, "http://localhost:8080"+test.path, bytes.NewReader(b))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("X-Company-ID", f.data.Companies[test.company])
			req.Header.Set("Origin", test.origin)
			req.Header.Set("X-CSRF-Token", f.csrf[test.csrf])
			req.Header.Set("Idempotency-Key", "http-"+test.name)
			if test.user != "" {
				req.AddCookie(&http.Cookie{Name: "serk_session", Value: f.tokens[test.user]})
			}
			rr := httptest.NewRecorder()
			f.handler.ServeHTTP(rr, req)
			if rr.Code != test.status {
				t.Fatalf("expected %d got %d %s", test.status, rr.Code, rr.Body.String())
			}
			if rr.Header().Get("Cache-Control") != "no-store" || rr.Header().Get("X-Content-Type-Options") != "nosniff" {
				t.Fatal("missing security headers")
			}
		})
	}
	t.Run("session_revocation", func(t *testing.T) {
		_, e := f.admin.Exec(context.Background(), `SELECT security.revoke_session($1)`, f.tokens["maker"])
		if e != nil {
			t.Fatal(e)
		}
		e = f.scope("maker", func(tx pgx.Tx) error { return nil })
		wantCode(t, e, "28000")
	})
}

func TestNativeConcurrentIdempotency(t *testing.T) {
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		t.Skip("PGlite multiplexes one connection: native PostgreSQL required for concurrency proof")
	}
	f := setup(t)
	var wg sync.WaitGroup
	results := make(chan string, 16)
	errs := make(chan error, 16)
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			j, e := f.cmd("maker", "concurrent-0001", "create", f.payload)
			if e != nil {
				errs <- e
				return
			}
			results <- j["id"].(string)
		}()
	}
	wg.Wait()
	close(results)
	close(errs)
	for e := range errs {
		t.Fatal(e)
	}
	id := ""
	n := 0
	for got := range results {
		n++
		if id == "" {
			id = got
		}
		if got != id {
			t.Fatal("duplicate financial transaction")
		}
	}
	if n != 16 {
		t.Fatal(n)
	}
	var count int
	if e := f.admin.QueryRow(context.Background(), `SELECT count(*) FROM ledger.journals WHERE company_id=$1`, f.data.Companies["A"]).Scan(&count); e != nil || count != 1 {
		t.Fatal(e, count)
	}
}

func TestNativeConcurrentPosting(t *testing.T) {
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		t.Skip("native PostgreSQL required for posting race proof")
	}
	f := setup(t)
	j := f.create(t, "race-post-create")
	x, e := f.move("maker", "race-post-submit", "submit", j)
	j = must(t, x, e)
	x, e = f.move("checker", "race-post-approve", "approve", j)
	j = must(t, x, e)
	results := make(chan error, 2)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			_, e := f.move("checker", fmt.Sprintf("race-post-%d", n), "post", j)
			results <- e
		}(i)
	}
	wg.Wait()
	close(results)
	success, conflict := 0, 0
	for e := range results {
		if e == nil {
			success++
		} else {
			wantCode(t, e, "40001")
			conflict++
		}
	}
	if success != 1 || conflict != 1 {
		t.Fatal("invalid concurrent outcome", success, conflict)
	}
}

func TestNativeCloseSerializesWithPosting(t *testing.T) {
	if os.Getenv("SERK_TEST_ROLE_OVERRIDE") == "1" {
		t.Skip("native PostgreSQL required for close/post lock proof")
	}
	f := setup(t)
	j := f.create(t, "race-close-create")
	x, e := f.move("maker", "race-close-submit", "submit", j)
	j = must(t, x, e)
	x, e = f.move("checker", "race-close-approve", "approve", j)
	j = must(t, x, e)
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
	go func() { _, e := f.move("checker", "race-close-post", "post", j); done <- e }()
	// Verify the posting transaction is waiting on an actual PostgreSQL lock.
	deadline := time.Now().Add(3 * time.Second)
	waiting := false
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
		t.Fatal("posting did not wait on period lock")
	}
	_, e = tx.Exec(ctx, `SELECT ledger.close_period($1::uuid,1,'Concurrent close acceptance evidence')`, f.data.Periods["A:2026-09"])
	wantCode(t, e, "55000")
	if e = tx.Rollback(ctx); e != nil {
		t.Fatal(e)
	}
	if e = <-done; e != nil {
		t.Fatal("posting failed after refused close", e)
	}
	e = f.scope("checker", func(tx pgx.Tx) error {
		_, e := tx.Exec(ctx, `SELECT ledger.close_period($1::uuid,1,'All journals now finished')`, f.data.Periods["A:2026-09"])
		return e
	})
	if e != nil {
		t.Fatal("close after posting failed", e)
	}
}
