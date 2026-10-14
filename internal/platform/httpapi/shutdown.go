package httpapi

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// serveWithShutdown serves until the listener fails, the process is signalled, or stop closes.
func serveWithShutdown(s *http.Server, stop <-chan struct{}) error {
	ctx, cancelSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancelSignals()
	done := make(chan error, 1)
	go func() { done <- s.ListenAndServe() }()
	select {
	case e := <-done:
		if errors.Is(e, http.ErrServerClosed) {
			return nil
		}
		return e
	case <-stop:
		c, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		return s.Shutdown(c)
	case <-ctx.Done():
		c, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		return s.Shutdown(c)
	}
}
