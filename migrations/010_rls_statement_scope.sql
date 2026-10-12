-- 0.2.0-rc4: statement-scoped evaluation of session security context.
-- Released migrations 001-009 stay unchanged.
--
-- Defect (found by the first native PostgreSQL run): RLS policies and the security
-- helper functions compared columns directly against SECURITY DEFINER functions, e.g.
-- tenant_id=security.tenant(). SECURITY DEFINER functions are never inlined, so
-- PostgreSQL re-evaluated the whole actor/tenant/company chain for every row examined,
-- including inside per-line triggers. Cost grew with journal size and a 500-line journal
-- exceeded the 10 s runtime statement_timeout on native PostgreSQL (PGlite masked it).
--
-- Fix: wrap every row-independent call in a scalar subquery so PostgreSQL evaluates it
-- once per statement as an InitPlan. Within a single statement these functions already
-- return one value (they read transaction-local settings, statement_timestamp() and the
-- statement snapshot), so access decisions are unchanged. Signatures, volatility,
-- SECURITY DEFINER, pinned search_path, owners and grants are all preserved; only the
-- evaluation strategy changes. Row-dependent checks (visible_branch(branch_id) and the
-- line->journal EXISTS) are unchanged and become cheap because their callees are fixed.
SET LOCAL ROLE serk_owner;

CREATE OR REPLACE FUNCTION security.tenant() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT tenant_id FROM security.users WHERE id=(SELECT security.actor())
$$;
CREATE OR REPLACE FUNCTION security.company() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,organization,pg_temp AS $$
 SELECT c.id FROM organization.companies c WHERE c.id=nullif(current_setting('serk.company_id',true),'')::uuid
 AND c.tenant_id=(SELECT security.tenant()) AND c.active
 AND EXISTS(SELECT FROM security.memberships m WHERE m.company_id=c.id AND m.user_id=(SELECT security.actor()))
$$;
CREATE OR REPLACE FUNCTION security.can(p_permission text, p_branch uuid DEFAULT NULL, p_amount numeric DEFAULT 0)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT EXISTS(SELECT FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor()) AND rp.permission=p_permission
 AND (m.branch_id IS NULL OR m.branch_id=p_branch)
 AND (p_permission<>'journal.approve' OR m.approval_limit_minor IS NULL OR p_amount<=m.approval_limit_minor))
$$;
CREATE OR REPLACE FUNCTION security.has(p_permission text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT EXISTS(SELECT FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor()) AND rp.permission=p_permission)
$$;

-- Policies: same names, same permissive/restrictive type, same command scope.
ALTER POLICY scoped ON organization.branches
 USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()) AND security.visible_branch(id));
DO $$
DECLARE r record; n integer:=0;
BEGIN
 FOR r IN SELECT schemaname s,tablename t FROM pg_policies
  WHERE policyname='scoped' AND qual='((tenant_id = security.tenant()) AND (company_id = security.company()))' LOOP
  EXECUTE format('ALTER POLICY scoped ON %I.%I USING (tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()))',r.s,r.t);
  n:=n+1;
 END LOOP;
 -- Fail closed if the policy set differs from the reviewed rc3 schema.
 IF n<>13 THEN RAISE EXCEPTION 'unexpected_rc3_policy_set: % scoped policies', n USING ERRCODE='55000'; END IF;
END $$;
ALTER POLICY account_permission ON ledger.accounts USING ((SELECT security.has('ledger.read')));
ALTER POLICY period_permission ON ledger.periods USING ((SELECT security.has('ledger.read')));
ALTER POLICY year_permission ON ledger.fiscal_years USING ((SELECT security.has('ledger.read')));
ALTER POLICY dimension_permission ON ledger.dimensions USING ((SELECT security.has('ledger.read')));
ALTER POLICY audit_scope ON audit.events USING ((SELECT security.can('audit.read')));

CREATE OR REPLACE FUNCTION security.release_version() RETURNS text LANGUAGE sql IMMUTABLE
 SET search_path=pg_catalog,pg_temp AS $$ SELECT '0.2.0-rc4'::text $$;
