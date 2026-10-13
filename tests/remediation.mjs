import assert from 'node:assert/strict';
import {mkdirSync,writeFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {database,fixture} from './rc3-fixture.mjs';
const out=process.env.SERK_RESULTS_DIR||'test-results/remediation';mkdirSync(out,{recursive:true});
const results=[],started=new Date().toISOString();let db;
const check=async(name,fn)=>{try{await fn();results.push({name,status:'PASS'});console.log('PASS',name);}catch(e){results.push({name,status:'FAIL',code:e.code,error:e.message});throw e;}};
const reject=async(fn,code)=>assert.rejects(fn,e=>{assert.equal(e.code,code,e.message);return true;});
try{
 db=await database();const f=await fixture(db,'repair');
 await check('every shipped migration applies and repaired release marker is present',async()=>assert.equal((await db.query('SELECT security.release_version() AS v')).rows[0].v,'0.3.0-rc1'));
 for(const u of ['maker','checker']){
  const role=(await db.query('SELECT role_id FROM security.memberships WHERE user_id=$1 AND company_id=$2',[f.users[u],f.company])).rows[0].role_id;
  for(const p of ['configuration.manage','sales.read','sales.manage','purchases.read','purchases.manage','inventory.read','inventory.manage','payroll.read','payroll.manage','taxes.read','taxes.manage'])await db.query('INSERT INTO security.role_permissions VALUES($1,$2,$3)',[f.tenant,role,p]);
 }
 const accounts={};
 for(const [code,type,normal] of [['1201','ASSET','DEBIT'],['1301','ASSET','DEBIT'],['1400','ASSET','DEBIT'],['2001','LIABILITY','CREDIT'],['2101','LIABILITY','CREDIT'],['2201','LIABILITY','CREDIT'],['2211','LIABILITY','CREDIT'],['2301','LIABILITY','CREDIT'],['5001','COST_OF_SALES','DEBIT'],['5100','EXPENSE','DEBIT']]){
  const id=randomUUID();accounts[code]=id;await db.query('INSERT INTO ledger.accounts(id,tenant_id,company_id,code,name,type,normal_balance,reporting_category) VALUES($1,$2,$3,$4,$4,$5,$6,$5)',[id,f.tenant,f.company,code,type,normal]);
 }
 await db.query('UPDATE ledger.accounts SET control_account=true WHERE id=$1',[accounts['1201']]);
 const mappings={cash_accounts:[f.accounts['1000']],receivable:accounts['1201'],payable:accounts['2001'],output_tax:accounts['2201'],input_tax:accounts['1301'],opening_equity:f.accounts['3000'],payroll_expense:f.accounts['5000'],payroll_payable:accounts['2101'],payroll_tax:accounts['2211'],pension_expense:accounts['5100'],pension_payable:accounts['2301']};
 const call=async(user,sql,args=[])=>(await f.query(user,sql,args))[0]?.value;
 const master=async(kind,p)=>call('maker','SELECT finance.create_master($1,$2::jsonb) AS value',[kind,JSON.stringify(p)]);
 const command=async(user,kind,action,p,key='repair:'+randomUUID())=>call(user,'SELECT finance.document_command($1,$2,$3,$4::jsonb) AS value',[key,kind,action,JSON.stringify(p)]);
 const step=async(d,action,user='maker',extra={})=>command(user,d.kind,action,{id:d.id,expected_version:d.version,reason:'Synthetic independently reviewed action',...extra});
 const post=async(d)=>step(await step(d,'submit'),'approve','checker');
 await check('company account configuration validates explicit mappings',async()=>{await call('maker','SELECT finance.configure($1::jsonb) AS value',[JSON.stringify(mappings)]);await reject(()=>call('reader','SELECT finance.configure($1::jsonb) AS value',['{}']),'42501');});
 await check('controlled accounts accept private module postings but reject ordinary manual postings',async()=>{const p=f.payload('100');p.lines[0].account_id=accounts['1201'];await reject(()=>f.command('maker','repair:manual-control','create',p),'55000');assert.equal((await db.query("SELECT has_function_privilege('serk_api','ledger.create_module_journal(jsonb,uuid)','EXECUTE') AS allowed")).rows[0].allowed,false);});
 const customer=await master('CUSTOMER',{name:'Synthetic customer'}),vendor=await master('VENDOR',{name:'Synthetic vendor'});
 const item=await master('ITEM',{type:'PRODUCT',name:'Synthetic widget',unit_price:'700',cost_price:'300',initial_quantity:'0',income_account_id:f.accounts['4000'],expense_account_id:accounts['5001'],asset_account_id:accounts['1400']});
 const service=await master('ITEM',{type:'SERVICE',name:'Synthetic service',unit_price:'10',cost_price:'0',income_account_id:f.accounts['4000'],expense_account_id:f.accounts['5000']});
 const agency=await master('AGENCY',{name:'Synthetic test agency',code:'TEST'});
 const tax=await master('RATE',{agency_id:agency.id,name:'Synthetic 15 percent fixture, not statutory advice',code:'TEST15',rate_percent:'15',effective_from:'2026-01-01'});
 const base={branch_id:f.branch,accounting_date:'2026-09-14',due_date:'2026-09-30',settlement_type:'CREDIT'};
 const bill=async(no,qty,price)=>command('maker','BILL','create',{...base,bill_number:no,vendor_id:vendor.id,lines:[{item_id:item.id,quantity:qty,unit_price:price,tax_rate_id:tax.id}]});
 const invoice=async(no,qty,price,target=item)=>command('maker','INVOICE','create',{...base,invoice_number:no,customer_id:customer.id,lines:[{item_id:target.id,quantity:qty,unit_price:price,tax_rate_id:tax.id}]});
 let b1;
 await check('purchase creates draft and kernel submission; self-approval is rejected',async()=>{
  b1=await bill('BILL-1','10','300');assert.equal(b1.state,'DRAFT');b1=await step(b1,'submit');assert.equal(b1.state,'SUBMITTED');
  await reject(()=>step(b1,'approve'),'42501');b1=await step(b1,'approve','checker');assert.equal(b1.state,'APPROVED');
  assert.equal((await call('maker','SELECT ledger.get_journal($1) AS value',[b1.journal_id])).source_type,'SYSTEM');
  const p=(await f.query('maker','SELECT quantity::text,value_minor::text FROM finance.positions WHERE item_id=$1',[item.id]))[0];assert.deepEqual(p,{quantity:'10',value_minor:'3000'});
 });
 await check('sales reserve stock and post exact cost of sales with independent approval',async()=>{
  let d=await invoice('INV-1','2','700');d=await step(d,'submit');assert.equal(d.payload.lines[0].stock_cost_minor,'600');d=await step(d,'approve','checker');
  const p=(await f.query('maker','SELECT quantity::text,value_minor::text,reserved_quantity::text FROM finance.positions WHERE item_id=$1',[item.id]))[0];assert.deepEqual(p,{quantity:'8',value_minor:'2400',reserved_quantity:'0'});
  const j=await call('maker','SELECT ledger.get_journal($1) AS value',[d.journal_id]);assert.equal(j.state,'POSTED');assert.ok(j.lines.some(l=>l.account_id===accounts['5001']&&l.debit_minor==='600'));
 });
 await check('moving weighted average reserves an exact rounded cost',async()=>{
  await post(await bill('BILL-2','5','500'));let d=await invoice('INV-FRACTION','0.125','700');d=await step(d,'submit');assert.equal(d.payload.lines[0].stock_cost_minor,'47');await step(d,'void');
  // Voiding a submitted document releases its reservation and leaves no posting.
  const p=(await f.query('maker','SELECT reserved_quantity::text,reserved_minor::text FROM finance.positions WHERE item_id=$1',[item.id]))[0];assert.deepEqual(p,{reserved_quantity:'0.000',reserved_minor:'0'});
 });
 await check('insufficient stock rolls back submission without a partial journal',async()=>{const d=await invoice('INV-TOO-MUCH','999','700');await reject(()=>step(d,'submit'),'23514');const row=(await f.query('maker','SELECT state,journal_id FROM finance.documents WHERE id=$1',[d.id]))[0];assert.equal(row.state,'DRAFT');assert.equal(row.journal_id,null);});
 await check('half-minor-unit tax rounds exactly and large money values retain precision',async()=>{
  const d=await invoice('INV-ROUND','1','10',service);assert.equal(d.tax_total,'2');assert.equal(d.total_amount,'12');
  const huge=await invoice('INV-HUGE','1','9007199254740993',service);assert.equal(huge.subtotal,'9007199254740993');
  await reject(()=>invoice('INV-OVERFLOW','999999','9999999999999999999999999999',service),'22023');
 });
 await check('durable module idempotency replays once and rejects changed payload',async()=>{
  const p={...base,invoice_number:'INV-IDEMP',customer_id:customer.id,lines:[{item_id:service.id,quantity:'1',unit_price:'10'}]};const key='repair:stable-create';
  const a=await command('maker','INVOICE','create',p,key),b=await command('maker','INVOICE','create',p,key);assert.equal(a.id,b.id);await reject(()=>command('maker','INVOICE','create',{...p,invoice_number:'INV-IDEMP-OTHER'},key),'22000');
 });
 await check('payment is a separate submitted journal requiring a different approver',async()=>{
  const d=await step(b1,'pay','maker',{accounting_date:'2026-09-20',payment_account_id:f.accounts['1000']});assert.equal(d.state,'APPROVED');assert.equal(d.payment_state,'SUBMITTED');await reject(()=>step(d,'pay-approve'),'42501');const paid=await step(d,'pay-approve','checker');assert.equal(paid.state,'PAID');assert.equal(paid.payment_state,'POSTED');
 });
 await check('settlement uses the document control account after company mappings change',async()=>{
  let d=await post(await invoice('INV-FROZEN-CONTROL','1','10',service));const original=d.control_account_id;assert.equal(original,accounts['1201']);
  const id=randomUUID();await db.query("INSERT INTO ledger.accounts(id,tenant_id,company_id,code,name,type,normal_balance,reporting_category) VALUES($1,$2,$3,'1202','New receivable','ASSET','DEBIT','ASSET')",[id,f.tenant,f.company]);
  await call('maker','SELECT finance.configure($1::jsonb) AS value',[JSON.stringify({...mappings,receivable:id})]);
  d=await step(d,'pay','maker',{accounting_date:'2026-09-20',payment_account_id:f.accounts['1000']});d=await step(d,'pay-approve','checker');
  const j=await call('maker','SELECT ledger.get_journal($1) AS value',[d.payment_journal_id]);assert.ok(j.lines.some(x=>x.account_id===original&&x.credit_minor==='12'));assert.ok(!j.lines.some(x=>x.account_id===id));
  await call('maker','SELECT finance.configure($1::jsonb) AS value',[JSON.stringify(mappings)]);
 });
 await check('stock opening uses a balanced, independently approved ledger journal',async()=>{
  const d=await command('maker','OPENING','create',{...base,document_number:'OPEN-1',lines:[{item_id:item.id,quantity:'2',unit_price:'200'}]});await post(d);
  await reject(()=>master('ITEM',{type:'PRODUCT',name:'Unsafe direct quantity',unit_price:'1',cost_price:'1',initial_quantity:'10'}),'22023');
 });
 await check('payroll policy must be approved by someone other than its author',async()=>{
  const rules={income_tax_brackets:[{up_to_minor:null,rate_percent:'10',subtract_minor:'0'}],employee_pension_percent:'7',employer_pension_percent:'11'};
  const pol=await call('maker',"SELECT finance.policy_command('create',$1::jsonb) AS value",[JSON.stringify({name:'Synthetic policy, not legal rates',effective_from:'2026-01-01',rules})]);
  await reject(()=>call('maker',"SELECT finance.policy_command('approve',$1::jsonb) AS value",[JSON.stringify({id:pol.id,expected_version:pol.version})]),'42501');
  await call('checker',"SELECT finance.policy_command('approve',$1::jsonb) AS value",[JSON.stringify({id:pol.id,expected_version:pol.version})]);
  await master('EMPLOYEE',{branch_id:f.branch,first_name:'Synthetic',last_name:'Employee',salary_amount:'10000',pay_frequency:'MONTHLY'});
  const p={branch_id:f.branch,accounting_date:'2026-09-30',payrun_number:'PAY-2026-09',pay_frequency:'MONTHLY',pay_period_start:'2026-09-01',pay_period_end:'2026-09-30',policy_id:pol.id};
  let d=await command('maker','PAYROLL','create',p);assert.equal(d.total_amount,'8300');assert.equal(d.subtotal,'10000');assert.equal(d.payload.lines[0].employer_pension_minor,'1100');
  d=await post(d);assert.equal(d.state,'APPROVED');const slips=await f.query('maker','SELECT gross_pay::text,net_pay::text,taxes_withheld::text FROM payroll.pay_slips');assert.deepEqual(slips[0],{gross_pay:'10000',net_pay:'8300',taxes_withheld:'1000'});
  await reject(()=>command('maker','PAYROLL','create',{...p,payrun_number:'PAY-REPEAT'}),'23505');
 });
 await check('submitted service invoices can be voided without negative stock reservations',async()=>{let d=await invoice('INV-SERVICE-VOID','1','10',service);d=await step(d,'submit');d=await step(d,'void');assert.equal(d.state,'VOIDED');});
 const reverse=async(d,action,user='maker',extra={})=>call(user,'SELECT finance.reversal_command($1,$2,$3,$4::jsonb) AS value',['repair:'+randomUUID(),d.kind,action,JSON.stringify({id:d.id,expected_version:d.version,reason:'Synthetic reviewed correction',...extra})]);
 await check('voided payment can be prepared again with a fresh operation identity',async()=>{let d=await post(await invoice('INV-PAY-RETRY','1','10',service));d=await step(d,'pay','maker',{accounting_date:'2026-09-20',payment_account_id:f.accounts['1000']});d=await reverse(d,'payment-void');d=await step(d,'pay','maker',{accounting_date:'2026-09-20',payment_account_id:f.accounts['1000']});d=await step(d,'pay-approve','checker');assert.equal(d.state,'PAID');
  let rev=await reverse(d,'reverse','maker',{accounting_date:'2026-09-21'});await reject(()=>reverse(rev,'reverse-approve'),'42501');rev=await reverse(rev,'reverse-approve','checker');assert.equal(rev.state,'REVERSED');assert.ok(rev.reversal_payment_journal_id);
 });
 await check('pending reversal can be voided and recreated; ordinary payment is blocked during reversal',async()=>{let d=await post(await invoice('INV-REV-RETRY','1','10',service));d=await reverse(d,'reverse','maker',{accounting_date:'2026-09-22'});await reject(()=>step(d,'pay','maker',{accounting_date:'2026-09-22',payment_account_id:f.accounts['1000']}),'55000');d=await reverse(d,'reverse-void');d=await reverse(d,'reverse','maker',{accounting_date:'2026-09-22'});d=await reverse(d,'reverse-approve','checker');assert.equal(d.state,'REVERSED');});
 await check('a ledger-only reader cannot see salaries or use module APIs',async()=>{
  assert.deepEqual(await f.query('reader','SELECT salary_amount FROM payroll.employees'),[]);assert.deepEqual(await f.query('reader','SELECT payload FROM finance.documents'),[]);assert.deepEqual(await f.query('reader','SELECT net_pay FROM payroll.pay_slips'),[]);await reject(()=>call('reader',"SELECT finance.list_documents('INVOICE') AS value"),'42501');
 });
 await check('cross-company customer identifiers are filtered by RLS',async()=>{
  const role=(await db.query('SELECT role_id FROM security.memberships WHERE user_id=$1 AND company_id=$2',[f.users.maker,f.company])).rows[0].role_id;
  await db.query('INSERT INTO security.memberships(tenant_id,company_id,user_id,role_id) VALUES($1,$2,$3,$4)',[f.tenant,f.otherCompany,f.users.maker,role]);
  let id;await db.transaction(async tx=>{await tx.exec('SET LOCAL ROLE serk_api');await tx.query("SELECT security.bind($1,$2,$3,'{}')",[f.tokens.maker,f.otherCompany,f.csrf]);id=(await tx.query("SELECT finance.create_master('CUSTOMER','{\"name\":\"Other company\"}') AS value")).rows[0].value.id;});
  assert.deepEqual(await f.query('maker','SELECT id FROM invoicing.customers WHERE id=$1',[id]),[]);
 });
 await check('runtime journal and line writes are denied even for SYSTEM source',async()=>{
  assert.equal((await db.query("SELECT has_table_privilege('serk_api','ledger.lines','UPDATE') AS allowed")).rows[0].allowed,false);
  await reject(()=>f.query('maker','UPDATE ledger.lines SET debit_minor=1 WHERE journal_id=$1',[b1.journal_id]),'42501');
 });
 await check('module-linked journal cannot bypass its source workflow',async()=>{await reject(()=>f.command('maker','repair:source-bypass','reverse',{id:b1.journal_id,expected_version:4,accounting_date:'2026-10-01',reason:'Synthetic bypass attempt'}),'55000');});
 await check('balance sheet asset sections are disjoint and reconcile',async()=>{
  const id=randomUUID();await db.query("INSERT INTO ledger.accounts(id,tenant_id,company_id,code,name,type,normal_balance,reporting_category,statement_class) VALUES($1,$2,$3,'1500','Synthetic property','ASSET','DEBIT','PROPERTY','NON_CURRENT')",[id,f.tenant,f.company]);
  const p=f.payload('100');p.lines=[{account_id:id,debit_minor:'100',credit_minor:'0'},{account_id:f.accounts['3000'],debit_minor:'0',credit_minor:'100'}];await f.post('repair-property',p);
  const b=await call('maker',"SELECT ledger.balance_sheet('2026-10-12') AS value");assert.equal(b.assets.current_assets.filter(x=>x.id===id).length,0);assert.equal(b.assets.non_current_assets.filter(x=>x.id===id).length,1);assert.equal(b.is_balanced,true);
 });
 await check('dashboard excludes submitted financial drafts and retains exact money strings',async()=>{const before=await call('maker',"SELECT finance.dashboard('2026-10-12') AS value");let d=await invoice('INV-DASHBOARD-DRAFT','1','99999',service);d=await step(d,'submit');const after=await call('maker',"SELECT finance.dashboard('2026-10-12') AS value");assert.deepEqual(after.metrics,before.metrics);assert.equal(typeof after.metrics.total_revenue,'string');await step(d,'void');});
 await check('current integrity reconciles final posted snapshots and outbox records',async()=>{const i=await call('maker','SELECT ledger.integrity_status() AS value');assert.equal(i.ok,true,JSON.stringify(i));assert.equal(i.posted_snapshot_mismatches,0);});
 await check('balanced privileged fault injection is detected against posting snapshot',async()=>{
  await db.exec('BEGIN;ALTER TABLE ledger.lines DISABLE TRIGGER guard_lines;');
  try{await db.query('UPDATE ledger.lines SET debit_minor=debit_minor*2,credit_minor=credit_minor*2,functional_debit_minor=functional_debit_minor*2,functional_credit_minor=functional_credit_minor*2 WHERE journal_id=$1',[b1.journal_id]);await db.exec('SET LOCAL ROLE serk_api');await db.query("SELECT security.bind($1,$2,$3,'{}')",[f.tokens.maker,f.company,f.csrf]);const i=(await db.query('SELECT ledger.integrity_status() AS value')).rows[0].value;assert.equal(i.ok,false);assert.equal(i.posted_snapshot_mismatches,1);}finally{await db.exec('ROLLBACK;');}
 });
 await check('session-only MFA mutations are no longer granted to the API role',async()=>{await reject(()=>call('reader','SELECT security.self_disable_mfa() AS value'),'42501');assert.equal((await db.query("SELECT has_function_privilege('serk_api','security.change_verified_mfa(text,text,uuid,bigint,text,bigint,boolean,boolean)','EXECUTE') AS allowed")).rows[0].allowed,false);});
 await check('verified MFA change revokes sessions; mandatory MFA cannot be disabled',async()=>{
  const current=Math.floor(Date.now()/30000),version=randomUUID();await db.query('INSERT INTO security.user_mfa(user_id,tenant_id,encrypted_secret,last_step,version) VALUES($1,$2,$3,$4,$5)',[f.users.reader,f.tenant,'x'.repeat(64),current-2,version]);
  await db.query('UPDATE security.sessions SET mfa_verified=true WHERE user_id=$1',[f.users.reader]);
  const args=[f.tokens.reader,'$argon2id$synthetic-not-for-login',version,current,'y'.repeat(64),current,true,true];
  await reject(()=>db.transaction(async tx=>{await tx.exec('SET LOCAL ROLE serk_auth');await tx.query('SELECT security.change_verified_mfa($1,$2,$3,$4,$5,$6,$7,$8)',args);}), '42501');
  args[6]=false;await db.transaction(async tx=>{await tx.exec('SET LOCAL ROLE serk_auth');await tx.query('SELECT security.change_verified_mfa($1,$2,$3,$4,$5,$6,$7,$8)',args);});
  assert.equal((await db.query('SELECT count(*)::int AS n FROM security.sessions WHERE user_id=$1 AND revoked_at IS NULL',[f.users.reader])).rows[0].n,0);
 });
 await check('a closed period rejects module submission without financial effects',async()=>{
  const d=await invoice('INV-CLOSED','1','10',service);await call('maker',"SELECT ledger.close_period_command('repair:close-period',$1,1,'Synthetic close') AS value",[f.period]);await reject(()=>step(d,'submit'),'55000');
  assert.equal((await f.query('maker','SELECT journal_id FROM finance.documents WHERE id=$1',[d.id]))[0].journal_id,null);
 });
}catch(e){console.error('FAIL',e.code,e.message);process.exitCode=1;}
finally{if(db)await db.close();const result={started,finished:new Date().toISOString(),status:process.exitCode?'FAIL':'PASS',passed:results.filter(x=>x.status==='PASS').length,failed:results.filter(x=>x.status==='FAIL').length,backend:db?.native?'native PostgreSQL synthetic SQL':'PGlite sequential synthetic SQL',results,limitations:'No native concurrency, Go compile/HTTP, container, or browser execution is represented by this suite.'};writeFileSync(out+'/results.json',JSON.stringify(result,null,2));}
