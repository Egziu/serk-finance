// Synthetic database-only fixtures. No real credentials or business data.
import {openDatabase} from './sql-backend.mjs';
import {readFileSync,readdirSync} from 'node:fs';
import {createHash,randomBytes,randomUUID} from 'node:crypto';

export const sha = value => createHash('sha256').update(value).digest('hex');
export async function database(through=999) {
  return openDatabase(through);
}
export async function fixture(db,suffix='primary') {
  const f={tenant:randomUUID(),company:randomUUID(),otherCompany:randomUUID(),branch:randomUUID(),second:randomUUID(),year:randomUUID(),period:randomUUID(),accounts:{},users:{},tokens:{},csrf:randomBytes(32).toString('base64url')};
  await db.query('INSERT INTO security.tenants(id,slug,name) VALUES($1,$2,$3)',[f.tenant,'test-'+suffix,suffix]);
  for(const id of [f.company,f.otherCompany]) await db.query("INSERT INTO organization.companies(id,tenant_id,code,name,functional_currency,country_code) VALUES($1::uuid,$2,$1::text,'Synthetic company','ETB','ET')",[id,f.tenant]);
  for(const id of [f.branch,f.second]) await db.query('INSERT INTO organization.branches(id,tenant_id,company_id,code,name) VALUES($1::uuid,$2,$3,$1::text,$1::text)',[id,f.tenant,f.company]);
  await db.query("INSERT INTO ledger.fiscal_years(id,tenant_id,company_id,name,start_date,end_date) VALUES($1,$2,$3,'2026','2026-01-01','2026-12-31')",[f.year,f.tenant,f.company]);
  await db.query("INSERT INTO ledger.periods(id,tenant_id,company_id,fiscal_year_id,name,start_date,end_date) VALUES($1,$2,$3,$4,'Full year','2026-01-01','2026-12-31')",[f.period,f.tenant,f.company,f.year]);
  for(const [code,type,normal] of [['1000','ASSET','DEBIT'],['3000','EQUITY','CREDIT'],['4000','REVENUE','CREDIT'],['5000','EXPENSE','DEBIT'],['7999','OTHER_EXPENSE','DEBIT']]) {
    f.accounts[code]=randomUUID();
    await db.query('INSERT INTO ledger.accounts(id,tenant_id,company_id,code,name,type,normal_balance,reporting_category) VALUES($1,$2,$3,$4,$4,$5,$6,$5)',[f.accounts[code],f.tenant,f.company,code,type,normal]);
  }
  const all=['ledger.read','journal.create','journal.submit','journal.approve','journal.post','journal.reverse','journal.void','period.close','audit.read'];
  for(const user of ['maker','checker','branch','reader','no_read']) {
    const id=randomUUID(),role=randomUUID();f.users[user]=id;f.tokens[user]=randomBytes(32).toString('base64url');
    await db.query("INSERT INTO security.users(id,tenant_id,email,display_name,password_hash) VALUES($1,$2,$3,$3,'$argon2id$synthetic-not-for-login')",[id,f.tenant,user+'@example.test']);
    await db.query('INSERT INTO security.roles(id,tenant_id,name) VALUES($1,$2,$3)',[role,f.tenant,user]);
    for(const perm of user==='no_read'?['journal.create']:user==='reader'?['ledger.read']:all) await db.query('INSERT INTO security.role_permissions VALUES($1,$2,$3)',[f.tenant,role,perm]);
    await db.query('INSERT INTO security.memberships(tenant_id,company_id,user_id,role_id,branch_id) VALUES($1,$2,$3,$4,$5)',[f.tenant,f.company,id,role,user==='branch'?f.second:null]);
    await db.query('SELECT security.issue_session($1,$2,$3)',[id,sha(f.tokens[user]),f.csrf]);
  }
  f.scope=async (user,fn)=>db.transaction(async tx=>{
    await tx.exec('SET LOCAL ROLE serk_api');
    await tx.query("SELECT security.bind($1,$2::uuid,$3,'{}')",[f.tokens[user],f.company,f.csrf]);
    return fn(tx);
  });
  f.query=(user,sql,args=[])=>f.scope(user,async tx=>(await tx.query(sql,args)).rows);
  f.command=async (user,key,action,payload)=>(await f.query(user,'SELECT ledger.command($1,$2,$3::jsonb) AS value',[key,action,JSON.stringify(payload)]))[0].value;
  f.payload=(amount='10000',date='2026-09-14',branch=f.branch)=>({branch_id:branch,accounting_date:date,description:'Synthetic accounting entry',currency:'ETB',fx_rate:'1',reason:'Regression evidence only',lines:[{account_id:f.accounts['1000'],debit_minor:amount,credit_minor:'0'},{account_id:f.accounts['4000'],debit_minor:'0',credit_minor:amount}]});
  f.post=async (key,payload=f.payload())=>{
    let j=await f.command('maker',key+'-create','create',payload);
    for(const [action,user] of [['submit','maker'],['approve','checker'],['post','checker']]) j=await f.command(user,key+'-'+action,action,{id:j.id,expected_version:j.version,reason:'Independent synthetic control'});
    return j;
  };
  return f;
}
