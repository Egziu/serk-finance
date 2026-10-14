package tests

import (
	"context"
	"strings"
	"testing"

	"serk.finance/internal/demo"
)

// An office setup interrupted after the company was provisioned can be completed by running
// the configuration again: every step is repeatable and nothing is duplicated.
func TestOfficeSetupConfigurationIsRepeatable(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	n := demo.NewCompany{Workspace: "office-" + strings.ToLower(f.slug), CompanyName: "Office Setup PLC", Currency: "ETB", Calendar: "ETHIOPIAN",
		YearStart: "2025-07-08", Branches: []string{"HQ"}, VATRegistered: true, AdminName: "Office Admin", AdminEmail: "admin@office.example", AdminPassword: "Office-Setup-Password-2026"}
	if len(n.Workspace) > 40 {
		n.Workspace = n.Workspace[:40]
	}
	if _, e := demo.CreateCompany(ctx, f.admin, n); e != nil {
		t.Fatal(e)
	}
	if e := demo.ConfigureCompany(ctx, f.admin, n); e != nil {
		t.Fatal("second configuration run", e)
	}
	var agencies, rates, mappings int
	if e := f.admin.QueryRow(ctx, `SELECT (SELECT count(*) FROM taxes.tax_agencies a JOIN organization.companies c ON c.id=a.company_id JOIN security.tenants t ON t.id=c.tenant_id WHERE t.slug=$1),
		(SELECT count(*) FROM taxes.tax_rates r JOIN organization.companies c ON c.id=r.company_id JOIN security.tenants t ON t.id=c.tenant_id WHERE t.slug=$1),
		(SELECT count(*) FROM finance.settings s JOIN organization.companies c ON c.id=s.company_id JOIN security.tenants t ON t.id=c.tenant_id WHERE t.slug=$1)`, n.Workspace).Scan(&agencies, &rates, &mappings); e != nil {
		t.Fatal(e)
	}
	if agencies != 1 || rates != 1 || mappings != 1 {
		t.Fatal("duplicated or missing configuration", agencies, rates, mappings)
	}
}
