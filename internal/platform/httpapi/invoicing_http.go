package httpapi

import "net/http"

func (s *Server) createCustomer(w http.ResponseWriter, r *http.Request) {
	s.masterWrite(w, r, "CUSTOMER")
}
func (s *Server) createVendor(w http.ResponseWriter, r *http.Request) { s.masterWrite(w, r, "VENDOR") }
func (s *Server) listCustomers(w http.ResponseWriter, r *http.Request) {
	s.moduleQuery(w, r, "sales.read", `SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM (SELECT id,name,email,phone,tax_id,active FROM invoicing.customers ORDER BY name,id LIMIT 200) t`)
}
func (s *Server) listVendors(w http.ResponseWriter, r *http.Request) {
	s.moduleQuery(w, r, "purchases.read", `SELECT coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) FROM (SELECT id,name,email,phone,tax_id,active FROM invoicing.vendors ORDER BY name,id LIMIT 200) t`)
}
func (s *Server) createInvoice(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "INVOICE", "create")
}
func (s *Server) createBill(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "BILL", "create")
}
func (s *Server) approveInvoice(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "INVOICE", "approve")
}
func (s *Server) approveBill(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "BILL", "approve")
}
func (s *Server) payInvoice(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "INVOICE", "pay")
}
func (s *Server) payBill(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "BILL", "pay")
}
func (s *Server) listInvoices(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, "SELECT finance.list_documents('INVOICE')")
}
func (s *Server) listBills(w http.ResponseWriter, r *http.Request) {
	s.query(w, r, "SELECT finance.list_documents('BILL')")
}
func (s *Server) invoiceAction(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "INVOICE", r.PathValue("action"))
}
func (s *Server) billAction(w http.ResponseWriter, r *http.Request) {
	s.documentWrite(w, r, "BILL", r.PathValue("action"))
}
