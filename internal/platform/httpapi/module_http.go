package httpapi

import (
	"encoding/json"
	"github.com/jackc/pgx/v5"
	"net/http"
)

// Financial JSON goes directly to PostgreSQL numeric validation; never through float64.
func (s *Server) moduleWrite(w http.ResponseWriter, r *http.Request, sql string, args ...any) {
	var body json.RawMessage
	if e := decode(w, r, &body); e != nil {
		s.fail(w, r, e)
		return
	}
	args = append(args, string(body))
	var result json.RawMessage
	e := s.scoped(r, func(tx pgx.Tx) error { return tx.QueryRow(r.Context(), sql, args...).Scan(&result) })
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, 200, result)
}

func (s *Server) masterWrite(w http.ResponseWriter, r *http.Request, kind string) {
	s.moduleWrite(w, r, "SELECT finance.create_master($1,$2::jsonb)", kind)
}

func (s *Server) documentWrite(w http.ResponseWriter, r *http.Request, kind, action string) {
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
	if id := r.PathValue("id"); id != "" {
		var supplied string
		if raw, ok := body["id"]; ok {
			if json.Unmarshal(raw, &supplied) != nil || supplied != id {
				s.fail(w, r, &problem{400, "invalid_request"})
				return
			}
		}
		body["id"], _ = json.Marshal(id)
	}
	payload, e := json.Marshal(body)
	if e != nil {
		s.fail(w, r, e)
		return
	}
	var result json.RawMessage
	sql := "SELECT finance.document_command($1,$2,$3,$4::jsonb)"
	if action == "reverse" || action == "reverse-approve" || action == "reverse-void" || action == "payment-void" {
		sql = "SELECT finance.reversal_command($1,$2,$3,$4::jsonb)"
	}
	e = s.scoped(r, func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), sql, key, kind, action, string(payload)).Scan(&result)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, 200, result)
}

func (s *Server) moduleQuery(w http.ResponseWriter, r *http.Request, permission, sql string, args ...any) {
	var result json.RawMessage
	e := s.scoped(r, func(tx pgx.Tx) error {
		if _, err := tx.Exec(r.Context(), "SELECT security.require($1)", permission); err != nil {
			return err
		}
		return tx.QueryRow(r.Context(), sql, args...).Scan(&result)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, 200, result)
}

func (s *Server) financeSettings(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, "SELECT finance.get_settings()")
}
func (s *Server) financeConfigure(w http.ResponseWriter, r *http.Request) {
	s.moduleWrite(w, r, "SELECT finance.configure($1::jsonb)")
}
func (s *Server) payrollPolicies(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, "SELECT finance.list_policies()")
}
func (s *Server) payrollPolicyCreate(w http.ResponseWriter, r *http.Request) {
	s.moduleWrite(w, r, "SELECT finance.policy_command('create',$1::jsonb)")
}
func (s *Server) payrollPolicyApprove(w http.ResponseWriter, r *http.Request) {
	s.moduleWrite(w, r, "SELECT finance.policy_command('approve',$1::jsonb)")
}
func (s *Server) listOpenings(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, "SELECT finance.list_documents('OPENING')")
}
func (s *Server) createOpening(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "OPENING", "create")
}
func (s *Server) openingAction(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "OPENING", r.PathValue("action"))
}
func (s *Server) listPayruns(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, "SELECT finance.list_documents('PAYROLL')")
}
func (s *Server) payrunAction(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "PAYROLL", r.PathValue("action"))
}
