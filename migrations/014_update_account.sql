-- Update Account
CREATE FUNCTION ledger.update_account(
 p_id uuid, p_name text, p_parent_id uuid, p_active boolean, p_posting_allowed boolean, p_reporting_category text
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE
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

  UPDATE ledger.accounts
  SET name = p_name, parent_id = p_parent_id, active = p_active,
      posting_allowed = p_posting_allowed, reporting_category = p_reporting_category
  WHERE id = p_id AND tenant_id = t AND company_id = c;

  IF NOT FOUND THEN
   RAISE EXCEPTION 'not_found' USING ERRCODE='P0002';
  END IF;
 END $$;
