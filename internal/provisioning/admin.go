package provisioning

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"serk.finance/internal/auth"
)

type AdminRequest struct {
	Tenant   string `json:"tenant"`
	Email    string `json:"email"`
	Action   string `json:"action"`
	Reason   string `json:"reason"`
	Password string `json:"password,omitempty"`
	Name     string `json:"name,omitempty"`
}

// SuperAdminRole is created or completed by grant_super_admin. It always holds every permission.
const SuperAdminRole = "Super Admin"

// Administer locks the identity, applies a change, revokes existing sessions,
// and appends an operator audit event in one transaction.
//
// grant_super_admin bootstraps in-application administration: it ensures the
// "Super Admin" role holds every permission and grants it company-wide in every
// active company of the workspace. When the user does not exist yet, name and
// password create it first. Later user and role changes are made in the application.
func Administer(ctx context.Context, db *pgx.Conn, r AdminRequest) error {
	if len(strings.TrimSpace(r.Reason)) < 3 || len(r.Reason) > 1000 {
		return errors.New("a reason of 3 to 1000 bytes is required")
	}
	var hash string
	var err error
	switch r.Action {
	case "reset_password":
		hash, err = auth.Hash(r.Password)
		if err != nil {
			return err
		}
	case "disable_user", "enable_user", "revoke_sessions":
		if r.Password != "" || r.Name != "" {
			return errors.New("password and name are only accepted for reset_password or grant_super_admin")
		}
	case "grant_super_admin":
		if r.Password != "" {
			if len(r.Password) < 14 || len(r.Password) > 256 {
				return errors.New("password must contain 14 to 256 bytes")
			}
			if hash, err = auth.Hash(r.Password); err != nil {
				return err
			}
		}
	default:
		return errors.New("unsupported administration action")
	}
	tx, err := db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(context.WithoutCancel(ctx))
	email := strings.ToLower(strings.TrimSpace(r.Email))
	if r.Action == "grant_super_admin" {
		if err = grantSuperAdmin(ctx, tx, r, email, hash); err != nil {
			return err
		}
		return tx.Commit(ctx)
	}
	var tid, uid string
	err = tx.QueryRow(ctx, `SELECT u.tenant_id,u.id FROM security.users u JOIN security.tenants t ON t.id=u.tenant_id
	 WHERE t.slug=$1 AND u.email=$2 FOR UPDATE OF u`, r.Tenant, email).Scan(&tid, &uid)
	if err != nil {
		return err
	}
	switch r.Action {
	case "reset_password":
		_, err = tx.Exec(ctx, `UPDATE security.users SET password_hash=$1,version=version+1 WHERE id=$2`, hash, uid)
	case "disable_user", "enable_user":
		_, err = tx.Exec(ctx, `UPDATE security.users SET active=$1,version=version+1 WHERE id=$2`, r.Action == "enable_user", uid)
	}
	if err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `UPDATE security.sessions SET revoked_at=clock_timestamp() WHERE user_id=$1 AND revoked_at IS NULL`, uid); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO security.admin_events(tenant_id,target_user_id,action,reason) VALUES($1,$2,$3,$4)`, tid, uid, r.Action, r.Reason); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func grantSuperAdmin(ctx context.Context, tx pgx.Tx, r AdminRequest, email, hash string) error {
	var tid string
	if err := tx.QueryRow(ctx, `SELECT id FROM security.tenants WHERE slug=$1 AND active FOR UPDATE`, r.Tenant).Scan(&tid); err != nil {
		return errors.New("workspace not found or inactive")
	}
	var uid string
	var active bool
	err := tx.QueryRow(ctx, `SELECT id,active FROM security.users WHERE tenant_id=$1 AND email=$2 FOR UPDATE`, tid, email).Scan(&uid, &active)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		name := strings.TrimSpace(r.Name)
		if hash == "" || name == "" || len(name) > 200 {
			return errors.New("a new super administrator needs name and password")
		}
		if err = tx.QueryRow(ctx, `INSERT INTO security.users(tenant_id,email,display_name,password_hash) VALUES($1,$2,$3,$4) RETURNING id`,
			tid, email, name, hash).Scan(&uid); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO security.admin_events(tenant_id,target_user_id,action,reason) VALUES($1,$2,'create_user',$3)`, tid, uid, r.Reason); err != nil {
			return err
		}
	case err != nil:
		return err
	case hash != "" || r.Name != "":
		return errors.New("user exists: omit name and password (use reset_password to change a password)")
	case !active:
		return errors.New("user is disabled: enable_user first")
	}
	var rid string
	if err = tx.QueryRow(ctx, `INSERT INTO security.roles(tenant_id,name,description) VALUES($1,$2,'Full access, including users and roles')
	 ON CONFLICT (tenant_id,name) DO UPDATE SET version=security.roles.version+1 RETURNING id`, tid, SuperAdminRole).Scan(&rid); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `INSERT INTO security.role_permissions(tenant_id,role_id,permission)
	 SELECT $1,$2,code FROM security.permissions ON CONFLICT DO NOTHING`, tid, rid); err != nil {
		return err
	}
	tag, err := tx.Exec(ctx, `INSERT INTO security.memberships(tenant_id,company_id,user_id,role_id)
	 SELECT $1,c.id,$2,$3 FROM organization.companies c WHERE c.tenant_id=$1 AND c.active
	 ON CONFLICT (company_id,user_id,role_id) DO UPDATE SET branch_id=NULL,approval_limit_minor=NULL`, tid, uid, rid)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errors.New("workspace has no active company")
	}
	if _, err = tx.Exec(ctx, `UPDATE security.users SET version=version+1 WHERE id=$1`, uid); err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO security.admin_events(tenant_id,target_user_id,action,reason) VALUES($1,$2,'grant_super_admin',$3)`, tid, uid, r.Reason)
	return err
}
