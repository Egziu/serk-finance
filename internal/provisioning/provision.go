// Package provisioning is operator-only. It is not imported by the API binary.
package provisioning

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/auth"
)

type Config struct {
	Slug      string    `json:"slug"`
	Name      string    `json:"name"`
	Companies []Company `json:"companies"`
	Roles     []Role    `json:"roles"`
	Users     []User    `json:"users"`
}
type Company struct {
	Code      string    `json:"code"`
	Name      string    `json:"name"`
	Currency  string    `json:"currency"`
	Country   string    `json:"country"`
	Branches  []string  `json:"branches"`
	YearName  string    `json:"year_name"`
	YearStart string    `json:"year_start"`
	YearEnd   string    `json:"year_end"`
	Accounts  []Account `json:"accounts"`
}
type Account struct {
	Code    string `json:"code"`
	Name    string `json:"name"`
	Type    string `json:"type"`
	Normal  string `json:"normal_balance"`
	Control bool   `json:"control_account"`
}
type Role struct {
	Name        string   `json:"name"`
	Permissions []string `json:"permissions"`
}
type Grant struct {
	Company       string  `json:"company"`
	Role          string  `json:"role"`
	Branch        string  `json:"branch,omitempty"`
	ApprovalLimit *string `json:"approval_limit_minor,omitempty"`
}
type User struct {
	Email    string  `json:"email"`
	Name     string  `json:"name"`
	Password string  `json:"password"`
	Grants   []Grant `json:"grants"`
}
type Result struct {
	TenantID  string            `json:"tenant_id"`
	Companies map[string]string `json:"companies"`
	Users     map[string]string `json:"users"`
	Branches  map[string]string `json:"branches"`
	Accounts  map[string]string `json:"accounts"`
	Periods   map[string]string `json:"periods"`
}

func Create(ctx context.Context, db *pgx.Conn, c Config) (Result, error) {
	r := Result{Companies: map[string]string{}, Users: map[string]string{}, Branches: map[string]string{}, Accounts: map[string]string{}, Periods: map[string]string{}}
	if len(c.Companies) == 0 || len(c.Users) == 0 || len(c.Roles) == 0 {
		return r, fmt.Errorf("companies, users, and roles required")
	}
	hashes := map[string]string{}
	for _, u := range c.Users {
		h, e := auth.Hash(u.Password)
		if e != nil {
			return r, e
		}
		hashes[u.Email] = h
	}
	tx, e := db.Begin(ctx)
	if e != nil {
		return r, e
	}
	defer tx.Rollback(ctx)
	if e = tx.QueryRow(ctx, `INSERT INTO security.tenants(slug,name) VALUES($1,$2) RETURNING id`, c.Slug, c.Name).Scan(&r.TenantID); e != nil {
		return r, e
	}
	for _, co := range c.Companies {
		var cid, fy string
		if e = tx.QueryRow(ctx, `INSERT INTO organization.companies(tenant_id,code,name,functional_currency,country_code) VALUES($1,$2,$3,$4,$5) RETURNING id`, r.TenantID, co.Code, co.Name, co.Currency, co.Country).Scan(&cid); e != nil {
			return r, e
		}
		r.Companies[co.Code] = cid
		if len(co.Branches) == 0 {
			return r, fmt.Errorf("at least one branch required")
		}
		for _, b := range co.Branches {
			var id string
			if e = tx.QueryRow(ctx, `INSERT INTO organization.branches(tenant_id,company_id,code,name) VALUES($1,$2,$3,$3) RETURNING id`, r.TenantID, cid, b).Scan(&id); e != nil {
				return r, e
			}
			r.Branches[co.Code+":"+b] = id
		}
		if e = tx.QueryRow(ctx, `INSERT INTO ledger.fiscal_years(tenant_id,company_id,name,start_date,end_date) VALUES($1,$2,$3,$4::date,$5::date) RETURNING id`, r.TenantID, cid, co.YearName, co.YearStart, co.YearEnd).Scan(&fy); e != nil {
			return r, e
		}
		start, e := time.Parse("2006-01-02", co.YearStart)
		if e != nil {
			return r, e
		}
		end, e := time.Parse("2006-01-02", co.YearEnd)
		if e != nil || end.Before(start) || end.Sub(start) > 367*24*time.Hour {
			return r, fmt.Errorf("invalid fiscal year")
		}
		// Calendar-neutral fiscal dates. Monthly Gregorian partitions are a provisioning convenience only.
		for n := 1; !start.After(end); n++ {
			next := time.Date(start.Year(), start.Month()+1, 1, 0, 0, 0, 0, time.UTC)
			last := next.AddDate(0, 0, -1)
			if last.After(end) {
				last = end
			}
			var id string
			if e = tx.QueryRow(ctx, `INSERT INTO ledger.periods(tenant_id,company_id,fiscal_year_id,name,start_date,end_date) VALUES($1,$2,$3,$4,$5::date,$6::date) RETURNING id`, r.TenantID, cid, fy, fmt.Sprintf("P%02d", n), start.Format("2006-01-02"), last.Format("2006-01-02")).Scan(&id); e != nil {
				return r, e
			}
			r.Periods[co.Code+":"+start.Format("2006-01")] = id
			start = next
		}
		for _, a := range co.Accounts {
			var id string
			if e = tx.QueryRow(ctx, `INSERT INTO ledger.accounts(tenant_id,company_id,code,name,type,normal_balance,control_account,reporting_category) VALUES($1,$2,$3,$4,$5,$6,$7,$5) RETURNING id`, r.TenantID, cid, a.Code, a.Name, a.Type, a.Normal, a.Control).Scan(&id); e != nil {
				return r, e
			}
			r.Accounts[co.Code+":"+a.Code] = id
		}
	}
	roles := map[string]string{}
	for _, role := range c.Roles {
		var id string
		if e = tx.QueryRow(ctx, `INSERT INTO security.roles(tenant_id,name) VALUES($1,$2) RETURNING id`, r.TenantID, role.Name).Scan(&id); e != nil {
			return r, e
		}
		roles[role.Name] = id
		for _, p := range role.Permissions {
			if _, e = tx.Exec(ctx, `INSERT INTO security.role_permissions VALUES($1,$2,$3)`, r.TenantID, id, p); e != nil {
				return r, e
			}
		}
	}
	for _, u := range c.Users {
		var uid string
		if e = tx.QueryRow(ctx, `INSERT INTO security.users(tenant_id,email,display_name,password_hash) VALUES($1,$2,$3,$4) RETURNING id`, r.TenantID, strings.ToLower(u.Email), u.Name, hashes[u.Email]).Scan(&uid); e != nil {
			return r, e
		}
		r.Users[u.Email] = uid
		for _, g := range u.Grants {
			cid, rid := r.Companies[g.Company], roles[g.Role]
			if cid == "" || rid == "" {
				return r, fmt.Errorf("unknown grant reference")
			}
			var branch, limit any
			if g.Branch != "" {
				branch = r.Branches[g.Company+":"+g.Branch]
				if branch == "" {
					return r, fmt.Errorf("unknown branch")
				}
			}
			if g.ApprovalLimit != nil {
				limit = *g.ApprovalLimit
			}
			if _, e = tx.Exec(ctx, `INSERT INTO security.memberships(tenant_id,company_id,user_id,role_id,branch_id,approval_limit_minor) VALUES($1,$2,$3,$4,$5::uuid,$6::numeric)`, r.TenantID, cid, uid, rid, branch, limit); e != nil {
				return r, e
			}
		}
	}
	if e = tx.Commit(ctx); e != nil {
		return r, e
	}
	return r, nil
}
