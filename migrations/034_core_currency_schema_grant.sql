-- 034_core_currency_schema_grant.sql
SET LOCAL ROLE serk_owner;

-- 1. Grant schema usage on core to serk_api
GRANT USAGE ON SCHEMA core TO serk_api;

-- 2. Ensure Finance role has taxes permissions as well
INSERT INTO security.role_permissions (tenant_id, role_id, permission)
SELECT tenant_id, id, unnest(ARRAY['taxes.read', 'taxes.manage'])
FROM security.roles
WHERE name IN ('Finance', 'Super Admin')
ON CONFLICT DO NOTHING;
