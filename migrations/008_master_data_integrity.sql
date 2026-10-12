-- Independently authored SERK controls. Released migrations 001-007 stay unchanged.
-- Fail closed on incompatible historical chart data; never silently rewrite it.
SET LOCAL row_security=off;
DO $$ BEGIN
 IF EXISTS(SELECT FROM ledger.accounts a JOIN ledger.accounts p ON p.id=a.parent_id
   WHERE p.posting_allowed OR p.control_account OR a.type<>p.type) THEN
  RAISE EXCEPTION 'chart_preflight_invalid_parent' USING ERRCODE='23514';
 END IF;
 IF EXISTS(WITH RECURSIVE tree AS (
   SELECT id AS root,id,parent_id,ARRAY[id] AS path,false AS cycle FROM ledger.accounts
   UNION ALL
   SELECT t.root,a.id,a.parent_id,t.path||a.id,a.id=ANY(t.path)
   FROM tree t JOIN ledger.accounts a ON a.id=t.parent_id
   WHERE NOT t.cycle AND cardinality(t.path)<=256
  ) SELECT FROM tree WHERE cycle OR cardinality(path)>256) THEN
  RAISE EXCEPTION 'chart_preflight_cycle_or_depth' USING ERRCODE='23514';
 END IF;
END $$;
SET LOCAL row_security=on;
SET LOCAL ROLE serk_owner;

-- Private write-serialization row: an actual update prevents stale-snapshot
-- graph write skew at REPEATABLE READ as well as at READ COMMITTED.
CREATE TABLE ledger.account_tree_versions (
 company_id uuid PRIMARY KEY REFERENCES organization.companies(id),
 revision bigint NOT NULL DEFAULT 1 CHECK(revision>0)
);
CREATE FUNCTION ledger.guard_account_definition() RETURNS trigger
 LANGUAGE plpgsql SET search_path=pg_catalog,ledger,organization,pg_temp AS $$
 DECLARE parent ledger.accounts;
 BEGIN
 IF TG_OP='UPDATE' THEN
  IF (NEW.id,NEW.tenant_id,NEW.company_id) IS DISTINCT FROM (OLD.id,OLD.tenant_id,OLD.company_id) THEN
   RAISE EXCEPTION 'account_identity_immutable' USING ERRCODE='55000';
  END IF;
  IF (NEW.code,NEW.type,NEW.normal_balance,NEW.parent_id,NEW.control_account,NEW.reporting_category)
    IS DISTINCT FROM (OLD.code,OLD.type,OLD.normal_balance,OLD.parent_id,OLD.control_account,OLD.reporting_category)
    AND EXISTS(SELECT FROM ledger.lines WHERE account_id=OLD.id) THEN
   RAISE EXCEPTION 'account_definition_in_use' USING ERRCODE='55000';
  END IF;
 END IF;
 INSERT INTO ledger.account_tree_versions(company_id) VALUES(NEW.company_id)
 ON CONFLICT(company_id) DO UPDATE SET revision=account_tree_versions.revision+1;
 IF NEW.parent_id IS NOT NULL THEN
  SELECT * INTO parent FROM ledger.accounts WHERE id=NEW.parent_id
   AND tenant_id=NEW.tenant_id AND company_id=NEW.company_id FOR SHARE;
  IF NOT FOUND OR parent.posting_allowed OR parent.control_account OR parent.type<>NEW.type THEN
   RAISE EXCEPTION 'invalid_account_parent' USING ERRCODE='23514';
  END IF;
  IF EXISTS(WITH RECURSIVE ancestors AS (
    SELECT id,parent_id,ARRAY[id] AS path FROM ledger.accounts WHERE id=NEW.parent_id
    UNION ALL
    SELECT a.id,a.parent_id,p.path||a.id FROM ancestors p JOIN ledger.accounts a ON a.id=p.parent_id
    WHERE NOT a.id=ANY(p.path) AND cardinality(p.path)<=256
   ) SELECT FROM ancestors WHERE id=NEW.id OR cardinality(path)>256) THEN
   RAISE EXCEPTION 'account_hierarchy_cycle_or_depth' USING ERRCODE='23514';
  END IF;
 END IF;
 IF EXISTS(SELECT FROM ledger.accounts WHERE parent_id=NEW.id
   AND (NEW.posting_allowed OR NEW.control_account OR type<>NEW.type)) THEN
  RAISE EXCEPTION 'invalid_group_account' USING ERRCODE='23514';
 END IF;
 RETURN NEW;
 END $$;
