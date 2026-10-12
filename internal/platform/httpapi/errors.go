package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
	"serk.finance/internal/accounting"
)

type problem struct {
	status int
	code   string
}

func (p *problem) Error() string { return p.code }

type contextKey string

const requestKey contextKey = "request_id"

func requestID(r *http.Request) string { v, _ := r.Context().Value(requestKey).(string); return v }
func write(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func (s *Server) fail(w http.ResponseWriter, r *http.Request, e error) {
	status, code := 500, "internal_error"
	var p *problem
	var pg *pgconn.PgError
	if errors.As(e, &p) {
		status, code = p.status, p.code
	} else if errors.As(e, &pg) {
		switch pg.Code {
		case "28000":
			status, code = 401, "unauthenticated"
		case "42501":
			if pg.Message == "invalid_csrf" || pg.Message == "company_access_denied" || pg.Message == "access_denied" {
				status, code = 403, pg.Message
			} else {
				status, code = 403, "permission_denied"
			}
		case "P0002":
			status, code = 404, "not_found"
		case "22000":
			status, code = 409, "idempotency_conflict"
		case "40001":
			status, code = 409, "version_conflict"
		case "23505":
			status, code = 409, "duplicate_record"
		case "23503":
			status, code = 422, "invalid_reference"
		case "23514", "22023", "23502":
			status, code = 422, "validation_failed"
		case "22P02", "22007", "22008", "22003":
			status, code = 400, "invalid_value"
		case "55000":
			status, code = 409, "invalid_state"
		case "57014", "55P03", "40P01":
			status, code = 503, "retry_later"
		}
		// Only audited, static application codes may cross the database boundary.
		for _, safe := range []string{"journal_unbalanced", "period_not_open", "segregation_of_duties", "invalid_posting_account", "journal_immutable", "version_conflict", "invalid_transition", "inactive_branch", "reversal_mismatch", "invalid_currency_conversion", "approval_no_longer_authorized", "period_has_unfinished_journals", "reversal_date_before_original", "fx_rounding_not_configured", "fx_rounding_limit_exceeded",
			"mfa_required", "account_configuration_required", "insufficient_stock", "approved_payroll_policy_required", "payroll_period_already_processed", "use_controlled_stock_opening", "idempotency_key_required", "use_module_workflow", "invalid_payroll_policy", "invalid_payroll_period", "last_administrator", "privilege_escalation", "cannot_change_self", "role_in_use", "invalid_grant", "invalid_permission", "invalid_reason", "invalid_email", "invalid_name"} {
			if pg.Message == safe {
				code = safe
			}
		}
	} else if errors.Is(e, accounting.ErrInvalid) {
		status, code = 422, "invalid_journal"
	}
	if status >= 500 {
		slog.Error("request_failed", "request_id", requestID(r), "code", code, "error", e.Error())
		s.mu.Lock()
		s.failures++
		s.mu.Unlock()
	}
	write(w, status, map[string]any{"error": map[string]any{"code": code, "message": strings.ReplaceAll(code, "_", " "), "request_id": requestID(r)}})
}
func decode(w http.ResponseWriter, r *http.Request, v any) error {
	if strings.Split(r.Header.Get("Content-Type"), ";")[0] != "application/json" {
		return &problem{415, "json_required"}
	}
	r.Body = http.MaxBytesReader(w, r.Body, 512<<10)
	data, readErr := io.ReadAll(r.Body)
	if readErr != nil || validateJSON(data) != nil {
		return &problem{400, "invalid_json"}
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil {
		return &problem{400, "invalid_json"}
	}
	if e := d.Decode(&struct{}{}); e != io.EOF {
		return &problem{400, "invalid_json"}
	}
	return nil
}
