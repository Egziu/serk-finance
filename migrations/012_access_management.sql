-- In-application access management: dynamic roles with ticked permissions, and user
-- administration by a super administrator. Released migrations 001-011 stay unchanged.
--
-- Rules enforced here, not only in the API or UI:
--  * user.manage / role.manage must be held company-wide (branch-scoped grants never administer).
--  * No privilege escalation: an administrator can only grant, edit or remove permissions they hold,
--    and cannot grant a larger approval limit than their own.
--  * A company that has an administrator always keeps at least one active administrator.
--  * Administrators cannot disable or reset the password of their own account here.
--  * Administration is serialized per workspace, uses expected versions, and every change is
--    appended to the company audit hash chain and outbox (verified by ledger.integrity_status).
SET LOCAL ROLE serk_owner;

ALTER TABLE security.permissions ADD COLUMN label text, ADD COLUMN category text, ADD COLUMN sort_order integer;
INSERT INTO security.permissions(code) VALUES ('user.manage'),('role.manage');
UPDATE security.permissions p SET label=v.label, category=v.category, sort_order=v.o FROM (VALUES
 ('ledger.read','View ledger, reports and chart of accounts','Ledger',10),
 ('journal.create','Create draft journals','Journals',20),
 ('journal.submit','Submit journals for approval','Journals',21),
 ('journal.approve','Approve journals (up to the approval limit)','Journals',22),
 ('journal.post','Post approved journals','Journals',23),
 ('journal.reverse','Reverse posted journals','Journals',24),
 ('journal.void','Void draft journals','Journals',25),
 ('period.close','Close accounting periods','Periods',30),
 ('audit.read','View audit history and ledger integrity','Audit',40),
 ('configuration.manage','Manage accounting configuration','Administration',50),
 ('user.manage','Create users and assign their roles','Administration',51),
 ('role.manage','Create roles and choose their permissions','Administration',52)
) v(code,label,category,o) WHERE p.code=v.code;

ALTER TABLE security.users ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK(version>=1),
 ADD COLUMN created_at timestamptz NOT NULL DEFAULT clock_timestamp();
ALTER TABLE security.roles ADD COLUMN version bigint NOT NULL DEFAULT 1 CHECK(version>=1),
 ADD COLUMN description text NOT NULL DEFAULT '' CHECK(length(description)<=500);

ALTER TABLE security.admin_events DROP CONSTRAINT admin_events_action_check;
ALTER TABLE security.admin_events ADD CONSTRAINT admin_events_action_check CHECK(action IN
 ('reset_password','disable_user','enable_user','revoke_sessions','enroll_mfa','grant_super_admin','create_user'));

-- ---------------------------------------------------------------- internal helpers (not granted)

-- Permissions the actor holds company-wide in the current company.
CREATE FUNCTION security.admin_held() RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT coalesce(array_agg(DISTINCT rp.permission),'{}'::text[]) FROM security.memberships m
 JOIN security.role_permissions rp ON rp.role_id=m.role_id
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor()) AND m.branch_id IS NULL
$$;

-- Actor's company-wide approval limit: NULL = unlimited, -1 = cannot approve.
CREATE FUNCTION security.admin_approval_limit() RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT CASE WHEN count(*)=0 THEN -1 WHEN bool_or(m.approval_limit_minor IS NULL) THEN NULL ELSE max(m.approval_limit_minor) END
 FROM security.memberships m JOIN security.role_permissions rp ON rp.role_id=m.role_id AND rp.permission='journal.approve'
 WHERE m.company_id=(SELECT security.company()) AND m.user_id=(SELECT security.actor()) AND m.branch_id IS NULL
$$;

-- Companies of the workspace that currently have an active, company-wide administrator
-- (a user holding both user.manage and role.manage there).
CREATE FUNCTION security.admin_companies() RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT coalesce(array_agg(DISTINCT m.company_id),'{}'::uuid[]) FROM security.memberships m
 JOIN security.users u ON u.id=m.user_id AND u.active
 WHERE m.tenant_id=(SELECT security.tenant()) AND m.branch_id IS NULL
 AND (SELECT count(DISTINCT rp.permission) FROM security.memberships m2 JOIN security.role_permissions rp ON rp.role_id=m2.role_id
      WHERE m2.company_id=m.company_id AND m2.user_id=m.user_id AND m2.branch_id IS NULL
      AND rp.permission IN ('user.manage','role.manage'))=2
