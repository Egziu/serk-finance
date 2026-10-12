-- 029_currency_grants.sql
SET LOCAL ROLE serk_owner;

GRANT SELECT ON core.currencies TO serk_api;
GRANT SELECT, INSERT, UPDATE ON core.exchange_rates TO serk_api;

ALTER TABLE core.currencies ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.exchange_rates ENABLE ROW LEVEL SECURITY;

CREATE POLICY select_currencies ON core.currencies FOR SELECT TO serk_api USING (true);

CREATE POLICY select_exchange_rates ON core.exchange_rates FOR SELECT TO serk_api 
USING (tenant_id = (SELECT security.tenant()) AND company_id = (SELECT security.company()));

CREATE POLICY insert_exchange_rates ON core.exchange_rates FOR INSERT TO serk_api 
WITH CHECK (tenant_id = (SELECT security.tenant()) AND company_id = (SELECT security.company()));

CREATE POLICY update_exchange_rates ON core.exchange_rates FOR UPDATE TO serk_api 
USING (tenant_id = (SELECT security.tenant()) AND company_id = (SELECT security.company()));
