-- 026_audit_triggers.sql
-- 1. Redefine audit.record_change() to safely handle tables without version or state columns natively
CREATE OR REPLACE FUNCTION audit.record_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,audit,integration,security,pg_temp AS $$
 DECLARE h audit.heads; ts timestamptz:=clock_timestamp();eid uuid:=gen_random_uuid();old_json jsonb;new_json jsonb;ctx jsonb; payload text;eh text;action_name text;
 v_version bigint; v_state text;
 BEGIN
 new_json:=to_jsonb(NEW);IF TG_OP='UPDATE' THEN old_json:=to_jsonb(OLD); END IF;
 IF TG_TABLE_NAME='journals' THEN
  new_json:=new_json||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_no) FROM ledger.lines l WHERE l.journal_id=NEW.id),
   'dimensions',(SELECT jsonb_agg(to_jsonb(d) ORDER BY d.line_no,d.kind) FROM ledger.line_dimensions d WHERE d.journal_id=NEW.id));
 END IF;
 ctx:=coalesce(nullif(current_setting('serk.request_context',true),'')::jsonb,'{}'::jsonb);
 
 v_state := coalesce(new_json->>'state', new_json->>'status', 'updated');
 v_version := coalesce((new_json->>'version')::bigint, 1);
 action_name:=TG_TABLE_NAME||'.'||lower(v_state);
 
 INSERT INTO audit.heads(tenant_id,company_id) VALUES(NEW.tenant_id,NEW.company_id) ON CONFLICT DO NOTHING;
 SELECT * INTO STRICT h FROM audit.heads WHERE company_id=NEW.company_id FOR UPDATE;
 payload:=jsonb_build_object('id',eid,'tenant_id',NEW.tenant_id,'company_id',NEW.company_id,'sequence',h.last_sequence+1,
  'actor',security.actor(),'at',ts,'action',action_name,'entity',NEW.id,'before',old_json,'after',new_json,'context',ctx)::text;
 eh:=encode(sha256(convert_to(h.last_hash||payload,'UTF8')),'hex');
 INSERT INTO audit.events VALUES(eid,NEW.tenant_id,NEW.company_id,h.last_sequence+1,security.actor(),ts,action_name,NEW.id,
 old_json,new_json,coalesce(new_json->>'reason',ctx->>'reason','State transition'),ctx,h.last_hash,eh,payload);
 UPDATE audit.heads SET last_sequence=h.last_sequence+1,last_hash=eh WHERE company_id=NEW.company_id;
 INSERT INTO integration.outbox(id,tenant_id,company_id,aggregate_id,aggregate_version,event_type,payload)
 VALUES(eid,NEW.tenant_id,NEW.company_id,NEW.id,v_version,action_name,jsonb_build_object('schema_version',1,'id',eid,
 'tenant_id',NEW.tenant_id,'company_id',NEW.company_id,'aggregate_id',NEW.id,'version',v_version,'state',v_state,'audit_hash',eh));
 RETURN NEW;
 END $$;

-- 2. Attach triggers to newly built module tables
CREATE TRIGGER audit_inv_customers AFTER INSERT OR UPDATE ON invoicing.customers FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER audit_inv_vendors AFTER INSERT OR UPDATE ON invoicing.vendors FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER audit_inv_invoices AFTER INSERT OR UPDATE ON invoicing.invoices FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER audit_inv_bills AFTER INSERT OR UPDATE ON invoicing.bills FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER audit_tax_agencies AFTER INSERT OR UPDATE ON taxes.tax_agencies FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER audit_tax_rates AFTER INSERT OR UPDATE ON taxes.tax_rates FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER audit_pay_employees AFTER INSERT OR UPDATE ON payroll.employees FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER audit_pay_payruns AFTER INSERT OR UPDATE ON payroll.payruns FOR EACH ROW EXECUTE FUNCTION audit.record_change();
CREATE TRIGGER audit_inv_items AFTER INSERT OR UPDATE ON inventory.items FOR EACH ROW EXECUTE FUNCTION audit.record_change();
