package httpapi

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// Application errors may name the offending field; PostgreSQL's own details never cross.
func TestErrorFieldOnlyForApplicationCodes(t *testing.T) {
	s := &Server{}
	cases := []struct {
		pg        *pgconn.PgError
		code      string
		wantField string
	}{
		{&pgconn.PgError{Code: "23514", Message: "account_type_not_allowed", Detail: "income_account_id"}, "account_type_not_allowed", "income_account_id"},
		{&pgconn.PgError{Code: "23514", Message: "account_reserved", Detail: "Key (id)=(42) is secret"}, "account_reserved", ""},
		{&pgconn.PgError{Code: "23505", Message: "duplicate key value violates unique constraint", Detail: "secret_value"}, "duplicate_record", ""},
	}
	for i, c := range cases {
		rr := httptest.NewRecorder()
		s.fail(rr, httptest.NewRequest("POST", "/x", nil), c.pg)
		var body struct {
			Error struct {
				Code  string `json:"code"`
				Field string `json:"field"`
			} `json:"error"`
		}
		if e := json.Unmarshal(rr.Body.Bytes(), &body); e != nil {
			t.Fatal(e)
		}
		if body.Error.Code != c.code || body.Error.Field != c.wantField {
			t.Fatalf("case %d: got %+v", i, body.Error)
		}
	}
}
