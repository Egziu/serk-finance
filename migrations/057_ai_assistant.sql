-- 0.4.0: AI assistant that answers from the books and prepares drafts.
--
-- The assistant acts strictly as the signed-in user: every read and every draft runs through
-- the same database functions, row-level security and permission checks as the screens. It can
-- only create DRAFT journals and documents; submitting, approving and posting stay with people,
-- so maker-checker control is unchanged. Using it needs the ai.use permission and the company's
-- "AI assistant" module switch; a provider must also be configured (by the server operator, or
-- per company here, with the API key encrypted by the application before it is stored).
SET LOCAL ROLE serk_owner;

INSERT INTO organization.features VALUES
 ('ai_assistant','AI assistant','Answers questions from the books and prepares draft journals, invoices and bills for people to review and approve.',90);
INSERT INTO security.permissions(code,label,category,sort_order) VALUES
 ('ai.use','Use the AI assistant (answers and drafts within the user''s own permissions)','AI',200);

CREATE OR REPLACE FUNCTION security.permission_feature(p_permission text) RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$
 SELECT CASE split_part(p_permission,'.',1) WHEN 'sales' THEN 'sales' WHEN 'purchases' THEN 'purchases'
  WHEN 'inventory' THEN 'inventory' WHEN 'payroll' THEN 'payroll' WHEN 'taxes' THEN 'taxes' WHEN 'ai' THEN 'ai_assistant' END $$;

-- Provider settings per company. The API key ciphertext lives in a separate table that is never
-- copied into the audit trail.
CREATE TABLE organization.ai_settings(
 id uuid NOT NULL DEFAULT gen_random_uuid(),tenant_id uuid NOT NULL,company_id uuid NOT NULL,
 provider text NOT NULL CHECK(provider IN('anthropic','openai')),model text NOT NULL CHECK(length(model) BETWEEN 1 AND 100),
 base_url text CHECK(base_url IS NULL OR length(base_url) BETWEEN 8 AND 300),key_set boolean NOT NULL DEFAULT false,
 reason text NOT NULL,version bigint NOT NULL DEFAULT 1,updated_by uuid,updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY(company_id),UNIQUE(id),FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id));
CREATE TABLE organization.ai_secrets(
 tenant_id uuid NOT NULL,company_id uuid NOT NULL PRIMARY KEY,ciphertext text NOT NULL CHECK(length(ciphertext) BETWEEN 20 AND 2000),
 FOREIGN KEY(tenant_id,company_id) REFERENCES organization.companies(tenant_id,id));
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['organization.ai_settings','organization.ai_secrets'] LOOP
  EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY scoped ON %s USING(tenant_id=(SELECT security.tenant()) AND company_id=(SELECT security.company()))',t);
 END LOOP;
END $$;
CREATE TRIGGER ai_settings_audit AFTER INSERT OR UPDATE ON organization.ai_settings FOR EACH ROW EXECUTE FUNCTION audit.record_change();

-- Runtime configuration for the assistant; the API decrypts the key with its own secret.
CREATE FUNCTION organization.ai_config() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,organization,security,pg_temp AS $$
BEGIN
 IF NOT security.has('ai.use') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 RETURN (SELECT jsonb_build_object('provider',s.provider,'model',s.model,'base_url',s.base_url,'ciphertext',k.ciphertext)
  FROM organization.ai_settings s LEFT JOIN organization.ai_secrets k ON k.company_id=s.company_id WHERE s.company_id=security.company());
END $$;

-- What the assistant needs to know about the caller: company, currency, name, effective
-- permissions and a branch the caller may prepare entries in. Requires ai.use.
CREATE FUNCTION organization.assistant_context() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,organization,security,pg_temp AS $$
BEGIN
 IF NOT security.has('ai.use') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 RETURN (SELECT jsonb_build_object('company',c.name,'currency',c.functional_currency,'places',cur.minor_units,
  'user',(SELECT display_name FROM security.users WHERE id=security.actor()),
  'held',to_jsonb(security.held_permissions()),
  'branch_id',(SELECT b.id FROM organization.branches b WHERE b.company_id=c.id AND b.active AND security.can('journal.create',b.id) ORDER BY b.code LIMIT 1),
  'branches',coalesce((SELECT jsonb_agg(x ORDER BY x->>'code') FROM (SELECT jsonb_build_object('id',b.id,'code',b.code,'name',b.name,
    'journal',security.can('journal.create',b.id),'sales',security.can('sales.manage',b.id),'purchases',security.can('purchases.manage',b.id)) x
   FROM organization.branches b WHERE b.company_id=c.id AND b.active) y
   WHERE (x->>'journal')::boolean OR (x->>'sales')::boolean OR (x->>'purchases')::boolean),'[]'::jsonb))
  FROM organization.companies c JOIN organization.currencies cur ON cur.code=c.functional_currency WHERE c.id=security.company());
END $$;

CREATE FUNCTION organization.get_ai_settings() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,organization,security,pg_temp AS $$
BEGIN
 PERFORM security.require('configuration.manage');
 RETURN coalesce((SELECT jsonb_build_object('provider',provider,'model',model,'base_url',base_url,'key_set',key_set,'version',version,'updated_at',updated_at)
  FROM organization.ai_settings WHERE company_id=security.company()),'null'::jsonb);
END $$;

