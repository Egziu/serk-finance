package httpapi
import("net/http";"time")
func(s *Server)dashboardMetrics(w http.ResponseWriter,r *http.Request){date:=r.URL.Query().Get("as_of");if date==""{date=time.Now().UTC().Format("2006-01-02")};s.query(w,r,"SELECT finance.dashboard($1::date)",date)}
