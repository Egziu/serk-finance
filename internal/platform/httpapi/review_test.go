package httpapi

import (
	"context"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5/pgconn"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLimiterCapacityDoesNotDenyOtherUsers(t *testing.T) {
	l := &limiter{}
	for i := 0; i < 20000; i++ {
		if !l.Allow(fmt.Sprint("attacker:", i), 600) {
			t.Fatal("new source denied due to unrelated entries")
		}
		if i%100 == 0 {
			if !l.Allow("legitimate", 600) {
				t.Fatal("unrelated user globally blocked")
			}
		}
	}
	if len(l.entries) != 10000 || l.recent.Len() != 10000 {
		t.Fatal("unbounded cache")
	}
	for i := 0; i < 601; i++ {
		l.Allow("abusive", 600)
	}
	if l.Allow("abusive", 600) {
		t.Fatal("per-source quota bypass")
	}
	w := l.entries["abusive"]
	w.since = time.Now().Add(-2 * time.Minute)
	l.entries["abusive"] = w
	if !l.Allow("abusive", 600) {
		t.Fatal("expired window not reset")
	}
}
func TestIPv6RotationSharesQuota(t *testing.T) {
	if sourceNetwork("2001:db8:1:2::1") != sourceNetwork("2001:db8:1:2:ffff::2") {
		t.Fatal("IPv6 churn bypass")
	}
	if sourceNetwork("::ffff:192.0.2.1") != "192.0.2.1" {
		t.Fatal("mapped IPv4 bypass")
	}
}
func TestLoginBurstsQueueAndCancel(t *testing.T) {
	s := &Server{loginSlots: make(chan struct{}, 2), loginQueue: make(chan struct{}, 16)}
	for i := 0; i < 2; i++ {
		if e := s.acquireLogin(context.Background()); e != nil {
			t.Fatal(e)
		}
	}
	done := make(chan error, 1)
	go func() { done <- s.acquireLogin(context.Background()) }()
	deadline := time.Now().Add(time.Second)
	for len(s.loginQueue) != 1 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if len(s.loginQueue) != 1 {
		t.Fatal("third request refused instead of waiting")
	}
	<-s.loginSlots
	if e := <-done; e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if e := s.acquireLogin(ctx); !errors.Is(e, context.Canceled) {
		t.Fatal("cancellation failed", e)
	}
	if len(s.loginQueue) != 0 {
		t.Fatal("queue slot leaked")
	}
	for i := 0; i < cap(s.loginQueue); i++ {
		s.loginQueue <- struct{}{}
	}
	if e := s.acquireLogin(context.Background()); e == nil {
		t.Fatal("queue unbounded")
	}
}
func TestStaticDirectoriesAreNotListed(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, "assets"), 0700)
	os.WriteFile(filepath.Join(dir, "index.html"), []byte("root page"), 0600)
	os.WriteFile(filepath.Join(dir, "assets", "app.js"), []byte("console.log('ok')"), 0600)
	os.WriteFile(filepath.Join(dir, ".private"), []byte("private"), 0600)
	s, e := New(nil, nil, Config{Origin: "http://localhost:8080", StaticDir: dir})
	if e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct {
		path   string
		status int
	}{{"/", 200}, {"/assets/", 404}, {"/assets/app.js", 200}, {"/.private", 404}, {"/missing", 404}} {
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, httptest.NewRequest("GET", tc.path, nil))
		if rr.Code != tc.status {
			t.Fatal(tc, rr.Code, rr.Body.String())
		}
	}
}
func TestStartupDiagnosticsAreUsefulAndSecretFree(t *testing.T) {
	for _, tc := range []struct {
		err  error
		code string
	}{
		{&pgconn.PgError{Code: "28P01", Message: "secret=supersecret postgres://user:password@host"}, "database_authentication_failed"},
		{errors.New("database migration version does not match this release"), "database_migration_version_mismatch"},
		{errors.New("runtime database identity must be an unprivileged non-owner"), "database_identity_unsafe"},
		{errors.New("postgresql://user:supersecret@host/db"), "configuration_invalid"},
	} {
		e := startupFailure("authentication_database", tc.err).(*StartupError)
		if e.Code != tc.code || e.Error() != "authentication_database: "+tc.code {
			t.Fatal("unsafe or unhelpful diagnostic", e)
		}
	}
}