-- p_ciphertext NULL keeps the stored key; p_clear_key removes it.
CREATE FUNCTION organization.set_ai_settings(p_provider text,p_model text,p_base_url text,p_ciphertext text,p_clear_key boolean,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,organization,security,pg_temp AS $$
BEGIN
 PERFORM security.require('configuration.manage');
 IF NOT security.company_wide('configuration.manage') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 IF length(btrim(coalesce(p_reason,''))) NOT BETWEEN 3 AND 1000 THEN RAISE EXCEPTION 'invalid_reason' USING ERRCODE='22023'; END IF;
 IF p_provider IS NULL OR p_provider NOT IN('anthropic','openai') OR length(coalesce(p_model,'')) NOT BETWEEN 1 AND 100 OR p_model !~ '^[A-Za-z0-9._:/-]+$'
  OR (p_clear_key AND p_ciphertext IS NOT NULL)
 THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 IF nullif(p_base_url,'') IS NOT NULL AND (length(p_base_url)>300 OR p_base_url !~ '^https?://[A-Za-z0-9.:\[\]-]+(/[A-Za-z0-9._~/-]*)?$')
 THEN RAISE EXCEPTION 'invalid_base_url' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('serk-ai:'||security.company()::text,0));
 -- A stored key is only ever sent to the address it was entered for: moving the assistant to
 -- another provider or server needs the key entered again (or removed).
 IF p_ciphertext IS NULL AND NOT p_clear_key
  AND EXISTS(SELECT FROM organization.ai_secrets WHERE company_id=security.company())
  AND EXISTS(SELECT FROM organization.ai_settings WHERE company_id=security.company()
   AND (provider IS DISTINCT FROM p_provider OR base_url IS DISTINCT FROM nullif(p_base_url,'')))
 THEN RAISE EXCEPTION 'assistant_key_required' USING ERRCODE='22023'; END IF;
 PERFORM set_config('serk.request_context',(coalesce(nullif(current_setting('serk.request_context',true),'')::jsonb,'{}'::jsonb)||jsonb_build_object('reason',p_reason))::text,true);
 IF p_clear_key THEN DELETE FROM organization.ai_secrets WHERE company_id=security.company();
 ELSIF p_ciphertext IS NOT NULL THEN
  INSERT INTO organization.ai_secrets VALUES(security.tenant(),security.company(),p_ciphertext)
  ON CONFLICT(company_id) DO UPDATE SET ciphertext=EXCLUDED.ciphertext;
 END IF;
 INSERT INTO organization.ai_settings(tenant_id,company_id,provider,model,base_url,key_set,reason,updated_by)
 VALUES(security.tenant(),security.company(),p_provider,p_model,nullif(p_base_url,''),
  EXISTS(SELECT FROM organization.ai_secrets WHERE company_id=security.company()),btrim(p_reason),security.actor())
 ON CONFLICT(company_id) DO UPDATE SET provider=EXCLUDED.provider,model=EXCLUDED.model,base_url=EXCLUDED.base_url,key_set=EXCLUDED.key_set,
  reason=EXCLUDED.reason,updated_by=EXCLUDED.updated_by,updated_at=clock_timestamp(),version=ai_settings.version+1;
 RETURN organization.get_ai_settings();
END $$;

-- The next free number in a company's invoice or bill sequence (INV-000041 -> INV-000042),
-- checked against every document of that kind in the company, whatever branch it belongs to.
-- It reveals only that a number is taken, to a user who may create that kind of document.
CREATE FUNCTION finance.next_document_number(p_kind text) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$
DECLARE last text; prefix text; digits int; n numeric; candidate text; i int;
BEGIN
 IF p_kind NOT IN('INVOICE','BILL') THEN RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 PERFORM security.require(finance.permission(p_kind)||'.manage');
 SELECT document_no INTO last FROM finance.documents WHERE company_id=security.company() AND kind=p_kind AND document_no ~ '[0-9]{1,12}$'
  ORDER BY created_at DESC,id LIMIT 1;
 IF last IS NULL THEN prefix:=CASE p_kind WHEN 'INVOICE' THEN 'INV-' ELSE 'BILL-' END; digits:=6; n:=0;
 ELSE prefix:=substring(last FROM '^(.*?)[0-9]+$'); digits:=length(substring(last FROM '([0-9]+)$')); n:=substring(last FROM '([0-9]+)$')::numeric;
 END IF;
 FOR i IN 1..1000 LOOP
  candidate:=prefix||lpad((n+i)::text,digits,'0');
  IF NOT EXISTS(SELECT FROM finance.documents WHERE company_id=security.company() AND kind=p_kind AND document_no=candidate) THEN RETURN candidate; END IF;
 END LOOP;
 RAISE EXCEPTION 'document_number_required' USING ERRCODE='22023';
END $$;
REVOKE ALL ON FUNCTION finance.next_document_number(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION finance.next_document_number(text) TO serk_api;

REVOKE ALL ON FUNCTION organization.ai_config(),organization.assistant_context(),organization.get_ai_settings(),
 organization.set_ai_settings(text,text,text,text,boolean,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION organization.ai_config(),organization.assistant_context(),organization.get_ai_settings(),
 organization.set_ai_settings(text,text,text,text,boolean,text) TO serk_api;

-- Publish the runtime marker only after every 0.4.0 migration is present.
CREATE OR REPLACE FUNCTION security.release_version() RETURNS text LANGUAGE sql IMMUTABLE
SET search_path=pg_catalog,pg_temp AS $$ SELECT '0.4.0-rc1'::text $$;
