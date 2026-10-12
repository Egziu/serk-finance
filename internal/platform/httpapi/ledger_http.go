package httpapi

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/accounting"
)

func (s *Server) reference(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT ledger.reference_data()`)
}
func (s *Server) get(w http.ResponseWriter, r *http.Request) {
	if !accounting.UUIDPattern.MatchString(r.PathValue("id")) {
		s.fail(w, r, &problem{400, "invalid_id"})
		return
	}
	s.query(w, r, `SELECT ledger.get_journal($1::uuid)`, r.PathValue("id"))
}
func (s *Server) list(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit := 50
	if q.Get("limit") != "" {
		n, e := strconv.Atoi(q.Get("limit"))
		if e != nil || n < 1 || n > 100 {
			s.fail(w, r, &problem{400, "invalid_pagination"})
			return
		}
		limit = n
	}
	var before, id, state any
	if q.Get("before") != "" {
		if _, e := time.Parse(time.RFC3339Nano, q.Get("before")); e != nil || !accounting.UUIDPattern.MatchString(q.Get("before_id")) {
			s.fail(w, r, &problem{400, "invalid_pagination"})
			return
		}
		before = q.Get("before")
		id = q.Get("before_id")
	}
	if q.Get("state") != "" {
		switch q.Get("state") {
		case "DRAFT", "SUBMITTED", "APPROVED", "POSTED", "VOIDED":
		default:
			s.fail(w, r, &problem{400, "invalid_pagination"})
			return
		}
		state = q.Get("state")
	}
	s.query(w, r, `SELECT ledger.list_journals($1,$2::timestamptz,$3::uuid,$4)`, limit, before, id, state)
}
func (s *Server) command(w http.ResponseWriter, r *http.Request, action string, p any, status int) {
	k := r.Header.Get("Idempotency-Key")
	if len(k) < 8 || len(k) > 128 {
		s.fail(w, r, &problem{400, "idempotency_key_required"})
		return
	}
	b, e := json.Marshal(p)
	if e != nil {
		s.fail(w, r, e)
		return
	}
	var data json.RawMessage
	e = s.scoped(r, func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), `SELECT ledger.command($1,$2,$3::jsonb)`, k, action, string(b)).Scan(&data)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, status, data)
}
func (s *Server) create(w http.ResponseWriter, r *http.Request) {
	var in accounting.CreateJournal
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	if e := in.Validate(); e != nil {
		s.fail(w, r, e)
		return
	}
	s.command(w, r, "create", in, 201)
}
func (s *Server) transition(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Version int64  `json:"expected_version"`
		Reason  string `json:"reason"`
		Date    string `json:"accounting_date,omitempty"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	id, action := r.PathValue("id"), r.PathValue("action")
	if !accounting.UUIDPattern.MatchString(id) || in.Version < 1 || len(strings.TrimSpace(in.Reason)) < 3 || len(in.Reason) > 1000 {
		s.fail(w, r, &problem{400, "invalid_transition"})
		return
	}
	if action != "submit" && action != "approve" && action != "post" && action != "reverse" && action != "void" {
		s.fail(w, r, &problem{404, "not_found"})
		return
	}
	if action == "reverse" {
		if _, e := time.Parse("2006-01-02", in.Date); e != nil {
			s.fail(w, r, &problem{400, "invalid_date"})
			return
		}
	}
	status := 200
	if action == "reverse" {
		status = 201
	}
	s.command(w, r, action, map[string]any{"id": id, "expected_version": in.Version, "reason": in.Reason, "accounting_date": in.Date}, status)
}
func (s *Server) trial(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	asof := q.Get("as_of")
	if _, e := time.Parse("2006-01-02", asof); e != nil {
		s.fail(w, r, &problem{400, "as_of_date_required"})
		return
	}
	var from any
	if q.Get("from") != "" {
		if _, e := time.Parse("2006-01-02", q.Get("from")); e != nil {
			s.fail(w, r, &problem{400, "invalid_date"})
			return
		}
		from = q.Get("from")
	}
	s.query(w, r, `SELECT ledger.trial_balance($1::date,$2::date)`, asof, from)
}
func (s *Server) balanceSheet(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	asof := q.Get("as_of")
	if asof == "" {
		asof = time.Now().Format("2006-01-02")
	} else if _, e := time.Parse("2006-01-02", asof); e != nil {
		s.fail(w, r, &problem{400, "invalid_as_of_date"})
		return
	}
	s.query(w, r, `SELECT ledger.balance_sheet($1::date)`, asof)
}
func (s *Server) incomeStatement(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	to := q.Get("to")
	if to == "" {
		to = time.Now().Format("2006-01-02")
	} else if _, e := time.Parse("2006-01-02", to); e != nil {
		s.fail(w, r, &problem{400, "invalid_to_date"})
		return
	}
	var from any
	if q.Get("from") != "" {
		if _, e := time.Parse("2006-01-02", q.Get("from")); e != nil {
			s.fail(w, r, &problem{400, "invalid_from_date"})
			return
		}
		from = q.Get("from")
	}
	s.query(w, r, `SELECT ledger.income_statement($1::date,$2::date)`, from, to)
}
func (s *Server) audit(w http.ResponseWriter, r *http.Request) {
	after := int64(0)
	if q := r.URL.Query().Get("after"); q != "" {
		n, e := strconv.ParseInt(q, 10, 64)
		if e != nil || n < 0 {
			s.fail(w, r, &problem{400, "invalid_pagination"})
			return
		}
		after = n
	}
	s.query(w, r, `SELECT audit.list_events($1,100)`, after)
}
func (s *Server) closePeriod(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Version int64  `json:"expected_version"`
		Reason  string `json:"reason"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	if !accounting.UUIDPattern.MatchString(r.PathValue("id")) || in.Version < 1 || len(in.Reason) < 3 || len(in.Reason) > 1000 {
		s.fail(w, r, &problem{400, "invalid_period_close"})
		return
	}
	var data json.RawMessage
	e := s.scoped(r, func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), `SELECT ledger.close_period_command($1,$2::uuid,$3,$4)`, r.Header.Get("Idempotency-Key"), r.PathValue("id"), in.Version, in.Reason).Scan(&data)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, 200, data)
}

func (s *Server) periodClosePreview(w http.ResponseWriter, r *http.Request) {
	if !accounting.UUIDPattern.MatchString(r.PathValue("id")) {
		s.fail(w, r, &problem{400, "invalid_id"})
		return
	}
	s.query(w, r, `SELECT ledger.period_close_preview($1::uuid)`, r.PathValue("id"))
}

func (s *Server) createFiscalYear(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Name      string `json:"name"`
		StartDate string `json:"start_date"`
		EndDate   string `json:"end_date"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	if len(in.Name) < 1 || len(in.Name) > 200 || len(in.StartDate) != 10 || len(in.EndDate) != 10 {
		s.fail(w, r, &problem{400, "invalid_fiscal_year"})
		return
	}

	var id string
	e := s.scoped(r, func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), `SELECT ledger.create_fiscal_year($1, $2::date, $3::date)`, in.Name, in.StartDate, in.EndDate).Scan(&id)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, 201, map[string]string{"id": id})
}
