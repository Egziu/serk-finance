-- 0.3.1: fixes from the first accountant test round.
--
-- 1. Account mappings and item accounts now say which field is wrong. An account of the wrong
--    kind is refused with account_type_not_allowed, an account already reserved for another use
--    with account_reserved, and a missing one with account_required. The field name travels in
--    the error DETAIL (a snake_case field key, never data). Before, every case reported
--    "an account mapping is missing", which sent users to the wrong screen.
-- 2. Remapping a control purpose (receivables, payables, VAT, payroll liabilities) releases the
--    previously mapped account when it has never carried an entry. A mistaken mapping no longer
--    locks an account, such as a bank account, out of manual journals and cash use for ever.
--    Accounts that already carry entries stay controlled.
-- 3. finance.get_settings lists the reserved accounts, so the screens offer only usable accounts.
-- 4. ledger.get_journal names the source document of a module journal and offers no
--    general-ledger actions for it; reversals and voids happen on the document's own screen.
SET LOCAL ROLE serk_owner;

CREATE FUNCTION finance.require_account(p_id text,p_types text[],p_field text) RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,security,pg_temp AS $$
DECLARE a ledger.accounts;
BEGIN
 IF nullif(btrim(coalesce(p_id,'')),'') IS NULL THEN RAISE EXCEPTION 'account_required' USING ERRCODE='23514',DETAIL=p_field; END IF;
 IF p_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RAISE EXCEPTION 'account_type_not_allowed' USING ERRCODE='23514',DETAIL=p_field; END IF;
 SELECT * INTO a FROM ledger.accounts WHERE id=p_id::uuid AND tenant_id=security.tenant() AND company_id=security.company();
 IF NOT FOUND OR NOT a.active OR NOT a.posting_allowed OR NOT a.type=ANY(p_types) THEN
  RAISE EXCEPTION 'account_type_not_allowed' USING ERRCODE='23514',DETAIL=p_field; END IF;
 RETURN a.id;
END $$;

