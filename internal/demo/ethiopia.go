// Package demo provisions an Ethiopian test workspace for accountant acceptance testing.
// It is operator-only (never imported by the API) and idempotent: it does nothing when the
// workspace already exists. All names are fictional; statutory figures are samples that a
// qualified Ethiopian accountant must confirm before any real use.
package demo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/auth"
	"serk.finance/internal/provisioning"
)

const Slug = "demo"

// Users of the demo workspace and the role each one holds.
var Users = []struct{ Email, Name, Role string }{
	{"admin@serk.demo", "Administrator", "Administrator"},
	{"chief.accountant@serk.demo", "Chief Accountant", "Chief Accountant"},
	{"accountant@serk.demo", "Accountant", "Accountant"},
	{"manager@serk.demo", "Finance Manager", "Finance Manager"},
	{"payroll@serk.demo", "Payroll Officer", "Payroll Officer"},
	{"sales@serk.demo", "Sales Clerk", "Sales Clerk"},
	{"auditor@serk.demo", "Auditor", "Auditor (read only)"},
}

var roles = map[string][]string{
	"Chief Accountant": {"ledger.read", "journal.create", "journal.submit", "journal.approve", "journal.post", "journal.reverse", "journal.void", "period.close", "audit.read", "configuration.manage",
		"sales.read", "sales.manage", "purchases.read", "purchases.manage", "inventory.read", "inventory.manage", "payroll.read", "payroll.manage", "taxes.read", "taxes.manage", "ai.use"},
	"Accountant": {"ledger.read", "journal.create", "journal.submit", "journal.void", "audit.read",
		"sales.read", "sales.manage", "purchases.read", "purchases.manage", "inventory.read", "inventory.manage", "taxes.read", "taxes.manage", "ai.use"},
	"Finance Manager": {"ledger.read", "journal.approve", "journal.post", "journal.reverse", "journal.void", "period.close", "audit.read",
		"sales.read", "sales.manage", "purchases.read", "purchases.manage", "inventory.read", "inventory.manage", "payroll.read", "payroll.manage", "taxes.read", "taxes.manage", "ai.use"},
	"Payroll Officer":     {"ledger.read", "journal.create", "journal.submit", "journal.void", "payroll.read", "payroll.manage", "ai.use"},
	"Sales Clerk":         {"ledger.read", "journal.create", "journal.submit", "journal.void", "sales.read", "sales.manage", "inventory.read", "ai.use"},
	"Auditor (read only)": {"ledger.read", "audit.read", "sales.read", "purchases.read", "inventory.read", "payroll.read", "taxes.read", "ai.use"},
}

func account(code, name, typ, normal string, opts ...string) provisioning.Account {
	a := provisioning.Account{Code: code, Name: name, Type: typ, Normal: normal}
	for _, o := range opts {
		switch o {
		case "control":
			a.Control = true
		case "noncurrent":
			a.Class = "NON_CURRENT"
		default:
			a.Category = o
		}
	}
	return a
}

