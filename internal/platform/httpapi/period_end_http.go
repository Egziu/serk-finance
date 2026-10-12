package httpapi

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/accounting"
)

// controlledCommands maps a URL resource to its database command. Every command is
// idempotent (Idempotency-Key), dual-controlled and audited inside PostgreSQL.
var controlledCommands = map[string]struct {
	sql     string
	actions map[string]bool
}{
	"year-close":       {"SELECT ledger.year_close_command($1,$2,$3::jsonb)", map[string]bool{"request": true, "approve": true, "void": true}},
	"period-reopening": {"SELECT ledger.period_reopen_command($1,$2,$3::jsonb)", map[string]bool{"request": true, "approve": true, "void": true}},
	"adjustment":       {"SELECT finance.adjustment_command($1,$2,$3::jsonb)", map[string]bool{"create": true, "submit": true, "approve": true, "void": true}},
}

func (s *Server) controlledCommand(resource string) http.HandlerFunc {
	spec := controlledCommands[resource]
	return func(w http.ResponseWriter, r *http.Request) {
		action := r.PathValue("action")
		if !spec.actions[action] {
			s.fail(w, r, &problem{404, "not_found"})
			return
		}
		key := r.Header.Get("Idempotency-Key")
		if len(key) < 8 || len(key) > 128 {
			s.fail(w, r, &problem{400, "idempotency_key_required"})
			return
		}
		var body map[string]json.RawMessage
		if e := decode(w, r, &body); e != nil {
			s.fail(w, r, e)
			return
		}
		if body == nil {
			s.fail(w, r, &problem{400, "invalid_request"})
			return
		}
		payload, e := json.Marshal(body)
		if e != nil {
			s.fail(w, r, e)
			return
		}
		var result json.RawMessage
		e = s.scoped(r, func(tx pgx.Tx) error {
			return tx.QueryRow(r.Context(), spec.sql, key, action, string(payload)).Scan(&result)
		})
		if e != nil {
			s.fail(w, r, e)
			return
		}
		write(w, 200, result)
	}
}

func (s *Server) yearClosePreview(w http.ResponseWriter, r *http.Request) {
	if !accounting.UUIDPattern.MatchString(r.PathValue("id")) {
		s.fail(w, r, &problem{400, "invalid_id"})
		return
	}
	s.query(w, r, `SELECT ledger.year_close_preview($1::uuid)`, r.PathValue("id"))
}

func (s *Server) listPeriodEnd(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT jsonb_build_object(
	 'fiscal_years',coalesce((SELECT jsonb_agg(to_jsonb(y) ORDER BY y.start_date DESC) FROM ledger.fiscal_years y),'[]'),
	 'year_closings',coalesce((SELECT jsonb_agg(to_jsonb(c)||jsonb_build_object('net_result_minor',c.net_result_minor::text) ORDER BY c.created_at DESC) FROM ledger.year_closings c),'[]'),
	 'period_reopenings',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.created_at DESC) FROM (SELECT * FROM ledger.period_reopenings ORDER BY created_at DESC LIMIT 200) p),'[]'))`)
}

func (s *Server) listAdjustments(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT finance.list_adjustments()`)
}

func (s *Server) taxReport(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	to, e := time.Parse("2006-01-02", q.Get("to"))
	if e != nil {
		s.fail(w, r, &problem{400, "invalid_report_parameters"})
		return
	}
	var from any
	if q.Get("from") != "" {
		f, e := time.Parse("2006-01-02", q.Get("from"))
		if e != nil || f.After(to) {
			s.fail(w, r, &problem{400, "invalid_report_parameters"})
			return
		}
		from = q.Get("from")
	}
	s.query(w, r, `SELECT finance.tax_report($1::date,$2::date)`, from, q.Get("to"))
}

func (s *Server) fxPolicy(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT jsonb_build_object('tolerance_bps',coalesce((SELECT tolerance_bps FROM ledger.fx_policies),200),
	 'max_age_days',coalesce((SELECT max_age_days FROM ledger.fx_policies),7))`)
}

func (s *Server) setFXPolicy(w http.ResponseWriter, r *http.Request) {
	var in struct {
		ToleranceBPS int  `json:"tolerance_bps"`
		MaxAgeDays   *int `json:"max_age_days,omitempty"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	s.query(w, r, `SELECT ledger.set_fx_policy($1,coalesce($2::integer,(SELECT max_age_days FROM ledger.fx_policies),7))`, in.ToleranceBPS, in.MaxAgeDays)
}

func (s *Server) recordedRate(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if _, e := time.Parse("2006-01-02", q.Get("date")); e != nil || len(q.Get("currency")) != 3 {
		s.fail(w, r, &problem{400, "invalid_report_parameters"})
		return
	}
	s.query(w, r, `SELECT jsonb_build_object('rate',ledger.recorded_rate($1,$2::date)::text)`, q.Get("currency"), q.Get("date"))
}
