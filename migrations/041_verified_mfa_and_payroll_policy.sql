SET LOCAL ROLE serk_owner;
CREATE FUNCTION security.profile_auth_record(p_token text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT jsonb_build_object('user_id',u.id,'password_hash',u.password_hash,'mfa_secret',m.encrypted_secret,'mfa_version',m.version)
 FROM security.sessions s JOIN security.users u ON u.id=s.user_id JOIN security.tenants t ON t.id=u.tenant_id
 LEFT JOIN security.user_mfa m ON m.user_id=u.id
 WHERE s.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') AND s.revoked_at IS NULL
 AND s.expires_at>statement_timestamp() AND u.active AND t.active;
$$;
CREATE FUNCTION security.change_verified_mfa(p_token text,p_verified_hash text,p_old_version uuid,p_old_step bigint,
 p_new_secret text,p_new_step bigint,p_disable boolean,p_required boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,security,pg_temp AS $$
DECLARE uid uuid;tid uuid;m security.user_mfa;current_step bigint:=floor(extract(epoch FROM clock_timestamp())/30);BEGIN
 IF p_disable AND p_required IS DISTINCT FROM false THEN RAISE EXCEPTION 'mfa_required' USING ERRCODE='42501'; END IF;
 SELECT u.id,u.tenant_id INTO uid,tid FROM security.sessions s JOIN security.users u ON u.id=s.user_id JOIN security.tenants t ON t.id=u.tenant_id
 WHERE s.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') AND s.revoked_at IS NULL AND s.expires_at>statement_timestamp()
 AND u.password_hash=p_verified_hash AND u.active AND t.active FOR UPDATE OF u;
 IF uid IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
 SELECT * INTO m FROM security.user_mfa WHERE user_id=uid FOR UPDATE;
 IF FOUND THEN
  IF p_old_version IS DISTINCT FROM m.version OR p_old_step IS NULL OR p_old_step<=m.last_step
   OR p_old_step NOT BETWEEN current_step-1 AND current_step+1 THEN RAISE EXCEPTION 'invalid_credentials' USING ERRCODE='28000'; END IF;
 ELSIF p_old_version IS NOT NULL OR p_disable THEN RAISE EXCEPTION 'invalid_credentials' USING ERRCODE='28000'; END IF;
 IF p_disable THEN DELETE FROM security.user_mfa WHERE user_id=uid;
 ELSE
  IF p_new_secret IS NULL OR length(p_new_secret) NOT BETWEEN 40 AND 512 OR p_new_step NOT BETWEEN current_step-1 AND current_step+1
  THEN RAISE EXCEPTION 'invalid_credentials' USING ERRCODE='28000'; END IF;
  INSERT INTO security.user_mfa(user_id,tenant_id,encrypted_secret,last_step) VALUES(uid,tid,p_new_secret,p_new_step)
  ON CONFLICT(user_id) DO UPDATE SET encrypted_secret=EXCLUDED.encrypted_secret,last_step=EXCLUDED.last_step,version=gen_random_uuid();
 END IF;
 UPDATE security.sessions SET revoked_at=clock_timestamp(),mfa_verified=false WHERE user_id=uid AND revoked_at IS NULL;
 INSERT INTO security.admin_events(tenant_id,target_user_id,action,reason)
 VALUES(tid,uid,CASE WHEN p_disable THEN 'disable_mfa' ELSE 'enroll_mfa' END,'Verified password and current factor; all sessions revoked');
 RETURN jsonb_build_object('status',CASE WHEN p_disable THEN 'disabled' ELSE 'enabled' END,'reauthentication_required',true);
END $$;
REVOKE ALL ON FUNCTION security.profile_auth_record(text),security.change_verified_mfa(text,text,uuid,bigint,text,bigint,boolean,boolean) FROM PUBLIC,serk_api;
GRANT EXECUTE ON FUNCTION security.profile_auth_record(text),security.change_verified_mfa(text,text,uuid,bigint,text,bigint,boolean,boolean) TO serk_auth;

CREATE FUNCTION finance.policy_command(p_action text,p jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$
DECLARE rule jsonb;bracket jsonb;id uuid;last_upper numeric:=-1;upper_limit numeric;rate numeric;i integer:=0;cnt integer;pol finance.payroll_policies;BEGIN
 PERFORM security.require('configuration.manage');PERFORM security.require('payroll.read');
 IF p_action='create' THEN
  rule:=p->'rules';cnt:=jsonb_array_length(rule->'income_tax_brackets');
  IF jsonb_typeof(rule) IS DISTINCT FROM 'object' OR cnt IS NULL OR cnt NOT BETWEEN 1 AND 100
  OR length(btrim(coalesce(p->>'name',''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_payroll_policy' USING ERRCODE='22023'; END IF;
  FOR bracket IN SELECT * FROM jsonb_array_elements(rule->'income_tax_brackets') LOOP
   i:=i+1;PERFORM finance.amount(bracket->>'subtract_minor');
   IF coalesce(bracket->>'rate_percent','') !~ '^[0-9]+(\.[0-9]{1,6})?$' THEN RAISE EXCEPTION 'invalid_payroll_policy' USING ERRCODE='22023'; END IF;
   rate:=(bracket->>'rate_percent')::numeric;IF rate>100 THEN RAISE EXCEPTION 'invalid_payroll_policy' USING ERRCODE='22023'; END IF;
   IF i=cnt THEN
    IF bracket->>'up_to_minor' IS NOT NULL THEN RAISE EXCEPTION 'invalid_payroll_policy' USING ERRCODE='22023'; END IF;
   ELSE
    upper_limit:=finance.amount(bracket->>'up_to_minor');IF upper_limit<=last_upper THEN RAISE EXCEPTION 'invalid_payroll_policy' USING ERRCODE='22023'; END IF;last_upper:=upper_limit;
   END IF;
  END LOOP;
  FOREACH rule IN ARRAY ARRAY[to_jsonb(p->'rules'->>'employee_pension_percent'),to_jsonb(p->'rules'->>'employer_pension_percent')] LOOP
   IF coalesce(rule#>>'{}','') !~ '^[0-9]+(\.[0-9]{1,6})?$' OR (rule#>>'{}')::numeric>100 THEN RAISE EXCEPTION 'invalid_payroll_policy' USING ERRCODE='22023'; END IF;
  END LOOP;
  INSERT INTO finance.payroll_policies(tenant_id,company_id,name,effective_from,effective_to,rules,created_by,pay_frequency)
  VALUES(security.tenant(),security.company(),p->>'name',(p->>'effective_from')::date,nullif(p->>'effective_to','')::date,p->'rules',security.actor(),coalesce(p->>'pay_frequency','MONTHLY')) RETURNING * INTO pol;
 ELSIF p_action='approve' THEN
  SELECT * INTO pol FROM finance.payroll_policies WHERE payroll_policies.id=(p->>'id')::uuid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  IF pol.created_by=security.actor() THEN RAISE EXCEPTION 'segregation_of_duties' USING ERRCODE='42501'; END IF;
  IF pol.approved_by IS NOT NULL OR pol.version IS DISTINCT FROM (p->>'expected_version')::bigint THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
  UPDATE finance.payroll_policies SET approved_by=security.actor(),version=version+1 WHERE payroll_policies.id=pol.id RETURNING * INTO pol;
 ELSE RAISE EXCEPTION 'invalid_request' USING ERRCODE='22023'; END IF;
 RETURN to_jsonb(pol);
END $$;
CREATE FUNCTION finance.list_policies() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=pg_catalog,finance,security,pg_temp AS $$ BEGIN
 PERFORM security.require('payroll.read');RETURN coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY effective_from DESC) FROM finance.payroll_policies p),'[]');
END $$;
GRANT EXECUTE ON FUNCTION finance.policy_command(text,jsonb),finance.list_policies() TO serk_api;
