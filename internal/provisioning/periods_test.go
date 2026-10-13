package provisioning

import "testing"

func TestEthiopianPeriods(t *testing.T) {
	for _, tc := range []struct{ start, pagumeEnd, end string }{
		{"2026-07-08", "2026-09-10", "2027-07-07"}, // Pagume 5 days
		{"2027-07-08", "2027-09-11", "2028-07-07"}, // Pagume 6 days (2028 is a Gregorian leap year)
	} {
		p, e := Periods(Company{Calendar: "ETHIOPIAN", YearStart: tc.start})
		if e != nil || len(p) != 13 {
			t.Fatal(tc.start, len(p), e)
		}
		if p[2].Name != "03 Pagume" || p[2].End.Format("2006-01-02") != tc.pagumeEnd || p[12].Name != "13 Sene" || p[12].End.Format("2006-01-02") != tc.end {
			t.Fatal(tc.start, p[2], p[12])
		}
		for i := 1; i < len(p); i++ {
			if !p[i].Start.Equal(p[i-1].End.AddDate(0, 0, 1)) {
				t.Fatal("gap", p[i-1], p[i])
			}
		}
	}
	if _, e := Periods(Company{Calendar: "ETHIOPIAN", YearStart: "2026-07-01"}); e == nil {
		t.Fatal("non-Hamle start accepted")
	}
}
