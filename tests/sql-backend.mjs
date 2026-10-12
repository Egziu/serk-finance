// SQL test backend: PGlite by default, or a fresh database on a native PostgreSQL server when
// SERK_SQL_BACKEND=native (operator URL in TEST_DATABASE_URL). Both expose the small subset of
// the PGlite API the fixtures use: query(sql,args) -> {rows}, exec(sql), transaction(fn), close().
import {readFileSync,readdirSync} from 'node:fs';
import {randomBytes} from 'node:crypto';

function migrationsThrough(through) {
  return readdirSync('migrations').filter(n=>/^\d+.*\.sql$/.test(n)).sort().filter(n=>Number(n.slice(0,3))<=through);
}

export async function openDatabase(through=999) {
  if (process.env.SERK_SQL_BACKEND !== 'native') {
    const {PGlite}=await import('@electric-sql/pglite');
    const db=await PGlite.create();
    for (const name of migrationsThrough(through)) await db.exec('BEGIN;'+readFileSync('migrations/'+name,'utf8')+';RESET ROLE;COMMIT;');
    return db;
  }
  const pg=(await import('pg')).default;
  const operator=process.env.TEST_DATABASE_URL;
  if (!operator) throw new Error('SERK_SQL_BACKEND=native requires TEST_DATABASE_URL (a disposable server)');
  const name='serk_sqltest_'+randomBytes(6).toString('hex');
  const admin=new pg.Client({connectionString:operator});await admin.connect();
  await admin.query(`CREATE DATABASE ${name}`);await admin.end();
  const url=new URL(operator);url.pathname='/'+name;
  const pool=new pg.Pool({connectionString:url.toString(),max:4});
  for (const file of migrationsThrough(through)) await pool.query('BEGIN;'+readFileSync('migrations/'+file,'utf8')+';RESET ROLE;COMMIT;');
  const wrap=client=>({
    query:async(sql,args=[])=>{const r=await client.query(sql,args);return {rows:r.rows};},
    exec:async sql=>{await client.query(sql);},
  });
  return {
    ...wrap(pool),
    native:true,
    transaction:async fn=>{
      const c=await pool.connect();
      try{await c.query('BEGIN');const r=await fn(wrap(c));await c.query('COMMIT');return r;}
      catch(e){await c.query('ROLLBACK').catch(()=>{});throw e;}
      finally{c.release();}
    },
    close:async()=>{
      await pool.end();
      const a=new pg.Client({connectionString:operator});await a.connect();
      await a.query(`DROP DATABASE IF EXISTS ${name} WITH (FORCE)`);await a.end();
    },
  };
}