-- The accounts cash, receivables, payables, VAT, payroll liabilities and inventory are reserved
-- for, as purpose -> account pairs: the recorded control accounts plus the current mappings.
CREATE FUNCTION finance.reserved_accounts() RETURNS TABLE(purpose text,account_id uuid) LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$
 SELECT c.purpose,c.account_id FROM finance.control_accounts c WHERE c.company_id=security.company()
 UNION
 SELECT k,(s.accounts->>k)::uuid FROM finance.settings s,
  unnest(ARRAY['receivable','payable','output_tax','input_tax','payroll_payable','payroll_tax','pension_payable']) k
 WHERE s.company_id=security.company() AND s.accounts->>k ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 UNION
 SELECT 'cash',x::uuid FROM finance.settings s,jsonb_array_elements_text(coalesce(s.accounts->'cash_accounts','[]')) x
 WHERE s.company_id=security.company() AND x ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 UNION
 SELECT 'inventory',i.asset_account_id FROM inventory.items i
 WHERE i.company_id=security.company() AND i.asset_account_id IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION finance.get_settings() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$ BEGIN
 PERFORM security.require('ledger.read');
 RETURN coalesce((SELECT jsonb_build_object('accounts',accounts,'version',version) FROM finance.settings WHERE company_id=security.company()),'{"accounts":{}}'::jsonb)
  ||jsonb_build_object('reserved_accounts',coalesce((SELECT jsonb_agg(jsonb_build_object('purpose',r.purpose,'account_id',r.account_id) ORDER BY r.purpose,r.account_id)
   FROM finance.reserved_accounts() r),'[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION finance.configure(p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,ledger,security,pg_temp AS $$
DECLARE
 control_keys constant text[]:=ARRAY['receivable','payable','output_tax','input_tax','payroll_payable','payroll_tax','pension_payable'];
 all_keys constant text[]:=control_keys||ARRAY['opening_equity','retained_earnings','payroll_expense','pension_expense','cash_accounts'];
 k text; other text; acc uuid; cash uuid[]:='{}'; x text;
BEGIN
 PERFORM security.require('configuration.manage'); PERFORM security.require('ledger.read');
 IF jsonb_typeof(p)<>'object' THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 -- One change at a time per company, so two people cannot map the same account concurrently.
 PERFORM pg_advisory_xact_lock(hashtextextended('finance-settings:'||security.company()::text,0));
 -- Adjustments and items being saved right now finish first, and new ones wait for this change,
 -- so the checks below see every account they use.
 LOCK TABLE finance.adjustments,inventory.items IN SHARE MODE;
 -- A blank selection means "not mapped": drop it rather than store an empty string.
 p:=coalesce((SELECT jsonb_object_agg(e.key,e.value) FROM jsonb_each(p) e
  WHERE NOT (jsonb_typeof(e.value)='string' AND btrim(e.value#>>'{}')='')),'{}'::jsonb);
 FOR k IN SELECT jsonb_object_keys(p) LOOP
  IF NOT k=ANY(all_keys) THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023',DETAIL='mapping'; END IF;
  IF k<>'cash_accounts' AND jsonb_typeof(p->k)<>'string' THEN RAISE EXCEPTION 'account_type_not_allowed' USING ERRCODE='23514',DETAIL=k; END IF;
 END LOOP;
 IF jsonb_typeof(p->'cash_accounts') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'cash_accounts') NOT BETWEEN 1 AND 100 THEN
  RAISE EXCEPTION 'cash_account_configuration_required' USING ERRCODE='23514',DETAIL='cash_accounts'; END IF;
 FOR x IN SELECT jsonb_array_elements_text(p->'cash_accounts') LOOP
  acc:=finance.require_account(x,ARRAY['ASSET'],'cash_accounts');
  IF NOT acc=ANY(cash) THEN cash:=cash||acc; END IF;
 END LOOP;
 p:=jsonb_set(p,'{cash_accounts}',to_jsonb(ARRAY(SELECT c::text FROM unnest(cash) c)));

 -- Kind of each mapped account, in a fixed order so the first wrong field is reported.
 FOREACH k IN ARRAY all_keys LOOP
  CONTINUE WHEN k='cash_accounts' OR nullif(p->>k,'') IS NULL;
  PERFORM finance.require_account(p->>k,CASE k WHEN 'receivable' THEN ARRAY['ASSET'] WHEN 'input_tax' THEN ARRAY['ASSET']
   WHEN 'opening_equity' THEN ARRAY['EQUITY'] WHEN 'retained_earnings' THEN ARRAY['EQUITY']
   WHEN 'payroll_expense' THEN ARRAY['EXPENSE'] WHEN 'pension_expense' THEN ARRAY['EXPENSE'] ELSE ARRAY['LIABILITY'] END,k);
  -- Store the canonical form, so the same account always compares equal.
  p:=jsonb_set(p,ARRAY[k],to_jsonb((p->>k)::uuid::text));
 END LOOP;

 -- Release control accounts of remapped purposes that never carried an entry.
 FOREACH k IN ARRAY control_keys LOOP
  DELETE FROM finance.control_accounts c WHERE c.company_id=security.company() AND c.purpose=k
   AND c.account_id IS DISTINCT FROM nullif(p->>k,'')::uuid
   AND NOT EXISTS(SELECT FROM ledger.lines l WHERE l.account_id=c.account_id)
   AND NOT EXISTS(SELECT FROM finance.documents d WHERE d.company_id=c.company_id AND d.control_account_id=c.account_id)
   AND NOT EXISTS(SELECT FROM finance.adjustments a,jsonb_array_elements(a.lines) line
    WHERE a.company_id=c.company_id AND a.state IN('DRAFT','SUBMITTED') AND line->>'account_id'=c.account_id::text);
 END LOOP;

 -- A control account serves one purpose only, and never doubles as a cash account.
 FOREACH k IN ARRAY control_keys LOOP
  CONTINUE WHEN nullif(p->>k,'') IS NULL;
  acc:=(p->>k)::uuid;
  IF acc=ANY(cash) THEN RAISE EXCEPTION 'account_reserved' USING ERRCODE='23514',DETAIL=k; END IF;
  FOREACH other IN ARRAY control_keys LOOP
   IF other<>k AND p->>other=p->>k THEN RAISE EXCEPTION 'account_reserved' USING ERRCODE='23514',DETAIL=k; END IF;
  END LOOP;
  IF EXISTS(SELECT FROM finance.control_accounts c WHERE c.company_id=security.company() AND c.account_id=acc AND c.purpose<>k)
   OR EXISTS(SELECT FROM inventory.items i WHERE i.company_id=security.company() AND i.asset_account_id=acc) THEN
   RAISE EXCEPTION 'account_reserved' USING ERRCODE='23514',DETAIL=k; END IF;
 END LOOP;
 IF EXISTS(SELECT FROM ledger.accounts a WHERE a.id=ANY(cash) AND a.control_account)
  OR EXISTS(SELECT FROM inventory.items i WHERE i.company_id=security.company() AND i.asset_account_id=ANY(cash))
  OR EXISTS(SELECT FROM finance.control_accounts c WHERE c.company_id=security.company() AND c.account_id=ANY(cash))
 THEN RAISE EXCEPTION 'account_reserved' USING ERRCODE='23514',DETAIL='cash_accounts'; END IF;

 FOREACH k IN ARRAY control_keys LOOP
  CONTINUE WHEN nullif(p->>k,'') IS NULL;
  INSERT INTO finance.control_accounts VALUES(security.tenant(),security.company(),k,(p->>k)::uuid) ON CONFLICT DO NOTHING;
 END LOOP;
 INSERT INTO finance.settings(tenant_id,company_id,accounts) VALUES(security.tenant(),security.company(),p)
 ON CONFLICT(company_id) DO UPDATE SET accounts=EXCLUDED.accounts,version=finance.settings.version+1;
 RETURN jsonb_build_object('accounts',p);
END $$;

-- Items: name the wrong field, and keep inventory off cash and other control accounts.
CREATE FUNCTION finance.validate_item_accounts(p jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$
DECLARE asset uuid;
BEGIN
 -- Serialised with account-mapping changes (finance.configure), so both see each other's accounts.
 PERFORM pg_advisory_xact_lock(hashtextextended('finance-settings:'||security.company()::text,0));
 PERFORM finance.require_account(p->>'income_account_id',ARRAY['REVENUE','OTHER_INCOME'],'income_account_id');
 IF p->>'type'='PRODUCT' OR nullif(p->>'expense_account_id','') IS NOT NULL THEN
  PERFORM finance.require_account(p->>'expense_account_id',ARRAY['EXPENSE','COST_OF_SALES'],'expense_account_id');
 END IF;
 IF p->>'type'='PRODUCT' OR nullif(p->>'asset_account_id','') IS NOT NULL THEN
  asset:=finance.require_account(p->>'asset_account_id',ARRAY['ASSET'],'asset_account_id');
  IF EXISTS(SELECT FROM finance.reserved_accounts() r WHERE r.account_id=asset AND r.purpose<>'inventory') THEN
   RAISE EXCEPTION 'account_reserved' USING ERRCODE='23514',DETAIL='asset_account_id'; END IF;
 END IF;
END $$;

CREATE OR REPLACE FUNCTION finance.create_master(p_kind text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,invoicing,inventory,payroll,taxes,ledger,security,pg_temp AS $$
DECLARE id uuid;perm text;b uuid;v numeric;BEGIN
 perm:=CASE p_kind WHEN 'CUSTOMER' THEN 'sales' WHEN 'VENDOR' THEN 'purchases' WHEN 'ITEM' THEN 'inventory'
 WHEN 'EMPLOYEE' THEN 'payroll' WHEN 'AGENCY' THEN 'taxes' WHEN 'RATE' THEN 'taxes' END;
 IF perm IS NULL THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM security.require(perm||'.manage'); PERFORM security.require(perm||'.read');
 IF p_kind='CUSTOMER' THEN
  IF length(btrim(coalesce(p->>'name',''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_name' USING ERRCODE='22023'; END IF;
  INSERT INTO invoicing.customers(tenant_id,company_id,name,email,phone,address,tax_id) VALUES(security.tenant(),security.company(),p->>'name',p->>'email',p->>'phone',p->>'address',p->>'tax_id') RETURNING customers.id INTO id;
 ELSIF p_kind='VENDOR' THEN
  IF length(btrim(coalesce(p->>'name',''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_name' USING ERRCODE='22023'; END IF;
  INSERT INTO invoicing.vendors(tenant_id,company_id,name,email,phone,address,tax_id) VALUES(security.tenant(),security.company(),p->>'name',p->>'email',p->>'phone',p->>'address',p->>'tax_id') RETURNING vendors.id INTO id;
 ELSIF p_kind='ITEM' THEN
  IF coalesce(p->>'initial_quantity','0')::numeric<>0 THEN RAISE EXCEPTION 'use_controlled_stock_opening' USING ERRCODE='22023'; END IF;
  IF p->>'type' NOT IN('PRODUCT','SERVICE') OR length(btrim(coalesce(p->>'name',''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  PERFORM finance.validate_item_accounts(p);
  INSERT INTO inventory.items(tenant_id,company_id,type,name,sku,description,unit_price,cost_price,income_account_id,expense_account_id,asset_account_id)
  VALUES(security.tenant(),security.company(),p->>'type',p->>'name',nullif(p->>'sku',''),p->>'description',finance.amount(coalesce(p->>'unit_price','0')),finance.amount(coalesce(p->>'cost_price','0')),
  nullif(p->>'income_account_id','')::uuid,nullif(p->>'expense_account_id','')::uuid,nullif(p->>'asset_account_id','')::uuid) RETURNING items.id INTO id;
  INSERT INTO finance.positions(tenant_id,company_id,item_id) VALUES(security.tenant(),security.company(),id);
 ELSIF p_kind='EMPLOYEE' THEN
  b:=(p->>'branch_id')::uuid;PERFORM security.require('ledger.read',b);
  IF b IS NULL OR NOT EXISTS(SELECT FROM organization.branches WHERE organization.branches.id=b AND company_id=security.company() AND active)
  OR length(btrim(coalesce(p->>'first_name',''))) NOT BETWEEN 1 AND 100 OR length(btrim(coalesce(p->>'last_name',''))) NOT BETWEEN 1 AND 100
  THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  INSERT INTO payroll.employees(tenant_id,company_id,branch_id,first_name,last_name,email,department,salary_amount,pay_frequency)
  VALUES(security.tenant(),security.company(),b,p->>'first_name',p->>'last_name',p->>'email',p->>'department',finance.amount(p->>'salary_amount'),p->>'pay_frequency') RETURNING employees.id INTO id;
 ELSIF p_kind='AGENCY' THEN
  INSERT INTO taxes.tax_agencies(tenant_id,company_id,name,code) VALUES(security.tenant(),security.company(),p->>'name',p->>'code') RETURNING tax_agencies.id INTO id;
 ELSE
  v:=(p->>'rate_percent')::numeric;
  INSERT INTO taxes.tax_rates(tenant_id,company_id,agency_id,name,code,rate_percent,effective_from,effective_to)
  VALUES(security.tenant(),security.company(),(p->>'agency_id')::uuid,p->>'name',p->>'code',v,(p->>'effective_from')::date,nullif(p->>'effective_to','')::date) RETURNING tax_rates.id INTO id;
 END IF;
 RETURN jsonb_build_object('id',id);
END $$;

-- Where a module journal came from, as far as the caller may see the source record.
CREATE FUNCTION ledger.journal_source(p_journal uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,ledger,pg_temp AS $$
 SELECT coalesce(
  (SELECT jsonb_build_object('kind',d.kind,'id',d.id,'number',d.document_no,'role',
     CASE p_journal WHEN d.journal_id THEN 'document' WHEN d.payment_journal_id THEN 'payment'
      WHEN d.reversal_journal_id THEN 'reversal' ELSE 'payment_reversal' END)
   FROM finance.documents d WHERE p_journal IN(d.journal_id,d.payment_journal_id,d.reversal_journal_id,d.reversal_payment_journal_id) LIMIT 1),
  (SELECT jsonb_build_object('kind','ADJUSTMENT','id',a.id,'number',a.number,'role',lower(a.purpose)) FROM finance.adjustments a WHERE a.journal_id=p_journal LIMIT 1),
  (SELECT jsonb_build_object('kind','YEAR_CLOSE','id',y.id,'number',f.name,'role','closing') FROM ledger.year_closings y JOIN ledger.fiscal_years f ON f.id=y.fiscal_year_id
   WHERE p_journal=ANY(y.journal_ids) LIMIT 1))
$$;

CREATE OR REPLACE FUNCTION ledger.get_journal(p_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE j ledger.journals; result jsonb; gl boolean;
 BEGIN
 SELECT * INTO j FROM ledger.journals WHERE id=p_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 PERFORM security.require('ledger.read',j.branch_id);
 -- Only manual journals, and reversals of manual journals, are driven from the general ledger.
 gl:=j.source_type='MANUAL' OR (j.source_type='REVERSAL' AND EXISTS(SELECT FROM ledger.journals o WHERE o.id=j.reversed_from AND o.source_type='MANUAL'));
 SELECT to_jsonb(j)||jsonb_build_object('effective_state',CASE WHEN EXISTS(SELECT FROM ledger.journals r WHERE r.reversed_from=j.id AND r.state='POSTED') THEN 'REVERSED' ELSE j.state END,
 'fx_rate',j.fx_rate::text,'lines',coalesce((SELECT jsonb_agg(jsonb_build_object('line_no',l.line_no,'is_rounding',l.is_rounding,'account_id',l.account_id,
 'account_code',a.code,'account_name',a.name,'description',l.description,'debit_minor',l.debit_minor::text,'credit_minor',l.credit_minor::text,
 'functional_debit_minor',l.functional_debit_minor::text,'functional_credit_minor',l.functional_credit_minor::text,
 'dimensions',coalesce((SELECT jsonb_agg(jsonb_build_object('kind',d.kind,'dimension_id',d.dimension_id)) FROM ledger.line_dimensions d
 WHERE d.journal_id=l.journal_id AND d.line_no=l.line_no),'[]'::jsonb)) ORDER BY l.line_no)
 FROM ledger.lines l JOIN ledger.accounts a ON a.id=l.account_id WHERE l.journal_id=j.id),'[]'::jsonb),
 'source_document',CASE WHEN gl THEN NULL ELSE ledger.journal_source(j.id) END,
 'permissions',jsonb_build_object('submit',gl AND security.can('journal.submit',j.branch_id),'approve',
 gl AND security.can('journal.approve',j.branch_id,(SELECT sum(functional_debit_minor) FROM ledger.lines WHERE journal_id=j.id)) AND
 security.actor()<>j.created_by AND security.actor() IS DISTINCT FROM j.submitted_by,
 'post',gl AND security.can('journal.post',j.branch_id),'reverse',gl AND security.can('journal.reverse',j.branch_id),'void',gl AND security.can('journal.void',j.branch_id))) INTO result;
 RETURN result;
 END $$;

REVOKE ALL ON FUNCTION finance.require_account(text,text[],text),finance.reserved_accounts(),finance.validate_item_accounts(jsonb),ledger.journal_source(uuid) FROM PUBLIC;

-- 5. Control trails show colleagues by name: the members of the current company, display names
--    only (no email or contact data).
CREATE OR REPLACE FUNCTION ledger.reference_data() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,ledger,organization,security,pg_temp AS $$
BEGIN
 IF NOT security.has('ledger.read') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('accounts',coalesce((SELECT jsonb_agg(to_jsonb(a) ORDER BY code) FROM ledger.accounts a),'[]'::jsonb),
 'branches',coalesce((SELECT jsonb_agg(to_jsonb(b) ORDER BY code) FROM organization.branches b),'[]'::jsonb),
 'periods',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY start_date) FROM ledger.periods p),'[]'::jsonb),
 'dimensions',coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY kind,code) FROM ledger.dimensions d),'[]'::jsonb),
 'currencies',(SELECT jsonb_agg(to_jsonb(c) ORDER BY code) FROM organization.currencies c),
 'permissions',jsonb_build_object('create',security.has('journal.create'),'audit',security.has('audit.read'),
  'close',security.can('period.close') AND security.can('ledger.read'),
  'users',security.can('user.manage'),'roles',security.can('role.manage'),'configure',security.can('configuration.manage')),
 'held',to_jsonb(security.held_permissions()),
 'features',(SELECT jsonb_object_agg(f.code,NOT (f.code=ANY(security.disabled_features()))) FROM organization.features f),
 'people',coalesce((SELECT jsonb_agg(jsonb_build_object('id',u.id,'name',u.display_name) ORDER BY u.display_name)
  FROM security.users u WHERE u.tenant_id=security.tenant() AND u.active
  AND EXISTS(SELECT FROM security.memberships m WHERE m.user_id=u.id AND m.company_id=security.company())),'[]'::jsonb));
END $$;
