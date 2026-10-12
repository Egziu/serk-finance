
CREATE FUNCTION organization.create_branch(p_code text, p_name text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,organization,security,pg_temp AS $$
DECLARE
  new_id uuid;
  c uuid := (SELECT security.company());
  t uuid := (SELECT security.tenant());
BEGIN
  IF NOT EXISTS(
    SELECT FROM security.role_permissions rp JOIN security.memberships m ON m.role_id=rp.role_id
    WHERE m.user_id=(SELECT security.actor()) AND m.company_id=c AND rp.permission='configuration.manage'
  ) THEN
   RAISE EXCEPTION 'access_denied' USING ERRCODE='42501';
  END IF;

  INSERT INTO organization.branches(tenant_id, company_id, code, name, active)
  VALUES (t, c, p_code, p_name, true)
  RETURNING id INTO new_id;

  RETURN new_id;
END $$;

