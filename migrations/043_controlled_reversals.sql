SET LOCAL ROLE serk_owner;
ALTER TABLE finance.documents DROP CONSTRAINT documents_state_check;
ALTER TABLE finance.documents ADD CHECK(state IN('DRAFT','SUBMITTED','APPROVED','PAID','VOIDED','REVERSED'));
ALTER TABLE finance.documents ADD CHECK(reversal_state IN('SUBMITTED','POSTED'));
ALTER TABLE finance.documents ADD FOREIGN KEY(tenant_id,company_id,reversal_payment_journal_id) REFERENCES ledger.journals(tenant_id,company_id,id);
ALTER TABLE finance.documents ADD FOREIGN KEY(tenant_id,company_id,reversal_journal_id) REFERENCES ledger.journals(tenant_id,company_id,id);
ALTER TABLE payroll.payruns DROP CONSTRAINT payruns_status_check;
ALTER TABLE payroll.payruns ADD CHECK(status IN('DRAFT','APPROVED','PAID','VOIDED','REVERSED'));
CREATE OR REPLACE FUNCTION ledger.command(p_key text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,ledger,finance,security,pg_temp AS $$ BEGIN
 IF p_action<>'create' AND EXISTS(SELECT FROM finance.documents WHERE journal_id=(p->>'id')::uuid OR payment_journal_id=(p->>'id')::uuid OR reversal_journal_id=(p->>'id')::uuid OR reversal_payment_journal_id=(p->>'id')::uuid)
 THEN RAISE EXCEPTION 'use_module_workflow' USING ERRCODE='55000'; END IF;
 RETURN ledger.command_internal(p_key,p_action,p);
END $$;
CREATE FUNCTION finance.reversal_command(p_key text,p_kind text,p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,ledger,inventory,taxes,payroll,security,pg_temp AS $$
DECLARE d finance.documents;prior finance.receipts;hash text;result jsonb;jn jsonb;v bigint;line jsonb;item inventory.items;pos finance.positions;qty numeric;cost numeric;dt date;
BEGIN
 IF finance.permission(p_kind) IS NULL OR p_action NOT IN('reverse','reverse-approve','reverse-void','payment-void') THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM security.require(finance.permission(p_kind)||'.manage');PERFORM security.require(finance.permission(p_kind)||'.read');
 IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 THEN RAISE EXCEPTION 'idempotency_key_required' USING ERRCODE='22023'; END IF;
 hash:=encode(sha256(convert_to(jsonb_build_object('kind',p_kind,'action',p_action,'payload',p)::text,'UTF8')),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(security.company()::text||security.actor()::text||p_key,0));
 SELECT * INTO prior FROM finance.receipts WHERE company_id=security.company() AND user_id=security.actor() AND key=p_key;
 IF FOUND THEN
  IF prior.request_hash<>hash THEN RAISE EXCEPTION 'idempotency_conflict' USING ERRCODE='22000'; END IF;
  SELECT * INTO d FROM finance.documents WHERE documents.id=(prior.response->>'id')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  PERFORM security.require(finance.permission(p_kind)||'.manage',d.branch_id);RETURN prior.response;
 END IF;
 SELECT * INTO d FROM finance.documents WHERE documents.id=(p->>'id')::uuid AND kind=p_kind FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 PERFORM security.require(finance.permission(p_kind)||'.manage',d.branch_id);
 IF d.version IS DISTINCT FROM (p->>'expected_version')::bigint THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
 IF length(btrim(coalesce(p->>'reason',''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'invalid_reason' USING ERRCODE='22023'; END IF;
 IF p_action IN('reverse','reverse-approve') THEN PERFORM finance.assert_clean(); END IF;
 IF p_action='payment-void' THEN
  IF d.state<>'APPROVED' OR d.payment_state IS DISTINCT FROM 'SUBMITTED' OR d.payment_by<>security.actor()
  THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
  SELECT version INTO v FROM ledger.journals WHERE journals.id=d.payment_journal_id;
  jn:=ledger.command_internal('finance:'||d.id||':payment-void'||':'||d.version,'void',jsonb_build_object('id',d.payment_journal_id,'expected_version',v,'reason',p->>'reason'));
  UPDATE finance.documents SET payment_journal_id=NULL,payment_state=NULL,payment_by=NULL,payment_date=NULL,payment_account_id=NULL,version=version+1 WHERE documents.id=d.id RETURNING * INTO d;
 ELSE
  IF d.state NOT IN('APPROVED','PAID') OR d.payment_state='SUBMITTED' THEN RAISE EXCEPTION 'reverse_payment_first_or_settle_with_credit_document' USING ERRCODE='55000'; END IF;
  IF p_action='reverse-void' THEN
   IF d.reversal_state IS DISTINCT FROM 'SUBMITTED' OR d.reversal_by<>security.actor() THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   SELECT version INTO v FROM ledger.journals WHERE journals.id=d.reversal_journal_id;
   jn:=ledger.command_internal('finance:'||d.id||':reverse-void'||':'||d.version,'void',jsonb_build_object('id',d.reversal_journal_id,'expected_version',v,'reason',p->>'reason'));
   IF d.reversal_payment_journal_id IS NOT NULL THEN
    SELECT version INTO v FROM ledger.journals WHERE journals.id=d.reversal_payment_journal_id;
    jn:=ledger.command_internal('finance:'||d.id||':refund-void'||':'||d.version,'void',jsonb_build_object('id',d.reversal_payment_journal_id,'expected_version',v,'reason',p->>'reason'));
   END IF;
   UPDATE finance.documents SET reversal_journal_id=NULL,reversal_payment_journal_id=NULL,reversal_state=NULL,reversal_by=NULL,version=version+1 WHERE documents.id=d.id RETURNING * INTO d;
  ELSIF p_action='reverse' THEN
   IF d.reversal_journal_id IS NOT NULL THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   dt:=(p->>'accounting_date')::date;
   IF dt IS NULL OR NOT isfinite(dt) OR dt<d.accounting_date OR (d.payment_date IS NOT NULL AND dt<d.payment_date) THEN RAISE EXCEPTION 'invalid_dates' USING ERRCODE='22023'; END IF;
   SELECT version INTO v FROM ledger.journals WHERE journals.id=d.journal_id;
   jn:=ledger.command_internal('finance:'||d.id||':reverse-create'||':'||d.version,'reverse',jsonb_build_object('id',d.journal_id,'expected_version',v,'accounting_date',dt,'reason',p->>'reason'));
   jn:=ledger.command_internal('finance:'||d.id||':reverse-submit'||':'||d.version,'submit',jsonb_build_object('id',jn->>'id','expected_version',jn->>'version','reason',p->>'reason'));
   IF d.payment_journal_id IS NOT NULL THEN
    SELECT version INTO v FROM ledger.journals WHERE journals.id=d.payment_journal_id;
    result:=ledger.command_internal('finance:'||d.id||':refund-create'||':'||d.version,'reverse',jsonb_build_object('id',d.payment_journal_id,'expected_version',v,'accounting_date',dt,'reason',p->>'reason'));
    result:=ledger.command_internal('finance:'||d.id||':refund-submit'||':'||d.version,'submit',jsonb_build_object('id',result->>'id','expected_version',result->>'version','reason',p->>'reason'));
   END IF;
   UPDATE finance.documents SET reversal_journal_id=(jn->>'id')::uuid,reversal_payment_journal_id=(result->>'id')::uuid,reversal_by=security.actor(),reversal_state='SUBMITTED',version=version+1 WHERE documents.id=d.id RETURNING * INTO d;
  ELSE
   IF d.reversal_state IS DISTINCT FROM 'SUBMITTED' THEN RAISE EXCEPTION 'invalid_transition' USING ERRCODE='55000'; END IF;
   IF d.reversal_by=security.actor() THEN RAISE EXCEPTION 'segregation_of_duties' USING ERRCODE='42501'; END IF;
   SELECT version INTO v FROM ledger.journals WHERE journals.id=d.reversal_journal_id;
   jn:=ledger.command_internal('finance:'||d.id||':reverse-approve'||':'||d.version,'approve',jsonb_build_object('id',d.reversal_journal_id,'expected_version',v,'reason',p->>'reason'));
   jn:=ledger.command_internal('finance:'||d.id||':reverse-post'||':'||d.version,'post',jsonb_build_object('id',d.reversal_journal_id,'expected_version',jn->>'version','reason',p->>'reason'));
   IF d.reversal_payment_journal_id IS NOT NULL THEN
    SELECT version INTO v FROM ledger.journals WHERE journals.id=d.reversal_payment_journal_id;
    result:=ledger.command_internal('finance:'||d.id||':refund-approve'||':'||d.version,'approve',jsonb_build_object('id',d.reversal_payment_journal_id,'expected_version',v,'reason',p->>'reason'));
    result:=ledger.command_internal('finance:'||d.id||':refund-post'||':'||d.version,'post',jsonb_build_object('id',d.reversal_payment_journal_id,'expected_version',result->>'version','reason',p->>'reason'));
   END IF;
   FOR line IN SELECT * FROM jsonb_array_elements(d.payload->'lines') ORDER BY value->>'item_id' LOOP
    IF p_kind='PAYROLL' THEN EXIT; END IF;
    SELECT * INTO STRICT item FROM inventory.items WHERE items.id=(line->>'item_id')::uuid FOR SHARE;
    IF item.type='PRODUCT' THEN
     qty:=(line->>'quantity')::numeric;
     cost:=CASE WHEN p_kind='INVOICE' THEN (line->>'stock_cost_minor')::numeric ELSE (line->>'line_total')::numeric END;
     SELECT * INTO STRICT pos FROM finance.positions WHERE item_id=item.id FOR UPDATE;
     IF pos.last_accounting_date IS NOT NULL AND (jn->>'accounting_date')::date<pos.last_accounting_date THEN RAISE EXCEPTION 'inventory_date_order' USING ERRCODE='23514'; END IF;
     IF p_kind<>'INVOICE' AND (pos.quantity-pos.reserved_quantity<qty OR pos.value_minor-pos.reserved_minor<cost)
     THEN RAISE EXCEPTION 'insufficient_stock_for_reversal' USING ERRCODE='23514'; END IF;
     UPDATE finance.positions SET last_accounting_date=(jn->>'accounting_date')::date,quantity=quantity+CASE WHEN p_kind='INVOICE' THEN qty ELSE -qty END,
      value_minor=value_minor+CASE WHEN p_kind='INVOICE' THEN cost ELSE -cost END WHERE item_id=item.id;
     INSERT INTO inventory.transactions(tenant_id,company_id,item_id,quantity,reference_type,reference_id)
     VALUES(security.tenant(),security.company(),item.id,CASE WHEN p_kind='INVOICE' THEN qty ELSE -qty END,p_kind||'_REVERSAL',d.id);
    END IF;
    IF p_kind IN('INVOICE','BILL') AND (line->>'tax_minor')::numeric>0 THEN
     INSERT INTO taxes.tax_entries(tenant_id,company_id,tax_rate_id,journal_id,taxable_amount,tax_amount,transaction_type)
     VALUES(security.tenant(),security.company(),(line->>'tax_rate_id')::uuid,d.reversal_journal_id,(line->>'line_total')::numeric,
      (line->>'tax_minor')::numeric,CASE WHEN p_kind='INVOICE' THEN 'PURCHASE' ELSE 'SALE' END);
    END IF;
   END LOOP;
   UPDATE finance.documents SET state='REVERSED',reversal_state='POSTED',version=version+1 WHERE documents.id=d.id RETURNING * INTO d;
   IF p_kind='PAYROLL' THEN UPDATE payroll.payruns SET status='REVERSED' WHERE document_id=d.id; END IF;
  END IF;
 END IF;
 result:=to_jsonb(d)||jsonb_build_object('subtotal',d.subtotal::text,'tax_total',d.tax_total::text,'total_amount',d.total_amount::text);
 INSERT INTO finance.receipts VALUES(security.tenant(),security.company(),security.actor(),p_key,hash,result);RETURN result;
END $$;
GRANT EXECUTE ON FUNCTION finance.reversal_command(text,text,text,jsonb) TO serk_api;
