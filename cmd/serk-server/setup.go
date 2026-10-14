package main

import (
	"context"
	"crypto/subtle"
	_ "embed"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/demo"
)

//go:embed setup.html
var setupPage []byte

// setup serves the first-run wizard until a company exists. Only this computer may use it,
// or a browser that presents the one-time token written to <data>/setup-token.txt.
type setup struct {
	mu       sync.Mutex
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
	st.needed = n == 0
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

func (st *setup) authorised(r *http.Request, token string) bool {
	return loopback(r) || (token != "" && subtle.ConstantTimeCompare([]byte(token), []byte(st.token)) == 1)
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
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Header().Set("Cache-Control", "no-store")
			w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
			w.Header().Set("X-Frame-Options", "DENY")
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
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
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
	st.mu.Lock()
	defer st.mu.Unlock()
	if !st.needed {
		reply(409, map[string]any{"error": "Setup is already complete. Sign in instead."})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer cancel()
	c, e := pgx.Connect(ctx, st.operator)
	if e != nil {
		reply(503, map[string]any{"error": "The database is not available."})
		return
	}
	defer c.Close(ctx)
	if _, e = demo.CreateCompany(ctx, c, in.NewCompany); e != nil {
		slog.Error("setup_failed", "error", e.Error())
		reply(422, map[string]any{"error": "Setup failed: " + e.Error()})
		return
	}
	if in.Practice {
		if exists, err := demo.Exists(ctx, c); err == nil && !exists {
			if err = demo.Seed(ctx, c, in.AdminPassword, time.Now().UTC()); err != nil {
				slog.Error("practice_workspace_failed", "error", err.Error())
			} else {
				st.settings.Practice = true
				_ = st.settings.save(st.data)
			}
		}
	}
	st.needed = false
	_ = os.Remove(filepath.Join(st.data, "setup-token.txt"))
	slog.Info("setup_complete", "workspace", in.Workspace)
	reply(201, map[string]any{"workspace": in.Workspace, "email": in.AdminEmail, "practice": in.Practice})
}
