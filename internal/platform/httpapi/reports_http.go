package httpapi

import (
	"net/http"
	"strconv"
	"time"

	"serk.finance/internal/accounting"
)

func (s *Server) generalLedger(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	from, e1 := time.Parse("2006-01-02", q.Get("from"))
	asOf, e2 := time.Parse("2006-01-02", q.Get("as_of"))
	if e1 != nil || e2 != nil || from.After(asOf) || !accounting.UUIDPattern.MatchString(q.Get("account_id")) {
		s.fail(w, r, &problem{400, "invalid_report_parameters"})
		return
	}
	limit := 100
	if q.Has("limit") {
		n, e := strconv.Atoi(q.Get("limit"))
		if e != nil || n < 1 || n > 100 {
			s.fail(w, r, &problem{400, "invalid_pagination"})
			return
		}
		limit = n
	}
	var afterDate, afterID, afterLine any
	if q.Has("after_date") || q.Has("after_id") || q.Has("after_line") {
		d, e := time.Parse("2006-01-02", q.Get("after_date"))
		line, lineErr := strconv.Atoi(q.Get("after_line"))
		if e != nil || lineErr != nil || d.Before(from) || d.After(asOf) || line < 1 || line > 501 || !accounting.UUIDPattern.MatchString(q.Get("after_id")) {
			s.fail(w, r, &problem{400, "invalid_pagination"})
			return
		}
		afterDate, afterID, afterLine = q.Get("after_date"), q.Get("after_id"), line
	}
	s.query(w, r, `SELECT ledger.general_ledger($1::uuid,$2::date,$3::date,$4::integer,$5::date,$6::uuid,$7::integer)`,
		q.Get("account_id"), q.Get("from"), q.Get("as_of"), limit, afterDate, afterID, afterLine)
}

func (s *Server) integrity(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT ledger.integrity_status()`)
}

func (s *Server) taxLiability(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT coalesce(json_build_object('total_tax_liability', coalesce(sum(functional_credit_minor - functional_debit_minor), 0)), '{}'::json) FROM ledger.lines l JOIN ledger.accounts a ON a.id = l.account_id WHERE a.name = 'Sales Tax Payable' AND l.tenant_id = (SELECT security.tenant()) AND l.company_id = (SELECT security.company())`)
}
