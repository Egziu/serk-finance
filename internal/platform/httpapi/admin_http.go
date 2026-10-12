package httpapi

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strings"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/accounting"
	"serk.finance/internal/auth"
)

// Access management. Authorization, anti-escalation, the last-administrator rule and
// auditing are enforced by the security.admin_* database functions; this layer only
// validates shape, hashes passwords and maps errors.

type grantInput struct {
	RoleID        string  `json:"role_id"`
	BranchID      *string `json:"branch_id,omitempty"`
	ApprovalLimit *string `json:"approval_limit_minor,omitempty"`
}

var minorPattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,17})$`)

func validGrants(gs []grantInput) bool {
	if len(gs) > 50 {
		return false
	}
	for _, g := range gs {
		if !accounting.UUIDPattern.MatchString(g.RoleID) {
			return false
		}
		if g.BranchID != nil && *g.BranchID != "" && !accounting.UUIDPattern.MatchString(*g.BranchID) {
			return false
		}
		if g.ApprovalLimit != nil && *g.ApprovalLimit != "" && !minorPattern.MatchString(*g.ApprovalLimit) {
			return false
		}
	}
	return true
}

func validReason(s string) bool { n := len(strings.TrimSpace(s)); return n >= 3 && len(s) <= 1000 }

// Same policy as the operator reset_password command.
func validPassword(p string) bool { return len(p) >= 14 && len(p) <= 256 }

func (s *Server) adminCall(w http.ResponseWriter, r *http.Request, status int, sql string, args ...any) {
	var data json.RawMessage
	e := s.scoped(r, func(tx pgx.Tx) error { return tx.QueryRow(r.Context(), sql, args...).Scan(&data) })
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, status, data)
}

func (s *Server) adminCatalog(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT security.admin_catalog()`)
}

func (s *Server) adminCreateUser(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Email    string       `json:"email"`
		Name     string       `json:"display_name"`
		Password string       `json:"password"`
		Grants   []grantInput `json:"grants"`
		Reason   string       `json:"reason"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	if !validGrants(in.Grants) || !validReason(in.Reason) || len(in.Email) > 254 || len(in.Name) > 200 {
		s.fail(w, r, &problem{400, "invalid_request"})
		return
	}
	if !validPassword(in.Password) {
		s.fail(w, r, &problem{422, "weak_password"})
		return
	}
	hash, e := auth.Hash(in.Password)
	if e != nil {
		s.fail(w, r, e)
		return
	}
	if in.Grants == nil {
		in.Grants = []grantInput{}
	}
	grants, _ := json.Marshal(in.Grants)
	s.adminCall(w, r, 201, `SELECT security.admin_create_user($1,$2,$3,$4::jsonb,$5)`, in.Email, in.Name, hash, string(grants), in.Reason)
}

func (s *Server) adminUserAction(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !accounting.UUIDPattern.MatchString(id) {
		s.fail(w, r, &problem{400, "invalid_id"})
		return
	}
	switch r.PathValue("action") {
	case "update":
		var in struct {
			Version int64  `json:"expected_version"`
			Name    string `json:"display_name"`
			Active  *bool  `json:"active"`
			Reason  string `json:"reason"`
		}
		if e := decode(w, r, &in); e != nil {
			s.fail(w, r, e)
			return
		}
		if in.Version < 1 || in.Active == nil || !validReason(in.Reason) || len(in.Name) > 200 {
			s.fail(w, r, &problem{400, "invalid_request"})
			return
		}
		s.adminCall(w, r, 200, `SELECT security.admin_update_user($1::uuid,$2,$3,$4,$5)`, id, in.Version, in.Name, *in.Active, in.Reason)
	case "grants":
		var in struct {
			Version int64        `json:"expected_version"`
			Grants  []grantInput `json:"grants"`
			Reason  string       `json:"reason"`
		}
		if e := decode(w, r, &in); e != nil {
			s.fail(w, r, e)
			return
		}
		if in.Version < 1 || in.Grants == nil || !validGrants(in.Grants) || !validReason(in.Reason) {
			s.fail(w, r, &problem{400, "invalid_request"})
			return
		}
		grants, _ := json.Marshal(in.Grants)
		s.adminCall(w, r, 200, `SELECT security.admin_set_grants($1::uuid,$2,$3::jsonb,$4)`, id, in.Version, string(grants), in.Reason)
	case "password":
		var in struct {
			Version  int64  `json:"expected_version"`
			Password string `json:"password"`
			Reason   string `json:"reason"`
		}
		if e := decode(w, r, &in); e != nil {
			s.fail(w, r, e)
			return
		}
		if in.Version < 1 || !validReason(in.Reason) {
			s.fail(w, r, &problem{400, "invalid_request"})
			return
		}
		if !validPassword(in.Password) {
			s.fail(w, r, &problem{422, "weak_password"})
			return
		}
		hash, e := auth.Hash(in.Password)
		if e != nil {
			s.fail(w, r, e)
			return
		}
		s.adminCall(w, r, 200, `SELECT security.admin_reset_password($1::uuid,$2,$3,$4)`, id, in.Version, hash, in.Reason)
	default:
		s.fail(w, r, &problem{404, "not_found"})
	}
}

type roleInput struct {
	Version     int64    `json:"expected_version,omitempty"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Permissions []string `json:"permissions"`
	Reason      string   `json:"reason"`
}

func (r roleInput) valid() bool {
	return r.Permissions != nil && len(r.Permissions) <= 100 && len(r.Name) <= 80 && len(r.Description) <= 500 && validReason(r.Reason)
}

func (s *Server) adminCreateRole(w http.ResponseWriter, r *http.Request) {
	var in roleInput
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}
	if in.Version != 0 || !in.valid() {
		s.fail(w, r, &problem{400, "invalid_request"})
		return
	}
	s.adminCall(w, r, 201, `SELECT security.admin_create_role($1,$2,$3::text[],$4)`, in.Name, in.Description, in.Permissions, in.Reason)
}

func (s *Server) adminRoleAction(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !accounting.UUIDPattern.MatchString(id) {
		s.fail(w, r, &problem{400, "invalid_id"})
		return
	}
	switch r.PathValue("action") {
	case "update":
		var in roleInput
		if e := decode(w, r, &in); e != nil {
			s.fail(w, r, e)
			return
		}
		if in.Version < 1 || !in.valid() {
			s.fail(w, r, &problem{400, "invalid_request"})
			return
		}
		s.adminCall(w, r, 200, `SELECT security.admin_update_role($1::uuid,$2,$3,$4,$5::text[],$6)`, id, in.Version, in.Name, in.Description, in.Permissions, in.Reason)
	case "delete":
		var in struct {
			Version int64  `json:"expected_version"`
			Reason  string `json:"reason"`
		}
		if e := decode(w, r, &in); e != nil {
			s.fail(w, r, e)
			return
		}
		if in.Version < 1 || !validReason(in.Reason) {
			s.fail(w, r, &problem{400, "invalid_request"})
			return
		}
		s.adminCall(w, r, 200, `SELECT security.admin_delete_role($1::uuid,$2,$3)`, id, in.Version, in.Reason)
	default:
		s.fail(w, r, &problem{404, "not_found"})
	}
}
