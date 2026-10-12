import assert from 'node:assert/strict';
import {readFileSync,mkdirSync,writeFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {database,fixture,sha} from './rc3-fixture.mjs';

const out=process.env.SERK_RESULTS_DIR||'test-results/rc3';mkdirSync(out,{recursive:true});
const results=[],started=new Date().toISOString();let db;
async function check(name,fn) {
  try {await fn();results.push({name,status:'PASS'});console.log('PASS '+name);}
  catch(e){results.push({name,status:'FAIL',message:e.message,code:e.code});console.error('FAIL '+name+': '+e.message);throw e;}
}
async function rejected(fn,code) {await assert.rejects(fn,e=>{assert.equal(e.code,code,e.message);return true;});}
try {
  db=await database(7);
  const f=await fixture(db,'upgrade');const huge='123456789012345678901';
  await f.post('opening',f.payload(huge,'2026-01-15'));
  const posted=await f.post('september');await f.post('second',f.payload('333','2026-09-14',f.second));
  const tables=['ledger.accounts','ledger.journals','ledger.lines','ledger.idempotency','audit.events','audit.heads','integration.outbox','security.sessions'];
  async function snapshot() {const o={};for(const t of tables)o[t]=sha((await db.query(`SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]')::text AS data FROM ${t} t`)).rows[0].data);return o;}
  const before=await snapshot();
  await check('populated rc2 to rc4 migration preserves financial, audit, outbox, receipts and sessions',async()=>{
    for(const name of ['008_master_data_integrity.sql','009_connected_reporting.sql','010_rls_statement_scope.sql'])await db.exec('BEGIN;'+readFileSync('migrations/'+name,'utf8')+';RESET ROLE;COMMIT;');
    assert.deepEqual(await snapshot(),before);
    assert.equal((await db.query('SELECT security.release_version() AS v')).rows[0].v,'0.2.0-rc4');
  });
  const gl=(user='maker',account=f.accounts['1000'],limit=100,cursor=null)=>f.query(user,'SELECT ledger.general_ledger($1,$2,$3,$4,$5,$6,$7) AS value',[account,'2026-09-01','2026-09-30',limit,cursor?.after_date??null,cursor?.after_id??null,cursor?.after_line??null]).then(r=>r[0].value);
  const integrity=(user='maker')=>f.query(user,'SELECT ledger.integrity_status() AS value').then(r=>r[0].value);
  await check('general ledger opening, movement, closing and running balances preserve 21-digit precision',async()=>{
    const g=await gl();assert.equal(g.opening_minor,huge);assert.equal(g.debit_minor,'10333');assert.equal(g.credit_minor,'0');assert.equal(g.closing_minor,(BigInt(huge)+10333n).toString());assert.equal(g.rows.at(-1).running_minor,g.closing_minor);assert.equal(g.company_wide,true);
  });
  await check('posted ledger reconciles with trial balance; drafts excluded',async()=>{
    await f.command('maker','excluded-draft','create',f.payload('50000'));
    const trial=(await f.query('maker',"SELECT ledger.trial_balance('2026-09-30') AS value"))[0].value;
    assert.equal((await gl()).closing_minor,trial.rows.find(r=>r.code==='1000').net_debit_minor);
  });
  await check('keyset pagination retains full opening and running balances without duplicate lines',async()=>{
    const all=await gl();let cursor=null,rows=[];
    do {const page=await gl('maker',f.accounts['1000'],1,cursor);rows.push(...page.rows);cursor=page.next_cursor;assert.equal(page.closing_minor,all.closing_minor);} while(cursor);
    assert.deepEqual(rows,all.rows);
  });
  await check('branch-limited reporting excludes other branches and declares partial scope',async()=>{
    const g=await gl('branch');assert.equal(g.company_wide,false);assert.equal(g.opening_minor,'0');assert.equal(g.closing_minor,'333');assert.equal(g.rows.length,1);
    await rejected(()=>integrity('branch'),'42501');
  });
  await check('unauthorized reports fail closed; audit check is not exposed to ordinary readers',async()=>{
    await rejected(()=>gl('no_read'),'42501');await rejected(()=>integrity('reader'),'42501');
    assert.equal((await gl('reader')).debit_minor,'10333');
    await rejected(()=>db.transaction(async tx=>{await tx.exec('SET LOCAL ROLE serk_api');await tx.query('SELECT ledger.integrity_status()');}),'42501');
  });
  await check('cross-tenant account identifiers do not disclose ledger data',async()=>{
    const other=await fixture(db,'other');await other.post('foreign');await rejected(()=>gl('maker',other.accounts['1000']),'P0002');
  });
  await check('used account financial classification cannot be changed',async()=>{
    for(const assignment of ["type='LIABILITY'","normal_balance='CREDIT'","code='1001'","reporting_category='LIABILITY'","control_account=true"])
      await rejected(()=>db.query('UPDATE ledger.accounts SET '+assignment+' WHERE id=$1',[f.accounts['1000']]),'55000');
  });
  await check('account identities cannot be moved to another company',async()=>{
    await rejected(()=>db.query('UPDATE ledger.accounts SET company_id=$1 WHERE id=$2',[f.otherCompany,f.accounts['1000']]),'55000');
  });
  await check('chart hierarchy rejects cycles, posting parents and invalid group conversion',async()=>{
    const a=randomUUID(),b=randomUUID();for(const [id,code] of [[a,'G1'],[b,'G2']])await db.query("INSERT INTO ledger.accounts(id,tenant_id,company_id,code,name,type,normal_balance,reporting_category,posting_allowed) VALUES($1,$2,$3,$4,$4,'ASSET','DEBIT','ASSET',false)",[id,f.tenant,f.company,code]);
    await db.query('UPDATE ledger.accounts SET parent_id=$1 WHERE id=$2',[a,b]);
    await rejected(()=>db.query('UPDATE ledger.accounts SET parent_id=$1 WHERE id=$2',[b,a]),'23514');
    await rejected(()=>db.query('UPDATE ledger.accounts SET posting_allowed=true WHERE id=$1',[a]),'23514');
    await rejected(()=>db.query('UPDATE ledger.accounts SET parent_id=$1 WHERE id=$2',[f.accounts['1000'],b]),'23514');
  });
  await check('used dimensions retain identity; deactivated dimension prevents posting',async()=>{
    const id=randomUUID();await db.query("INSERT INTO ledger.dimensions(id,tenant_id,company_id,kind,code,name) VALUES($1,$2,$3,'PROJECT','P1','Synthetic project')",[id,f.tenant,f.company]);
    const payload=f.payload('71');payload.lines[0].dimensions=[{kind:'PROJECT',dimension_id:id}];
    let j=await f.command('maker','dimension-create','create',payload);
    await rejected(()=>db.query("UPDATE ledger.dimensions SET code='P2' WHERE id=$1",[id]),'55000');
    for(const [action,user] of [['submit','maker'],['approve','checker']]) j=await f.command(user,'dimension-'+action,action,{id:j.id,expected_version:j.version,reason:'Reviewed dimension'});
    await db.query('UPDATE ledger.dimensions SET active=false WHERE id=$1',[id]);
    await rejected(()=>f.command('checker','dimension-post','post',{id:j.id,expected_version:j.version,reason:'Posting must fail'}),'23514');
    await db.query('UPDATE ledger.dimensions SET active=true WHERE id=$1',[id]);
    await f.command('checker','dimension-post','post',{id:j.id,expected_version:j.version,reason:'Posting must fail'});
  });
  await check('reversal flows through approval, reports and atomic outbox without erasing the original',async()=>{
    let j=await f.command('maker','reverse-original','reverse',{id:posted.id,expected_version:posted.version,accounting_date:'2026-09-15',reason:'Synthetic correction'});
    for(const [action,user] of [['submit','maker'],['approve','checker'],['post','checker']]) j=await f.command(user,'reversal-'+action,action,{id:j.id,expected_version:j.version,reason:'Independent reversal'});
    const g=await gl();assert.equal(g.credit_minor,'10000');assert.equal(g.debit_minor,'10404');assert.equal(g.rows.filter(r=>r.reversed_from===posted.id).length,1);
  });
  await check('duplicate command replay adds neither a journal nor audit/outbox effects',async()=>{
    const previous=await integrity();await f.command('maker','september-create','create',f.payload());assert.deepEqual(await integrity().then(({checked_at,...r})=>r),Object.fromEntries(Object.entries(previous).filter(([k])=>k!=='checked_at')));
  });
  await check('invalid and nullable pagination and date parameters are rejected at the database boundary',async()=>{
    for(const limit of [null,0,101])await rejected(()=>gl('maker',f.accounts['1000'],limit),'22023');
    await rejected(()=>gl('maker',f.accounts['1000'],1,{after_date:'2026-09-01'}),'22023');
    await rejected(()=>f.query('maker',"SELECT ledger.general_ledger($1,'infinity','infinity')",[f.accounts['1000']]),'22023');
    await rejected(()=>f.query('maker','SELECT ledger.list_journals(NULL)'),'22023');
    await rejected(()=>f.query('maker',"SELECT ledger.list_journals(10,NULL,NULL,'wrong')"),'22023');
  });
  await check('integrity checks reconcile every journal version, audit hash chain and matching outbox event',async()=>{
    const status=await integrity();assert.equal(status.ok,true,JSON.stringify(status));assert.equal(status.posted_journals,5);
  });
  await check('audit integrity verification tolerates database session timezone changes',async()=>{
    await db.exec("SET TIME ZONE 'Africa/Nairobi'");assert.equal((await integrity()).ok,true);await db.exec("SET TIME ZONE 'UTC'");
  });
  await check('integrity checks detect a corrupted outbox payload in an isolated rollback-only fault injection',async()=>{
    await db.exec('BEGIN;ALTER TABLE integration.outbox DISABLE TRIGGER immutable_outbox;');
    try {await db.query("UPDATE integration.outbox SET payload=payload||'{\"audit_hash\":\"wrong\"}'::jsonb WHERE id=(SELECT id FROM integration.outbox WHERE company_id=$1 LIMIT 1)",[f.company]);
      await db.exec('SET LOCAL ROLE serk_api');await db.query('SELECT security.bind($1,$2,$3)',[f.tokens.maker,f.company,f.csrf]);
      const r=(await db.query('SELECT ledger.integrity_status() AS value')).rows[0].value;assert.equal(r.ok,false);assert.equal(r.outbox_mismatches,1);
    } finally {await db.exec('ROLLBACK;');}
    assert.equal((await integrity()).ok,true);
  });
  await check('new functions expose only read operations and preserve function-only financial writes',async()=>{
    const rows=(await db.query("SELECT p.proname,has_function_privilege('serk_auth',p.oid,'EXECUTE') AS auth FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname='ledger' AND p.proname IN ('general_ledger','integrity_status')")).rows;
    assert.equal(rows.length,2);assert.ok(rows.every(r=>r.auth===false));
    assert.equal((await db.query("SELECT has_table_privilege('serk_api','ledger.lines','INSERT') AS allowed")).rows[0].allowed,false);
  });
  writeFileSync(out+'/upgrade-preservation.json',JSON.stringify({from:'0.2.0-rc2',to:'0.2.0-rc4',status:'PASS',sha256_before_and_after:before},null,2));
} catch(e) {console.error(e.code||e.name,e.message);process.exitCode=1;}
finally {
  if(db)await db.close();
  const report={started,finished:new Date().toISOString(),backend:'PGlite 0.5.8 / PostgreSQL 18.3 WASM',status:process.exitCode?'FAIL':'PASS',passed:results.filter(r=>r.status==='PASS').length,failed:results.filter(r=>r.status==='FAIL').length,results,limitations:'Sequential database verification, not native PostgreSQL concurrency or HTTP/browser verification.'};
  writeFileSync(out+'/controls.json',JSON.stringify(report,null,2));console.log(JSON.stringify({status:report.status,passed:report.passed,failed:report.failed}));
}
