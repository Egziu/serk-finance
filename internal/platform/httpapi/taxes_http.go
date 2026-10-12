package httpapi

import "net/http"

func (s *Server) createTaxAgency(w http.ResponseWriter, r *http.Request) {
	s.masterWrite(w, r, "AGENCY")
}
func (s *Server) createTaxRate(w http.ResponseWriter, r *http.Request) { s.masterWrite(w, r, "RATE") }
func (s *Server) listTaxAgencies(w http.ResponseWriter, r *http.Request) {
	s.moduleQuery(w, r, "taxes.read", `SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) FROM (SELECT id,name,code FROM taxes.tax_agencies ORDER BY name,id LIMIT 200) t`)
}
func (s *Server) listTaxRates(w http.ResponseWriter, r *http.Request) {
	s.moduleQuery(w, r, "taxes.read", `SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) FROM (SELECT r.id,r.agency_id,r.name,r.code,r.rate_percent::text AS rate_percent,r.active,r.effective_from,r.effective_to,a.name AS agency_name FROM taxes.tax_rates r LEFT JOIN taxes.tax_agencies a ON a.id=r.agency_id ORDER BY r.code,r.id LIMIT 200) t`)
}
func (s *Server) taxLiability(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, "SELECT finance.tax_liability()")
}
