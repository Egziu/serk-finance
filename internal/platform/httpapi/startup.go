package httpapi

import (
	"context"
	"crypto/x509"
	"errors"
	"net"
	"syscall"

	"github.com/jackc/pgx/v5/pgconn"
)

// StartupError exposes only fixed diagnostics, never DSNs, SQL, paths, or secrets.
type StartupError struct {
	Stage, Code string
	cause       error
}

func (e *StartupError) Error() string { return e.Stage + ": " + e.Code }
func (e *StartupError) Unwrap() error { return e.cause }
func startupFailure(stage string, err error) error {
	code := "configuration_invalid"
	var pg *pgconn.PgError
	var dns *net.DNSError
	var unknown x509.UnknownAuthorityError
	var host x509.HostnameError
	var invalid x509.CertificateInvalidError
	switch {
	case errors.As(err, &pg):
		switch pg.Code {
		case "28P01", "28000":
			code = "database_authentication_failed"
		case "3D000":
			code = "database_not_found"
		case "42501":
			code = "database_permission_denied"
		case "42883", "42P01":
			code = "database_schema_missing"
		default:
			code = "database_sqlstate_" + pg.Code
		}
	case errors.As(err, &dns):
		code = "database_dns_failed"
	case errors.As(err, &unknown), errors.As(err, &host), errors.As(err, &invalid):
		code = "database_certificate_invalid"
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, syscall.ETIMEDOUT):
		code = "connection_timeout"
	case errors.Is(err, syscall.ECONNREFUSED):
		code = "connection_refused"
	case errors.Is(err, syscall.EADDRINUSE):
		code = "listen_address_in_use"
	default:
		switch err.Error() {
		case "database migration version does not match this release":
			code = "database_migration_version_mismatch"
		case "runtime database identity must be an unprivileged non-owner":
			code = "database_identity_unsafe"
		case "production requires verified database TLS without fallback":
			code = "database_verified_tls_required"
		case "web bundle missing; build web assets first":
			code = "web_bundle_missing"
		case "invalid trusted proxy CIDR", "unrestricted proxy trust is forbidden":
			code = "trusted_proxy_invalid"
		}
	}
	return &StartupError{Stage: stage, Code: code, cause: err}
}
