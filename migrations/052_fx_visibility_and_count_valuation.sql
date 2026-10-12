-- 0.2.2-rc1: findings from independent release verification.
--
--  V1 (high)  Exchange rates were readable only with configuration.manage (037), so for every other
--             user ledger.recorded_rate returned NULL and no foreign-currency journal could be posted.
--             Rates are company reference data: anyone who can read the ledger may read them;
--             writing them still needs configuration.manage.
--  V2         A recorded rate is only used for journals dated within the company's maximum rate age
--             (default 7 days), so a months-old rate cannot validate a current journal.
--  V3 (IAS 2) Stock removed or found by an inventory count adjustment moves at the item's moving
--             weighted-average cost, computed when the adjustment is approved; arbitrary values are
--             refused. Only when no unreserved stock is held (no average exists) may found stock carry
--             its own cost. Value-only write-downs (quantity 0) are unaffected.
SET LOCAL ROLE serk_owner;

ALTER POLICY repaired_read ON core.exchange_rates
 USING ((SELECT security.has('ledger.read')) OR (SELECT security.has('configuration.manage')));

ALTER TABLE ledger.fx_policies ADD COLUMN max_age_days integer NOT NULL DEFAULT 7 CHECK(max_age_days BETWEEN 0 AND 366);

CREATE OR REPLACE FUNCTION ledger.recorded_rate(p_currency text,p_date date) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,core,ledger,security,pg_temp AS $$
 SELECT r.exchange_rate FROM core.exchange_rates r
 WHERE r.company_id=(SELECT security.company()) AND r.foreign_currency=p_currency AND r.date<=p_date
  AND r.date>=p_date-coalesce((SELECT max_age_days FROM ledger.fx_policies WHERE company_id=(SELECT security.company())),7)
 ORDER BY r.date DESC,r.created_at DESC LIMIT 1
$$;

CREATE FUNCTION ledger.set_fx_policy(p_bps integer,p_max_age_days integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$
DECLARE r ledger.fx_policies;
BEGIN
 PERFORM security.require('configuration.manage');
 IF p_bps IS NULL OR p_bps NOT BETWEEN 0 AND 5000 OR p_max_age_days IS NULL OR p_max_age_days NOT BETWEEN 0 AND 366 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 INSERT INTO ledger.fx_policies(tenant_id,company_id,tolerance_bps,max_age_days) VALUES(security.tenant(),security.company(),p_bps,p_max_age_days)
 ON CONFLICT(company_id) DO UPDATE SET tolerance_bps=EXCLUDED.tolerance_bps,max_age_days=EXCLUDED.max_age_days,version=fx_policies.version+1 RETURNING * INTO r;
 RETURN to_jsonb(r);
END $$;
REVOKE ALL ON FUNCTION ledger.set_fx_policy(integer,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.set_fx_policy(integer,integer) TO serk_api;

-- Count adjustments move stock at the moving weighted-average cost at approval.
CREATE FUNCTION finance.guard_count_valuation() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,inventory,pg_temp AS $$
DECLARE pos finance.positions; line jsonb; qty numeric; delta numeric; expected numeric; avail numeric;
BEGIN
 IF NEW.state='POSTED' AND OLD.state='SUBMITTED' AND NEW.purpose='INVENTORY_ADJUSTMENT' THEN
  FOR line IN SELECT * FROM jsonb_array_elements(NEW.lines) WHERE value ? 'item_id' LOOP
   qty:=(line->>'quantity_delta')::numeric;
   CONTINUE WHEN qty=0;
   delta:=(line->>'debit_minor')::numeric-(line->>'credit_minor')::numeric;
   -- Positions were already moved by this approval; reconstruct the balance before it.
   SELECT * INTO STRICT pos FROM finance.positions WHERE item_id=(line->>'item_id')::uuid;
   pos.quantity:=pos.quantity-qty; pos.value_minor:=pos.value_minor-delta;
   avail:=pos.quantity-pos.reserved_quantity;
   IF qty<0 THEN
    expected:=-CASE WHEN -qty=avail THEN pos.value_minor-pos.reserved_minor ELSE round((pos.value_minor-pos.reserved_minor)*(-qty)/avail) END;
   ELSIF avail>0 THEN
    expected:=round((pos.value_minor-pos.reserved_minor)*qty/avail);
   ELSE
    CONTINUE;
   END IF;
   IF delta<>expected THEN RAISE EXCEPTION 'inventory_adjustment_not_at_average_cost' USING ERRCODE='23514'; END IF;
  END LOOP;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER aa_count_valuation BEFORE UPDATE ON finance.adjustments FOR EACH ROW EXECUTE FUNCTION finance.guard_count_valuation();

-- Publish the runtime marker only after every 0.2.2 migration is present.
CREATE OR REPLACE FUNCTION security.release_version() RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT '0.2.2-rc1'::text $$;
