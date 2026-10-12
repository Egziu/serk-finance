package accounting

import (
	"fmt"
	"math/big"
	"testing"
)

func TestMinorRejectsUnsafeRepresentations(t *testing.T) {
	for _, s := range []string{"-1", "1.0", "1e3", "NaN", "Infinity", " 1", "01", "", "10000000000000000000000000000"} {
		t.Run(s, func(t *testing.T) {
			if _, e := Minor(s); e == nil {
				t.Fatal("accepted", s)
			}
		})
	}
}
func TestExactLargeMoney(t *testing.T) {
	n, e := Minor("9999999999999999999999999999")
	if e != nil {
		t.Fatal(e)
	}
	if n.String() != "9999999999999999999999999999" {
		t.Fatal(n)
	}
}
func TestConversion(t *testing.T) {
	for _, c := range []struct {
		n, r     string
		src, dst int
		want     string
	}{{"101", "0.5", 2, 2, "51"}, {"100", "125.75", 2, 2, "12575"}, {"100", "2", 0, 2, "20000"}, {"250", "1", 2, 0, "3"}, {"0", "1", 2, 2, "0"}} {
		got, e := ConvertMinor(c.n, c.r, c.src, c.dst)
		if e != nil || got != c.want {
			t.Fatalf("%+v got %s err %v", c, got, e)
		}
	}
}
func TestJournalProperties(t *testing.T) {
	for i := int64(1); i < 5000; i++ {
		a := new(big.Int).Mul(big.NewInt(i), big.NewInt(129938713))
		j := CreateJournal{BranchID: "00000000-0000-0000-0000-000000000001", Date: "2026-09-14", Description: "Property test", Currency: "ETB", FXRate: "1", Reason: "Test", Lines: []Line{{AccountID: "00000000-0000-0000-0000-000000000002", Debit: a.String(), Credit: "0"}, {AccountID: "00000000-0000-0000-0000-000000000003", Debit: "0", Credit: a.String()}}}
		if e := j.Validate(); e != nil {
			t.Fatal(e)
		}
		j.Lines[1].Credit = fmt.Sprint(i)
		if e := j.Validate(); e == nil {
			t.Fatal("unbalanced accepted")
		}
	}
}
func FuzzMoney(f *testing.F) {
	for _, s := range []string{"0", "100", "NaN", "9223372036854775808"} {
		f.Add(s)
	}
	f.Fuzz(func(t *testing.T, s string) {
		n, e := Minor(s)
		if e == nil && (n.Sign() < 0 || n.String() != s) {
			t.Fatal("noncanonical money")
		}
	})
}
