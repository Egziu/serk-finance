// 0.2.2 regression suite: security and IFRS controls added after the independent reviews.
// Runs on PGlite by default, or on native PostgreSQL with SERK_SQL_BACKEND=native.
import assert from 'node:assert/strict';
import {mkdirSync,writeFileSync} from 'node:fs';
import {randomBytes,randomUUID} from 'node:crypto';
import {database,fixture,sha} from './rc3-fixture.mjs';

const out=process.env.SERK_RESULTS_DIR||'test-results/controls-022';mkdirSync(out,{recursive:true});
const results=[],started=new Date().toISOString();let db;
const check=async(name,fn)=>{try{await fn();results.push({name,status:'PASS'});console.log('PASS',name);}catch(e){results.push({name,status:'FAIL',code:e.code,error:e.message});console.log('FAIL',name,e.code||'',e.message);process.exitCode=1;}};
const reject=async(fn,code,message)=>assert.rejects(fn,e=>{assert.equal(e.code,code,e.message);if(message)assert.equal(e.message,message);return true;});

// Module-enabled company on top of the ledger fixture (same shape as remediation.mjs).
async function modules(f,suffix){
  const call=async(user,sql,args=[])=>(await f.query(user,sql,args))[0]?.value;
  for(const u of ['maker','checker']){
    const role=(await db.query('SELECT role_id FROM security.memberships WHERE user_id=$1 AND company_id=$2',[f.users[u],f.company])).rows[0].role_id;
    for(const p of ['configuration.manage','sales.read','sales.manage','purchases.read','purchases.manage','inventory.read','inventory.manage','payroll.read','payroll.manage','taxes.read','taxes.manage','user.manage','role.manage'])
      await db.query('INSERT INTO security.role_permissions VALUES($1,$2,$3) ON CONFLICT DO NOTHING',[f.tenant,role,p]);
  }
  const a={};
  for(const [code,type,normal,cls] of [['1201','ASSET','DEBIT','CURRENT'],['1301','ASSET','DEBIT','CURRENT'],['1400','ASSET','DEBIT','CURRENT'],['2001','LIABILITY','CREDIT','CURRENT'],['2101','LIABILITY','CREDIT','CURRENT'],['2201','LIABILITY','CREDIT','CURRENT'],['2211','LIABILITY','CREDIT','CURRENT'],['2301','LIABILITY','CREDIT','CURRENT'],['3100','EQUITY','CREDIT',null],['5001','COST_OF_SALES','DEBIT',null],['5100','EXPENSE','DEBIT',null],['5200','EXPENSE','DEBIT',null]]){
    const id=randomUUID();a[code]=id;
    await db.query('INSERT INTO ledger.accounts(id,tenant_id,company_id,code,name,type,normal_balance,reporting_category,statement_class) VALUES($1,$2,$3,$4,$4,$5,$6,$5,$7)',[id,f.tenant,f.company,code,type,normal,cls]);
  }
  const mappings={cash_accounts:[f.accounts['1000']],receivable:a['1201'],payable:a['2001'],output_tax:a['2201'],input_tax:a['1301'],opening_equity:f.accounts['3000'],retained_earnings:a['3100'],payroll_expense:f.accounts['5000'],payroll_payable:a['2101'],payroll_tax:a['2211'],pension_expense:a['5100'],pension_payable:a['2301']};
  await call('maker','SELECT finance.configure($1::jsonb) AS value',[JSON.stringify(mappings)]);
  const master=async(kind,p)=>call('maker','SELECT finance.create_master($1,$2::jsonb) AS value',[kind,JSON.stringify(p)]);
  const command=async(user,kind,action,p,key='c022:'+randomUUID())=>call(user,'SELECT finance.document_command($1,$2,$3,$4::jsonb) AS value',[key,kind,action,JSON.stringify(p)]);
  const step=async(d,action,user='maker',extra={})=>command(user,d.kind,action,{id:d.id,expected_version:d.version,reason:'Synthetic independently reviewed action',...extra});
  const post=async d=>step(await step(d,'submit'),'approve','checker');
  const reverse=async(d,action,user='maker',extra={})=>call(user,'SELECT finance.reversal_command($1,$2,$3,$4::jsonb) AS value',['c022:'+randomUUID(),d.kind,action,JSON.stringify({id:d.id,expected_version:d.version,reason:'Synthetic reviewed correction',...extra})]);
  const adjust=async(user,action,p)=>call(user,'SELECT finance.adjustment_command($1,$2,$3::jsonb) AS value',['c022:'+randomUUID(),action,JSON.stringify(p)]);
  const adjStep=async(x,action,user)=>adjust(user,action,{id:x.id,expected_version:x.version,reason:'Synthetic reviewed adjustment'});
  const customer=await master('CUSTOMER',{name:'Synthetic customer '+suffix}),vendor=await master('VENDOR',{name:'Synthetic vendor '+suffix});
  const item=await master('ITEM',{type:'PRODUCT',name:'Synthetic widget '+suffix,unit_price:'700',cost_price:'300',income_account_id:f.accounts['4000'],expense_account_id:a['5001'],asset_account_id:a['1400']});
  const agency=await master('AGENCY',{name:'Synthetic agency',code:'TST'+suffix});
  const tax=await master('RATE',{agency_id:agency.id,name:'Synthetic 15 percent fixture, not statutory advice',code:'T15'+suffix,rate_percent:'15',effective_from:'2026-01-01'});
  const base={branch_id:f.branch,accounting_date:'2026-09-14',due_date:'2026-09-30',settlement_type:'CREDIT'};
  const bill=(no,qty,price,date='2026-09-14')=>command('maker','BILL','create',{...base,accounting_date:date,due_date:'2026-12-31',bill_number:no,vendor_id:vendor.id,lines:[{item_id:item.id,quantity:qty,unit_price:price,tax_rate_id:tax.id}]});
  const invoice=(no,qty,price,date='2026-09-14')=>command('maker','INVOICE','create',{...base,accounting_date:date,due_date:'2026-12-31',invoice_number:no,customer_id:customer.id,lines:[{item_id:item.id,quantity:qty,unit_price:price,tax_rate_id:tax.id}]});
  const balance=async id=>(await db.query("SELECT coalesce(sum(l.functional_debit_minor-l.functional_credit_minor),0)::text AS b FROM ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id WHERE j.state='POSTED' AND l.account_id=$1",[id])).rows[0].b;
  await post(await bill('BILL-SEED','100','300','2026-09-01'));
  return {a,call,master,command,step,post,reverse,adjust,adjStep,item,tax,bill,invoice,balance,mappings};
}
async function addUser(f,name,perms,company=f.company,branch=null){
  const id=randomUUID(),role=randomUUID();f.users[name]=id;f.tokens[name]=randomBytes(32).toString('base64url');
  await db.query("INSERT INTO security.users(id,tenant_id,email,display_name,password_hash) VALUES($1,$2,$3,$3,'$argon2id$synthetic-not-for-login')",[id,f.tenant,name+'@example.test']);
  await db.query('INSERT INTO security.roles(id,tenant_id,name) VALUES($1,$2,$3)',[role,f.tenant,name]);
  for(const p of perms)await db.query('INSERT INTO security.role_permissions VALUES($1,$2,$3)',[f.tenant,role,p]);
  await db.query('INSERT INTO security.memberships(tenant_id,company_id,user_id,role_id,branch_id) VALUES($1,$2,$3,$4,$5)',[f.tenant,company,id,role,branch]);
  await db.query('SELECT security.issue_session($1,$2,$3)',[id,sha(f.tokens[name]),f.csrf]);
  return id;
}
const ledgerPerms=['ledger.read','journal.create','journal.submit','journal.approve','journal.post','journal.reverse','journal.void','period.close','audit.read'];

