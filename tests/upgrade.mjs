import {PGlite} from '@electric-sql/pglite';
import {PGLiteSocketServer} from '@electric-sql/pglite-socket';
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {createHash,randomBytes} from 'node:crypto';
import {closePGliteHarness} from './pglite-lifecycle.mjs';
const fromRC1=process.argv.includes('--from-rc1');
const fromRC2=process.argv.includes('--from-rc2');
const fromRC3=process.argv.includes('--from-rc3');
if([fromRC1,fromRC2,fromRC3].filter(Boolean).length>1)throw Error('Select exactly one source version');
const resultRoot=process.env.SERK_RESULTS_DIR||'test-results';
const out=resultRoot+(fromRC3?'/upgrade-rc3':fromRC2?'/upgrade-rc2':fromRC1?'/upgrade-rc1':'/upgrade');mkdirSync(out,{recursive:true});
const started=new Date().toISOString();
let result={status:'RUNNING',started};
writeFileSync(out+'/upgrade-result.json',JSON.stringify(result,null,2));
const db=await PGlite.create();const server=new PGLiteSocketServer({db,port:55434,host:'127.0.0.1'});
await server.start();
const env={...process.env,SERK_ENV:'development',MIGRATOR_DATABASE_URL:'postgres://postgres@127.0.0.1:55434/postgres?sslmode=disable'};
// Child processes must be asynchronous: PGlite's socket runs on this event loop.
const {spawn}=await import('node:child_process');
function run(args,input=''){return new Promise((resolve,reject)=>{const p=spawn('go',args,{env,stdio:['pipe','pipe','pipe']});let stdout='',stderr='';p.stdout.on('data',d=>stdout+=d);p.stderr.on('data',d=>stderr+=d);p.on('error',reject);p.on('close',code=>resolve({code,stdout,stderr}));p.stdin.end(input)})}
const sha=s=>createHash('sha256').update(s).digest('hex');
try {
 await db.exec('CREATE TABLE public.serk_migrations(name text PRIMARY KEY,sha256 text NOT NULL,applied_at timestamptz NOT NULL DEFAULT now())');
 for(const name of ['001_foundation.sql','002_ledger.sql','003_commands.sql',...((fromRC1||fromRC2||fromRC3)?['004_release_controls.sql','005_financial_race_guards.sql']:[]),...((fromRC2||fromRC3)?['006_review_controls.sql','007_mfa.sql']:[]),...(fromRC3?['008_master_data_integrity.sql','009_connected_reporting.sql']:[])]) {
  const source=readFileSync('migrations/'+name,'utf8');await db.exec('BEGIN;'+source+';RESET ROLE;COMMIT;');
  await db.query('INSERT INTO public.serk_migrations(name,sha256)VALUES($1,$2)',[name,sha(source)]);
 }
 const pass=randomBytes(24).toString('base64url');
 const cfg={slug:'upgrade',name:'Upgrade acceptance',companies:[{code:'TEST',name:'Upgrade fixture',currency:'ETB',country:'ET',branches:['HQ'],year_name:'2026',year_start:'2026-01-01',year_end:'2026-12-31',accounts:[{code:'1000',name:'Cash',type:'ASSET',normal_balance:'DEBIT'},{code:'3000',name:'Capital',type:'EQUITY',normal_balance:'CREDIT'}]}],roles:[{name:'Finance',permissions:['ledger.read','journal.create','journal.submit','journal.approve','journal.post']}],users:['maker','checker'].map(name=>({email:name+'@upgrade.test',name,password:pass,grants:[{company:'TEST',role:'Finance'}]}))};
 const boot=await run(['run','./cmd/bootstrap','--file','-'],JSON.stringify(cfg));if(boot.code!==0)throw Error('Bootstrap failed: '+boot.stderr);
 const ids=JSON.parse(boot.stdout);const cid=ids.companies.TEST;
 const tokens={maker:randomBytes(32).toString('base64url'),checker:randomBytes(32).toString('base64url')};
 const csrf=randomBytes(32).toString('base64url');
 for(const name of ['maker','checker'])await db.query('SELECT security.issue_session($1::uuid,$2,$3)',[ids.users[name+'@upgrade.test'],sha(tokens[name]),csrf]);
 async function cmd(user,key,action,payload){return db.transaction(async tx=>{
  await tx.query('SELECT security.bind($1,$2::uuid,$3)',[tokens[user],cid,csrf]);await tx.exec('SET LOCAL ROLE serk_api');
  return (await tx.query('SELECT ledger.command($1,$2,$3::jsonb) AS journal',[key,action,JSON.stringify(payload)])).rows[0].journal;
 })}
 let j=await cmd('maker','upgrade-create','create',{branch_id:ids.branches['TEST:HQ'],accounting_date:'2026-09-01',description:'Upgrade continuity evidence',currency:'ETB',fx_rate:'1',reason:'Synthetic fixture',lines:[{account_id:ids.accounts['TEST:1000'],debit_minor:'12345678901234567890',credit_minor:'0'},{account_id:ids.accounts['TEST:3000'],debit_minor:'0',credit_minor:'12345678901234567890'}]});
 for(const [action,user]of [['submit','maker'],['approve','checker'],['post','checker']])j=await cmd(user,'upgrade-'+action,action,{id:j.id,expected_version:j.version,reason:'Approved upgrade fixture'});
 async function snapshot(){const value={};for(const table of ['ledger.journals','ledger.lines','ledger.idempotency','audit.events','audit.heads','integration.outbox'])value[table]=sha(JSON.stringify((await db.query("SELECT to_jsonb(t)-'is_rounding' AS preserved FROM "+table+" t ORDER BY (to_jsonb(t)-'is_rounding')::text")).rows));return value}
 const before=await snapshot();
 const upgrade=await run(['run','./cmd/migrate']);writeFileSync(out+'/upgrade.log',upgrade.stdout+upgrade.stderr);if(upgrade.code!==0)throw Error('Upgrade failed');
 const after=await snapshot();
 const active=(await db.query('SELECT count(*) AS n FROM security.sessions WHERE revoked_at IS NULL')).rows[0].n;
 if(fromRC2||fromRC3) {if(Number(active)!==2)throw Error('MFA-era sessions unexpectedly changed');}
 else if(Number(active)!==0)throw Error('Pre-MFA sessions survived upgrade');
 if(JSON.stringify(before)!==JSON.stringify(after))throw Error('Upgrade changed existing financial records');
 const replay=await run(['run','./cmd/migrate']);if(replay.code!==0)throw Error('Migration repeat failed');
 await db.query("UPDATE public.serk_migrations SET sha256='changed' WHERE name='001_foundation.sql'");
 const drift=await run(['run','./cmd/migrate']);if(drift.code===0||!(drift.stderr.includes('checksum mismatch')))throw Error('Checksum drift not rejected');
 result={status:'PASS',backend:'pglite',started,at:new Date().toISOString(),from:fromRC3?'0.2.0-rc3':fromRC2?'0.2.0-rc2':fromRC1?'0.2.0-rc1':'0.1.0',to:'0.3.0-rc1',session_check:(fromRC2||fromRC3)?'MFA-era sessions preserved':'pre-MFA sessions revoked',posted_journal_preserved:true,exact_table_hashes:before,migration_replay:'PASS',checksum_drift:'REJECTED',limits:'Does not establish native PostgreSQL lock behavior or backup recovery.'};
}catch(e){console.error(e);process.exitCode=1;result={...result,status:'FAIL',error:e.message}}
finally{
 try{await closePGliteHarness(server,db);result.teardown='PASS'}
 catch(e){console.error(e);process.exitCode=1;result={...result,status:'FAIL',teardown:'FAIL',teardown_error:e.message}}
 result.finished=new Date().toISOString();
 writeFileSync(out+'/upgrade-result.json',JSON.stringify(result,null,2));
}
if(!process.exitCode)console.log('PASS: populated supported-version upgrade preserves posted amounts, receipts, audit and outbox; repeat verified; checksum drift rejected; teardown completed.');
