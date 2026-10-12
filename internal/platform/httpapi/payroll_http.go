package httpapi

import "net/http"

func (s *Server) createEmployee(w http.ResponseWriter,r *http.Request){s.masterWrite(w,r,"EMPLOYEE")}
func (s *Server) listEmployees(w http.ResponseWriter,r *http.Request){s.moduleQuery(w,r,"payroll.read",`SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]'::jsonb) FROM (SELECT id,branch_id,first_name,last_name,email,department,salary_amount::text AS salary_amount,pay_frequency,active FROM payroll.employees ORDER BY last_name,first_name,id LIMIT 200) t`)}
func (s *Server) runPayroll(w http.ResponseWriter,r *http.Request){s.documentWrite(w,r,"PAYROLL","create")}