try{
 db=await database();
 const f=await fixture(db,'c022');
 const m=await modules(f,'A');

 // ---------------------------------------------------------------- security
 await check('S1 a ledger-only approver cannot push a module journal through the general ledger',async()=>{
  await addUser(f,'ledgeronly',ledgerPerms);
  let d=await m.invoice('INV-S1','1','700');d=await m.step(d,'submit');
  const j=await m.call('maker','SELECT ledger.get_journal($1) AS value',[d.journal_id]);
  await reject(()=>f.command('ledgeronly','c022:s1-approve','approve',{id:j.id,expected_version:j.version,reason:'Bypass attempt'}),'55000','use_module_workflow');
  await reject(()=>f.command('checker','c022:s1-approve2','approve',{id:j.id,expected_version:j.version,reason:'Bypass attempt'}),'55000','use_module_workflow');
  await m.step(d,'void');
 });
 await check('S2 a company user administrator cannot reset or disable an administrator of another company',async()=>{
  const victim=await addUser(f,'victim',[...ledgerPerms,'user.manage','role.manage'],f.otherCompany);
  await addUser(f,'admin1',['user.manage','role.manage','ledger.read']);
  // Give the victim a minor role in company A too, so the A administrator "sees" them.
  const role=randomUUID();await db.query("INSERT INTO security.roles(id,tenant_id,name) VALUES($1,$2,'victim-reader')",[role,f.tenant]);
  await db.query("INSERT INTO security.role_permissions VALUES($1,$2,'ledger.read')",[f.tenant,role]);
  await db.query('INSERT INTO security.memberships(tenant_id,company_id,user_id,role_id) VALUES($1,$2,$3,$4)',[f.tenant,f.company,victim,role]);
  const v=(await db.query('SELECT version FROM security.users WHERE id=$1',[victim])).rows[0].version;
  await reject(()=>m.call('admin1','SELECT security.admin_reset_password($1,$2,$3,$4) AS value',[victim,v,'$argon2id$attacker','Takeover attempt']),'42501','privilege_escalation');
  await reject(()=>m.call('admin1','SELECT security.admin_update_user($1,$2,$3,false,$4) AS value',[victim,v,'victim','Disable attempt']),'42501','privilege_escalation');
 });
 await check('S3 branch-limited configuration rights cannot change company-wide master data',async()=>{
  await addUser(f,'branchcfg',['configuration.manage','ledger.read'],f.company,f.second);
  await reject(()=>m.call('branchcfg',"SELECT ledger.create_account('9001','X','EXPENSE','DEBIT',NULL,true,false,'EXPENSE',NULL) AS value"),'42501');
  await reject(()=>m.call('branchcfg',"SELECT ledger.create_fiscal_year('FY27','2027-01-01','2027-12-31') AS value"),'42501');
  await reject(()=>m.call('branchcfg',"SELECT organization.create_branch('B9','Branch 9') AS value"),'42501');
 });
 await check('S3 accounts with balances or configuration roles cannot be deactivated; changes are audited',async()=>{
  await f.post('c022-s3-balance');
  await reject(()=>m.call('maker',"SELECT ledger.update_account($1,'Revenue',NULL,false,true,'REVENUE',NULL) AS value",[f.accounts['4000']]),'55000','account_has_balance');
  await reject(()=>m.call('maker',"SELECT ledger.update_account($1,'Retained',NULL,false,true,'EQUITY',NULL) AS value",[m.a['3100']]),'55000','account_in_use_by_configuration');
  await m.call('maker',"SELECT ledger.update_account($1,'Other costs',NULL,true,true,'EXPENSE',NULL) AS value",[m.a['5200']]);
  const ev=(await db.query("SELECT action FROM audit.events WHERE entity_id=$1",[m.a['5200']])).rows;
  assert.ok(ev.some(e=>e.action.startsWith('accounts.')),JSON.stringify(ev));
 });
 await check('S4 no application function is executable by PUBLIC and definer functions are owned by serk_owner',async()=>{
  const r=(await db.query(`SELECT p.oid::regprocedure::text AS f, pg_get_userbyid(p.proowner) AS owner, p.prosecdef, has_function_privilege('public',p.oid,'EXECUTE') AS pub
   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN('ledger','security','finance','organization','audit','integration','core','taxes','payroll','inventory','invoicing') AND p.prokind='f'`)).rows;
  assert.deepEqual(r.filter(x=>x.pub).map(x=>x.f),[]);
  assert.deepEqual(r.filter(x=>x.prosecdef&&x.owner!=='serk_owner').map(x=>x.f),[]);
 });
 await check('S5 the API role sees only its own tenant companies',async()=>{
  const other=randomUUID(),oc=randomUUID();
  await db.query("INSERT INTO security.tenants(id,slug,name) VALUES($1,'c022-other','other')",[other]);
  await db.query("INSERT INTO organization.companies(id,tenant_id,code,name,functional_currency,country_code) VALUES($1,$2,'OTHER','Other tenant co','ETB','ET')",[oc,other]);
  const rows=await f.query('maker','SELECT id FROM organization.companies');
  assert.ok(rows.length>=1&&!rows.some(r=>r.id===oc));
 });

 // ---------------------------------------------------------------- module integrity
 await check('S1 adjustment journals cannot be approved through the general ledger',async()=>{
  let inv=await m.post(await m.invoice('INV-VAT-1','2','700'));
  let x=await m.adjust('maker','create',{purpose:'TAX_SETTLEMENT',number:'VAT-REM-S1',branch_id:f.branch,accounting_date:'2026-09-20',description:'Remit output VAT',reason:'September VAT return filed',
   lines:[{account_id:m.a['2201'],debit_minor:'210',credit_minor:'0'},{account_id:f.accounts['1000'],debit_minor:'0',credit_minor:'210'}]});
  x=await m.adjStep(x,'submit','maker');
  const j=await m.call('maker','SELECT ledger.get_journal($1) AS value',[x.journal_id]);
  await reject(()=>f.command('checker','c022:adj-gl','approve',{id:j.id,expected_version:j.version,reason:'Bypass attempt'}),'55000','use_module_workflow');
  await reject(()=>m.adjStep(x,'approve','maker'),'42501','segregation_of_duties');
  const before=await m.balance(m.a['2201']);
  x=await m.adjStep(x,'approve','checker');assert.equal(x.state,'POSTED');
  assert.equal(BigInt(await m.balance(m.a['2201']))-BigInt(before),210n);
 });
 await check('D1 adjustments only touch the control accounts their purpose allows',async()=>{
  await reject(()=>m.adjust('maker','create',{purpose:'RECEIVABLE_ADJUSTMENT',number:'BAD-1',branch_id:f.branch,accounting_date:'2026-09-20',description:'Wrong purpose',reason:'Should fail',
   lines:[{account_id:m.a['2201'],debit_minor:'1',credit_minor:'0'},{account_id:f.accounts['1000'],debit_minor:'0',credit_minor:'1'}]}),'23514','control_account_not_allowed_for_purpose');
  await reject(()=>m.adjust('maker','create',{purpose:'TAX_SETTLEMENT',number:'BAD-2',branch_id:f.branch,accounting_date:'2026-09-20',description:'No control account',reason:'Should fail',
   lines:[{account_id:f.accounts['5000'],debit_minor:'1',credit_minor:'0'},{account_id:f.accounts['1000'],debit_minor:'0',credit_minor:'1'}]}),'23514','use_general_journal');
  await addUser(f,'taxless',[...ledgerPerms,'sales.read','sales.manage']);
  await reject(()=>m.adjust('taxless','create',{purpose:'TAX_SETTLEMENT',number:'BAD-3',branch_id:f.branch,accounting_date:'2026-09-20',description:'No tax rights',reason:'Should fail',
   lines:[{account_id:m.a['2201'],debit_minor:'1',credit_minor:'0'},{account_id:f.accounts['1000'],debit_minor:'0',credit_minor:'1'}]}),'42501');
 });
 await check('D1 receivable write-off and inventory write-down post with their sub-ledger',async()=>{
  await m.post(await m.bill('BILL-WD','10','300'));
  let x=await m.adjust('maker','create',{purpose:'RECEIVABLE_ADJUSTMENT',number:'WO-1',branch_id:f.branch,accounting_date:'2026-09-21',description:'Uncollectible receivable written off',reason:'Customer insolvent; approved by finance manager',
   lines:[{account_id:m.a['5200'],debit_minor:'100',credit_minor:'0'},{account_id:m.a['1201'],debit_minor:'0',credit_minor:'100'}]});
  x=await m.adjStep(await m.adjStep(x,'submit','maker'),'approve','checker');assert.equal(x.state,'POSTED');
  const pos=async()=>(await f.query('maker','SELECT quantity::text,value_minor::text FROM finance.positions WHERE item_id=$1',[m.item.id]))[0];
  const before=await pos();
  await reject(()=>m.adjust('maker','create',{purpose:'INVENTORY_ADJUSTMENT',number:'WD-BAD',branch_id:f.branch,accounting_date:'2026-09-21',description:'Inconsistent',reason:'Should fail',
   lines:[{account_id:m.a['5001'],debit_minor:'0',credit_minor:'50'},{account_id:m.a['1400'],debit_minor:'50',credit_minor:'0',item_id:m.item.id,quantity_delta:'-1'}]}),'23514','inconsistent_inventory_adjustment');
  x=await m.adjust('maker','create',{purpose:'INVENTORY_ADJUSTMENT',number:'WD-1',branch_id:f.branch,accounting_date:'2026-09-21',description:'Write-down to net realisable value (IAS 2.28)',reason:'Damaged stock valuation',
   lines:[{account_id:m.a['5001'],debit_minor:'500',credit_minor:'0'},{account_id:m.a['1400'],debit_minor:'0',credit_minor:'500',item_id:m.item.id,quantity_delta:'0'}]});
  x=await m.adjStep(await m.adjStep(x,'submit','maker'),'approve','checker');
  const after=await pos();
  assert.equal(after.quantity,before.quantity);assert.equal(BigInt(before.value_minor)-BigInt(after.value_minor),500n);
  // Sub-ledger and general ledger agree for the item's inventory account.
  const total=(await db.query('SELECT sum(value_minor)::text AS v FROM finance.positions p JOIN inventory.items i ON i.id=p.item_id WHERE i.asset_account_id=$1',[m.a['1400']])).rows[0].v;
  assert.equal(await m.balance(m.a['1400']),total);
 });
 await check('V3 stock removed by a count adjustment leaves at moving weighted-average cost',async()=>{
  const pos=(await f.query('maker','SELECT quantity::text,value_minor::text,reserved_quantity::text,reserved_minor::text FROM finance.positions WHERE item_id=$1',[m.item.id]))[0];
  const avail=Number(pos.quantity)-Number(pos.reserved_quantity),value=BigInt(pos.value_minor)-BigInt(pos.reserved_minor);
  const cost=String(Math.round(Number(value)/avail));
  let x=await m.adjust('maker','create',{purpose:'INVENTORY_ADJUSTMENT',number:'CNT-BAD',branch_id:f.branch,accounting_date:'2026-09-21',description:'Count shortage',reason:'Stock count',
   lines:[{account_id:m.a['5001'],debit_minor:'1',credit_minor:'0'},{account_id:m.a['1400'],debit_minor:'0',credit_minor:'1',item_id:m.item.id,quantity_delta:'-1'}]});
  x=await m.adjStep(x,'submit','maker');
  await reject(()=>m.adjStep(x,'approve','checker'),'23514','inventory_adjustment_not_at_average_cost');
  await m.adjStep(x,'void','maker');
  x=await m.adjust('maker','create',{purpose:'INVENTORY_ADJUSTMENT',number:'CNT-OK',branch_id:f.branch,accounting_date:'2026-09-21',description:'Count shortage',reason:'Stock count',
   lines:[{account_id:m.a['5001'],debit_minor:cost,credit_minor:'0'},{account_id:m.a['1400'],debit_minor:'0',credit_minor:cost,item_id:m.item.id,quantity_delta:'-1'}]});
  x=await m.adjStep(await m.adjStep(x,'submit','maker'),'approve','checker');assert.equal(x.state,'POSTED');
 });
 await check('A7 a purchase return is refused once the stock has moved after the bill',async()=>{
  const b=await m.post(await m.bill('BILL-RET','4','300','2026-09-22'));
  await m.post(await m.invoice('INV-RET','1','700','2026-09-22'));
  const r=await m.reverse(b,'reverse','maker',{accounting_date:'2026-09-22'});
  await reject(()=>m.reverse(r,'reverse-approve','checker'),'55000','stock_moved_since_bill_use_inventory_adjustment');
 });
 await check('A5 the VAT report shows reversals as negative amounts of the original type',async()=>{
  const before=await m.call('maker',"SELECT finance.tax_report('2026-09-23','2026-09-23') AS value");
  assert.equal(before.input_tax_minor,'0');
  const b=await m.post(await m.bill('BILL-VAT','1','1000','2026-09-23'));
  let r=await m.reverse(b,'reverse','maker',{accounting_date:'2026-09-23'});
  r=await m.reverse(r,'reverse-approve','checker');assert.equal(r.state,'REVERSED');
  const rep=await m.call('maker',"SELECT finance.tax_report('2026-09-23','2026-09-23') AS value");
  assert.equal(rep.input_tax_minor,'0');assert.equal(rep.output_tax_minor,'0');
  assert.equal(rep.ledger_input_tax_movement_minor,'0');
 });
 await check('A5 a tax rate that is in use cannot be re-priced or back-dated',async()=>{
  await reject(()=>db.query("UPDATE taxes.tax_rates SET rate_percent=10 WHERE id=$1",[m.tax.id]),'55000','tax_rate_in_use_create_new_version');
  await reject(()=>db.query("UPDATE taxes.tax_rates SET effective_from='2020-01-01' WHERE id=$1",[m.tax.id]),'55000','tax_rate_in_use_create_new_version');
 });
 await check('A6 payroll is accrued on the last day of its pay period',async()=>{
  const rules={income_tax_brackets:[{up_to_minor:null,rate_percent:'10',subtract_minor:'0'}],employee_pension_percent:'7',employer_pension_percent:'11'};
  const pol=await m.call('maker',"SELECT finance.policy_command('create',$1::jsonb) AS value",[JSON.stringify({name:'Synthetic policy, not legal rates',effective_from:'2026-01-01',rules})]);
  await m.call('checker',"SELECT finance.policy_command('approve',$1::jsonb) AS value",[JSON.stringify({id:pol.id,expected_version:pol.version})]);
  await m.master('EMPLOYEE',{branch_id:f.branch,first_name:'Synthetic',last_name:'Employee',salary_amount:'10000',pay_frequency:'MONTHLY'});
  const p={branch_id:f.branch,payrun_number:'PAY-2026-08',pay_frequency:'MONTHLY',pay_period_start:'2026-08-01',pay_period_end:'2026-08-31',policy_id:pol.id};
  await reject(()=>m.command('maker','PAYROLL','create',{...p,accounting_date:'2026-09-01'}),'22023','payroll_accounting_date_must_be_period_end');
  const d=await m.command('maker','PAYROLL','create',{...p,accounting_date:'2026-08-31'});assert.equal(d.accounting_date,'2026-08-31');
 });
 await check('A4 foreign-currency journals need a recorded rate within tolerance',async()=>{
  const p={...f.payload('1000','2026-09-24'),currency:'USD',fx_rate:'120'};
  await reject(()=>f.command('maker','c022:fx-none','create',p),'23514','exchange_rate_not_recorded');
  await f.query('maker',"INSERT INTO core.exchange_rates(tenant_id,company_id,date,base_currency,foreign_currency,exchange_rate) VALUES($1,$2,'2026-09-24','ETB','USD',120)",[f.tenant,f.company]);
  await reject(()=>f.command('maker','c022:fx-far','create',{...p,fx_rate:'130'}),'23514','exchange_rate_outside_tolerance');
  await reject(()=>f.command('maker','c022:fx-inv','create',{...p,fx_rate:'0.0083'}),'23514','exchange_rate_outside_tolerance');
  const j=await f.command('maker','c022:fx-ok','create',{...p,fx_rate:'121'});assert.equal(j.fx_rate,'121');
  await reject(()=>f.query('maker',"INSERT INTO core.exchange_rates(tenant_id,company_id,date,base_currency,foreign_currency,exchange_rate) VALUES($1,$2,'2026-09-25','ETB','USD',0)",[f.tenant,f.company]),'23514','invalid_exchange_rate');
  await f.command('maker','c022:fx-void','void',{id:j.id,expected_version:j.version,reason:'Test cleanup'});
 });
 await check('V1 an accountant without configuration rights can post a foreign-currency journal at the recorded rate',async()=>{
  await addUser(f,'fxclerk',ledgerPerms);
  const rate=await m.call('fxclerk',"SELECT ledger.recorded_rate('USD','2026-09-24') AS value");assert.equal(String(rate),'120');
  const j=await f.command('fxclerk','c022:fx-clerk','create',{...f.payload('1000','2026-09-24'),currency:'USD',fx_rate:'120'});assert.equal(j.currency,'USD');
  await f.command('fxclerk','c022:fx-clerk-void','void',{id:j.id,expected_version:j.version,reason:'Test cleanup'});
 });
 await check('V2 a recorded rate older than the maximum age does not validate a journal',async()=>{
  await reject(()=>f.command('maker','c022:fx-stale','create',{...f.payload('1000','2026-10-15'),currency:'USD',fx_rate:'120'}),'23514','exchange_rate_not_recorded');
  await m.call('maker','SELECT ledger.set_fx_policy(200,30) AS value');
  const j=await f.command('maker','c022:fx-30d','create',{...f.payload('1000','2026-10-15'),currency:'USD',fx_rate:'120'});
  await f.command('maker','c022:fx-30d-void','void',{id:j.id,expected_version:j.version,reason:'Test cleanup'});
  await m.call('maker','SELECT ledger.set_fx_policy(200,7) AS value');
 });
 await check('A2 statement of financial position uses explicit current / non-current classes',async()=>{
  const loan=await m.call('maker',"SELECT ledger.create_account('2500','Bank loan (5 year)','LIABILITY','CREDIT',NULL,true,false,'BORROWINGS','NON_CURRENT') AS value");
  const intangible=await m.call('maker',"SELECT ledger.create_account('1600','Intangible assets','ASSET','DEBIT',NULL,true,false,'INTANGIBLES','NON_CURRENT') AS value");
  await reject(()=>m.call('maker',"SELECT ledger.create_account('1700','No class','ASSET','DEBIT',NULL,true,false,'X',NULL) AS value"),'22023','statement_class_required');
  const p=f.payload('4000','2026-09-24');p.lines=[{account_id:intangible,debit_minor:'4000',credit_minor:'0'},{account_id:loan,debit_minor:'0',credit_minor:'4000'}];
  await f.post('c022-a2',p);
  const b=await m.call('maker',"SELECT ledger.balance_sheet('2026-09-30') AS value");
  assert.ok(b.liabilities.non_current_liabilities.some(x=>x.id===loan));assert.ok(!b.liabilities.current_liabilities.some(x=>x.id===loan));
  assert.ok(b.assets.non_current_assets.some(x=>x.id===intangible));assert.equal(b.is_balanced,true);
 });

 // ---------------------------------------------------------------- year end (separate tenant)
 const g=await fixture(db,'c022-year');
 const re=randomUUID();
 await db.query("INSERT INTO ledger.accounts(id,tenant_id,company_id,code,name,type,normal_balance,reporting_category) VALUES($1,$2,$3,'3100','Retained earnings','EQUITY','CREDIT','EQUITY')",[re,g.tenant,g.company]);
 const gcall=async(user,sql,args=[])=>(await g.query(user,sql,args))[0]?.value;
 const close=async(user,action,p)=>gcall(user,'SELECT ledger.year_close_command($1,$2,$3::jsonb) AS value',['c022:'+randomUUID(),action,JSON.stringify(p)]);
 await check('A1 year-end close transfers profit to retained earnings under dual control',async()=>{
  await g.post('y-rev',g.payload('10000','2026-03-10'));
  const e=g.payload('2500','2026-06-10');e.lines=[{account_id:g.accounts['5000'],debit_minor:'2500',credit_minor:'0'},{account_id:g.accounts['1000'],debit_minor:'0',credit_minor:'2500'}];
  await g.post('y-exp',e);
  const draft=await g.command('maker','c022:y-draft','create',g.payload('1','2026-07-01'));
  let pv=await gcall('maker','SELECT ledger.year_close_preview($1) AS value',[g.year]);
  assert.ok(pv.blockers.includes('unfinished_journals'));assert.equal(pv.profit_minor,'7500');
  await reject(()=>close('maker','request',{fiscal_year_id:g.year,retained_earnings_account_id:re,reason:'Year-end'}),'55000','year_close_blocked');
  await g.command('maker','c022:y-void','void',{id:draft.id,expected_version:draft.version,reason:'Not needed'});
  let c=await close('maker','request',{fiscal_year_id:g.year,retained_earnings_account_id:re,reason:'FY2026 year-end close'});
  assert.equal(c.state,'SUBMITTED');assert.equal(c.net_result_minor,'7500');
  await reject(()=>close('maker','approve',{id:c.id,expected_version:c.version,reason:'Self approval'}),'42501','segregation_of_duties');
  c=await close('checker','approve',{id:c.id,expected_version:c.version,reason:'Reviewed closing entries'});assert.equal(c.state,'POSTED');
  const is=await gcall('maker',"SELECT ledger.income_statement('2026-01-01','2026-12-31') AS value");assert.equal(is.net_profit_minor,'7500');
  const bs=await gcall('maker',"SELECT ledger.balance_sheet('2026-12-31') AS value");
  assert.equal(bs.equity.net_income_minor,'0');assert.ok(bs.equity.equity_accounts.some(x=>x.id===re&&x.balance_minor==='7500'));assert.equal(bs.is_balanced,true);
  const per=(await db.query('SELECT state FROM ledger.periods WHERE id=$1',[g.period])).rows[0].state;assert.equal(per,'CLOSED');
  const integrity=await gcall('maker','SELECT ledger.integrity_status() AS value');assert.equal(integrity.ok,true,JSON.stringify(integrity));
 });
 await check('A3 a closed year cannot be reopened through a period reopen',async()=>{
  await reject(()=>gcall('maker',"SELECT ledger.period_reopen_command($1,'request',$2::jsonb) AS value",['c022:'+randomUUID(),JSON.stringify({period_id:g.period,reason:'Audit adjustment'})]),'55000','fiscal_year_closed');
 });
 await check('A3 a closed period reopens only with a second approver',async()=>{
  for(const u of ['maker','checker']){const role=(await db.query('SELECT role_id FROM security.memberships WHERE user_id=$1',[g.users[u]])).rows[0].role_id;await db.query("INSERT INTO security.role_permissions VALUES($1,$2,'configuration.manage') ON CONFLICT DO NOTHING",[g.tenant,role]);}
  const fy=await gcall('maker',"SELECT ledger.create_fiscal_year('FY2027','2027-01-01','2027-12-31') AS value");
  const p1=(await db.query("SELECT id,version FROM ledger.periods WHERE fiscal_year_id=$1 ORDER BY start_date LIMIT 1",[fy])).rows[0];
  await gcall('maker','SELECT ledger.close_period($1,$2,$3) AS value',[p1.id,p1.version,'Month end']);
  let r=await gcall('maker',"SELECT ledger.period_reopen_command($1,'request',$2::jsonb) AS value",['c022:'+randomUUID(),JSON.stringify({period_id:p1.id,reason:'IAS 10 adjusting event'})]);
  await reject(()=>gcall('maker',"SELECT ledger.period_reopen_command($1,'approve',$2::jsonb) AS value",['c022:'+randomUUID(),JSON.stringify({id:r.id,expected_version:r.version,reason:'Self'})]),'42501','segregation_of_duties');
  r=await gcall('checker',"SELECT ledger.period_reopen_command($1,'approve',$2::jsonb) AS value",['c022:'+randomUUID(),JSON.stringify({id:r.id,expected_version:r.version,reason:'Approved by controller'})]);
  assert.equal(r.state,'APPROVED');assert.equal((await db.query('SELECT state FROM ledger.periods WHERE id=$1',[p1.id])).rows[0].state,'OPEN');
 });
}catch(e){console.error(e);process.exitCode=1;}
finally{
 if(db?.close)await db.close();
 const result={started,finished:new Date().toISOString(),status:process.exitCode?'FAIL':'PASS',passed:results.filter(x=>x.status==='PASS').length,failed:results.filter(x=>x.status==='FAIL').length,backend:db?.native?'native PostgreSQL':'PGlite',results};
 writeFileSync(out+'/results.json',JSON.stringify(result,null,2));
 console.log(result.status,result.passed,'passed',result.failed,'failed');
}
