package tests

import (
	"context"
	"fmt"
	"net/url"
	"testing"
)

func TestHTTPConnectedReports(t *testing.T) {
	f := setup(t)
	root := "/api/v1/reports/general-ledger"
	path := root + "?account_id=" + f.data.Accounts["A:1000"] + "&from=2026-09-01&as_of=2026-09-30"
	j := f.create(t, "report-create-001")
	for _, action := range []string{"submit", "approve", "post"} {
		user := "checker"
		if action == "submit" {
			user = "maker"
		}
		next, err := f.move(user, "report-"+action, action, j)
		j = must(t, next, err)
	}
	f.create(t, "report-excluded-draft")
	r := decodeObject(t, f.request(t, "maker", "GET", path+"&limit=1", "", nil, 200))
	if r["opening_minor"] != "0" || r["debit_minor"] != "10000" || r["closing_minor"] != "10000" || r["has_more"] != false {
		t.Fatal(r)
	}
	rows := r["rows"].([]any)
	if len(rows) != 1 || rows[0].(map[string]any)["journal_id"] != j["id"] {
		t.Fatal(rows)
	}
	row := rows[0].(map[string]any)
	cursor := fmt.Sprintf("&after_date=%s&after_id=%s&after_line=1", row["accounting_date"], j["id"])
	page := decodeObject(t, f.request(t, "reader", "GET", path+cursor, "", nil, 200))
	if len(page["rows"].([]any)) != 0 || page["closing_minor"] != "10000" {
		t.Fatal(page)
	}
	branch := decodeObject(t, f.request(t, "branch", "GET", path, "", nil, 200))
	if branch["company_wide"] != false || branch["closing_minor"] != "0" {
		t.Fatal(branch)
	}
	status := decodeObject(t, f.request(t, "checker", "GET", "/api/v1/accounting/integrity", "", nil, 200))
	if status["ok"] != true || status["posted_journals"] != float64(1) || status["audit_events"] != float64(5) {
		t.Fatal(status)
	}
	f.request(t, "reader", "GET", "/api/v1/accounting/integrity", "", nil, 403)
	f.request(t, "branch", "GET", "/api/v1/accounting/integrity", "", nil, 403)
	foreign := root + "?account_id=" + f.other.Accounts["A:1000"] + "&from=2026-09-01&as_of=2026-09-30"
	f.request(t, "maker", "GET", foreign, "", nil, 404)
	for _, suffix := range []string{"&limit=0", "&limit=101", "&limit=bad", "&after_date=2026-09-01", "&after_id=bad", "&after_line=0", "&after_date=2026-09-14&after_id=" + j["id"].(string) + "&after_line=502"} {
		f.request(t, "maker", "GET", path+suffix, "", nil, 400)
	}
	for _, q := range []string{"", "?account_id=bad&from=2026-09-01&as_of=2026-09-30", "?account_id=" + f.data.Accounts["A:1000"] + "&from=2026-10-01&as_of=2026-09-30"} {
		f.request(t, "maker", "GET", root+q, "", nil, 400)
	}
	f.request(t, "maker", "GET", "/api/v1/accounting/journals?state="+url.QueryEscape("NOT_A_STATE"), "", nil, 400)
}

func TestUsedAccountDefinitionIsProtected(t *testing.T) {
	f := setup(t)
	f.create(t, "definition-create")
	_, err := f.admin.Exec(context.Background(), `UPDATE ledger.accounts SET type='LIABILITY' WHERE id=$1`, f.data.Accounts["A:1000"])
	wantCode(t, err, "55000")
}
