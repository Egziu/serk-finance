// Package accounting holds the financial value objects shared by command handlers.
// Stored-procedure guards independently enforce the same posting invariants.
package accounting

import (
	"errors"
	"math/big"
	"regexp"
	"time"
)

var ErrInvalid = errors.New("invalid_journal")
var minorPattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,27})$`)
var ratePattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,11})(\.[0-9]{1,12})?$`)
var UUIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// Minor accepts a canonical integer string, never a floating point JSON number.
func Minor(s string) (*big.Int, error) {
	if !minorPattern.MatchString(s) {
		return nil, ErrInvalid
	}
	n, _ := new(big.Int).SetString(s, 10)
	return n, nil
}

type Dimension struct {
	Kind string `json:"kind"`
	ID   string `json:"dimension_id"`
}
type Line struct {
	AccountID   string      `json:"account_id"`
	Description string      `json:"description"`
	Debit       string      `json:"debit_minor"`
	Credit      string      `json:"credit_minor"`
	Dimensions  []Dimension `json:"dimensions,omitempty"`
}
type CreateJournal struct {
	BranchID    string `json:"branch_id"`
	Date        string `json:"accounting_date"`
	Description string `json:"description"`
	Currency    string `json:"currency"`
	FXRate      string `json:"fx_rate"`
	Reason      string `json:"reason"`
	Lines       []Line `json:"lines"`
}

func (j CreateJournal) Validate() error {
	if !UUIDPattern.MatchString(j.BranchID) || len(j.Description) < 1 || len(j.Description) > 1000 || len(j.Reason) < 3 || len(j.Reason) > 1000 ||
		len(j.Lines) < 2 || len(j.Lines) > 500 || !regexp.MustCompile(`^[A-Z]{3}$`).MatchString(j.Currency) || !ratePattern.MatchString(j.FXRate) {
		return ErrInvalid
	}
	if _, e := time.Parse("2006-01-02", j.Date); e != nil {
		return ErrInvalid
	}
	rate, ok := new(big.Rat).SetString(j.FXRate)
	if !ok || rate.Sign() <= 0 {
		return ErrInvalid
	}
	dr, cr := new(big.Int), new(big.Int)
	for _, l := range j.Lines {
		if !UUIDPattern.MatchString(l.AccountID) || len(l.Description) > 1000 || len(l.Dimensions) > 11 {
			return ErrInvalid
		}
		d, e := Minor(l.Debit)
		if e != nil {
			return e
		}
		c, e := Minor(l.Credit)
		if e != nil {
			return e
		}
		if (d.Sign() == 0) == (c.Sign() == 0) {
			return ErrInvalid
		}
		dr.Add(dr, d)
		cr.Add(cr, c)
		seen := map[string]bool{}
		for _, dim := range l.Dimensions {
			if !UUIDPattern.MatchString(dim.ID) || seen[dim.Kind] {
				return ErrInvalid
			}
			seen[dim.Kind] = true
		}
	}
	if dr.Sign() <= 0 || dr.Cmp(cr) != 0 {
		return ErrInvalid
	}
	return nil
}

// ConvertMinor rounds exact rational conversion to nearest minor unit, half away from zero.
// Only nonnegative line-side values are valid. The database repeats this calculation.
func ConvertMinor(amount, rate string, sourceExponent, targetExponent int) (string, error) {
	n, e := Minor(amount)
	if e != nil {
		return "", e
	}
	if !ratePattern.MatchString(rate) || sourceExponent < 0 || sourceExponent > 4 || targetExponent < 0 || targetExponent > 4 {
		return "", ErrInvalid
	}
	r, ok := new(big.Rat).SetString(rate)
	if !ok || r.Sign() <= 0 {
		return "", ErrInvalid
	}
	r.Mul(r, new(big.Rat).SetInt(n))
	pow := func(n int) *big.Int { return new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(n)), nil) }
	r.Mul(r, new(big.Rat).SetFrac(pow(targetExponent), pow(sourceExponent)))
	q, rem := new(big.Int), new(big.Int)
	q.QuoRem(r.Num(), r.Denom(), rem)
	if new(big.Int).Mul(rem, big.NewInt(2)).Cmp(r.Denom()) >= 0 {
		q.Add(q, big.NewInt(1))
	}
	if len(q.String()) > 28 {
		return "", ErrInvalid
	}
	return q.String(), nil
}
