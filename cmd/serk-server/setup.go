package main

import (
	"context"
	"crypto/subtle"
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/demo"
)

//go:embed setup.html
var setupPage []byte

// setup serves the first-run wizard until a company exists. Only this computer may use it,
// or a browser that presents the one-time token written to <data>/setup-token.txt.
type setup struct {
	mu       sync.Mutex  // guards needed and settings; never held while setup runs
	running  atomic.Bool // one setup at a time
	needed   bool
	token    string
	operator string
	origins  map[string]bool
	settings *Settings
	data     string
}

func newSetup(ctx context.Context, operator, data string, s *Settings, origins []string) (*setup, error) {
	st := &setup{operator: operator, data: data, settings: s, origins: map[string]bool{}}
	for _, o := range origins {
		st.origins[o] = true
	}
	c, e := pgx.Connect(ctx, operator)
	if e != nil {
		return nil, e
	}
	defer c.Close(ctx)
	var n int
	if e = c.QueryRow(ctx, `SELECT count(*) FROM security.tenants WHERE slug<>$1`, demo.Slug).Scan(&n); e != nil {
		return nil, e
	}
	st.needed = n == 0 || s.PendingSetup != ""
	if st.needed {
		st.token = secret(18)
		_ = os.WriteFile(filepath.Join(data, "setup-token.txt"), []byte(st.token+"\n"), 0o600)
	}
	return st, nil
}

func (st *setup) isNeeded() bool { st.mu.Lock(); defer st.mu.Unlock(); return st.needed }

func loopback(r *http.Request) bool {
	host, _, e := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	return e == nil && ip != nil && ip.IsLoopback()
}

// authorised trusts this computer, unless the request came through a proxy (which would make
// every visitor look local); otherwise the one-time token is required.
func (st *setup) authorised(r *http.Request, token string) bool {
	proxied := r.Header.Get("X-Forwarded-For") != "" || r.Header.Get("Forwarded") != "" || r.Header.Get("X-Real-IP") != ""
	return (loopback(r) && !proxied) || (token != "" && subtle.ConstantTimeCompare([]byte(token), []byte(st.token)) == 1)
}

func setupHeaders(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("X-Frame-Options", "DENY")
	h.Set("Referrer-Policy", "no-referrer")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
}

func (st *setup) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !st.isNeeded() {
			if strings.HasPrefix(r.URL.Path, "/setup") {
				http.Redirect(w, r, "/", http.StatusSeeOther)
				return
			}
			next.ServeHTTP(w, r)
			return
		}
		switch {
		case r.Method == "GET" && (r.URL.Path == "/" || r.URL.Path == "/index.html"):
			target := "/setup"
			if t := r.URL.Query().Get("token"); t != "" {
				target += "?token=" + t
			}
			http.Redirect(w, r, target, http.StatusSeeOther)
		case r.Method == "GET" && r.URL.Path == "/setup":
			setupHeaders(w)
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = w.Write(setupPage)
		case r.Method == "POST" && r.URL.Path == "/setup/api":
			st.create(w, r)
		default:
			next.ServeHTTP(w, r)
		}
	})
}

func (st *setup) create(w http.ResponseWriter, r *http.Request) {
	reply := func(status int, v map[string]any) {
		setupHeaders(w)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(v)
	}
	if !st.origins[r.Header.Get("Origin")] || !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		reply(403, map[string]any{"error": "This page must be opened from the Serk Finance address."})
		return
	}
	var in struct {
		demo.NewCompany
		Token    string `json:"token"`
		Practice bool   `json:"practice_workspace"`
	}
	d := json.NewDecoder(io.LimitReader(r.Body, 64<<10))
	d.DisallowUnknownFields()
	if e := d.Decode(&in); e != nil {
		reply(400, map[string]any{"error": "The form could not be read."})
		return
	}
	if !st.authorised(r, in.Token) {
		reply(403, map[string]any{"error": "Open the setup page on the server computer, or use the address with the setup token."})
		return
	}
	if e := in.NewCompany.Validate(); e != nil {
		reply(422, map[string]any{"error": e.Error()})
		return
	}
	if !st.isNeeded() {
		reply(409, map[string]any{"error": "Setup is already complete. Sign in instead."})
		return
	}
	if !st.running.CompareAndSwap(false, true) {
		reply(409, map[string]any{"error": "Setup is already running. Wait for it to finish, then reload this page."})
		return
	}
	defer st.running.Store(false)
	if !st.isNeeded() { // another setup finished while this request waited
		reply(409, map[string]any{"error": "Setup is already complete. Sign in instead."})
		return
	}
	// Setup outlives a closed browser tab: it has its own deadline, not the request's.
	_ = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(6 * time.Minute))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	practice, e := st.run(ctx, in.NewCompany, in.Practice)
	if e != nil {
		var se *setupError
		if errors.As(e, &se) {
			reply(se.status, map[string]any{"error": se.message})
			return
		}
		slog.Error("setup_failed", "error", e.Error())
		reply(500, map[string]any{"error": "Setup did not finish. Nothing is lost: submit the form again with the same workspace and email to complete it. Details are in the server log."})
		return
	}
	slog.Info("setup_complete", "workspace", in.Workspace)
	out := map[string]any{"workspace": in.Workspace, "email": in.AdminEmail, "practice": practice != ""}
	if practice != "" {
		out["practice_password"] = practice
	}
	reply(201, out)
}

