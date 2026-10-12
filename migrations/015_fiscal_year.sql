-- Create Fiscal Year and 12 Monthly Periods
CREATE FUNCTION ledger.create_fiscal_year(
 p_name text, p_start_date date, p_end_date date
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE
  t uuid := (SELECT security.tenant());
  c uuid := (SELECT security.company());
  fy_id uuid;
  i integer;
  p_start date;
  p_end date;
 BEGIN
  -- Must have configuration.manage permission
  IF NOT EXISTS(
    SELECT FROM security.role_permissions rp JOIN security.memberships m ON m.role_id=rp.role_id
    WHERE m.user_id=(SELECT security.actor()) AND m.company_id=c AND rp.permission='configuration.manage'
  ) THEN
   RAISE EXCEPTION 'access_denied' USING ERRCODE='42501';
  END IF;

  IF p_start_date > p_end_date THEN
   RAISE EXCEPTION 'invalid_dates' USING ERRCODE='22008';
  END IF;

  INSERT INTO ledger.fiscal_years(tenant_id, company_id, name, start_date, end_date)
  VALUES(t, c, p_name, p_start_date, p_end_date)
  RETURNING id INTO fy_id;

  -- Automatically generate 12 monthly periods
  FOR i IN 1..12 LOOP
    p_start := p_start_date + ((i - 1) || ' month')::interval;
    -- End of the month is the start of the next month minus one day
    p_end := (p_start_date + (i || ' month')::interval)::date - 1;
    
    -- Ensure the last period does not exceed the fiscal year end date
    IF i = 12 OR p_end > p_end_date THEN
      p_end := p_end_date;
    END IF;

    -- Avoid creating invalid periods if the fiscal year is shorter than 12 months
    IF p_start <= p_end_date THEN
      INSERT INTO ledger.periods(tenant_id, company_id, fiscal_year_id, name, start_date, end_date, state)
      VALUES(t, c, fy_id, 'Period ' || i, p_start, p_end, 'OPEN');
    END IF;
  END LOOP;

  -- Create default journal numbering for the fiscal year if it doesn't exist
  INSERT INTO ledger.numbering(tenant_id, company_id, fiscal_year_id, document_type, prefix, next_value)
  VALUES(t, c, fy_id, 'JOURNAL', 'JRN', 1)
  ON CONFLICT DO NOTHING;

  RETURN fy_id;
 END $$;
