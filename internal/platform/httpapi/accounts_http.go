package httpapi

import (
	"net/http"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/accounting"
)

// List accounts
func (s *Server) listAccounts(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT ledger.list_accounts()`)
}

type createAccountRequest struct {
	Code              string  `json:"code"`
	Name              string  `json:"name"`
	Type              string  `json:"type"`
	NormalBalance     string  `json:"normal_balance"`
	ParentID          *string `json:"parent_id,omitempty"`
	PostingAllowed    bool    `json:"posting_allowed"`
	ControlAccount    bool    `json:"control_account"`
	ReportingCategory string  `json:"reporting_category"`
	StatementClass    *string `json:"statement_class,omitempty"`
}

func (s *Server) createAccount(w http.ResponseWriter, r *http.Request) {
	var in createAccountRequest
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}

	var newID string
	e := s.scoped(r, func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(),
			`SELECT ledger.create_account($1, $2, $3, $4, $5::uuid, $6, $7, $8, $9)`,
			in.Code, in.Name, in.Type, in.NormalBalance, in.ParentID,
			in.PostingAllowed, in.ControlAccount, in.ReportingCategory, in.StatementClass,
		).Scan(&newID)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}

	write(w, 201, map[string]string{"id": newID})
}

type updateAccountRequest struct {
	Name              string  `json:"name"`
	ParentID          *string `json:"parent_id,omitempty"`
	Active            bool    `json:"active"`
	PostingAllowed    bool    `json:"posting_allowed"`
	ReportingCategory string  `json:"reporting_category"`
	StatementClass    *string `json:"statement_class,omitempty"`
}

func (s *Server) updateAccount(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !accounting.UUIDPattern.MatchString(id) {
		s.fail(w, r, &problem{400, "invalid_id"})
		return
	}

	var in updateAccountRequest
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}

	e := s.scoped(r, func(tx pgx.Tx) error {
		_, err := tx.Exec(r.Context(),
			`SELECT ledger.update_account($1::uuid, $2, $3::uuid, $4, $5, $6, $7)`,
			id, in.Name, in.ParentID, in.Active, in.PostingAllowed, in.ReportingCategory, in.StatementClass,
		)
		return err
	})

	if e != nil {
		s.fail(w, r, e)
		return
	}

	write(w, 204, nil)
}

func (s *Server) createBranch(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Code string `json:"code"`
		Name string `json:"name"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}

	var newID string
	e := s.scoped(r, func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(),
			`SELECT organization.create_branch($1, $2)`,
			in.Code, in.Name,
		).Scan(&newID)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}

	write(w, 201, map[string]string{"id": newID})
}

func (s *Server) createDimension(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Kind string `json:"kind"`
		Code string `json:"code"`
		Name string `json:"name"`
	}
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}

	var newID string
	e := s.scoped(r, func(tx pgx.Tx) error {
		return tx.QueryRow(r.Context(),
			`SELECT ledger.create_dimension($1, $2, $3)`,
			in.Kind, in.Code, in.Name,
		).Scan(&newID)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}

	write(w, 201, map[string]string{"id": newID})
}
