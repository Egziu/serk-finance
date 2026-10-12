package httpapi

import (
	"context"
	"errors"
	"time"
)

// Bound both Argon2 memory (two workers) and waiting requests (sixteen).
// Transient bursts wait briefly; sustained overload receives a retryable 503.
func (s *Server) acquireLogin(ctx context.Context) error {
	select {
	case s.loginSlots <- struct{}{}:
		return nil
	default:
	}
	select {
	case s.loginQueue <- struct{}{}:
	default:
		return errors.New("login queue full")
	}
	defer func() { <-s.loginQueue }()
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case s.loginSlots <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return errors.New("login queue timeout")
	}
}
