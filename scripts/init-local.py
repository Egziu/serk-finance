"""Generate credentials for local development; never creates production identities."""
import base64, json, os, pathlib, secrets

root = pathlib.Path(__file__).resolve().parents[1]
local = root / '.local'
local.mkdir(exist_ok=True, mode=0o700)
if (root / '.env').exists() or (local / 'bootstrap.json').exists():
    raise SystemExit('Local configuration already exists. Preserve existing credentials and data.')
def write(path, content):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f: f.write(content)
write(root / '.env', '\n'.join(k+'='+secrets.token_urlsafe(32) for k in ['SERK_DB_ADMIN_PASSWORD','SERK_API_PASSWORD','SERK_AUTH_PASSWORD'])+'\nSERK_MFA_KEY='+base64.b64encode(secrets.token_bytes(32)).decode()+'\n')
password = secrets.token_urlsafe(24)
all_permissions = [
    'ledger.read', 'journal.create', 'journal.submit', 'journal.approve', 'journal.post', 'journal.reverse', 'journal.void',
    'period.close', 'audit.read', 'configuration.manage', 'user.manage', 'role.manage',
    'sales.read', 'sales.manage', 'purchases.read', 'purchases.manage', 'taxes.read', 'taxes.manage',
    'payroll.read', 'payroll.manage', 'inventory.read', 'inventory.manage'
]
finance_permissions = [
    'ledger.read', 'journal.create', 'journal.submit', 'journal.approve', 'journal.post', 'journal.reverse', 'journal.void',
    'audit.read', 'period.close', 'sales.read', 'sales.manage', 'purchases.read', 'purchases.manage',
    'taxes.read', 'taxes.manage', 'payroll.read', 'payroll.manage', 'inventory.read', 'inventory.manage'
]
config = {
 'slug': 'local', 'name': 'Local workspace',
 'companies': [{'code':'LOCAL','name':'Local company','currency':'ETB','country':'ET','branches':['HQ'],
 'year_name':'FY2026','year_start':'2026-01-01','year_end':'2026-12-31','accounts':[
 {'code':'1000','name':'Bank','type':'ASSET','normal_balance':'DEBIT'},
 {'code':'3000','name':'Capital','type':'EQUITY','normal_balance':'CREDIT'},
 {'code':'4000','name':'Revenue','type':'REVENUE','normal_balance':'CREDIT'},
 {'code':'5000','name':'Operating expense','type':'EXPENSE','normal_balance':'DEBIT'},{'code': '1200', 'name': 'Accounts receivable', 'type': 'ASSET', 'normal_balance': 'DEBIT'},{'code': '1300', 'name': 'Recoverable input tax', 'type': 'ASSET', 'normal_balance': 'DEBIT'},{'code': '1400', 'name': 'Inventory', 'type': 'ASSET', 'normal_balance': 'DEBIT'},{'code': '2000', 'name': 'Accounts payable', 'type': 'LIABILITY', 'normal_balance': 'CREDIT'},{'code': '2100', 'name': 'Payroll payable', 'type': 'LIABILITY', 'normal_balance': 'CREDIT'},{'code': '2200', 'name': 'Output tax payable', 'type': 'LIABILITY', 'normal_balance': 'CREDIT'},{'code': '2210', 'name': 'Payroll tax payable', 'type': 'LIABILITY', 'normal_balance': 'CREDIT'},{'code': '2300', 'name': 'Pension payable', 'type': 'LIABILITY', 'normal_balance': 'CREDIT'},{'code': '5001', 'name': 'Cost of sales', 'type': 'COST_OF_SALES', 'normal_balance': 'DEBIT'},{'code': '5100', 'name': 'Salary expense', 'type': 'EXPENSE', 'normal_balance': 'DEBIT'},{'code': '5200', 'name': 'Employer pension expense', 'type': 'EXPENSE', 'normal_balance': 'DEBIT'}]}],
 'roles':[
     {'name':'Super Admin','permissions':all_permissions},
     {'name':'Finance','permissions':finance_permissions},
     {'name':'Configuration reviewer','permissions':['configuration.manage','payroll.read','ledger.read']}
 ],
 'users':[
     {'email':'controller@local.test','name':'Configuration reviewer','password':password,'grants':[{'company':'LOCAL','role':'Configuration reviewer'}]},
     {'email':'accountant@local.test','name':'accountant','password':password,'grants':[{'company':'LOCAL','role':'Finance'}]},
     {'email':'approver@local.test','name':'approver','password':password,'grants':[{'company':'LOCAL','role':'Finance'}]},
     {'email':'admin@local.test','name':'Super Admin','password':password,'grants':[{'company':'LOCAL','role':'Super Admin'}]}
 ]
}
write(local/'bootstrap.json',json.dumps(config,indent=2)+'\n')
write(local/'sign-in.txt',f'''Workspace: local
Super Admin: admin@local.test
Configuration reviewer: controller@local.test
Finance Approver: approver@local.test
Accountant: accountant@local.test
Password: {password}
''')
print('Created local configuration. Sign-in details are in .local/sign-in.txt.')