// Chart of accounts for an Ethiopian trading SME (IFRS for SMEs presentation).
var chart = []provisioning.Account{
	account("1000", "Cash on hand", "ASSET", "DEBIT", "Cash and cash equivalents"),
	account("1010", "Commercial Bank of Ethiopia — current", "ASSET", "DEBIT", "Cash and cash equivalents"),
	account("1020", "Bank — USD account", "ASSET", "DEBIT", "Cash and cash equivalents"),
	account("1100", "Trade receivables", "ASSET", "DEBIT", "Trade and other receivables"),
	account("1150", "Withholding tax receivable", "ASSET", "DEBIT", "Trade and other receivables"),
	account("1200", "Inventory — merchandise", "ASSET", "DEBIT", "Inventories"),
	account("1300", "Input VAT recoverable", "ASSET", "DEBIT", "Trade and other receivables"),
	account("1400", "Prepayments", "ASSET", "DEBIT", "Trade and other receivables"),
	account("1500", "Property, plant and equipment — cost", "ASSET", "DEBIT", "noncurrent", "Property, plant and equipment"),
	account("1590", "Accumulated depreciation", "ASSET", "CREDIT", "noncurrent", "Property, plant and equipment"),
	account("2000", "Trade payables", "LIABILITY", "CREDIT", "Trade and other payables"),
	account("2100", "Salaries payable", "LIABILITY", "CREDIT", "Trade and other payables"),
	account("2110", "Employment income tax (PAYE) payable", "LIABILITY", "CREDIT", "Current tax liabilities"),
	account("2120", "Pension contributions payable", "LIABILITY", "CREDIT", "Trade and other payables"),
	account("2200", "Output VAT payable", "LIABILITY", "CREDIT", "Current tax liabilities"),
	account("2210", "Withholding tax payable", "LIABILITY", "CREDIT", "Current tax liabilities"),
	account("2300", "Accrued expenses", "LIABILITY", "CREDIT", "Trade and other payables"),
	account("2500", "Bank loan — long term", "LIABILITY", "CREDIT", "noncurrent", "Borrowings"),
	account("3000", "Share capital", "EQUITY", "CREDIT", "Share capital"),
	account("3100", "Retained earnings", "EQUITY", "CREDIT", "Retained earnings"),
	account("3200", "Legal reserve", "EQUITY", "CREDIT", "Reserves"),
	account("3900", "Opening balance equity", "EQUITY", "CREDIT", "Retained earnings"),
	account("4000", "Sales of goods", "REVENUE", "CREDIT", "Revenue"),
	account("4100", "Service revenue", "REVENUE", "CREDIT", "Revenue"),
	account("4900", "Other income", "OTHER_INCOME", "CREDIT", "Other income"),
	account("5000", "Cost of goods sold", "COST_OF_SALES", "DEBIT", "Cost of sales"),
	account("6000", "Salaries and wages", "EXPENSE", "DEBIT", "Employee benefits"),
	account("6010", "Employer pension contribution", "EXPENSE", "DEBIT", "Employee benefits"),
	account("6100", "Rent", "EXPENSE", "DEBIT", "Administrative expenses"),
	account("6200", "Utilities", "EXPENSE", "DEBIT", "Administrative expenses"),
	account("6300", "Transport and fuel", "EXPENSE", "DEBIT", "Distribution costs"),
	account("6400", "Depreciation", "EXPENSE", "DEBIT", "Administrative expenses"),
	account("6500", "Impairment of receivables", "EXPENSE", "DEBIT", "Administrative expenses"),
	account("6600", "Inventory write-down", "COST_OF_SALES", "DEBIT", "Cost of sales"),
	account("6900", "Bank charges", "EXPENSE", "DEBIT", "Finance costs"),
	account("7000", "Foreign exchange differences", "OTHER_EXPENSE", "DEBIT", "Other expenses"),
	account("8000", "Income tax expense", "EXPENSE", "DEBIT", "Income tax"),
}

// Upgrade brings an existing demo workspace up to the current release: every demo role may use
// the AI assistant (0.4.0). It is idempotent.
func Upgrade(ctx context.Context, db *pgx.Conn) error {
	_, e := db.Exec(ctx, `INSERT INTO security.role_permissions(tenant_id,role_id,permission)
		SELECT r.tenant_id,r.id,'ai.use' FROM security.roles r JOIN security.tenants t ON t.id=r.tenant_id WHERE t.slug=$1
		ON CONFLICT DO NOTHING`, Slug)
	return e
}

// Exists reports whether the demo workspace has been provisioned.
func Exists(ctx context.Context, db *pgx.Conn) (bool, error) {
	var n int
	e := db.QueryRow(ctx, `SELECT count(*) FROM security.tenants WHERE slug=$1`, Slug).Scan(&n)
	return n > 0, e
}

