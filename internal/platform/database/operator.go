package database

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/platform/config"
)

// Operator is used only by offline administrative binaries, never by the API.
func Operator(ctx context.Context) (*pgx.Conn, error) {
	env, err := config.Environment()
	if err != nil {
		return nil, err
	}
	dsn, err := config.Secret("MIGRATOR_DATABASE_URL")
	if err != nil {
		return nil, err
	}
	c, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, errors.New("invalid migrator configuration")
	}
	if env != "development" && (c.TLSConfig == nil || c.TLSConfig.InsecureSkipVerify || len(c.Fallbacks) > 0) {
		return nil, errors.New("operator connection requires verified database TLS")
	}
	c.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	c.ConnectTimeout = 5 * time.Second
	return pgx.ConnectConfig(ctx, c)
}
