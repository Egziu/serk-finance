INSERT INTO security.role_permissions (tenant_id, role_id, permission)
SELECT tenant_id, role_id, unnest(ARRAY['sales.read', 'sales.manage', 'purchases.read', 'purchases.manage'])
FROM security.role_permissions
WHERE permission = 'role.manage'
ON CONFLICT DO NOTHING;
