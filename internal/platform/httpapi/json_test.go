package httpapi

import "testing"

func TestAmbiguousJSONRejected(t *testing.T) {
	for _, s := range []string{`{"amount":"100","amount":"200"}`, `{"lines":[{"debit":"1","debit":"2"}]}`, `{} {}`, `{"x":`} {
		if validateJSON([]byte(s)) == nil {
			t.Fatal("ambiguous request accepted")
		}
	}
	if e := validateJSON([]byte(`{"lines":[{"amount":"100"},{"amount":"200"}]}`)); e != nil {
		t.Fatal(e)
	}
}
