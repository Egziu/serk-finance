// Runs the accountant test guide's core scenarios over HTTP against a demo workspace
// (local or Railway). It writes test transactions with unique numbers, so it can be repeated.
//   SERK_BASE_URL=https://… SERK_DEMO_PASSWORD=… node tests/demo-scenarios.mjs
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
const base=process.env.SERK_BASE_URL||'http://localhost:8080',password=process.env.SERK_DEMO_PASSWORD;
if(!password)throw new Error('SERK_DEMO_PASSWORD required');
const run=Date.now().toString(36).toUpperCase();
async function login(email){
 const r=await fetch(base+'/api/v1/auth/login',{method:'POST',headers:{'Content-Type':'application/json',Origin:base},body:JSON.stringify({tenant:'demo',email,password})});
 const body=await r.json();assert.equal(r.status,200,email+' '+JSON.stringify(body));
 const cookie=r.headers.get('set-cookie').split(';')[0];
 const s=await (await fetch(base+'/api/v1/session',{headers:{Cookie:cookie}})).json();
 const company=s.companies[0].id;
 const call=async(method,path,payload,expect=200)=>{
  const h={Cookie:cookie,'X-Company-ID':company,Origin:base};
  if(method!=='GET'){h['Content-Type']='application/json';h['X-CSRF-Token']=body.csrf_token;h['Idempotency-Key']=randomUUID();}
  const res=await fetch(base+'/api/v1'+path,{method,headers:h,body:payload===undefined?undefined:JSON.stringify(payload)});
  const text=await res.text();const data=text?JSON.parse(text):null;
  if(res.status!==expect)throw new Error(`${email} ${method} ${path} → ${res.status} ${text.slice(0,300)}`);
  return data;
 };
 return {call};
}
const results=[];
const step=async(name,fn)=>{try{await fn();results.push(name);console.log('PASS',name);}catch(e){console.log('FAIL',name,e.message);process.exitCode=1;}};
const acc=await login('accountant@serk.demo'),mgr=await login('manager@serk.demo'),pay=await login('payroll@serk.demo'),aud=await login('auditor@serk.demo'),admin=await login('admin@serk.demo');
const ref=await acc.call('GET','/accounting/reference');
const A=code=>ref.accounts.find(a=>a.code===code).id,hq=ref.branches.find(b=>b.code==='MEKELLE').id;
const today=new Date().toISOString().slice(0,10);
const tb=async()=>Object.fromEntries((await acc.call('GET',`/reports/trial-balance?as_of=${today}`)).accounts?.map?.(a=>[a.code,a])??[]);

