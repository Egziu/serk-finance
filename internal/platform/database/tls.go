package database

import (
	"errors"
	"os"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
)

// RequireTLS enforces verified TLS for every non-development database connection. The single
// exception is an operator-declared private network (SERK_DB_PRIVATE_NETWORK=true) where every
// configured host is a Railway private-network name: that network is already encrypted
// (WireGuard) and not reachable from the internet, and Railway's internal Postgres has no
// publicly verifiable certificate. Any other host still requires verified TLS.
func RequireTLS(environment string, c *pgconn.Config) error {
	if environment == "development" {
		return nil
	}
	if os.Getenv("SERK_DB_PRIVATE_NETWORK") == "true" && privateHost(c.Host) {
		for _, f := range c.Fallbacks {
			if !privateHost(f.Host) {
				return errors.New("production requires verified database TLS without fallback")
			}
		}
		return nil
	}
	if c.TLSConfig == nil || c.TLSConfig.InsecureSkipVerify || len(c.Fallbacks) > 0 {
		return errors.New("production requires verified database TLS without fallback")
	}
	return nil
}

func privateHost(h string) bool { return strings.HasSuffix(strings.ToLower(h), ".railway.internal") }
