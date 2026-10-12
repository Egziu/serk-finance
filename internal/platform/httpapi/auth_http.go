package httpapi

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"serk.finance/internal/mfa"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/auth"
)

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	ip := sourceNetwork(s.clientIP(r))
	if !s.loginLimits.Allow("login:"+ip, 60) {
		w.Header().Set("Retry-After", "60")
		s.fail(w, r, &problem{429, "rate_limited"})
		return
	}
	var in struct {
		Tenant   string `json:"tenant"`
		Email    string `json:"email"`
		Password string `json:"password"`
		Code     string `json:"code,omitempty"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	if len(in.Tenant) > 63 || len(in.Email) > 254 || len(in.Password) > 256 || len(in.Code) > 6 {
		s.fail(w, r, &problem{400, "invalid_credentials"})
		return
	}
	if e := s.acquireLogin(r.Context()); e != nil {
		w.Header().Set("Retry-After", "2")
		s.fail(w, r, &problem{503, "authentication_busy"})
		return
	}
	defer func() { <-s.loginSlots }()
	var allowed bool
	if e := s.AuthDB.Transaction(r.Context(), func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), `SELECT security.consume_login_attempt($1,$2,$3)`, in.Tenant, strings.ToLower(strings.TrimSpace(in.Email)), ip).Scan(&allowed)
	}); e != nil {
		s.fail(w, r, e)
		return
	}
	if !allowed {
		w.Header().Set("Retry-After", "60")
		s.fail(w, r, &problem{429, "rate_limited"})
		return
	}
	var record json.RawMessage
	e := s.AuthDB.Transaction(r.Context(), func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), `SELECT security.login_record($1,$2)`, in.Tenant, strings.ToLower(strings.TrimSpace(in.Email))).Scan(&record)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	var user struct {
		ID         string `json:"user_id"`
		Hash       string `json:"password_hash"`
		MFASecret  string `json:"mfa_secret"`
		MFAVersion string `json:"mfa_version"`
	}
	_ = json.Unmarshal(record, &user)
	h := user.Hash
	if h == "" {
		h = s.dummyHash
	}
	valid := auth.Verify(h, in.Password)
	if !valid || user.ID == "" {
		s.fail(w, r, &problem{401, "invalid_credentials"})
		return
	}
	var mfaVersion any
	step := int64(-1)
	if user.MFASecret != "" && in.Code == "" {
		// Step one of the two-step login: the password is verified, the code comes next.
		challenge, e := auth.Token()
		if e != nil {
			s.fail(w, r, e)
			return
		}
		if e = s.AuthDB.Transaction(r.Context(), func(tx pgx.Tx) error {
			_, e := tx.Exec(r.Context(), `SELECT security.create_login_challenge($1::uuid,$2,$3,$4::uuid)`, user.ID, auth.Digest(challenge), user.Hash, user.MFAVersion)
			return e
		}); e != nil {
			s.fail(w, r, e)
			return
		}
		res := map[string]any{"mfa_required": true, "mfa_token": challenge, "expires_in": 300}
		if s.Config.DevShowOTP {
			if secret, err := mfa.Decrypt(s.Config.MFAKey, user.ID, user.MFASecret); err == nil {
				if code, err := mfa.CurrentCode(secret, time.Now()); err == nil {
					res["dev_code"] = code
				}
			}
		}
		write(w, 200, res)
		return
	}
	if user.MFASecret != "" {
		secret, err := mfa.Decrypt(s.Config.MFAKey, user.ID, user.MFASecret)
		if err != nil {
			s.fail(w, r, &problem{503, "authentication_unavailable"})
			return
		}
		var ok bool
		step, ok = mfa.MatchStep(secret, in.Code, time.Now())
		if !ok {
			s.fail(w, r, &problem{401, "invalid_credentials"})
			return
		}
		mfaVersion = user.MFAVersion
	} else if s.Config.RequireMFA {
		s.fail(w, r, &problem{401, "invalid_credentials"})
		return
	}
	s.issueSession(w, r, user.ID, user.Hash, mfaVersion, step, in.Tenant, in.Email, ip, nil)
}

// issueSession is the only place a session is created. before runs first inside the same transaction.
func (s *Server) issueSession(w http.ResponseWriter, r *http.Request, userID, hash string, mfaVersion any, step int64, tenant, email, ip string, before func(pgx.Tx) error) {
	t, e := auth.Token()
	if e != nil {
		s.fail(w, r, e)
		return
	}
	csrf, e := auth.Token()
	if e != nil {
		s.fail(w, r, e)
		return
	}
	e = s.AuthDB.Transaction(r.Context(), func(tx pgx.Tx) error {
		if before != nil {
			if e := before(tx); e != nil {
				return e
			}
		}
		// Rotate an existing session as part of the same login transaction.
		if old := s.token(r); old != "" {
			if _, e := tx.Exec(r.Context(), `SELECT security.revoke_session($1)`, old); e != nil {
				return e
			}
		}
		if _, e := tx.Exec(r.Context(), `SELECT security.issue_verified_session($1::uuid,$2,$3,$4,$5::uuid,$6,$7)`, userID, auth.Digest(t), csrf, hash, mfaVersion, step, s.Config.RequireMFA); e != nil {
			return e
		}
		_, e := tx.Exec(r.Context(), `SELECT security.reset_login_attempts($1,$2,$3)`, tenant, strings.ToLower(strings.TrimSpace(email)), ip)
		return e
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	s.cookie(w, t, 8*60*60)
	write(w, 200, map[string]string{"csrf_token": csrf})
}

// loginMFA is step two of the two-step login: the challenge from step one plus an authenticator code.
func (s *Server) loginMFA(w http.ResponseWriter, r *http.Request) {
	ip := sourceNetwork(s.clientIP(r))
	if !s.loginLimits.Allow("login:"+ip, 60) {
		w.Header().Set("Retry-After", "60")
		s.fail(w, r, &problem{429, "rate_limited"})
		return
	}
	var in struct {
		MFAToken string `json:"mfa_token"`
		Code     string `json:"code"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	if len(in.MFAToken) != 43 || len(in.Code) != 6 {
		s.fail(w, r, &problem{400, "invalid_credentials"})
		return
	}
	if e := s.acquireLogin(r.Context()); e != nil {
		w.Header().Set("Retry-After", "2")
		s.fail(w, r, &problem{503, "authentication_busy"})
		return
	}
	defer func() { <-s.loginSlots }()
	challenge := auth.Digest(in.MFAToken)
	// Committed on its own so a wrong code still uses up one of the challenge's attempts.
	var record json.RawMessage
	if e := s.AuthDB.Transaction(r.Context(), func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), `SELECT security.open_login_challenge($1)`, challenge).Scan(&record)
	}); e != nil {
		s.fail(w, r, &problem{401, "invalid_credentials"})
		return
	}
	var user struct {
		ID         string `json:"user_id"`
		Tenant     string `json:"tenant"`
		Email      string `json:"email"`
		Hash       string `json:"password_hash"`
		MFASecret  string `json:"mfa_secret"`
		MFAVersion string `json:"mfa_version"`
	}
	if json.Unmarshal(record, &user) != nil || user.ID == "" {
		s.fail(w, r, &problem{401, "invalid_credentials"})
		return
	}
	var allowed bool
	if e := s.AuthDB.Transaction(r.Context(), func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(), `SELECT security.consume_login_attempt($1,$2,$3)`, user.Tenant, user.Email, ip).Scan(&allowed)
	}); e != nil {
		s.fail(w, r, e)
		return
	}
	if !allowed {
		w.Header().Set("Retry-After", "60")
		s.fail(w, r, &problem{429, "rate_limited"})
		return
	}
	secret, err := mfa.Decrypt(s.Config.MFAKey, user.ID, user.MFASecret)
	if err != nil {
		s.fail(w, r, &problem{503, "authentication_unavailable"})
		return
	}
	step, ok := mfa.MatchStep(secret, in.Code, time.Now())
	if !ok {
		s.fail(w, r, &problem{401, "invalid_credentials"})
		return
	}
	s.issueSession(w, r, user.ID, user.Hash, user.MFAVersion, step, user.Tenant, user.Email, ip, func(tx pgx.Tx) error {
		_, e := tx.Exec(r.Context(), `SELECT security.finish_login_challenge($1)`, challenge)
		return e
	})
}
func (s *Server) sessionData(r *http.Request) (json.RawMessage, error) {
	var data json.RawMessage
	t := s.token(r)
	if len(t) != 43 {
		return nil, &problem{401, "unauthenticated"}
	}
	e := s.DB.Transaction(r.Context(), func(tx pgx.Tx) error {
		if _, e := tx.Exec(r.Context(), `SELECT security.require_session_assurance($1,$2)`, t, s.Config.RequireMFA); e != nil {
			return e
		}
		return tx.QueryRow(r.Context(), `SELECT security.session_info($1)`, t).Scan(&data)
	})
	return data, e
}
func (s *Server) session(w http.ResponseWriter, r *http.Request) {
	data, e := s.sessionData(r)
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, 200, data)
}
func (s *Server) logout(w http.ResponseWriter, r *http.Request) {
	data, e := s.sessionData(r)
	if e != nil {
		s.fail(w, r, e)
		return
	}
	var session struct {
		CSRF string `json:"csrf_token"`
	}
	_ = json.Unmarshal(data, &session)
	if subtle.ConstantTimeCompare([]byte(session.CSRF), []byte(r.Header.Get("X-CSRF-Token"))) != 1 {
		s.fail(w, r, &problem{403, "invalid_csrf"})
		return
	}
	e = s.AuthDB.Transaction(r.Context(), func(tx pgx.Tx) error {
		_, e := tx.Exec(r.Context(), `SELECT security.revoke_session($1)`, s.token(r))
		return e
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	s.cookie(w, "", -1)
	write(w, 200, map[string]string{"status": "signed_out"})
}
