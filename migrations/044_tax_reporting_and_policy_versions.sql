SET LOCAL ROLE serk_owner;
ALTER TABLE finance.payroll_policies ADD COLUMN pay_frequency text NOT NULL DEFAULT 'MONTHLY' CHECK(pay_frequency IN('MONTHLY','WEEKLY','BIWEEKLY'));
CREATE FUNCTION finance.guard_payroll_policy() RETURNS trigger LANGUAGE plpgsql
SET search_path=pg_catalog,finance,pg_temp AS $$ BEGIN
 IF TG_OP='UPDATE' AND OLD.approved_by IS NOT NULL THEN RAISE EXCEPTION 'approved_policy_immutable' USING ERRCODE='55000'; END IF;
 IF NEW.approved_by IS NOT NULL THEN
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.company_id::text||NEW.pay_frequency,2));
  IF EXISTS(SELECT FROM finance.payroll_policies p WHERE p.company_id=NEW.company_id AND p.pay_frequency=NEW.pay_frequency AND p.id<>NEW.id AND p.approved_by IS NOT NULL
   AND p.effective_from<=coalesce(NEW.effective_to,'infinity'::date) AND coalesce(p.effective_to,'infinity'::date)>=NEW.effective_from)
  THEN RAISE EXCEPTION 'overlapping_payroll_policy' USING ERRCODE='23505'; END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER payroll_policy_rules BEFORE INSERT OR UPDATE ON finance.payroll_policies FOR EACH ROW EXECUTE FUNCTION finance.guard_payroll_policy();
CREATE FUNCTION finance.tax_liability() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,taxes,ledger,organization,security,pg_temp AS $$ BEGIN
 PERFORM security.require('taxes.read');PERFORM security.require('ledger.read');
 RETURN jsonb_build_object('currency',(SELECT functional_currency FROM organization.companies WHERE id=security.company()),
  'total_tax_liability',coalesce((SELECT sum(CASE WHEN e.transaction_type='SALE' THEN e.tax_amount ELSE -e.tax_amount END)
   FROM taxes.tax_entries e JOIN ledger.journals j ON j.id=e.journal_id AND j.state='POSTED'),0)::text);
END $$;
GRANT EXECUTE ON FUNCTION finance.tax_liability() TO serk_api;
