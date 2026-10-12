package httpapi

import (
	"net/http"

	"github.com/jackc/pgx/v5"
)

type exchangeRate struct {
	ID              string `json:"id"`
	Date            string `json:"date"`
	BaseCurrency    string `json:"base_currency"`
	ForeignCurrency string `json:"foreign_currency"`
	ExchangeRate    string `json:"exchange_rate"`
}

func (s *Server) listCurrencies(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT coalesce(json_agg(json_build_object('code', code, 'name', name, 'symbol', symbol, 'active', active) ORDER BY code), '[]'::json) FROM core.currencies WHERE active = true`)
}

func (s *Server) listExchangeRates(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, `SELECT coalesce(json_agg(json_build_object('id', id, 'date', date, 'base_currency', base_currency, 'foreign_currency', foreign_currency, 'exchange_rate', exchange_rate::text) ORDER BY date DESC), '[]'::json) FROM core.exchange_rates WHERE tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company())`)
}

type addExchangeRateRequest struct {
	Date            string `json:"date"`
	ForeignCurrency string `json:"foreign_currency"`
	ExchangeRate    string `json:"exchange_rate"`
}

func (s *Server) addExchangeRate(w http.ResponseWriter, r *http.Request) {
	var in addExchangeRateRequest
	if e := decode(w, r, &in); e != nil {
		s.fail(w, r, e)
		return
	}

	var newID string
	e := s.scoped(r, func(tx pgx.Tx) error {
		if _, err := tx.Exec(r.Context(), "SELECT security.require('configuration.manage')"); err != nil {
			return err
		}
		return tx.QueryRow(r.Context(),
			`INSERT INTO core.exchange_rates (tenant_id, company_id, date, base_currency, foreign_currency, exchange_rate) 
			 VALUES ((SELECT security.tenant()), (SELECT security.company()), $1, (SELECT functional_currency FROM organization.companies WHERE id=(SELECT security.company())), $2, $3) RETURNING id`,
			in.Date, in.ForeignCurrency, in.ExchangeRate,
		).Scan(&newID)
	})
	if e != nil {
		s.fail(w, r, e)
		return
	}
	write(w, 201, map[string]string{"id": newID})
}