// Seed creates the demo workspace, configuration, master data and a few posted sample
// transactions through the same database commands the API uses (maker-checker included).
func Seed(ctx context.Context, db *pgx.Conn, password string, today time.Time) error {
	if ok, e := Exists(ctx, db); e != nil || ok {
		return e
	}
	if len(password) < 14 {
		return errors.New("demo password must be at least 14 characters")
	}
	all := []string{}
	rows, e := db.Query(ctx, `SELECT code FROM security.permissions ORDER BY code`)
	if e != nil {
		return e
	}
	for rows.Next() {
		var c string
		if e = rows.Scan(&c); e != nil {
			return e
		}
		all = append(all, c)
	}
	rows.Close()
	cfg := provisioning.Config{Slug: Slug, Name: "Serk Finance accountant test workspace",
		Companies: []provisioning.Company{{Code: "DEMO", Name: "Abay Demo Trading PLC", Currency: "ETB", Country: "ET",
			Branches: []string{"MEKELLE", "ADDIS"}, YearName: "EFY2019", YearStart: "2026-07-08", Calendar: "ETHIOPIAN", Accounts: chart}},
		Roles: []provisioning.Role{{Name: "Administrator", Permissions: all}}}
	for _, name := range []string{"Chief Accountant", "Accountant", "Finance Manager", "Payroll Officer", "Sales Clerk", "Auditor (read only)"} {
		cfg.Roles = append(cfg.Roles, provisioning.Role{Name: name, Permissions: roles[name]})
	}
	for _, u := range Users {
		cfg.Users = append(cfg.Users, provisioning.User{Email: u.Email, Name: u.Name, Password: password, Grants: []provisioning.Grant{{Company: "DEMO", Role: u.Role}}})
	}
	res, e := provisioning.Create(ctx, db, cfg)
	if e != nil {
		return fmt.Errorf("provision: %w", e)
	}
	s := &session{db: db, company: res.Companies["DEMO"], tokens: map[string]string{}, csrf: map[string]string{}}
	for _, u := range Users {
		if e = s.login(ctx, u.Email, res.Users[u.Email]); e != nil {
			return e
		}
	}
	defer s.logout(ctx)
	acc := func(code string) string { return res.Accounts["DEMO:"+code] }
	hq := res.Branches["DEMO:MEKELLE"]

	// Operator-only FX rounding policy (one minor unit per two lines at most).
	if _, e = db.Exec(ctx, `SELECT ledger.configure_fx_rounding($1::uuid,$2::uuid,2,'Demo foreign-currency rounding policy')`, s.company, acc("7000")); e != nil {
		return fmt.Errorf("fx rounding: %w", e)
	}
	steps := []struct {
		user, sql string
		args      []any
	}{
		{"admin@serk.demo", `SELECT finance.configure($1::jsonb)`, []any{jsonOf(map[string]any{
			"cash_accounts": []string{acc("1000"), acc("1010"), acc("1020")}, "receivable": acc("1100"), "payable": acc("2000"),
			"output_tax": acc("2200"), "input_tax": acc("1300"), "opening_equity": acc("3900"), "retained_earnings": acc("3100"),
			"payroll_expense": acc("6000"), "payroll_payable": acc("2100"), "payroll_tax": acc("2110"),
			"pension_expense": acc("6010"), "pension_payable": acc("2120")})}},
		{"admin@serk.demo", `SELECT ledger.set_fx_policy(200,7)`, nil},
	}
	for _, st := range steps {
		if _, e = s.call(ctx, st.user, st.sql, st.args...); e != nil {
			return fmt.Errorf("%s: %w", st.sql, e)
		}
	}
	// Exchange rate (sample; record official NBE rates when testing foreign currency).
	if _, e = s.exec(ctx, "admin@serk.demo", `INSERT INTO core.exchange_rates(tenant_id,company_id,date,base_currency,foreign_currency,exchange_rate)
		VALUES((SELECT security.tenant()),(SELECT security.company()),$1::date,'ETB','USD',155.5)`, today.Format("2006-01-02")); e != nil {
		return fmt.Errorf("rate: %w", e)
	}
	master := func(kind string, p map[string]any) (string, error) {
		out, e := s.call(ctx, "admin@serk.demo", `SELECT finance.create_master($1,$2::jsonb)`, kind, jsonOf(p))
		if e != nil {
			return "", fmt.Errorf("master %s: %w", kind, e)
		}
		return out["id"].(string), nil
	}
	mor, e := master("AGENCY", map[string]any{"name": "Ministry of Revenues (sample)", "code": "MOR"})
	if e != nil {
		return e
	}
	vat, e := master("RATE", map[string]any{"agency_id": mor, "name": "VAT standard 15% (sample — confirm)", "code": "VAT15", "rate_percent": "15", "effective_from": "2026-07-08"})
	if e != nil {
		return e
	}
	customer, e := master("CUSTOMER", map[string]any{"name": "Demo Customer — Mekelle Retail", "tax_id": "0000000001", "phone": "+251900000001"})
	if e != nil {
		return e
	}
	if _, e = master("CUSTOMER", map[string]any{"name": "Demo Customer — Addis Wholesale", "tax_id": "0000000002"}); e != nil {
		return e
	}
	vendor, e := master("VENDOR", map[string]any{"name": "Demo Supplier — Grain Traders", "tax_id": "0000000003"})
	if e != nil {
		return e
	}
	teff, e := master("ITEM", map[string]any{"type": "PRODUCT", "name": "Teff, 50 kg bag", "sku": "TEFF-50", "unit_price": "650000", "cost_price": "500000",
		"income_account_id": acc("4000"), "expense_account_id": acc("5000"), "asset_account_id": acc("1200")})
	if e != nil {
		return e
	}
	if _, e = master("ITEM", map[string]any{"type": "PRODUCT", "name": "Coffee beans, 1 kg", "sku": "COF-1", "unit_price": "90000", "cost_price": "65000",
		"income_account_id": acc("4000"), "expense_account_id": acc("5000"), "asset_account_id": acc("1200")}); e != nil {
		return e
	}
	if _, e = master("ITEM", map[string]any{"type": "SERVICE", "name": "Delivery service", "sku": "DELIV", "unit_price": "50000", "cost_price": "0",
		"income_account_id": acc("4100"), "expense_account_id": acc("6300")}); e != nil {
		return e
	}
	for _, emp := range []map[string]any{
		{"first_name": "Hagos", "last_name": "Demo", "department": "Finance", "salary_amount": "1500000"},
		{"first_name": "Selam", "last_name": "Demo", "department": "Sales", "salary_amount": "900000"},
		{"first_name": "Tesfay", "last_name": "Demo", "department": "Warehouse", "salary_amount": "550000"},
	} {
		emp["branch_id"], emp["pay_frequency"] = hq, "MONTHLY"
		if _, e = master("EMPLOYEE", emp); e != nil {
			return e
		}
	}
	// Payroll policy in minor units (santim). Sample of the 2025 monthly employment income tax
	// bands and 7%/11% pension; a qualified accountant must confirm before relying on it.
	brackets := []map[string]any{
		{"up_to_minor": "200000", "rate_percent": "0", "subtract_minor": "0"},
		{"up_to_minor": "400000", "rate_percent": "15", "subtract_minor": "30000"},
		{"up_to_minor": "700000", "rate_percent": "20", "subtract_minor": "50000"},
		{"up_to_minor": "1000000", "rate_percent": "25", "subtract_minor": "85000"},
		{"up_to_minor": "1400000", "rate_percent": "30", "subtract_minor": "135000"},
		{"up_to_minor": nil, "rate_percent": "35", "subtract_minor": "205000"},
	}
	pol, e := s.call(ctx, "admin@serk.demo", `SELECT finance.policy_command('create',$1::jsonb)`, jsonOf(map[string]any{
		"name": "Monthly PAYE and pension — sample, confirm with an accountant", "effective_from": "2026-07-08", "pay_frequency": "MONTHLY",
		"rules": map[string]any{"income_tax_brackets": brackets, "employee_pension_percent": "7", "employer_pension_percent": "11"}}))
	if e != nil {
		return fmt.Errorf("policy: %w", e)
	}
	if _, e = s.call(ctx, "chief.accountant@serk.demo", `SELECT finance.policy_command('approve',$1::jsonb)`, jsonOf(map[string]any{"id": pol["id"], "expected_version": pol["version"]})); e != nil {
		return fmt.Errorf("policy approve: %w", e)
	}

	// Sample posted history: opening capital, a purchase and a sale, each prepared and approved by different people.
	j, e := s.call(ctx, "accountant@serk.demo", `SELECT ledger.command($1,'create',$2::jsonb)`, "demo-capital-create", jsonOf(map[string]any{
		"branch_id": hq, "accounting_date": "2026-07-10", "description": "Share capital paid into the bank", "currency": "ETB", "fx_rate": "1",
		"reason": "Bank deposit slip and share register", "lines": []map[string]any{
			{"account_id": acc("1010"), "debit_minor": "500000000", "credit_minor": "0"},
			{"account_id": acc("3000"), "debit_minor": "0", "credit_minor": "500000000"}}}))
	if e != nil {
		return fmt.Errorf("capital: %w", e)
	}
	for _, a := range []struct{ user, action string }{{"accountant@serk.demo", "submit"}, {"manager@serk.demo", "approve"}, {"manager@serk.demo", "post"}} {
		if j, e = s.call(ctx, a.user, `SELECT ledger.command($1,$2,$3::jsonb)`, "demo-capital-"+a.action, a.action,
			jsonOf(map[string]any{"id": j["id"], "expected_version": j["version"], "reason": "Reviewed deposit slip"})); e != nil {
			return fmt.Errorf("capital %s: %w", a.action, e)
		}
	}
	doc := func(kind string, p map[string]any) error {
		d, e := s.call(ctx, "accountant@serk.demo", `SELECT finance.document_command($1,$2,'create',$3::jsonb)`, "demo-"+kind+"-create", kind, jsonOf(p))
		if e != nil {
			return fmt.Errorf("%s create: %w", kind, e)
		}
		if d, e = s.call(ctx, "accountant@serk.demo", `SELECT finance.document_command($1,$2,'submit',$3::jsonb)`, "demo-"+kind+"-submit", kind,
			jsonOf(map[string]any{"id": d["id"], "expected_version": d["version"], "reason": "Supporting documents attached"})); e != nil {
			return fmt.Errorf("%s submit: %w", kind, e)
		}
		if _, e = s.call(ctx, "manager@serk.demo", `SELECT finance.document_command($1,$2,'approve',$3::jsonb)`, "demo-"+kind+"-approve", kind,
			jsonOf(map[string]any{"id": d["id"], "expected_version": d["version"], "reason": "Checked against delivery and order"})); e != nil {
			return fmt.Errorf("%s approve: %w", kind, e)
		}
		return nil
	}
	if e = doc("BILL", map[string]any{"branch_id": hq, "accounting_date": "2026-08-15", "due_date": "2026-09-14", "bill_number": "SUP-INV-1001",
		"vendor_id": vendor, "lines": []map[string]any{{"item_id": teff, "quantity": "100", "unit_price": "500000", "tax_rate_id": vat}}}); e != nil {
		return e
	}
	if e = doc("INVOICE", map[string]any{"branch_id": hq, "accounting_date": "2026-09-20", "due_date": "2026-10-20", "invoice_number": "INV-0001",
		"customer_id": customer, "lines": []map[string]any{{"item_id": teff, "quantity": "20", "unit_price": "650000", "tax_rate_id": vat}}}); e != nil {
		return e
	}
	return nil
}

