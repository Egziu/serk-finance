import assert from 'node:assert/strict';
import {database,fixture} from './rc3-fixture.mjs';
const db=await database(7);
try {
  const f=await fixture(db,'rc2');await f.post('baseline');
  await db.query("UPDATE ledger.accounts SET type='LIABILITY',normal_balance='CREDIT',reporting_category='LIABILITY' WHERE id=$1",[f.accounts['1000']]);
  const trial=(await f.query('maker',"SELECT ledger.trial_balance('2026-09-30') AS value"))[0].value;
  assert.equal(trial.rows.find(r=>r.code==='1000').type,'LIABILITY');
  console.log('REPRODUCED rc2: an operator can reclassify a used ASSET account as LIABILITY, changing historical report classification.');
  await db.query('UPDATE ledger.accounts SET parent_id=$1 WHERE id=$2',[f.accounts['4000'],f.accounts['1000']]);
  await db.query('UPDATE ledger.accounts SET parent_id=$1 WHERE id=$2',[f.accounts['1000'],f.accounts['4000']]);
  console.log('REPRODUCED rc2: a two-account parent cycle is accepted by the database.');
  const count=(await db.query("SELECT count(*)::int n FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname='ledger' AND p.proname IN ('general_ledger','integrity_status')")).rows[0].n;
  assert.equal(count,0);
  console.log('CONFIRMED rc2: no general-ledger drill-down or ledger integrity-status function.');
  console.log('PASS: baseline findings reproduced against unchanged migrations 001-007.');
} finally {await db.close();}
