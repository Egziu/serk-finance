package provisioning

import (
	"context"
	"errors"
	"github.com/jackc/pgx/v5"
	"serk.finance/internal/mfa"
	"strings"
	"time"
)

type MFARequest struct {
	Tenant string `json:"tenant"`
	Email  string `json:"email"`
	Secret string `json:"secret"`
	Code   string `json:"code"`
	Reason string `json:"reason"`
}

// Enrollment/recovery requires operator credentials and proof of the new device.
// It has no disable/bypass action. Existing sessions and older devices are revoked.
func EnrollMFA(ctx context.Context, db *pgx.Conn, key []byte, r MFARequest) error {
	step, ok := mfa.MatchStep(r.Secret, r.Code, time.Now())
	if !ok || !mfa.ValidSecret(r.Secret) {
		return errors.New("invalid authenticator proof")
	}
	if len(strings.TrimSpace(r.Reason)) < 3 || len(r.Reason) > 1000 {
		return errors.New("enrollment reason required")
	}
	tx, e := db.Begin(ctx)
	if e != nil {
		return e
	}
	defer tx.Rollback(context.WithoutCancel(ctx))
	var uid, tid string
	e = tx.QueryRow(ctx, `SELECT u.id,u.tenant_id FROM security.users u JOIN security.tenants t ON t.id=u.tenant_id WHERE t.slug=$1 AND u.email=$2 AND u.active AND t.active FOR UPDATE OF u`, r.Tenant, strings.ToLower(strings.TrimSpace(r.Email))).Scan(&uid, &tid)
	if e != nil {
		return e
	}
	encrypted, e := mfa.Encrypt(key, uid, r.Secret)
	if e != nil {
		return e
	}
	_, e = tx.Exec(ctx, `INSERT INTO security.user_mfa(user_id,tenant_id,encrypted_secret,last_step) VALUES($1,$2,$3,$4) ON CONFLICT(user_id) DO UPDATE SET encrypted_secret=EXCLUDED.encrypted_secret,last_step=EXCLUDED.last_step,version=gen_random_uuid()`, uid, tid, encrypted, step)
	if e != nil {
		return e
	}
	_, e = tx.Exec(ctx, `UPDATE security.sessions SET revoked_at=clock_timestamp() WHERE user_id=$1 AND revoked_at IS NULL`, uid)
	if e != nil {
		return e
	}
	_, e = tx.Exec(ctx, `INSERT INTO security.admin_events(tenant_id,target_user_id,action,reason) VALUES($1,$2,'enroll_mfa',$3)`, tid, uid, r.Reason)
	if e != nil {
		return e
	}
	return tx.Commit(ctx)
}
