SET LOCAL ROLE serk_owner;
CREATE OR REPLACE FUNCTION ledger.validate(p_id uuid,p_posting boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
 DECLARE j ledger.journals;p ledger.periods; n integer;td numeric;tc numeric;fd numeric;fc numeric; te integer;fe integer; nr integer; delta numeric; r ledger.lines;
 BEGIN
 SELECT * INTO STRICT j FROM ledger.journals WHERE id=p_id;
 IF p_posting THEN
  SELECT * INTO STRICT p FROM ledger.periods WHERE id=j.period_id FOR SHARE;
  PERFORM 1 FROM ledger.accounts WHERE id IN(SELECT account_id FROM ledger.lines WHERE journal_id=p_id) ORDER BY id FOR SHARE;
 END IF;
 SELECT count(*),sum(debit_minor),sum(credit_minor),sum(functional_debit_minor),sum(functional_credit_minor)
 INTO n,td,tc,fd,fc FROM ledger.lines WHERE journal_id=p_id;
 SELECT count(*) INTO nr FROM ledger.lines WHERE journal_id=p_id AND is_rounding;
 IF n-nr<2 OR n-nr>500 OR nr>1 OR td IS DISTINCT FROM tc OR fd IS DISTINCT FROM fc OR coalesce(td,0)<=0 OR coalesce(fd,0)<=0
 THEN RAISE EXCEPTION 'journal_unbalanced' USING ERRCODE='23514'; END IF;
 SELECT minor_units INTO te FROM organization.currencies WHERE code=j.currency;
 SELECT minor_units INTO fe FROM organization.currencies WHERE code=j.functional_currency;
 IF EXISTS(SELECT FROM ledger.lines l WHERE l.journal_id=p_id AND NOT l.is_rounding AND
 (l.functional_debit_minor<>round(l.debit_minor*j.fx_rate*power(10::numeric,fe-te)) OR
 l.functional_credit_minor<>round(l.credit_minor*j.fx_rate*power(10::numeric,fe-te)))) THEN
 RAISE EXCEPTION 'invalid_currency_conversion' USING ERRCODE='23514'; END IF;
 IF nr=1 THEN
  SELECT * INTO STRICT r FROM ledger.lines WHERE journal_id=p_id AND is_rounding;
  SELECT sum(functional_debit_minor-functional_credit_minor) INTO delta FROM ledger.lines WHERE journal_id=p_id AND NOT is_rounding;
  IF j.currency=j.functional_currency OR delta=0 OR abs(delta)>floor((n-nr)::numeric/2)
   OR r.functional_debit_minor<>greatest(-delta,0) OR r.functional_credit_minor<>greatest(delta,0)
   OR r.line_no<>(SELECT max(line_no)+1 FROM ledger.lines WHERE journal_id=p_id AND NOT is_rounding)
   OR EXISTS(SELECT FROM ledger.line_dimensions WHERE journal_id=p_id AND line_no=r.line_no)
  THEN RAISE EXCEPTION 'invalid_rounding_line' USING ERRCODE='23514'; END IF;
 END IF;
 IF j.currency=j.functional_currency AND j.fx_rate<>1 THEN RAISE EXCEPTION 'invalid_exchange_rate' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT FROM ledger.lines l JOIN ledger.accounts a ON a.id=l.account_id WHERE l.journal_id=p_id
 AND (NOT a.active OR NOT a.posting_allowed OR (a.control_account AND NOT (j.source_type='SYSTEM' OR (j.source_type='REVERSAL' AND EXISTS(SELECT FROM ledger.journals original WHERE original.id=j.reversed_from AND original.source_type='SYSTEM')))) OR EXISTS(SELECT FROM ledger.accounts child WHERE child.parent_id=a.id)))
 THEN RAISE EXCEPTION 'invalid_posting_account' USING ERRCODE='23514'; END IF;
 IF EXISTS(SELECT FROM ledger.line_dimensions d JOIN ledger.dimensions v ON v.id=d.dimension_id WHERE d.journal_id=p_id AND NOT v.active)
 THEN RAISE EXCEPTION 'inactive_dimension' USING ERRCODE='23514'; END IF;
 IF p_posting THEN
  IF p.state<>'OPEN' OR j.accounting_date NOT BETWEEN p.start_date AND p.end_date
  THEN RAISE EXCEPTION 'period_not_open' USING ERRCODE='55000'; END IF;
  PERFORM 1 FROM organization.branches WHERE id=j.branch_id AND active FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'inactive_branch' USING ERRCODE='23514'; END IF;
 END IF;
 IF j.reversed_from IS NOT NULL THEN
  IF NOT EXISTS(SELECT FROM ledger.journals WHERE id=j.reversed_from AND state='POSTED' AND accounting_date<=j.accounting_date) THEN RAISE EXCEPTION 'invalid_reversal' USING ERRCODE='23514'; END IF;
  IF EXISTS((SELECT line_no,account_id,debit_minor,credit_minor,functional_debit_minor,functional_credit_minor,is_rounding FROM ledger.lines WHERE journal_id=p_id
   EXCEPT SELECT line_no,account_id,credit_minor,debit_minor,functional_credit_minor,functional_debit_minor,is_rounding FROM ledger.lines WHERE journal_id=j.reversed_from)
   UNION ALL (SELECT line_no,account_id,credit_minor,debit_minor,functional_credit_minor,functional_debit_minor,is_rounding FROM ledger.lines WHERE journal_id=j.reversed_from
   EXCEPT SELECT line_no,account_id,debit_minor,credit_minor,functional_debit_minor,functional_credit_minor,is_rounding FROM ledger.lines WHERE journal_id=p_id)) THEN
   RAISE EXCEPTION 'reversal_mismatch' USING ERRCODE='23514'; END IF;
  IF EXISTS((SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=p_id EXCEPT SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=j.reversed_from)
   UNION ALL (SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=j.reversed_from EXCEPT SELECT line_no,kind,dimension_id FROM ledger.line_dimensions WHERE journal_id=p_id)) THEN
   RAISE EXCEPTION 'reversal_dimensions_mismatch' USING ERRCODE='23514'; END IF;
 END IF;
 END $$;

CREATE FUNCTION finance.guard_control_mapping() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,ledger,pg_temp AS $$ BEGIN
 IF EXISTS(SELECT FROM ledger.journals j WHERE j.id=NEW.journal_id AND j.source_type='MANUAL')
 AND EXISTS(SELECT FROM finance.control_accounts c WHERE c.company_id=NEW.company_id AND c.account_id=NEW.account_id)
 THEN RAISE EXCEPTION 'use_module_workflow' USING ERRCODE='55000'; END IF;RETURN NEW;
END $$;
CREATE TRIGGER module_control_mapping BEFORE INSERT OR UPDATE ON ledger.lines FOR EACH ROW EXECUTE FUNCTION finance.guard_control_mapping();