CREATE TRIGGER account_definition BEFORE INSERT OR UPDATE ON ledger.accounts
 FOR EACH ROW EXECUTE FUNCTION ledger.guard_account_definition();

CREATE FUNCTION ledger.guard_dimension_definition() RETURNS trigger
 LANGUAGE plpgsql SET search_path=pg_catalog,ledger,pg_temp AS $$
 BEGIN
 IF (NEW.id,NEW.tenant_id,NEW.company_id,NEW.kind,NEW.code)
  IS DISTINCT FROM (OLD.id,OLD.tenant_id,OLD.company_id,OLD.kind,OLD.code)
  AND EXISTS(SELECT FROM ledger.line_dimensions WHERE dimension_id=OLD.id) THEN
  RAISE EXCEPTION 'dimension_definition_in_use' USING ERRCODE='55000';
 END IF;
 RETURN NEW;
 END $$;
CREATE TRIGGER dimension_definition BEFORE UPDATE ON ledger.dimensions
 FOR EACH ROW EXECUTE FUNCTION ledger.guard_dimension_definition();

-- Foreign keys alone take KEY SHARE, which does not block a classification or
-- active-flag update. SHARE locks protect interpretation through commit.
CREATE FUNCTION ledger.lock_line_definition() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,pg_temp AS $$
 BEGIN
 IF TG_TABLE_NAME='lines' THEN
  PERFORM 1 FROM ledger.accounts WHERE id=NEW.account_id FOR SHARE;
 ELSE
  PERFORM 1 FROM ledger.dimensions WHERE id=NEW.dimension_id FOR SHARE;
 END IF;
 RETURN NEW;
 END $$;
CREATE TRIGGER aa_lock_account BEFORE INSERT OR UPDATE ON ledger.lines
 FOR EACH ROW EXECUTE FUNCTION ledger.lock_line_definition();
CREATE TRIGGER aa_lock_dimension BEFORE INSERT OR UPDATE ON ledger.line_dimensions
 FOR EACH ROW EXECUTE FUNCTION ledger.lock_line_definition();

CREATE FUNCTION ledger.lock_posting_dimensions() RETURNS trigger
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,ledger,pg_temp AS $$
 BEGIN
 IF OLD.state='APPROVED' AND NEW.state='POSTED' THEN
  PERFORM 1 FROM ledger.dimensions WHERE id IN
   (SELECT dimension_id FROM ledger.line_dimensions WHERE journal_id=OLD.id) ORDER BY id FOR SHARE;
  IF EXISTS(SELECT FROM ledger.line_dimensions d JOIN ledger.dimensions v ON v.id=d.dimension_id
   WHERE d.journal_id=OLD.id AND NOT v.active) THEN
   RAISE EXCEPTION 'inactive_dimension' USING ERRCODE='23514';
  END IF;
 END IF;
 RETURN NEW;
 END $$;
CREATE TRIGGER ab_lock_posting_dimensions BEFORE UPDATE ON ledger.journals
 FOR EACH ROW EXECUTE FUNCTION ledger.lock_posting_dimensions();

-- Close nullable-parameter validation gaps for direct database callers too.
CREATE OR REPLACE FUNCTION ledger.list_journals(p_limit integer DEFAULT 50,p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL,p_state text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,ledger,security,pg_temp AS $$
 DECLARE result jsonb;
 BEGIN
 IF NOT security.has('ledger.read') THEN RAISE EXCEPTION 'permission_denied' USING ERRCODE='42501'; END IF;
 IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 OR (p_before IS NULL)<>(p_before_id IS NULL)
   OR (p_state IS NOT NULL AND p_state NOT IN ('DRAFT','SUBMITTED','APPROVED','POSTED','VOIDED')) THEN
  RAISE EXCEPTION 'invalid_pagination' USING ERRCODE='22023';
 END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.created_at DESC,s.id DESC),'[]'::jsonb) INTO result FROM (
 SELECT j.id,j.number,j.description,j.accounting_date,j.currency,j.state,j.version,j.created_at,
 CASE WHEN EXISTS(SELECT FROM ledger.journals r WHERE r.reversed_from=j.id AND r.state='POSTED') THEN 'REVERSED' ELSE j.state END effective_state,
 (SELECT sum(l.debit_minor)::text FROM ledger.lines l WHERE l.journal_id=j.id) debit_minor
 FROM ledger.journals j WHERE (p_before IS NULL OR (j.created_at,j.id)<(p_before,p_before_id)) AND (p_state IS NULL OR j.state=p_state)
 ORDER BY j.created_at DESC,j.id DESC LIMIT p_limit) s;
 RETURN result;
 END $$;
