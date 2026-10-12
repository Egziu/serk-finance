-- Phase 1: Chart of Accounts Configuration API
-- Adds secure definer functions to manage the chart of accounts, respecting RLS and audit rules.
SET LOCAL ROLE serk_owner;

CREATE FUNCTION ledger.list_accounts() RETURNS json LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 SELECT coalesce(json_agg(json_build_object(
  'id', id, 'code', code, 'name', name, 'type', type, 'normal_balance', normal_balance,
  'parent_id', parent_id, 'active', active, 'posting_allowed', posting_allowed,
  'control_account', control_account, 'reporting_category', reporting_category
 ) ORDER BY code), '[]'::json)
 FROM ledger.accounts
 WHERE tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company());
$$;

-- Create Account
CREATE FUNCTION ledger.create_account(
 p_code text, p_name text, p_type text, p_normal_balance text,
 p_parent_id uuid, p_posting_allowed boolean, p_control_account boolean, p_reporting_category text
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE
  new_id uuid;
  t uuid := (SELECT security.tenant());
  c uuid := (SELECT security.company());
 BEGIN
  -- Must have configuration.manage permission
  IF NOT EXISTS(
    SELECT FROM security.role_permissions rp JOIN security.memberships m ON m.role_id=rp.role_id
    WHERE m.user_id=(SELECT security.actor()) AND m.company_id=c AND rp.permission='configuration.manage'
  ) THEN
   RAISE EXCEPTION 'access_denied' USING ERRCODE='42501';
  END IF;

  INSERT INTO ledger.accounts (
   tenant_id, company_id, code, name, type, normal_balance, parent_id,
   posting_allowed, control_account, reporting_category
  ) VALUES (
   t, c, p_code, p_name, p_type, p_normal_balance, p_parent_id,
   p_posting_allowed, p_control_account, p_reporting_category
  ) RETURNING id INTO new_id;
  
  RETURN new_id;
 END $$;