$$;

CREATE FUNCTION security.admin_begin(p_permission text,p_reason text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE t uuid:=security.tenant();
 BEGIN
 PERFORM security.require(p_permission);
 IF p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 3 AND 1000 THEN
  RAISE EXCEPTION 'invalid_reason' USING ERRCODE='22023'; END IF;
 -- One administrative change at a time per workspace, so the last-administrator rule
 -- cannot be bypassed by concurrent changes.
 PERFORM 1 FROM security.tenants WHERE id=t FOR UPDATE;
 RETURN t;
 END $$;

CREATE FUNCTION security.admin_keep_administrators(p_before uuid[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 BEGIN
 IF NOT (security.admin_companies() @> p_before) THEN
  RAISE EXCEPTION 'last_administrator' USING ERRCODE='55000'; END IF;
 END $$;

-- The actor must hold every permission in p_permissions.
CREATE FUNCTION security.admin_cover(p_permissions text[]) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 BEGIN
 IF EXISTS(SELECT unnest(coalesce(p_permissions,'{}'::text[])) EXCEPT SELECT unnest(security.admin_held())) THEN
  RAISE EXCEPTION 'privilege_escalation' USING ERRCODE='42501'; END IF;
 END $$;

-- The actor must cover every permission the target user holds in the current company.
CREATE FUNCTION security.admin_cover_user(p_user uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 BEGIN
 PERFORM security.admin_cover((SELECT array_agg(DISTINCT rp.permission) FROM security.memberships m
  JOIN security.role_permissions rp ON rp.role_id=m.role_id
  WHERE m.user_id=p_user AND m.company_id=(SELECT security.company())));
 END $$;

CREATE FUNCTION security.admin_user_json(p_user uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,organization,pg_temp AS $$
 SELECT jsonb_build_object('id',u.id,'email',u.email,'display_name',u.display_name,'active',u.active,
  'state',CASE WHEN u.active THEN 'ACTIVE' ELSE 'DISABLED' END,'version',u.version,'created_at',u.created_at,
  'mfa_enrolled',EXISTS(SELECT FROM security.user_mfa f WHERE f.user_id=u.id),
  'grants',coalesce((SELECT jsonb_agg(jsonb_build_object('role_id',m.role_id,'role_name',r.name,'branch_id',m.branch_id,
    'branch_code',b.code,'approval_limit_minor',m.approval_limit_minor::text) ORDER BY r.name,b.code NULLS FIRST)
   FROM security.memberships m JOIN security.roles r ON r.id=m.role_id
   LEFT JOIN organization.branches b ON b.id=m.branch_id AND b.company_id=m.company_id
   WHERE m.user_id=u.id AND m.company_id=(SELECT security.company())),'[]'::jsonb))
 FROM security.users u WHERE u.id=p_user AND u.tenant_id=(SELECT security.tenant())
$$;

CREATE FUNCTION security.admin_role_json(p_role uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 SELECT jsonb_build_object('id',r.id,'name',r.name,'description',r.description,'version',r.version,'state','ACTIVE',
  'permissions',coalesce((SELECT jsonb_agg(rp.permission ORDER BY rp.permission) FROM security.role_permissions rp WHERE rp.role_id=r.id),'[]'::jsonb),
  'members',(SELECT count(DISTINCT m.user_id) FROM security.memberships m WHERE m.role_id=r.id))
 FROM security.roles r WHERE r.id=p_role AND r.tenant_id=(SELECT security.tenant())
$$;

-- Replaces all grants of a user in the current company.
-- p_grants: [{"role_id":uuid,"branch_id":uuid|null,"approval_limit_minor":"123"|null}]
CREATE FUNCTION security.admin_apply_grants(p_user uuid,p_grants jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,organization,pg_temp AS $$
 -- Captured before existing grants are replaced, so administrators can edit their own grants.
 DECLARE g jsonb; rid uuid; bid uuid; lim numeric; t uuid:=security.tenant(); c uuid:=security.company();
  my_limit numeric:=security.admin_approval_limit(); held text[]:=security.admin_held(); seen uuid[]:='{}';
 BEGIN
 IF p_grants IS NULL OR jsonb_typeof(p_grants)<>'array' OR jsonb_array_length(p_grants)>50 THEN
  RAISE EXCEPTION 'invalid_grant' USING ERRCODE='22023'; END IF;
 DELETE FROM security.memberships WHERE user_id=p_user AND company_id=c;
 FOR g IN SELECT * FROM jsonb_array_elements(p_grants) LOOP
  IF jsonb_typeof(g)<>'object' OR NOT (g ?& ARRAY['role_id']) OR EXISTS(SELECT FROM jsonb_object_keys(g) k
     WHERE k NOT IN ('role_id','branch_id','approval_limit_minor')) THEN
   RAISE EXCEPTION 'invalid_grant' USING ERRCODE='22023'; END IF;
  rid:=(g->>'role_id')::uuid;
  bid:=nullif(g->>'branch_id','')::uuid;
  lim:=nullif(g->>'approval_limit_minor','')::numeric;
  IF rid=ANY(seen) THEN RAISE EXCEPTION 'invalid_grant' USING ERRCODE='22023'; END IF;
  seen:=seen||rid;
  IF NOT EXISTS(SELECT FROM security.roles WHERE id=rid AND tenant_id=t) THEN
   RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
  IF bid IS NOT NULL AND NOT EXISTS(SELECT FROM organization.branches WHERE id=bid AND company_id=c AND active) THEN
   RAISE EXCEPTION 'invalid_grant' USING ERRCODE='22023'; END IF;
  IF lim IS NOT NULL AND (lim<0 OR lim<>trunc(lim)) THEN RAISE EXCEPTION 'invalid_grant' USING ERRCODE='22023'; END IF;
  IF EXISTS(SELECT permission FROM security.role_permissions WHERE role_id=rid EXCEPT SELECT unnest(held)) THEN
   RAISE EXCEPTION 'privilege_escalation' USING ERRCODE='42501'; END IF;
  IF EXISTS(SELECT FROM security.role_permissions WHERE role_id=rid AND permission='journal.approve')
     AND my_limit IS NOT NULL AND (my_limit<0 OR lim IS NULL OR lim>my_limit) THEN
   RAISE EXCEPTION 'privilege_escalation' USING ERRCODE='42501'; END IF;
  INSERT INTO security.memberships(tenant_id,company_id,user_id,role_id,branch_id,approval_limit_minor)
  VALUES(t,c,p_user,rid,bid,lim);
 END LOOP;
 END $$;

CREATE FUNCTION security.admin_lock_user(p_user uuid,p_version bigint) RETURNS security.users LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE u security.users;
 BEGIN
 SELECT * INTO u FROM security.users WHERE id=p_user AND tenant_id=(SELECT security.tenant()) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 IF u.version<>p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
 PERFORM security.admin_cover_user(p_user);
 RETURN u;
 END $$;

CREATE FUNCTION security.admin_lock_role(p_role uuid,p_version bigint) RETURNS security.roles LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE r security.roles;
 BEGIN
 SELECT * INTO r FROM security.roles WHERE id=p_role AND tenant_id=(SELECT security.tenant()) FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'not_found' USING ERRCODE='P0002'; END IF;
 IF r.version<>p_version THEN RAISE EXCEPTION 'version_conflict' USING ERRCODE='40001'; END IF;
 PERFORM security.admin_cover((SELECT array_agg(permission) FROM security.role_permissions WHERE role_id=p_role));
 RETURN r;
 END $$;

CREATE FUNCTION security.admin_check_permissions(p_permissions text[]) RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER
 SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE clean text[];
 BEGIN
 IF p_permissions IS NULL OR cardinality(p_permissions)>100 THEN RAISE EXCEPTION 'invalid_permission' USING ERRCODE='22023'; END IF;
 SELECT coalesce(array_agg(DISTINCT x ORDER BY x),'{}'::text[]) INTO clean FROM unnest(p_permissions) x;
 IF EXISTS(SELECT unnest(clean) EXCEPT SELECT code FROM security.permissions) THEN
  RAISE EXCEPTION 'invalid_permission' USING ERRCODE='22023'; END IF;
 PERFORM security.admin_cover(clean);
 RETURN clean;
 END $$;

-- Company-scoped administrative audit event on the same hash chain and outbox as journals.
-- p_after must carry "version" and "state".
CREATE FUNCTION audit.record_admin(p_action text,p_entity uuid,p_before jsonb,p_after jsonb,p_reason text) RETURNS void
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,audit,integration,security,pg_temp AS $$
 DECLARE h audit.heads; ts timestamptz:=clock_timestamp(); eid uuid:=gen_random_uuid(); ctx jsonb; payload text; eh text;
  t uuid:=security.tenant(); c uuid:=security.company(); a uuid:=security.actor();
 BEGIN
 IF a IS NULL OR c IS NULL OR p_after IS NULL OR NOT (p_after ?& ARRAY['version','state']) THEN
  RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 ctx:=coalesce(nullif(current_setting('serk.request_context',true),'')::jsonb,'{}'::jsonb);
 INSERT INTO audit.heads(tenant_id,company_id) VALUES(t,c) ON CONFLICT DO NOTHING;
 SELECT * INTO STRICT h FROM audit.heads WHERE company_id=c FOR UPDATE;
 payload:=jsonb_build_object('id',eid,'tenant_id',t,'company_id',c,'sequence',h.last_sequence+1,'actor',a,'at',ts,
  'action',p_action,'entity',p_entity,'before',p_before,'after',p_after,'context',ctx)::text;
 eh:=encode(sha256(convert_to(h.last_hash||payload,'UTF8')),'hex');
 INSERT INTO audit.events VALUES(eid,t,c,h.last_sequence+1,a,ts,p_action,p_entity,p_before,p_after,btrim(p_reason),ctx,h.last_hash,eh,payload);
 UPDATE audit.heads SET last_sequence=h.last_sequence+1,last_hash=eh WHERE company_id=c;
 INSERT INTO integration.outbox(id,tenant_id,company_id,aggregate_id,aggregate_version,event_type,payload)
 VALUES(eid,t,c,p_entity,(p_after->>'version')::bigint,p_action,jsonb_build_object('schema_version',1,'id',eid,
  'tenant_id',t,'company_id',c,'aggregate_id',p_entity,'version',(p_after->>'version')::bigint,'state',p_after->>'state','audit_hash',eh));
 END $$;

-- ---------------------------------------------------------------- API functions (granted to serk_api)

CREATE FUNCTION security.admin_catalog() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path=pg_catalog,security,organization,pg_temp AS $$
 DECLARE t uuid:=security.tenant(); lim numeric;
 BEGIN
 IF NOT (security.can('user.manage') OR security.can('role.manage')) THEN
  RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 lim:=security.admin_approval_limit();
 RETURN jsonb_build_object(
  'permissions',(SELECT jsonb_agg(jsonb_build_object('code',code,'label',coalesce(label,code),'category',coalesce(category,'Other'))
    ORDER BY sort_order NULLS LAST,code) FROM security.permissions),
  'roles',coalesce((SELECT jsonb_agg(security.admin_role_json(r.id) ORDER BY r.name) FROM security.roles r WHERE r.tenant_id=t),'[]'::jsonb),
  'users',CASE WHEN security.can('user.manage') THEN coalesce((SELECT jsonb_agg(security.admin_user_json(u.id) ORDER BY u.email)
    FROM security.users u WHERE u.tenant_id=t),'[]'::jsonb) ELSE '[]'::jsonb END,
  'branches',coalesce((SELECT jsonb_agg(jsonb_build_object('id',b.id,'code',b.code,'name',b.name) ORDER BY b.code)
    FROM organization.branches b WHERE b.company_id=(SELECT security.company()) AND b.active),'[]'::jsonb),
  'me',jsonb_build_object('user_id',security.actor(),'permissions',to_jsonb(security.admin_held()),
    'can_manage_users',security.can('user.manage'),'can_manage_roles',security.can('role.manage'),
    'approval_limit_minor',CASE WHEN lim IS NULL THEN NULL WHEN lim<0 THEN '-1' ELSE lim::text END));
 END $$;

CREATE FUNCTION security.admin_create_user(p_email text,p_name text,p_hash text,p_grants jsonb,p_reason text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE t uuid; uid uuid; before uuid[]; email text:=lower(btrim(coalesce(p_email,'')));
 BEGIN
 t:=security.admin_begin('user.manage',p_reason);
 before:=security.admin_companies();
 IF email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' OR length(email)>254 THEN RAISE EXCEPTION 'invalid_email' USING ERRCODE='22023'; END IF;
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'invalid_name' USING ERRCODE='22023'; END IF;
 INSERT INTO security.users(tenant_id,email,display_name,password_hash) VALUES(t,email,btrim(p_name),p_hash) RETURNING id INTO uid;
 PERFORM security.admin_apply_grants(uid,coalesce(p_grants,'[]'::jsonb));
 PERFORM security.admin_keep_administrators(before);
 PERFORM audit.record_admin('user.created',uid,NULL,security.admin_user_json(uid),p_reason);
 RETURN security.admin_user_json(uid);
 END $$;

CREATE FUNCTION security.admin_update_user(p_user uuid,p_version bigint,p_name text,p_active boolean,p_reason text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE u security.users; before uuid[]; old jsonb; act text;
 BEGIN
 PERFORM security.admin_begin('user.manage',p_reason);
 before:=security.admin_companies();
 u:=security.admin_lock_user(p_user,p_version);
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 1 AND 200 OR p_active IS NULL THEN
  RAISE EXCEPTION 'invalid_name' USING ERRCODE='22023'; END IF;
 IF p_user=security.actor() AND NOT p_active THEN RAISE EXCEPTION 'cannot_change_self' USING ERRCODE='55000'; END IF;
 old:=security.admin_user_json(p_user);
 UPDATE security.users SET display_name=btrim(p_name),active=p_active,version=version+1 WHERE id=p_user;
 IF NOT p_active THEN
  UPDATE security.sessions SET revoked_at=clock_timestamp() WHERE user_id=p_user AND revoked_at IS NULL;
 END IF;
 PERFORM security.admin_keep_administrators(before);
 act:=CASE WHEN u.active AND NOT p_active THEN 'user.disabled' WHEN NOT u.active AND p_active THEN 'user.enabled' ELSE 'user.updated' END;
 PERFORM audit.record_admin(act,p_user,old,security.admin_user_json(p_user),p_reason);
 RETURN security.admin_user_json(p_user);
 END $$;

CREATE FUNCTION security.admin_set_grants(p_user uuid,p_version bigint,p_grants jsonb,p_reason text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE before uuid[]; old jsonb;
 BEGIN
 PERFORM security.admin_begin('user.manage',p_reason);
 before:=security.admin_companies();
 PERFORM security.admin_lock_user(p_user,p_version);
 old:=security.admin_user_json(p_user);
 PERFORM security.admin_apply_grants(p_user,p_grants);
 UPDATE security.users SET version=version+1 WHERE id=p_user;
 PERFORM security.admin_keep_administrators(before);
 PERFORM audit.record_admin('user.roles_changed',p_user,old,security.admin_user_json(p_user),p_reason);
 RETURN security.admin_user_json(p_user);
 END $$;

CREATE FUNCTION security.admin_reset_password(p_user uuid,p_version bigint,p_hash text,p_reason text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE old jsonb;
 BEGIN
 PERFORM security.admin_begin('user.manage',p_reason);
 PERFORM security.admin_lock_user(p_user,p_version);
 IF p_user=security.actor() THEN RAISE EXCEPTION 'cannot_change_self' USING ERRCODE='55000'; END IF;
 old:=security.admin_user_json(p_user);
 UPDATE security.users SET password_hash=p_hash,version=version+1 WHERE id=p_user;
 UPDATE security.sessions SET revoked_at=clock_timestamp() WHERE user_id=p_user AND revoked_at IS NULL;
 PERFORM audit.record_admin('user.password_reset',p_user,old,security.admin_user_json(p_user),p_reason);
 RETURN security.admin_user_json(p_user);
 END $$;

CREATE FUNCTION security.admin_create_role(p_name text,p_description text,p_permissions text[],p_reason text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE t uuid; rid uuid; perms text[];
 BEGIN
 t:=security.admin_begin('role.manage',p_reason);
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 2 AND 80 OR length(coalesce(p_description,''))>500 THEN
  RAISE EXCEPTION 'invalid_name' USING ERRCODE='22023'; END IF;
 perms:=security.admin_check_permissions(p_permissions);
 INSERT INTO security.roles(tenant_id,name,description) VALUES(t,btrim(p_name),btrim(coalesce(p_description,''))) RETURNING id INTO rid;
 INSERT INTO security.role_permissions(tenant_id,role_id,permission) SELECT t,rid,x FROM unnest(perms) x;
 PERFORM audit.record_admin('role.created',rid,NULL,security.admin_role_json(rid),p_reason);
 RETURN security.admin_role_json(rid);
 END $$;

CREATE FUNCTION security.admin_update_role(p_role uuid,p_version bigint,p_name text,p_description text,p_permissions text[],p_reason text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE t uuid; before uuid[]; old jsonb; perms text[];
 BEGIN
 t:=security.admin_begin('role.manage',p_reason);
 before:=security.admin_companies();
 PERFORM security.admin_lock_role(p_role,p_version);
 IF length(btrim(coalesce(p_name,''))) NOT BETWEEN 2 AND 80 OR length(coalesce(p_description,''))>500 THEN
  RAISE EXCEPTION 'invalid_name' USING ERRCODE='22023'; END IF;
 perms:=security.admin_check_permissions(p_permissions);
 old:=security.admin_role_json(p_role);
 UPDATE security.roles SET name=btrim(p_name),description=btrim(coalesce(p_description,'')),version=version+1 WHERE id=p_role;
 DELETE FROM security.role_permissions WHERE role_id=p_role AND permission<>ALL(perms);
 INSERT INTO security.role_permissions(tenant_id,role_id,permission) SELECT t,p_role,x FROM unnest(perms) x ON CONFLICT DO NOTHING;
 PERFORM security.admin_keep_administrators(before);
 PERFORM audit.record_admin('role.updated',p_role,old,security.admin_role_json(p_role),p_reason);
 RETURN security.admin_role_json(p_role);
 END $$;

CREATE FUNCTION security.admin_delete_role(p_role uuid,p_version bigint,p_reason text) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,security,pg_temp AS $$
 DECLARE old jsonb; gone jsonb;
 BEGIN
 PERFORM security.admin_begin('role.manage',p_reason);
 PERFORM security.admin_lock_role(p_role,p_version);
 IF EXISTS(SELECT FROM security.memberships WHERE role_id=p_role) THEN
  RAISE EXCEPTION 'role_in_use' USING ERRCODE='55000'; END IF;
 old:=security.admin_role_json(p_role);
 gone:=old||jsonb_build_object('version',p_version+1,'state','DELETED');
 DELETE FROM security.role_permissions WHERE role_id=p_role;
 DELETE FROM security.roles WHERE id=p_role;
 PERFORM audit.record_admin('role.deleted',p_role,old,gone,p_reason);
 RETURN gone;
 END $$;

-- The web app shows the Users & roles pages from reference data.
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
  'users',security.can('user.manage'),'roles',security.can('role.manage')));
 END $$;

REVOKE EXECUTE ON FUNCTION security.admin_held(),security.admin_approval_limit(),security.admin_companies(),
 security.admin_begin(text,text),security.admin_keep_administrators(uuid[]),security.admin_cover(text[]),
 security.admin_cover_user(uuid),security.admin_user_json(uuid),security.admin_role_json(uuid),
 security.admin_apply_grants(uuid,jsonb),security.admin_lock_user(uuid,bigint),security.admin_lock_role(uuid,bigint),
 security.admin_check_permissions(text[]),audit.record_admin(text,uuid,jsonb,jsonb,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION security.admin_catalog(),security.admin_create_user(text,text,text,jsonb,text),
 security.admin_update_user(uuid,bigint,text,boolean,text),security.admin_set_grants(uuid,bigint,jsonb,text),
 security.admin_reset_password(uuid,bigint,text,text),security.admin_create_role(text,text,text[],text),
 security.admin_update_role(uuid,bigint,text,text,text[],text),security.admin_delete_role(uuid,bigint,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION security.admin_catalog(),security.admin_create_user(text,text,text,jsonb,text),
 security.admin_update_user(uuid,bigint,text,boolean,text),security.admin_set_grants(uuid,bigint,jsonb,text),
 security.admin_reset_password(uuid,bigint,text,text),security.admin_create_role(text,text,text[],text),
 security.admin_update_role(uuid,bigint,text,text,text[],text),security.admin_delete_role(uuid,bigint,text) TO serk_api;
