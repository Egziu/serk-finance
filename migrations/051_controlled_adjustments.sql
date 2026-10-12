-- 0.2.2-rc1: controlled adjustments for module control accounts.
--
-- Control accounts (receivable, payable, VAT, payroll liabilities, inventory) reject ordinary
-- manual journals so that sub-ledgers cannot drift from the general ledger. Before this
-- migration that also meant VAT and payroll liabilities could never be remitted, receivables
-- could not be written off, opening balances could not be entered and inventory could not be
-- written down to net realisable value (IAS 2.28).
--
-- A controlled adjustment is a purpose-specific, dual-controlled document. It may touch only
-- the control accounts its purpose allows, needs the module permission for that purpose, is
-- posted through a SYSTEM journal (never through the general-ledger command), and an
-- inventory adjustment moves the item's quantity/value position together with the ledger.
SET LOCAL ROLE serk_owner;

CREATE TABLE finance.adjustments(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,branch_id uuid NOT NULL,
 number text NOT NULL,purpose text NOT NULL CHECK(purpose IN('TAX_SETTLEMENT','PAYROLL_SETTLEMENT','RECEIVABLE_ADJUSTMENT',
  'PAYABLE_ADJUSTMENT','INVENTORY_ADJUSTMENT','OPENING_BALANCE')),
 accounting_date date NOT NULL,description text NOT NULL,lines jsonb NOT NULL,total_minor ledger.minor NOT NULL,
 state text NOT NULL DEFAULT 'DRAFT' CHECK(state IN('DRAFT','SUBMITTED','POSTED','VOIDED')),
 journal_id uuid,created_by uuid NOT NULL,submitted_by uuid,approved_by uuid,reason text NOT NULL,
 version bigint NOT NULL DEFAULT 1,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id),
 FOREIGN KEY(tenant_id,company_id,branch_id) REFERENCES organization.branches(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,company_id,journal_id) REFERENCES ledger.journals(tenant_id,company_id,id),
 FOREIGN KEY(tenant_id,created_by) REFERENCES security.users(tenant_id,id),
 UNIQUE(company_id,number),CHECK(approved_by IS NULL OR (approved_by<>created_by AND approved_by<>submitted_by)));
CREATE INDEX finance_adjustment_scope ON finance.adjustments(company_id,created_at DESC,id);

CREATE FUNCTION finance.adjustment_permission(p_purpose text) RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT CASE p_purpose WHEN 'TAX_SETTLEMENT' THEN 'taxes' WHEN 'PAYROLL_SETTLEMENT' THEN 'payroll'
 WHEN 'RECEIVABLE_ADJUSTMENT' THEN 'sales' WHEN 'PAYABLE_ADJUSTMENT' THEN 'purchases' WHEN 'INVENTORY_ADJUSTMENT' THEN 'inventory'
 WHEN 'OPENING_BALANCE' THEN 'configuration' END $$;
CREATE FUNCTION finance.adjustment_controls(p_purpose text) RETURNS text[] LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT CASE p_purpose WHEN 'TAX_SETTLEMENT' THEN ARRAY['output_tax','input_tax']
 WHEN 'PAYROLL_SETTLEMENT' THEN ARRAY['payroll_payable','payroll_tax','pension_payable']
 WHEN 'RECEIVABLE_ADJUSTMENT' THEN ARRAY['receivable'] WHEN 'PAYABLE_ADJUSTMENT' THEN ARRAY['payable']
 WHEN 'INVENTORY_ADJUSTMENT' THEN ARRAY['inventory']
 WHEN 'OPENING_BALANCE' THEN ARRAY['receivable','payable','output_tax','input_tax','payroll_payable','payroll_tax','pension_payable'] END $$;
-- Read permission for listing: configuration has no ".read", so opening balances need manage.
CREATE FUNCTION finance.adjustment_read_permission(p_purpose text) RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT CASE WHEN p_purpose='OPENING_BALANCE' THEN 'configuration.manage' ELSE finance.adjustment_permission(p_purpose)||'.read' END $$;

ALTER TABLE finance.adjustments ENABLE ROW LEVEL SECURITY;
ALTER TABLE finance.adjustments FORCE ROW LEVEL SECURITY;
CREATE POLICY scoped ON finance.adjustments USING(tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()));
CREATE POLICY branch_scope ON finance.adjustments AS RESTRICTIVE
 USING((SELECT security.company_wide('ledger.read')) OR branch_id=ANY((SELECT security.permitted_branches('ledger.read'))::uuid[]));