await step('journal: prepare, refuse self-approval, approve and post by another user',async()=>{
 let j=await acc.call('POST','/accounting/journals',{branch_id:hq,accounting_date:today,description:'Office rent '+run,currency:'ETB',fx_rate:'1',reason:'Rent agreement',
  lines:[{account_id:A('6100'),debit_minor:'2000000',credit_minor:'0'},{account_id:A('1010'),debit_minor:'0',credit_minor:'2000000'}]},201);
 j=await acc.call('POST',`/accounting/journals/${j.id}/submit`,{expected_version:j.version,reason:'Rent agreement attached'});
 await acc.call('POST',`/accounting/journals/${j.id}/approve`,{expected_version:j.version,reason:'Self approval'},403);
 j=await mgr.call('POST',`/accounting/journals/${j.id}/approve`,{expected_version:j.version,reason:'Checked agreement'});
 j=await mgr.call('POST',`/accounting/journals/${j.id}/post`,{expected_version:j.version,reason:'Release'});
 assert.equal(j.state,'POSTED');
});
let invoice;
await step('sales invoice with 15% VAT, approved by the manager',async()=>{
 const customers=await acc.call('GET','/invoicing/customers'),items=await acc.call('GET','/inventory/items'),rates=await acc.call('GET','/taxes/rates');
 const teff=items.find(i=>i.sku==='TEFF-50'),vat=rates.find(r=>r.code==='VAT15');
 let d=await acc.call('POST','/invoicing/invoices',{branch_id:hq,accounting_date:today,due_date:today,invoice_number:'INV-'+run,customer_id:customers[0].id,
  lines:[{item_id:teff.id,quantity:'2',unit_price:'650000',tax_rate_id:vat.id}]});
 assert.equal(d.subtotal,'1300000');assert.equal(d.tax_total,'195000');
 d=await acc.call('POST',`/invoicing/invoices/${d.id}/submit`,{expected_version:d.version,reason:'Delivery note signed'});
 d=await mgr.call('POST',`/invoicing/invoices/${d.id}/approve`,{expected_version:d.version,reason:'Checked order'});
 assert.equal(d.state,'APPROVED');invoice=d;
});
await step('VAT report for today includes the invoice',async()=>{
 const r=await acc.call('GET',`/taxes/report?from=${today}&to=${today}`);
 assert.ok(BigInt(r.output_tax_minor)>=195000n,JSON.stringify(r));
});
await step('VAT settlement through a controlled adjustment',async()=>{
 let x=await acc.call('POST','/finance/adjustments/create',{purpose:'TAX_SETTLEMENT',number:'VAT-'+run,branch_id:hq,accounting_date:today,description:'Remit VAT',reason:'VAT return filed',
  lines:[{account_id:A('2200'),debit_minor:'195000',credit_minor:'0'},{account_id:A('1010'),debit_minor:'0',credit_minor:'195000'}]});
 x=await acc.call('POST','/finance/adjustments/submit',{id:x.id,expected_version:x.version,reason:'Prepared'});
 await acc.call('POST','/finance/adjustments/approve',{id:x.id,expected_version:x.version,reason:'Self'},403);
 x=await mgr.call('POST','/finance/adjustments/approve',{id:x.id,expected_version:x.version,reason:'Receipt checked'});
 assert.equal(x.state,'POSTED');
});
await step('payroll for a month is computed and approved by another user',async()=>{
 const pols=await pay.call('GET','/payroll/policies');const pol=pols.find(p=>p.approved_by);
 // Use a month this run has not paid yet: walk back from last month.
 let d,month=new Date();month.setUTCDate(1);
 for(let i=0;i<24&&!d;i++){
  month.setUTCMonth(month.getUTCMonth()-1);
  const ps=month.toISOString().slice(0,10),pe=new Date(Date.UTC(month.getUTCFullYear(),month.getUTCMonth()+1,0)).toISOString().slice(0,10);
  if(ps<'2026-07-08')break;
  try{d=await pay.call('POST','/payroll/run',{branch_id:hq,accounting_date:pe,payrun_number:'PAY-'+run+'-'+i,pay_frequency:'MONTHLY',pay_period_start:ps,pay_period_end:pe,policy_id:pol.id});}
  catch(e){if(!/payroll_period_already_processed|period_not_open/.test(e.message))throw e;}
 }
 if(!d){console.log('   (all eligible months already paid; skipped)');return;}
 // 15,000 gross: 35% band, 15000*0.35-2050 = 3,200 PAYE; 7% pension 1,050 → net 10,750.
 const slip=d.payload.lines.find(l=>l.gross_minor==='1500000');
 assert.deepEqual([slip.income_tax_minor,slip.employee_pension_minor,slip.net_minor],['320000','105000','1075000']);
 d=await pay.call('POST',`/payroll/payruns/${d.id}/submit`,{expected_version:d.version,reason:'Attendance checked'});
 d=await mgr.call('POST',`/payroll/payruns/${d.id}/approve`,{expected_version:d.version,reason:'Approved'});
 assert.equal(d.state,'APPROVED');
});
await step('auditor can read but cannot prepare',async()=>{
 await aud.call('GET','/reports/trial-balance?as_of='+today);
 await aud.call('POST','/accounting/journals',{branch_id:hq,accounting_date:today,description:'Auditor attempt',currency:'ETB',fx_rate:'1',reason:'Should be refused',
  lines:[{account_id:A('6100'),debit_minor:'1',credit_minor:'0'},{account_id:A('1010'),debit_minor:'0',credit_minor:'1'}]},403);
});
await step('statements balance and the ledger integrity check passes',async()=>{
 const b=await acc.call('GET',`/reports/balance-sheet?as_of=${today}`);assert.equal(b.is_balanced,true);
 const i=await admin.call('GET','/accounting/integrity');assert.equal(i.ok,true,JSON.stringify(i));
});
console.log(process.exitCode?'FAIL':'PASS',`${results.length} scenarios passed`);
