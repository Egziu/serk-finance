package demo

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/provisioning"
)

// NewCompany describes a real company created by the office installer's first-run setup.
type NewCompany struct {
	Workspace     string   `json:"workspace"`
	CompanyName   string   `json:"company_name"`
	Currency      string   `json:"currency"`
	Calendar      string   `json:"calendar"`   // ETHIOPIAN or GREGORIAN
	YearStart     string   `json:"year_start"` // Hamle 1 for ETHIOPIAN
	Branches      []string `json:"branches"`
	VATRegistered bool     `json:"vat_registered"`
	AdminName     string   `json:"admin_name"`
	AdminEmail    string   `json:"admin_email"`
	AdminPassword string   `json:"admin_password"`
}

var (
	slugPattern   = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,39}$`)
	branchPattern = regexp.MustCompile(`^[A-Z0-9][A-Z0-9_-]{0,19}$`)
	emailPattern  = regexp.MustCompile(`^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$`)
)

// Validate checks the setup form before anything is written.
func (n *NewCompany) Validate() error {
	n.Workspace = strings.ToLower(strings.TrimSpace(n.Workspace))
	n.CompanyName, n.AdminName, n.AdminEmail = strings.TrimSpace(n.CompanyName), strings.TrimSpace(n.AdminName), strings.ToLower(strings.TrimSpace(n.AdminEmail))
	n.Currency = strings.ToUpper(strings.TrimSpace(n.Currency))
	if n.Currency == "" {
		n.Currency = "ETB"
	}
	if n.Calendar == "" {
		n.Calendar = "ETHIOPIAN"
	}
	if len(n.Branches) == 0 {
		n.Branches = []string{"HQ"}
	}
	switch {
	case !slugPattern.MatchString(n.Workspace) || n.Workspace == Slug:
		return errors.New("workspace: use 2–40 lowercase letters, digits or hyphens (not \"demo\")")
	case len(n.CompanyName) < 2 || len(n.CompanyName) > 200:
		return errors.New("company name: 2–200 characters")
	case !regexp.MustCompile(`^[A-Z]{3}$`).MatchString(n.Currency):
		return errors.New("currency: a three-letter code such as ETB")
	case n.Calendar != "ETHIOPIAN" && n.Calendar != "GREGORIAN":
		return errors.New("calendar: ETHIOPIAN or GREGORIAN")
	case len(n.AdminName) < 2 || len(n.AdminName) > 200:
		return errors.New("administrator name: 2–200 characters")
	case !emailPattern.MatchString(n.AdminEmail):
		return errors.New("administrator email is not valid")
	case len(n.AdminPassword) < 14 || len(n.AdminPassword) > 256:
		return errors.New("administrator password: at least 14 characters")
	}
	if len(n.Branches) > 20 {
		return errors.New("at most 20 branches")
	}
	seen := map[string]bool{}
	for i, b := range n.Branches {
		b = strings.ToUpper(strings.TrimSpace(b))
		if !branchPattern.MatchString(b) || seen[b] {
			return fmt.Errorf("branch %q: use up to 20 capital letters, digits, - or _, each once", n.Branches[i])
		}
		seen[b], n.Branches[i] = true, b
	}
	start, e := time.Parse("2006-01-02", n.YearStart)
	if e != nil {
		return errors.New("fiscal year start must be a date")
	}
	if n.Calendar == "ETHIOPIAN" {
		// Hamle 1 = Meskerem 1 of the year before + 300 days.
		if hamle := provisioning.MeskeremOne(start.Year()-1).AddDate(0, 0, 300); !hamle.Equal(start) {
			return fmt.Errorf("an Ethiopian fiscal year starts on Hamle 1 (%s in %d)", hamle.Format("2 January"), start.Year())
		}
	}
	return nil
}

// EthiopianYearName returns "EFY<year>" for a Hamle 1 start date (Hamle 1 2026 opens EFY 2019).
func EthiopianYearName(start time.Time) string { return fmt.Sprintf("EFY%d", start.Year()-7) }

// CreateCompany provisions a workspace with one company ready for use: the Ethiopian SME
// chart of accounts (IFRS for SMEs presentation), standard roles, the administrator, account
// mappings, the exchange-rate policy and, when VAT-registered, the standard VAT rate. Nothing
// is posted. Statutory rates are samples to confirm.
func CreateCompany(ctx context.Context, db *pgx.Conn, n NewCompany) (provisioning.Result, error) {
	if e := n.Validate(); e != nil {
		return provisioning.Result{}, e
	}
	start, _ := time.Parse("2006-01-02", n.YearStart)
	co := provisioning.Company{Code: "MAIN", Name: n.CompanyName, Currency: n.Currency, Country: "ET", Branches: n.Branches,
		YearStart: n.YearStart, Calendar: n.Calendar, Accounts: chart}
	if n.Calendar == "ETHIOPIAN" {
		co.YearName = EthiopianYearName(start)
	} else {
		co.YearName = fmt.Sprintf("FY%d", start.Year())
		co.YearEnd = start.AddDate(1, 0, -1).Format("2006-01-02")
	}
	all, e := permissions(ctx, db)
	if e != nil {
		return provisioning.Result{}, e
	}
	cfg := provisioning.Config{Slug: n.Workspace, Name: n.CompanyName, Companies: []provisioning.Company{co},
		Roles: []provisioning.Role{{Name: "Administrator", Permissions: all}}}
	for _, name := range []string{"Chief Accountant", "Accountant", "Finance Manager", "Payroll Officer", "Sales Clerk", "Auditor (read only)"} {
		cfg.Roles = append(cfg.Roles, provisioning.Role{Name: name, Permissions: roles[name]})
	}
	cfg.Users = []provisioning.User{{Email: n.AdminEmail, Name: n.AdminName, Password: n.AdminPassword, Grants: []provisioning.Grant{{Company: "MAIN", Role: "Administrator"}}}}
	res, e := provisioning.Create(ctx, db, cfg)
	if e != nil {
		return res, fmt.Errorf("provision: %w", e)
	}
	return res, ConfigureCompany(ctx, db, n)
}

// ConfigureCompany applies the starting configuration (account mappings, rounding, foreign
// exchange policy and VAT) to a provisioned company. Every step is safe to repeat, so a setup
// interrupted after provisioning can be completed by running it again.
func ConfigureCompany(ctx context.Context, db *pgx.Conn, n NewCompany) error {
	var company, admin string
	if e := db.QueryRow(ctx, `SELECT c.id::text,u.id::text FROM security.tenants t JOIN organization.companies c ON c.tenant_id=t.id AND c.code='MAIN'
		JOIN security.users u ON u.tenant_id=t.id AND lower(u.email)=lower($2) WHERE t.slug=$1`, n.Workspace, n.AdminEmail).Scan(&company, &admin); e != nil {
		return fmt.Errorf("find company: %w", e)
	}
	rows, e := db.Query(ctx, `SELECT code,id::text FROM ledger.accounts WHERE company_id=$1::uuid`, company)
	if e != nil {
		return e
	}
	accounts := map[string]string{}
	for rows.Next() {
		var code, id string
		if e = rows.Scan(&code, &id); e != nil {
			rows.Close()
			return e
		}
		accounts[code] = id
	}
	rows.Close()
	if e = rows.Err(); e != nil {
		return e
	}
	s := &session{db: db, company: company, tokens: map[string]string{}, csrf: map[string]string{}}
	if e = s.login(ctx, n.AdminEmail, admin); e != nil {
		return e
	}
	defer s.logout(ctx)
	acc := func(code string) string { return accounts[code] }
	if _, e = db.Exec(ctx, `SELECT ledger.configure_fx_rounding($1::uuid,$2::uuid,2,'Foreign-currency rounding to exchange differences')`, s.company, acc("7000")); e != nil {
		return fmt.Errorf("fx rounding: %w", e)
	}
	if _, e = s.call(ctx, n.AdminEmail, `SELECT finance.configure($1::jsonb)`, jsonOf(map[string]any{
		"cash_accounts": []string{acc("1000"), acc("1010"), acc("1020")}, "receivable": acc("1100"), "payable": acc("2000"),
		"output_tax": acc("2200"), "input_tax": acc("1300"), "opening_equity": acc("3900"), "retained_earnings": acc("3100"),
		"payroll_expense": acc("6000"), "payroll_payable": acc("2100"), "payroll_tax": acc("2110"),
		"pension_expense": acc("6010"), "pension_payable": acc("2120")})); e != nil {
		return fmt.Errorf("account mappings: %w", e)
	}
	if _, e = s.call(ctx, n.AdminEmail, `SELECT ledger.set_fx_policy(200,7)`); e != nil {
		return fmt.Errorf("fx policy: %w", e)
	}
	if n.VATRegistered {
		var agency string
		_ = db.QueryRow(ctx, `SELECT id::text FROM taxes.tax_agencies WHERE company_id=$1::uuid AND code='MOR'`, company).Scan(&agency)
		if agency == "" {
			mor, e := s.call(ctx, n.AdminEmail, `SELECT finance.create_master('AGENCY',$1::jsonb)`, jsonOf(map[string]any{"name": "Ministry of Revenues", "code": "MOR"}))
			if e != nil {
				return fmt.Errorf("tax agency: %w", e)
			}
			agency, _ = mor["id"].(string)
		}
		var rates int
		if e = db.QueryRow(ctx, `SELECT count(*) FROM taxes.tax_rates WHERE company_id=$1::uuid AND code='VAT15'`, company).Scan(&rates); e != nil {
			return e
		}
		if rates == 0 {
			if _, e = s.call(ctx, n.AdminEmail, `SELECT finance.create_master('RATE',$1::jsonb)`, jsonOf(map[string]any{"agency_id": agency,
				"name": "VAT standard rate 15% (confirm)", "code": "VAT15", "rate_percent": "15", "effective_from": n.YearStart})); e != nil {
				return fmt.Errorf("VAT rate: %w", e)
			}
		}
	}
	return nil
}

func permissions(ctx context.Context, db *pgx.Conn) ([]string, error) {
	rows, e := db.Query(ctx, `SELECT code FROM security.permissions ORDER BY code`)
	if e != nil {
		return nil, e
	}
	return pgx.CollectRows(rows, pgx.RowTo[string])
}
