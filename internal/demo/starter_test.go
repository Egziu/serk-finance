package demo

import (
	"strings"
	"testing"
	"time"
)

func TestNewCompanyValidation(t *testing.T) {
	ok := NewCompany{Workspace: "Abay-Trading", CompanyName: "Abay Trading PLC", Calendar: "ETHIOPIAN", YearStart: "2026-07-08",
		Branches: []string{"hq", "Addis"}, AdminName: "Admin", AdminEmail: "Admin@Example.com", AdminPassword: "a-long-password-1"}
	if e := ok.Validate(); e != nil {
		t.Fatal(e)
	}
	if ok.Workspace != "abay-trading" || ok.Branches[0] != "HQ" || ok.Currency != "ETB" || ok.AdminEmail != "admin@example.com" {
		t.Fatalf("normalised %+v", ok)
	}
	for name, mutate := range map[string]func(*NewCompany){
		"not Hamle 1":    func(n *NewCompany) { n.YearStart = "2026-07-01" },
		"demo slug":      func(n *NewCompany) { n.Workspace = "demo" },
		"short password": func(n *NewCompany) { n.AdminPassword = "short" },
		"bad email":      func(n *NewCompany) { n.AdminEmail = "nobody" },
		"dup branch":     func(n *NewCompany) { n.Branches = []string{"HQ", "hq"} },
		"bad calendar":   func(n *NewCompany) { n.Calendar = "LUNAR" },
	} {
		n := ok
		n.Branches = append([]string(nil), ok.Branches...)
		mutate(&n)
		if n.Validate() == nil {
			t.Errorf("%s accepted", name)
		}
	}
	g := ok
	g.Calendar, g.YearStart = "GREGORIAN", "2026-01-01"
	if e := g.Validate(); e != nil {
		t.Fatal(e)
	}
	if EthiopianYearName(mustDate("2026-07-08")) != "EFY2019" || !strings.HasPrefix(EthiopianYearName(mustDate("2027-07-08")), "EFY2020") {
		t.Fatal("year name")
	}
}

func mustDate(s string) (t time.Time) { t, _ = time.Parse("2006-01-02", s); return }
