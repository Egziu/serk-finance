SET LOCAL ROLE serk_owner;

-- Allow parent accounts to host sub-accounts seamlessly
CREATE OR REPLACE FUNCTION ledger.create_account(
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

  -- If a parent account is specified and currently has posting_allowed = true,
  -- automatically convert it into a Group Header account (posting_allowed = false)
  -- so it can host sub-accounts in the account tree.
  IF p_parent_id IS NOT NULL THEN
    UPDATE ledger.accounts 
    SET posting_allowed = false 
    WHERE id = p_parent_id AND tenant_id = t AND company_id = c AND posting_allowed = true;
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

GRANT EXECUTE ON FUNCTION ledger.create_account(text, text, text, text, uuid, boolean, boolean, text) TO serk_api;
