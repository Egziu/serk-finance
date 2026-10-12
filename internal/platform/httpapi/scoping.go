package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/accounting"
)

func (s *Server) cookieName() string {
	if s.Config.SecureCookies {
		return "__Host-serk_session"
	}
	return "serk_session"
}
func (s *Server) token(r *http.Request) string {
	c, e := r.Cookie(s.cookieName())
	if e != nil {
		return ""
	}
	return c.Value
}
func (s *Server) cookie(w http.ResponseWriter, value string, maxAge int) {
	http.SetCookie(w, &http.Cookie{Name: s.cookieName(), Value: value, Path: "/", MaxAge: maxAge, HttpOnly: true, Secure: s.Config.SecureCookies, SameSite: http.SameSiteStrictMode})
}
func (s *Server) scoped(r *http.Request, fn func(pgx.Tx) error) error {
	cid := r.Header.Get("X-Company-ID")
	if !accounting.UUIDPattern.MatchString(cid) {
		return &problem{400, "company_id_required"}
	}
	t := s.token(r)
	if len(t) != 43 {
		return &problem{401, "unauthenticated"}
	}
	csrf := ""
	if r.Method != "GET" && r.Method != "HEAD" && r.Method != "OPTIONS" {
		csrf = r.Header.Get("X-CSRF-Token")
		if csrf == "" {
			return &problem{403, "csrf_required"}
		}
	}
	ip := s.clientIP(r)
	return s.DB.Scoped(r.Context(), t, cid, csrf, map[string]string{"request_id": requestID(r), "remote_ip": ip, "user_agent": truncate(r.UserAgent(), 300)}, func(tx pgx.Tx) error {
		if _, e := tx.Exec(r.Context(), `SELECT security.require_session_assurance($1,$2)`, t, s.Config.RequireMFA); e != nil {
			return e
		}
		return fn(tx)
	})
}
func truncate(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}
func (s *Server) query(w http.ResponseWriter, r *http.Request, sql string, args ...any) {
	var data json.RawMessage
	e := s.scoped(r, func(tx pgx.Tx) error { return tx.QueryRow(r.Context(), sql, args...).Scan(&data) })
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, 200, data)
}
