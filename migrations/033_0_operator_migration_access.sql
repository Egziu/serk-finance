-- Run before the unchanged legacy 033 data/schema migration.
-- Only the privileged CONNECTION identity may use this maintenance context.
-- Runtime definer functions keep normal RLS because their session_user is not an operator.
SET LOCAL ROLE serk_owner;
CREATE FUNCTION security.migration_is_operator() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,pg_temp AS $$
 SELECT coalesce((SELECT rolsuper OR pg_has_role(session_user,'serk_owner','MEMBER') FROM pg_roles WHERE rolname=session_user),false)
$$;
GRANT EXECUTE ON FUNCTION security.migration_is_operator() TO serk_api,serk_auth;
CREATE POLICY migration_owner ON ledger.accounts TO serk_owner USING(security.migration_is_operator()) WITH CHECK(security.migration_is_operator());
CREATE POLICY migration_owner ON ledger.journals TO serk_owner USING(security.migration_is_operator()) WITH CHECK(security.migration_is_operator());
CREATE POLICY migration_owner ON ledger.lines TO serk_owner USING(security.migration_is_operator()) WITH CHECK(security.migration_is_operator());
ALTER POLICY account_permission ON ledger.accounts USING(security.has('ledger.read') OR security.migration_is_operator());
ALTER POLICY branch_scope ON ledger.journals USING(security.visible_branch(branch_id) OR security.migration_is_operator());
