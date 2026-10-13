package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/auth"
)

// profilePassword lets a signed-in user change their own password. The current password is
// verified here; the database accepts the change only while the stored hash is still the one
// verified, then revokes every session of the user so they sign in again.
func (s *Server) profilePassword(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Current string `json:"current_password"`
		New     string `json:"new_password"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	if len(in.Current) == 0 || len(in.Current) > 256 {
		s.fail(w, r, &problem{401, "invalid_credentials"})
		return
	}
	if !validPassword(in.New) || in.New == in.Current {
		s.fail(w, r, &problem{422, "weak_password"})
		return
	}
	if !s.loginLimits.Allow("password-change:"+auth.Digest(s.token(r)), 5) {
		s.fail(w, r, &problem{429, "rate_limited"})
		return
	}
	if e := s.scoped(r, func(tx pgx.Tx) error { return nil }); e != nil {
		s.fail(w, r, e)
		return
	}
	if e := s.acquireLogin(r.Context()); e != nil {
		s.fail(w, r, &problem{503, "authentication_busy"})
		return
	}
	defer func() { <-s.loginSlots }()
	var record json.RawMessage
	e := s.AuthDB.Transaction(r.Context(), func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), "SELECT security.profile_auth_record($1)", s.token(r)).Scan(&record)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	var user struct {
		ID   string `json:"user_id"`
		Hash string `json:"password_hash"`
	}
	if e = json.Unmarshal(record, &user); e != nil || user.ID == "" || !auth.Verify(user.Hash, in.Current) {
		s.fail(w, r, &problem{401, "invalid_credentials"})
		return
	}
	hash, e := auth.Hash(in.New)
	if e != nil {
		s.fail(w, r, e)
		return
	}
	var result json.RawMessage
	e = s.AuthDB.Transaction(r.Context(), func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), "SELECT security.change_own_password($1,$2,$3)", s.token(r), user.Hash, hash).Scan(&result)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	s.cookie(w, "", -1)
	write(w, 200, result)
}
