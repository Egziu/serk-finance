# Account administration

## In-application users and roles (migration 012)

Administrators manage users and roles in the web app under **Users & roles**, or through `/api/v1/admin/*`.

| Permission | Allows |
|---|---|
| `user.manage` | Create users, change name, enable/disable, reset password, assign roles in the current company (with optional branch scope and approval limit) |
| `role.manage` | Create roles at any time, tick their permissions, rename, delete unused roles |

Both must be granted company-wide (a branch-scoped grant never administers). A **Super Admin** role holds every permission.

Rules enforced by the database functions `security.admin_*`, not only by the UI:

- **No privilege escalation.** You can only grant, change or remove permissions you hold yourself, and never a larger approval limit than your own. Otherwise: `privilege_escalation` (403).
- **Last administrator.** A company that has an administrator (a user with both permissions) always keeps one: `last_administrator` (409).
- **Own account.** You cannot disable yourself or reset your own password here: `cannot_change_self` (409).
- **Roles in use** cannot be deleted: `role_in_use` (409). Remove the role from every user first.
- Changes use `expected_version` (`version_conflict` on stale data), require a reason of 3–1000 characters, are serialized per workspace, and are written to the company audit hash chain and outbox (`user.created`, `user.updated`, `user.disabled`, `user.enabled`, `user.roles_changed`, `user.password_reset`, `role.created`, `role.updated`, `role.deleted`). No password or hash is ever recorded. `ledger.integrity_status()` verifies these events like journal events.
- Disabling a user or resetting a password signs the user out everywhere. Passwords must have 14–256 characters.

Not included yet: invitation emails, self-service password reset, MFA enrollment from the UI (use the MFA operator workflow), dual approval of administrative changes, and user management across companies at once (grants are managed per company selected in the sidebar).

### First super administrator (operator)

The first administrator of a workspace is created with the operator command, because nobody in the application can administer yet:

```json
{"tenant":"your-workspace","email":"admin@example.com","action":"grant_super_admin",
 "name":"Finance Administrator","password":"<14+ characters, delivered securely>",
 "reason":"First administrator, approved by CEO, ticket IAM-1"}
```

For an existing user omit `name` and `password`. The command creates or completes the **Super Admin** role with every permission, grants it company-wide in every active company, and records `create_user` / `grant_super_admin` in `security.admin_events`.

## Operator commands

The API runtime cannot provision workspaces or bootstrap the first administrator. Use the separate `tools` image or `go run ./cmd/admin` from an authorized operator environment, with `SERK_ENV` and a protected `MIGRATOR_DATABASE_URL`/`MIGRATOR_DATABASE_URL_FILE`.

Create a protected JSON file (mode 0600) with one request, then pass it on standard input:

```bash
go run ./cmd/admin < /protected/operator-request.json
```

For a container, use the tools image and `--entrypoint /app/admin`, with operator configuration supplied through your secret manager. Standard input remains the request channel; do not place passwords in shell arguments.

Example disable request:

```json
{
  "tenant": "your-workspace",
  "email": "user@example.com",
  "action": "disable_user",
  "reason": "Approved access termination, ticket IAM-123"
}
```

Supported actions: `disable_user`, `enable_user`, `revoke_sessions`, `reset_password`, `grant_super_admin`. Only `reset_password` and `grant_super_admin` (for a new user) accept a `password` field, which must contain 14–256 bytes and should be generated/delivered through an approved secret channel. Enabling a user does not restore any revoked sessions. Password reset does not reactivate a disabled user.

Each successful action locks the user, applies the change, revokes existing sessions, and inserts `security.admin_events` in one transaction. The event records the database operator login, target, action, reason and time; no password or password hash is copied into that audit record. The operator must use an individually attributable identity in production. Shared administrator credentials reduce attribution to the shared database login.

MFA enrollment and lost-device recovery are available through the separate [MFA operator workflow](mfa-operations.md). FX configuration uses [the audited rounding-policy command](fx-rounding-policy.md). Identity-provider federation, self-service recovery and dual approval for privileged administration are not implemented. Role and membership management is in the application (see above). Direct database changes are outside this operator command's audit workflow and must be governed/reviewed independently. Database administrators can ultimately bypass application-owned triggers; use external access logs and controlled privileged access.

The source/account authentication window persists across API replicas, resets on successful login, and cleans up at most 100 rows older than one hour per call. One source cannot consume another source’s account quota. An operator should prune obsolete `security.login_windows` rows and expired/revoked sessions on a reviewed schedule. Financial idempotency receipts, ledger history and audit/outbox data must not be treated as disposable session data.