func jsonOf(v any) string { b, _ := json.Marshal(v); return string(b) }

// session issues short-lived sessions for the demo users so that seed data goes through the
// same permission, segregation-of-duties and audit controls as the API.
type session struct {
	db           *pgx.Conn
	company      string
	tokens, csrf map[string]string
}

func (s *session) login(ctx context.Context, email, user string) error {
	t, e := auth.Token()
	if e != nil {
		return e
	}
	c, e := auth.Token()
	if e != nil {
		return e
	}
	if _, e = s.db.Exec(ctx, `SELECT security.issue_session($1::uuid,$2,$3)`, user, auth.Digest(t), c); e != nil {
		return fmt.Errorf("session: %w", e)
	}
	s.tokens[email], s.csrf[email] = t, c
	return nil
}

func (s *session) logout(ctx context.Context) {
	for email, t := range s.tokens {
		_, _ = s.db.Exec(ctx, `UPDATE security.sessions SET revoked_at=clock_timestamp() WHERE token_hash=$1`, auth.Digest(t))
		delete(s.tokens, email)
	}
}

func (s *session) scoped(ctx context.Context, user string, fn func(pgx.Tx) error) error {
	tx, e := s.db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(ctx)
	if _, e = tx.Exec(ctx, `SET LOCAL ROLE serk_api`); e != nil {
		return e
	}
	if _, e = tx.Exec(ctx, `SELECT security.bind($1,$2::uuid,$3,'{"request_id":"demo-seed"}'::jsonb)`, s.tokens[user], s.company, s.csrf[user]); e != nil {
		return e
	}
	if e = fn(tx); e != nil {
		return e
	}
	return tx.Commit(ctx)
}

func (s *session) call(ctx context.Context, user, sql string, args ...any) (map[string]any, error) {
	var raw []byte
	e := s.scoped(ctx, user, func(tx pgx.Tx) error { return tx.QueryRow(ctx, sql, args...).Scan(&raw) })
	if e != nil {
		return nil, e
	}
	out := map[string]any{}
	_ = json.Unmarshal(raw, &out)
	return out, nil
}

func (s *session) exec(ctx context.Context, user, sql string, args ...any) (int64, error) {
	var n int64
	e := s.scoped(ctx, user, func(tx pgx.Tx) error {
		tag, e := tx.Exec(ctx, sql, args...)
		n = tag.RowsAffected()
		return e
	})
	return n, e
}
