SET LOCAL ROLE serk_owner;
ALTER TABLE core.exchange_rates ALTER COLUMN exchange_rate TYPE numeric;
ALTER TABLE core.exchange_rates ADD CHECK(exchange_rate>0 AND exchange_rate<1e12 AND scale(exchange_rate)<=12);
ALTER TABLE core.exchange_rates ADD CHECK(base_currency<>foreign_currency);
CREATE TRIGGER immutable_tax_entries BEFORE UPDATE OR DELETE ON taxes.tax_entries FOR EACH ROW EXECUTE FUNCTION ledger.block_mutation();
CREATE FUNCTION finance.guard_master_identity() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,inventory,pg_temp AS $$ BEGIN
 IF (NEW.id,NEW.tenant_id,NEW.company_id) IS DISTINCT FROM (OLD.id,OLD.tenant_id,OLD.company_id)
 THEN RAISE EXCEPTION 'master_identity_immutable' USING ERRCODE='55000'; END IF;
 IF TG_TABLE_SCHEMA='inventory' AND TG_TABLE_NAME='items' THEN
  IF (to_jsonb(NEW)->'type',to_jsonb(NEW)->'income_account_id',to_jsonb(NEW)->'expense_account_id',to_jsonb(NEW)->'asset_account_id')
    IS DISTINCT FROM (to_jsonb(OLD)->'type',to_jsonb(OLD)->'income_account_id',to_jsonb(OLD)->'expense_account_id',to_jsonb(OLD)->'asset_account_id')
  AND EXISTS(SELECT FROM finance.item_usage u WHERE u.item_id=OLD.id)
  THEN RAISE EXCEPTION 'item_definition_in_use' USING ERRCODE='55000'; END IF;
 END IF;
 RETURN NEW;
END $$;
DO $$ DECLARE t text;BEGIN
 FOREACH t IN ARRAY ARRAY['invoicing.customers','invoicing.vendors','inventory.items','payroll.employees','taxes.tax_agencies','taxes.tax_rates','core.exchange_rates'] LOOP
  EXECUTE format('CREATE TRIGGER master_identity BEFORE UPDATE ON %s FOR EACH ROW EXECUTE FUNCTION finance.guard_master_identity()',t);
 END LOOP;
END $$;
