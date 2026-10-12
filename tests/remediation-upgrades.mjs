import assert from 'node:assert/strict';
import {readFileSync,readdirSync,mkdirSync,writeFileSync} from 'node:fs';
import {database,fixture,sha} from './rc3-fixture.mjs';
const out=process.env.SERK_RESULTS_DIR||'test-results/remediation';mkdirSync(out,{recursive:true});const results=[];
for(const through of [4,5,7,9,10,36]){
 let db;try{
  db=await database(through);const f=await fixture(db,'upgrade-'+through);await f.post('upgrade-'+through,f.payload('123456789012345678901'));
  const snapshot=async()=>{const o={};for(const t of ['ledger.journals','ledger.lines','ledger.idempotency','audit.events','audit.heads','integration.outbox'])o[t]=sha(JSON.stringify((await db.query(`SELECT to_jsonb(t)-'is_rounding' AS row FROM ${t} t ORDER BY (to_jsonb(t)-'is_rounding')::text`)).rows));return o;};
  const before=await snapshot();for(const n of readdirSync('migrations').filter(x=>/^\d+.*\.sql$/.test(x)).sort()){if(Number(n.slice(0,3))<=through)continue;await db.exec('BEGIN;'+readFileSync('migrations/'+n,'utf8')+';RESET ROLE;COMMIT;');}
  assert.deepEqual(await snapshot(),before);assert.equal((await db.query('SELECT security.release_version() AS v')).rows[0].v,'0.2.1-rc1');
  results.push({baseline_through:through,status:'PASS',financial_hashes:before});console.log('PASS populated SQL upgrade through',through);
 }catch(e){results.push({baseline_through:through,status:'FAIL',error:e.message,code:e.code});console.error('FAIL',through,e.code,e.message);process.exitCode=1;}finally{if(db)await db.close();}
}
writeFileSync(out+'/upgrades.json',JSON.stringify({status:process.exitCode?'FAIL':'PASS',results,scope:'Sequential SQL-only upgrade preservation of financial/audit/outbox records; excludes Go migrator execution, checksums, native locks, and backup restoration.'},null,2));
