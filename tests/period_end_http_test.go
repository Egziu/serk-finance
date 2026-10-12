package tests

import (
	"context"
	"testing"
)

// HTTP routing, authorization and error-code mapping for the 0.2.2 period-end, adjustment and
// tax-report endpoints. The accounting behaviour itself is covered by tests/controls-022.mjs.
func TestPeriodEndHTTP(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	var year string
	if e := f.admin.QueryRow(ctx, `SELECT id FROM ledger.fiscal_years WHERE company_id=$1::uuid`, f.data.Companies["A"]).Scan(&year); e != nil {
		t.Fatal(e)
	}
	overview := decodeObject(t, f.request(t, "maker", "GET", "/api/v1/accounting/period-end", "", nil, 200))
	if len(overview["fiscal_years"].([]any)) != 1 {
		t.Fatal("fiscal years", overview)
	}
	preview := decodeObject(t, f.request(t, "maker", "GET", "/api/v1/accounting/fiscal-years/"+year+"/close-preview", "", nil, 200))
	if preview["ready"] != false || len(preview["blockers"].([]any)) == 0 {
		t.Fatal("a fresh year with open periods must not be ready to close", preview)
	}
	f.request(t, "maker", "GET", "/api/v1/accounting/fiscal-years/not-a-uuid/close-preview", "", nil, 400)
	f.request(t, "reader", "GET", "/api/v1/accounting/fiscal-years/"+year+"/close-preview", "", nil, 403)

	// Commands need an idempotency key, a known action, and map database codes to safe API codes.
	f.request(t, "maker", "POST", "/api/v1/accounting/year-close/request", "", map[string]any{"fiscal_year_id": year, "reason": "Year end"}, 400)
	f.request(t, "maker", "POST", "/api/v1/accounting/year-close/explode", "year-close-unknown-1", map[string]any{"reason": "Year end"}, 404)
	rr := f.request(t, "maker", "POST", "/api/v1/accounting/year-close/request", "year-close-blocked-1", map[string]any{"fiscal_year_id": year, "retained_earnings_account_id": f.data.Accounts["A:4000"], "reason": "Year end"}, 409)
	wantError(t, rr, "year_close_blocked")
	rr = f.request(t, "maker", "POST", "/api/v1/accounting/period-reopenings/request", "reopen-open-period-1", map[string]any{"period_id": f.data.Periods["A:2026-09"], "reason": "Adjusting event"}, 409)
	wantError(t, rr, "period_not_closed")

	// Adjustments and tax reports are module-permissioned.
	f.request(t, "maker", "GET", "/api/v1/finance/adjustments", "", nil, 200)
	rr = f.request(t, "maker", "POST", "/api/v1/finance/adjustments/create", "adjust-no-taxes-1", map[string]any{
		"purpose": "TAX_SETTLEMENT", "number": "VAT-1", "branch_id": f.data.Branches["A:HQ"], "accounting_date": "2026-09-14",
		"description": "VAT", "reason": "Return filed", "lines": []any{}}, 403)
	wantError(t, rr, "permission_denied")
	f.request(t, "maker", "GET", "/api/v1/taxes/report?to=2026-13-01", "", nil, 400)
	f.request(t, "maker", "GET", "/api/v1/taxes/report?from=2026-10-01&to=2026-09-01", "", nil, 400)
	f.request(t, "maker", "GET", "/api/v1/taxes/report?to=2026-09-30", "", nil, 403)

	// Exchange-rate helpers.
	pol := decodeObject(t, f.request(t, "maker", "GET", "/api/v1/fx-policy", "", nil, 200))
	if pol["tolerance_bps"] != float64(200) {
		t.Fatal("default tolerance", pol)
	}
	f.request(t, "maker", "POST", "/api/v1/fx-policy", "", map[string]any{"tolerance_bps": 100}, 403)
	got := decodeObject(t, f.request(t, "maker", "GET", "/api/v1/exchange-rates/recorded?currency=USD&date=2026-09-14", "", nil, 200))
	if got["rate"] != nil {
		t.Fatal("no rate expected", got)
	}
	f.rate(t, "USD", "2026-09-01", "120.5")
	got = decodeObject(t, f.request(t, "maker", "GET", "/api/v1/exchange-rates/recorded?currency=USD&date=2026-09-14", "", nil, 200))
	if got["rate"] != "120.5" {
		t.Fatal("recorded rate", got)
	}
}
