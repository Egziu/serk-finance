package httpapi

import (
	"container/list"
	"context"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"serk.finance/internal/auth"
)

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t, _ := auth.Token()
		id := truncate(t, 22)
		ctx, cancel := context.WithTimeout(context.WithValue(r.Context(), requestKey, id), 15*time.Second)
		defer cancel()
		r = r.WithContext(ctx)
		w.Header().Set("X-Request-ID", id)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Content-Security-Policy", csp(""))
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		if s.Config.SecureCookies {
			w.Header().Set("Strict-Transport-Security", "max-age=31536000")
		}
		if strings.HasPrefix(r.URL.Path, "/api/") {
			w.Header().Set("Cache-Control", "no-store")
		}
		defer func() {
			if recover() != nil {
				s.fail(w, r, &problem{500, "internal_error"})
			}
		}()
		if r.Method != "GET" && r.Method != "HEAD" && r.Method != "OPTIONS" && !s.allowedOrigin(r.Header.Get("Origin")) {
			s.fail(w, r, &problem{403, "origin_denied"})
			return
		}
		ip := sourceNetwork(s.clientIP(r))
		if !strings.HasPrefix(r.URL.Path, "/health/") && !s.limits.Allow("all:"+ip, 600) {
			w.Header().Set("Retry-After", "60")
			s.fail(w, r, &problem{429, "rate_limited"})
			return
		}
		start := time.Now()
		next.ServeHTTP(w, r)
		s.mu.Lock()
		s.requests++
		s.mu.Unlock()
		slog.Info("http_request", "request_id", id, "method", r.Method, "route", r.Pattern, "duration_ms", time.Since(start).Milliseconds())
	})
}

type window struct {
	since time.Time
	count int
	node  *list.Element
}
type limiter struct {
	mu      sync.Mutex
	entries map[string]window
	recent  list.List
}

func (l *limiter) Allow(key string, max int) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	if l.entries == nil {
		l.entries = make(map[string]window)
	}
	w, found := l.entries[key]
	if !found {
		// Capacity pressure evicts the least recently used key, never all users.
		// Persistent login quotas remain independent of this best-effort edge cache.
		if len(l.entries) >= 10000 {
			old := l.recent.Back()
			delete(l.entries, old.Value.(string))
			l.recent.Remove(old)
		}
		w.node = l.recent.PushFront(key)
	} else {
		l.recent.MoveToFront(w.node)
	}
	if now.Sub(w.since) > time.Minute {
		w.since, w.count = now, 0
	}
	if w.count <= max {
		w.count++
	}
	l.entries[key] = w
	return w.count <= max
}

func (s *Server) allowedOrigin(o string) bool {
	if o == s.Config.Origin {
		return true
	}
	for _, x := range s.Config.ExtraOrigins {
		if o == x {
			return true
		}
	}
	return false
}