CREATE POLICY module_read ON finance.adjustments AS RESTRICTIVE FOR SELECT
 USING(finance.adjustment_read_permission(purpose)=ANY((SELECT security.held_permissions())::text[]));
GRANT SELECT ON finance.adjustments TO serk_api;
CREATE TRIGGER finance_adjustments_audit AFTER INSERT OR UPDATE ON finance.adjustments FOR EACH ROW EXECUTE FUNCTION audit.record_change();

CREATE FUNCTION finance.require_adjustment(p_purpose text,p_branch uuid) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$
DECLARE perm text:=finance.adjustment_permission(p_purpose);
BEGIN
 IF perm IS NULL THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM security.require(perm||'.manage',p_branch);
 IF perm<>'configuration' THEN PERFORM security.require(perm||'.read',p_branch); END IF;
 PERFORM security.require('ledger.read',p_branch);
END $$;

CREATE FUNCTION finance.adjustment_command(p_key text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,ledger,inventory,organization,security,pg_temp AS $$
DECLARE h text; prior finance.receipts; a finance.adjustments; b uuid; dt date; purpose text; line jsonb; norm jsonb:='[]';
 dr numeric; cr numeric; td numeric:=0; tc numeric:=0; acc ledger.accounts; ctl text[]; allowed text[]; touched boolean:=false;
 item inventory.items; qty numeric; pos finance.positions; jn jsonb; v bigint; entry jsonb:='[]'; result jsonb; seen uuid[]:='{}';
BEGIN
 IF p_action NOT IN('create','submit','approve','void') OR jsonb_typeof(p)<>'object' THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'idempotency_key_required' USING ERRCODE='22023'; END IF;
 IF length(btrim(coalesce(p->>'reason',''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'invalid_reason' USING ERRCODE='22023'; END IF;
 h:=encode(sha256(convert_to(jsonb_build_object('kind','ADJUSTMENT','action',p_action,'payload',p)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(security.company()::text||security.actor()::text||p_key,0));
 SELECT * INTO prior FROM finance.receipts WHERE company_id=security.company() AND user_id=security.actor() AND key=p_key;
 IF FOUND THEN
  IF prior.request_hash<>h THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='22000'; END IF;
  SELECT * INTO a FROM finance.adjustments WHERE id=(prior.response->>'id')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  PERFORM finance.require_adjustment(a.purpose,a.branch_id); RETURN prior.response;
 END IF;

 IF p_action='create' THEN
  IF EXISTS(SELECT FROM jsonb_object_keys(p) k WHERE k NOT IN('branch_id','accounting_date','purpose','number','description','lines','reason'))
  THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  purpose:=p->>'purpose';b:=(p->>'branch_id')::uuid;dt:=(p->>'accounting_date')::date;
  PERFORM finance.require_adjustment(purpose,b);
  IF b IS NULL OR dt IS NULL OR NOT isfinite(dt) OR NOT EXISTS(SELECT FROM organization.branches WHERE id=b AND company_id=security.company() AND active)
   OR length(btrim(coalesce(p->>'number',''))) NOT BETWEEN 1 AND 100 OR length(btrim(coalesce(p->>'description',''))) NOT BETWEEN 1 AND 500
  THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') NOT BETWEEN 2 AND 100 THEN RAISE EXCEPTION 'invalid_lines' USING ERRCODE='22023'; END IF;
  allowed:=finance.adjustment_controls(purpose);
  FOR line IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
   IF jsonb_typeof(line) IS DISTINCT FROM 'object' OR EXISTS(SELECT FROM jsonb_object_keys(line) k WHERE k NOT IN('account_id','debit_minor','credit_minor','description','item_id','quantity_delta'))
   THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
   dr:=finance.amount(coalesce(line->>'debit_minor','0'));cr:=finance.amount(coalesce(line->>'credit_minor','0'));
   IF (dr>0)=(cr>0) THEN RAISE EXCEPTION 'invalid_amount' USING ERRCODE='22023'; END IF;
   SELECT * INTO acc FROM ledger.accounts WHERE id=(line->>'account_id')::uuid AND company_id=security.company() AND active AND posting_allowed;
   IF NOT FOUND THEN RAISE EXCEPTION 'invalid_posting_account' USING ERRCODE='23514'; END IF;
   SELECT array_agg(DISTINCT c.purpose) INTO ctl FROM finance.control_accounts c WHERE c.company_id=security.company() AND c.account_id=acc.id;
   IF ctl IS NOT NULL THEN
    IF NOT ctl && allowed THEN RAISE EXCEPTION 'control_account_not_allowed_for_purpose' USING ERRCODE='23514'; END IF;
    touched:=true;
   ELSIF acc.control_account THEN RAISE EXCEPTION 'control_account_not_allowed_for_purpose' USING ERRCODE='23514';
   END IF;
   qty:=NULL;
   IF ctl IS NOT NULL AND 'inventory'=ANY(ctl) THEN
    qty:=coalesce(nullif(line->>'quantity_delta','')::numeric,0);
    IF abs(qty)>=1e20 OR scale(qty)>6 THEN RAISE EXCEPTION 'invalid_amount' USING ERRCODE='22023'; END IF;
    SELECT * INTO item FROM inventory.items WHERE id=(line->>'item_id')::uuid AND company_id=security.company() AND type='PRODUCT';
    IF NOT FOUND OR item.asset_account_id IS DISTINCT FROM acc.id OR (line->>'item_id')::uuid=ANY(seen) THEN RAISE EXCEPTION 'invalid_reference' USING ERRCODE='23503'; END IF;
    IF (qty>0 AND cr>0) OR (qty<0 AND dr>0) THEN RAISE EXCEPTION 'inconsistent_inventory_adjustment' USING ERRCODE='23514'; END IF;
    seen:=seen||item.id;
   ELSIF line ? 'item_id' OR line ? 'quantity_delta' THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023';
   END IF;
   td:=td+dr;tc:=tc+cr;
   norm:=norm||jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('account_id',acc.id,'debit_minor',dr::text,'credit_minor',cr::text,
    'description',coalesce(line->>'description',''),'item_id',CASE WHEN qty IS NOT NULL THEN item.id END,'quantity_delta',qty::text)));
  END LOOP;
  IF td<>tc THEN RAISE EXCEPTION 'journal_unbalanced' USING ERRCODE='23514'; END IF;
  IF NOT touched THEN RAISE EXCEPTION 'use_general_journal' USING ERRCODE='23514'; END IF;
  INSERT INTO finance.adjustments(tenant_id,company_id,branch_id,number,purpose,accounting_date,description,lines,total_minor,created_by,reason)
  VALUES(security.tenant(),security.company(),b,btrim(p->>'number'),purpose,dt,btrim(p->>'description'),norm,td,security.actor(),p->>'reason') RETURNING * INTO a;
 ELSE
  SELECT * INTO a FROM finance.adjustments WHERE id=(p->>'id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  PERFORM finance.require_adjustment(a.purpose,a.branch_id);
  IF a.version IS DISTINCT FROM (p->>'expected_version')::bigint THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
  IF p_action IN('submit','approve') THEN PERFORM finance.assert_clean(); END IF;
  IF p_action='submit' THEN
   IF a.state<>'DRAFT' OR a.created_by<>security.actor() THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   FOR line IN SELECT * FROM jsonb_array_elements(a.lines) LOOP
    entry:=entry||jsonb_build_array(jsonb_build_object('account_id',line->>'account_id','debit_minor',line->>'debit_minor','credit_minor',line->>'credit_minor','description',line->>'description'));
   END LOOP;
   jn:=ledger.module_command('adjustment:'||a.id||':create','create',jsonb_build_object('branch_id',a.branch_id,'accounting_date',a.accounting_date,
    'currency',(SELECT functional_currency FROM organization.companies WHERE id=a.company_id),'fx_rate','1',
    'description',a.purpose||' '||a.number||': '||a.description,'reason',p->>'reason','lines',entry));
   jn:=ledger.module_command('adjustment:'||a.id||':submit','submit',jsonb_build_object('id',jn->>'id','expected_version',jn->>'version','reason',p->>'reason'));
   UPDATE finance.adjustments SET state='SUBMITTED',submitted_by=security.actor(),journal_id=(jn->>'id')::uuid,version=version+1,reason=p->>'reason' WHERE id=a.id RETURNING * INTO a;
  ELSIF p_action='approve' THEN
   IF a.state<>'SUBMITTED' THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   IF a.created_by=security.actor() OR a.submitted_by=security.actor() THEN RAISE EXCEPTION 'segregation_of_duties' USING ERRCODE='42501'; END IF;
   SELECT version INTO v FROM ledger.journals WHERE id=a.journal_id;
   jn:=ledger.module_command('adjustment:'||a.id||':approve','approve',jsonb_build_object('id',a.journal_id,'expected_version',v,'reason',p->>'reason'));
   jn:=ledger.module_command('adjustment:'||a.id||':post','post',jsonb_build_object('id',a.journal_id,'expected_version',jn->>'version','reason',p->>'reason'));
   -- Inventory: quantity and value move with the ledger (stable item order avoids lock inversion).
   FOR line IN SELECT * FROM jsonb_array_elements(a.lines) WHERE value ? 'item_id' ORDER BY value->>'item_id' LOOP
    INSERT INTO finance.positions(tenant_id,company_id,item_id) VALUES(a.tenant_id,a.company_id,(line->>'item_id')::uuid) ON CONFLICT DO NOTHING;
    SELECT * INTO STRICT pos FROM finance.positions WHERE item_id=(line->>'item_id')::uuid FOR UPDATE;
    IF pos.last_accounting_date IS NOT NULL AND a.accounting_date<pos.last_accounting_date THEN RAISE EXCEPTION 'inventory_date_order' USING ERRCODE='23514'; END IF;
    qty:=(line->>'quantity_delta')::numeric;dr:=(line->>'debit_minor')::numeric-(line->>'credit_minor')::numeric;
    IF pos.quantity+qty<pos.reserved_quantity OR pos.value_minor+dr<pos.reserved_minor THEN RAISE EXCEPTION 'insufficient_stock' USING ERRCODE='23514'; END IF;
    IF pos.quantity+qty=0 AND pos.value_minor+dr<>0 THEN RAISE EXCEPTION 'inventory_value_without_quantity' USING ERRCODE='23514'; END IF;
    UPDATE finance.positions SET quantity=quantity+qty,value_minor=value_minor+dr,last_accounting_date=a.accounting_date WHERE item_id=pos.item_id;
    INSERT INTO inventory.transactions(tenant_id,company_id,item_id,quantity,reference_type,reference_id)
    VALUES(a.tenant_id,a.company_id,pos.item_id,qty,'ADJUSTMENT',a.id);
   END LOOP;
   UPDATE finance.adjustments SET state='POSTED',approved_by=security.actor(),version=version+1,reason=p->>'reason' WHERE id=a.id RETURNING * INTO a;
  ELSE
   IF a.state NOT IN('DRAFT','SUBMITTED') OR a.created_by<>security.actor() THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   IF a.journal_id IS NOT NULL THEN
    SELECT version INTO v FROM ledger.journals WHERE id=a.journal_id;
    jn:=ledger.module_command('adjustment:'||a.id||':void','void',jsonb_build_object('id',a.journal_id,'expected_version',v,'reason',p->>'reason'));
   END IF;
   UPDATE finance.adjustments SET state='VOIDED',version=version+1,reason=p->>'reason' WHERE id=a.id RETURNING * INTO a;
  END IF;
 END IF;
 result:=to_jsonb(a)||jsonb_build_object('total_minor',a.total_minor::text);
 INSERT INTO finance.receipts VALUES(security.tenant(),security.company(),security.actor(),p_key,h,result);
 RETURN result;
END $$;

CREATE FUNCTION finance.list_adjustments() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('total_minor',a.total_minor::text) ORDER BY a.created_at DESC,a.id),'[]')
 FROM (SELECT * FROM finance.adjustments ORDER BY created_at DESC,id LIMIT 200) a
$$;

REVOKE ALL ON FUNCTION finance.adjustment_command(text,text,jsonb),finance.list_adjustments(),finance.require_adjustment(text,uuid),
 finance.adjustment_permission(text),finance.adjustment_controls(text),finance.adjustment_read_permission(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION finance.adjustment_command(text,text,jsonb),finance.list_adjustments(),
 finance.adjustment_permission(text),finance.adjustment_controls(text),finance.adjustment_read_permission(text) TO serk_api;
