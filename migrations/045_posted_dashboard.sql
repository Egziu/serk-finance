SET LOCAL ROLE serk_owner;
CREATE FUNCTION finance.dashboard(p_as_of date) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,ledger,security,pg_temp AS $$
DECLARE result jsonb;from_date date;BEGIN
 PERFORM security.require('ledger.read');
 IF p_as_of IS NULL OR NOT isfinite(p_as_of) THEN RAISE EXCEPTION 'invalid_dates' USING ERRCODE='22023'; END IF;
 SELECT min(start_date) INTO from_date FROM ledger.fiscal_years WHERE p_as_of BETWEEN start_date AND end_date;
 from_date:=coalesce(from_date,date_trunc('year',p_as_of)::date);
 WITH posted AS(
  SELECT l.*,j.accounting_date,a.type,a.normal_balance FROM ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id AND j.state='POSTED' AND j.accounting_date<=p_as_of
   JOIN ledger.accounts a ON a.id=l.account_id
 ), config AS(SELECT accounts FROM finance.settings WHERE company_id=security.company()),
 metrics AS(SELECT
  coalesce(sum(functional_credit_minor-functional_debit_minor) FILTER(WHERE type IN('REVENUE','OTHER_INCOME') AND accounting_date>=from_date),0)::text AS total_revenue,
  coalesce(sum(functional_debit_minor-functional_credit_minor) FILTER(WHERE type IN('EXPENSE','COST_OF_SALES','OTHER_EXPENSE') AND accounting_date>=from_date),0)::text AS total_expenses,
  coalesce(sum(functional_debit_minor-functional_credit_minor) FILTER(WHERE account_id IN(SELECT account_id FROM finance.control_accounts WHERE purpose='receivable')),0)::text AS accounts_receivable,
  coalesce(sum(functional_credit_minor-functional_debit_minor) FILTER(WHERE account_id IN(SELECT account_id FROM finance.control_accounts WHERE purpose='payable')),0)::text AS accounts_payable,
  coalesce(sum(functional_debit_minor-functional_credit_minor) FILTER(WHERE account_id IN(SELECT x::uuid FROM config,jsonb_array_elements_text(accounts->'cash_accounts') x)),0)::text AS cash_balance FROM posted
 ), monthly AS(SELECT to_char(accounting_date,'YYYY-MM') AS month,
  coalesce(sum(functional_credit_minor-functional_debit_minor) FILTER(WHERE type IN('REVENUE','OTHER_INCOME')),0)::text AS income,
  coalesce(sum(functional_debit_minor-functional_credit_minor) FILTER(WHERE type IN('EXPENSE','COST_OF_SALES','OTHER_EXPENSE')),0)::text AS expense
  FROM posted WHERE accounting_date>=from_date GROUP BY to_char(accounting_date,'YYYY-MM'))
 SELECT jsonb_build_object('as_of',p_as_of,'from',from_date,'metrics',(SELECT to_jsonb(m) FROM metrics m),
  'cashflow',coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY month) FROM monthly c),'[]'),
  'receivable_configured',coalesce((SELECT accounts?'receivable' FROM config),false),'payable_configured',coalesce((SELECT accounts?'payable' FROM config),false)) INTO result;
 RETURN result;
END $$;
GRANT EXECUTE ON FUNCTION finance.dashboard(date) TO serk_api;
