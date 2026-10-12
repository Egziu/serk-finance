-- 0.2.2-rc1: restore statement-scoped row-level security.
--
-- Migrations 037, 040 and 047 re-introduced bare SECURITY DEFINER calls
-- (security.has/can/visible_branch) into RLS policies. PostgreSQL cannot
-- inline SECURITY DEFINER functions, so each call runs once per examined row.
-- On native PostgreSQL 17 this made a 500-line FX journal exceed the 10 s
-- runtime statement_timeout (TestFXRoundingAndExactReversal), the same
-- regression migration 010 originally fixed.
--
-- Every rewritten policy below is logically identical to the one it replaces:
--   has(p)              == p = ANY(held_permissions())             (any branch)
--   can(p) [no branch]  == (SELECT can(p))                         (row-independent)
--   visible_branch(b)   == company_wide('ledger.read') OR b = ANY(permitted_branches('ledger.read'))
-- The row-independent parts are wrapped in scalar sub-selects so the planner
-- evaluates them once per statement (InitPlan).
SET LOCAL ROLE serk_owner;

-- Permissions the actor holds in the current company, in any branch.
CREATE FUNCTION security.held_permissions() RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT coalesce(array_agg(DISTINCT rp.permission),'{}'::text[])
 FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor())
$$;

-- True when the actor holds the permission through a company-wide (branch NULL) membership.
CREATE FUNCTION security.company_wide(p_permission text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT EXISTS(SELECT FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor())
 AND rp.permission=p_permission AND m.branch_id IS NULL)
$$;

-- Branches for which the actor holds the permission through a branch-limited membership.
CREATE FUNCTION security.permitted_branches(p_permission text) RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT coalesce(array_agg(DISTINCT m.branch_id),'{}'::uuid[])
 FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor())
 AND rp.permission=p_permission AND m.branch_id IS NOT NULL
$$;

REVOKE ALL ON FUNCTION security.held_permissions(), security.company_wide(text), security.permitted_branches(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.held_permissions(), security.company_wide(text), security.permitted_branches(text) TO serk_api, serk_auth;

ALTER POLICY account_permission ON ledger.accounts
 USING ((SELECT security.has('ledger.read')));

ALTER POLICY position_access ON finance.positions
 USING ((SELECT security.can('inventory.read')));

ALTER POLICY branch_scope ON ledger.journals
 USING ((SELECT security.company_wide('ledger.read')) OR branch_id = ANY((SELECT security.permitted_branches('ledger.read'))::uuid[]));

ALTER POLICY branch_scope ON finance.documents
 USING ((SELECT security.company_wide('ledger.read')) OR branch_id = ANY((SELECT security.permitted_branches('ledger.read'))::uuid[]));

ALTER POLICY module_read ON finance.documents
 USING (finance.permission(kind)||'.read' = ANY((SELECT security.held_permissions())::text[]));

ALTER POLICY employee_branch ON payroll.employees
 USING ((SELECT security.company_wide('ledger.read')) OR branch_id = ANY((SELECT security.permitted_branches('ledger.read'))::uuid[]));

ALTER POLICY scoped ON organization.branches
 USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company())
  AND ((SELECT security.company_wide('ledger.read')) OR id = ANY((SELECT security.permitted_branches('ledger.read'))::uuid[])));

ALTER POLICY payrun_branch ON payroll.payruns USING (
 (document_id IS NULL AND (SELECT security.can('payroll.read')) AND (SELECT security.can('ledger.read')))
 OR EXISTS(SELECT FROM finance.documents d WHERE d.id=document_id
   AND ((SELECT security.company_wide('ledger.read')) OR d.branch_id = ANY((SELECT security.permitted_branches('ledger.read'))::uuid[]))));

ALTER POLICY payslip_branch ON payroll.pay_slips USING (
 EXISTS(SELECT FROM payroll.payruns r WHERE r.id=payrun_id AND
  ((r.document_id IS NULL AND (SELECT security.can('payroll.read')) AND (SELECT security.can('ledger.read')))
   OR EXISTS(SELECT FROM finance.documents d WHERE d.id=r.document_id
     AND ((SELECT security.company_wide('ledger.read')) OR d.branch_id = ANY((SELECT security.permitted_branches('ledger.read'))::uuid[]))))));

CREATE OR REPLACE FUNCTION security.release_version() RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT '0.2.2-rc1'::text $$;
