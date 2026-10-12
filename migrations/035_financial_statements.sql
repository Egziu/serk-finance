SET LOCAL ROLE serk_owner;

CREATE OR REPLACE FUNCTION ledger.balance_sheet(p_as_of date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_currency text;
  v_result jsonb;
  v_net_income numeric := 0;
BEGIN
  IF NOT security.has('ledger.read') THEN 
    RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; 
  END IF;
  IF p_as_of IS NULL THEN 
    RAISE EXCEPTION 'as_of_required' USING ERRCODE='22023'; 
  END IF;

  SELECT functional_currency INTO v_currency FROM organization.companies WHERE id = security.company();

  -- Cumulative Net Income up to as_of
  SELECT COALESCE(SUM(
    CASE 
      WHEN a.type IN ('REVENUE','OTHER_INCOME') THEN l.functional_credit_minor - l.functional_debit_minor
      WHEN a.type IN ('COST_OF_SALES','EXPENSE','OTHER_EXPENSE') THEN -(l.functional_debit_minor - l.functional_credit_minor)
      ELSE 0
    END
  ), 0) INTO v_net_income
  FROM ledger.accounts a
  JOIN ledger.lines l ON l.account_id = a.id
  JOIN ledger.journals j ON l.journal_id = j.id AND j.state = 'POSTED' AND j.accounting_date <= p_as_of
  WHERE a.tenant_id = security.tenant() AND a.company_id = security.company();

  WITH acct_balances AS (
    SELECT 
      a.id, a.code, a.name, a.type, a.reporting_category,
      COALESCE(SUM(
        CASE 
          WHEN a.type = 'ASSET' THEN l.functional_debit_minor - l.functional_credit_minor
          WHEN a.type IN ('LIABILITY', 'EQUITY') THEN l.functional_credit_minor - l.functional_debit_minor
          ELSE 0 
        END
      ), 0) as balance_minor,
      COALESCE(SUM(l.functional_debit_minor), 0) as dr_minor,
      COALESCE(SUM(l.functional_credit_minor), 0) as cr_minor
    FROM ledger.accounts a
    LEFT JOIN (
      ledger.lines l 
      JOIN ledger.journals j ON l.journal_id = j.id AND j.state = 'POSTED' AND j.accounting_date <= p_as_of
    ) ON l.account_id = a.id
    WHERE a.tenant_id = security.tenant() AND a.company_id = security.company()
      AND a.type IN ('ASSET', 'LIABILITY', 'EQUITY')
    GROUP BY a.id, a.code, a.name, a.type, a.reporting_category
  ),
  current_assets AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'balance_minor', balance_minor::text, 'dr_minor', dr_minor::text, 'cr_minor', cr_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_balances
    WHERE type = 'ASSET' AND (reporting_category ILIKE '%current%' OR reporting_category ILIKE '%cash%' OR reporting_category ILIKE '%receivable%' OR reporting_category ILIKE '%inventory%' OR reporting_category ILIKE '%bank%' OR reporting_category NOT ILIKE '%fixed%')
  ),
  non_current_assets AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'balance_minor', balance_minor::text, 'dr_minor', dr_minor::text, 'cr_minor', cr_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_balances
    WHERE type = 'ASSET' AND (reporting_category ILIKE '%fixed%' OR reporting_category ILIKE '%property%' OR reporting_category ILIKE '%depreciation%' OR reporting_category ILIKE '%non-current%')
  ),
  current_liabilities AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'balance_minor', balance_minor::text, 'dr_minor', dr_minor::text, 'cr_minor', cr_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_balances
    WHERE type = 'LIABILITY' AND (reporting_category ILIKE '%current%' OR reporting_category ILIKE '%payable%' OR reporting_category ILIKE '%accrued%' OR reporting_category ILIKE '%tax%' OR reporting_category NOT ILIKE '%long%')
  ),
  non_current_liabilities AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'balance_minor', balance_minor::text, 'dr_minor', dr_minor::text, 'cr_minor', cr_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_balances
    WHERE type = 'LIABILITY' AND (reporting_category ILIKE '%long%' OR reporting_category ILIKE '%non-current%')
  ),
  equity_accounts AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'balance_minor', balance_minor::text, 'dr_minor', dr_minor::text, 'cr_minor', cr_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_balances
    WHERE type = 'EQUITY'
  )
  SELECT jsonb_build_object(
    'as_of', p_as_of,
    'currency', v_currency,
    'assets', jsonb_build_object(
      'current_assets', (SELECT rows FROM current_assets),
      'current_assets_total_minor', (SELECT total::text FROM current_assets),
      'non_current_assets', (SELECT rows FROM non_current_assets),
      'non_current_assets_total_minor', (SELECT total::text FROM non_current_assets),
      'total_assets_minor', ((SELECT total FROM current_assets) + (SELECT total FROM non_current_assets))::text
    ),
    'liabilities', jsonb_build_object(
      'current_liabilities', (SELECT rows FROM current_liabilities),
      'current_liabilities_total_minor', (SELECT total::text FROM current_liabilities),
      'non_current_liabilities', (SELECT rows FROM non_current_liabilities),
      'non_current_liabilities_total_minor', (SELECT total::text FROM non_current_liabilities),
      'total_liabilities_minor', ((SELECT total FROM current_liabilities) + (SELECT total FROM non_current_liabilities))::text
    ),
    'equity', jsonb_build_object(
      'equity_accounts', (SELECT rows FROM equity_accounts),
      'equity_accounts_total_minor', (SELECT total::text FROM equity_accounts),
      'net_income_minor', v_net_income::text,
      'total_equity_minor', ((SELECT total FROM equity_accounts) + v_net_income)::text
    ),
    'total_liabilities_and_equity_minor', ((SELECT total FROM current_liabilities) + (SELECT total FROM non_current_liabilities) + (SELECT total FROM equity_accounts) + v_net_income)::text,
    'is_balanced', (((SELECT total FROM current_assets) + (SELECT total FROM non_current_assets)) = ((SELECT total FROM current_liabilities) + (SELECT total FROM non_current_liabilities) + (SELECT total FROM equity_accounts) + v_net_income))
  ) INTO v_result;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION ledger.income_statement(p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
  v_currency text;
  v_result jsonb;
BEGIN
  IF NOT security.has('ledger.read') THEN 
    RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; 
  END IF;
  IF p_to IS NULL THEN 
    RAISE EXCEPTION 'to_date_required' USING ERRCODE='22023'; 
  END IF;

  SELECT functional_currency INTO v_currency FROM organization.companies WHERE id = security.company();

  WITH acct_activity AS (
    SELECT 
      a.id, a.code, a.name, a.type, a.reporting_category,
      COALESCE(SUM(
        CASE 
          WHEN a.type IN ('REVENUE', 'OTHER_INCOME') THEN l.functional_credit_minor - l.functional_debit_minor
          WHEN a.type IN ('COST_OF_SALES', 'EXPENSE', 'OTHER_EXPENSE') THEN l.functional_debit_minor - l.functional_credit_minor
          ELSE 0 
        END
      ), 0) as balance_minor
    FROM ledger.accounts a
    LEFT JOIN (
      ledger.lines l 
      JOIN ledger.journals j ON l.journal_id = j.id AND j.state = 'POSTED' 
        AND j.accounting_date <= p_to AND (p_from IS NULL OR j.accounting_date >= p_from)
    ) ON l.account_id = a.id
    WHERE a.tenant_id = security.tenant() AND a.company_id = security.company()
      AND a.type IN ('REVENUE', 'COST_OF_SALES', 'EXPENSE', 'OTHER_INCOME', 'OTHER_EXPENSE')
    GROUP BY a.id, a.code, a.name, a.type, a.reporting_category
  ),
  revenue AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'amount_minor', balance_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_activity WHERE type = 'REVENUE'
  ),
  cogs AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'amount_minor', balance_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_activity WHERE type = 'COST_OF_SALES'
  ),
  operating_expenses AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'amount_minor', balance_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_activity WHERE type = 'EXPENSE'
  ),
  other_income AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'amount_minor', balance_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_activity WHERE type = 'OTHER_INCOME'
  ),
  other_expenses AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'name', name, 'reporting_category', reporting_category, 'amount_minor', balance_minor::text
    ) ORDER BY code), '[]'::jsonb) as rows,
    COALESCE(SUM(balance_minor), 0) as total
    FROM acct_activity WHERE type = 'OTHER_EXPENSE'
  )
  SELECT jsonb_build_object(
    'from', p_from,
    'to', p_to,
    'currency', v_currency,
    'revenue', (SELECT rows FROM revenue),
    'total_revenue_minor', (SELECT total::text FROM revenue),
    'cost_of_sales', (SELECT rows FROM cogs),
    'total_cost_of_sales_minor', (SELECT total::text FROM cogs),
    'gross_profit_minor', ((SELECT total FROM revenue) - (SELECT total FROM cogs))::text,
    'operating_expenses', (SELECT rows FROM operating_expenses),
    'total_operating_expenses_minor', (SELECT total::text FROM operating_expenses),
    'operating_income_minor', ((SELECT total FROM revenue) - (SELECT total FROM cogs) - (SELECT total FROM operating_expenses))::text,
    'other_income', (SELECT rows FROM other_income),
    'total_other_income_minor', (SELECT total::text FROM other_income),
    'other_expenses', (SELECT rows FROM other_expenses),
    'total_other_expenses_minor', (SELECT total::text FROM other_expenses),
    'net_profit_minor', ((SELECT total FROM revenue) - (SELECT total FROM cogs) - (SELECT total FROM operating_expenses) + (SELECT total FROM other_income) - (SELECT total FROM other_expenses))::text
  ) INTO v_result;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION ledger.balance_sheet(date) TO serk_api;
GRANT EXECUTE ON FUNCTION ledger.income_statement(date, date) TO serk_api;