type setupError struct {
	status  int
	message string
}

func (e *setupError) Error() string { return e.message }

// run creates the company, or completes one whose setup was interrupted. It returns the
// practice workspace password when that workspace was created.
func (st *setup) run(ctx context.Context, n demo.NewCompany, practice bool) (string, error) {
	c, e := pgx.Connect(ctx, st.operator)
	if e != nil {
		return "", &setupError{503, "The database is not available. Restart Serk Finance and try again."}
	}
	defer c.Close(context.Background())
	var exists bool
	if e = c.QueryRow(ctx, `SELECT EXISTS(SELECT FROM security.tenants WHERE slug=$1)`, n.Workspace).Scan(&exists); e != nil {
		return "", e
	}
	st.mu.Lock()
	pending := st.settings.PendingSetup
	st.mu.Unlock()
	switch {
	case exists && pending == n.Workspace:
		// An earlier attempt provisioned the company; finish its configuration.
		var admin bool
		if e = c.QueryRow(ctx, `SELECT EXISTS(SELECT FROM security.users u JOIN security.tenants t ON t.id=u.tenant_id WHERE t.slug=$1 AND lower(u.email)=lower($2))`,
			n.Workspace, n.AdminEmail).Scan(&admin); e != nil {
			return "", e
		}
		if !admin {
			return "", &setupError{409, "Use the same administrator email as in the first attempt."}
		}
		if e = demo.ConfigureCompany(ctx, c, n); e != nil {
			return "", e
		}
	case exists:
		return "", &setupError{409, "That workspace name is already used. Choose another."}
	default:
		if pending != "" && pending != n.Workspace {
			// The earlier attempt created nothing (its workspace does not exist): start afresh.
			var earlier bool
			if e = c.QueryRow(ctx, `SELECT EXISTS(SELECT FROM security.tenants WHERE slug=$1)`, pending).Scan(&earlier); e != nil {
				return "", e
			}
			if !earlier {
				pending = ""
			}
		}
		if pending != "" && pending != n.Workspace {
			return "", &setupError{409, "An earlier setup for workspace " + pending + " did not finish. Submit the form again with that workspace to complete it."}
		}
		if e = st.update(func(s *Settings) { s.PendingSetup = n.Workspace }); e != nil {
			return "", e
		}
		if _, e = demo.CreateCompany(ctx, c, n); e != nil {
			return "", e
		}
	}
	password := ""
	if practice {
		if ok, err := demo.Exists(ctx, c); err == nil && !ok {
			password = practicePassword()
			if err = demo.Seed(ctx, c, password, time.Now().UTC()); err != nil {
				slog.Error("practice_workspace_failed", "error", err.Error())
				password = ""
			} else if err = st.update(func(s *Settings) { s.Practice, s.PracticePassword = true, password }); err != nil {
				slog.Error("practice_workspace_settings_failed", "error", err.Error())
			}
		}
	}
	if e = st.update(func(s *Settings) { s.PendingSetup = "" }); e != nil {
		return "", e
	}
	st.mu.Lock()
	st.needed = false
	st.mu.Unlock()
	_ = os.Remove(filepath.Join(st.data, "setup-token.txt"))
	return password, nil
}

// update changes and saves the settings file.
func (st *setup) update(change func(*Settings)) error {
	st.mu.Lock()
	defer st.mu.Unlock()
	change(st.settings)
	return st.settings.save(st.data)
}
