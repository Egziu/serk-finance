// Isolated regression process: an unhandled shutdown error must fail the process.
import assert from 'node:assert/strict';
import {createConnection, Server} from 'node:net';
import {once} from 'node:events';
import {PGlite} from '@electric-sql/pglite';
import {PGLiteSocketServer} from '@electric-sql/pglite-socket';
import {closePGliteHarness} from './pglite-lifecycle.mjs';

const mode=process.argv[2] || 'queued-close';
assert.ok(['queued-close','transaction-close','server-close'].includes(mode));
const unsafe=process.argv.includes('--unsafe-baseline');
const db=await PGlite.create();
const originalClose=db.close.bind(db);
db.close=async()=>{
  if(mode==='transaction-close'){
    assert.equal(db.isInTransaction(),false,'Disconnect must finish rollback before database close');
    const {rows}=await db.query("SELECT to_regclass('shutdown_uncommitted') AS relation");
    assert.equal(rows[0].relation,null,'Uncommitted DDL must be rolled back');
  }
  return originalClose();
};
const server=new PGLiteSocketServer({db,port:0,host:'127.0.0.1'});
await server.start();
// Test-only access to the pinned 0.2.11 implementation exposes the real native
// close event, before its deferred handler callback runs. No dependency is patched.
assert.ok(server.server instanceof Server,'Pinned socket implementation changed; review this regression');
const accepted=once(server.server,'connection');
const attached=new Promise(resolve=>server.addEventListener('connection',resolve,{once:true}));
const address=server.server.address();
const client=createConnection({port:address.port,host:'127.0.0.1'});
client.on('error',error=>{throw error;});
const [peer]=await accepted;
await attached;
let buffer=Buffer.alloc(0),readyResolve;
client.on('data',data=>{
  buffer=Buffer.concat([buffer,data]);
  while(buffer.length>=5){
    const length=buffer.readInt32BE(1);
    if(buffer.length<length+1)return;
    const type=String.fromCharCode(buffer[0]),body=buffer.subarray(5,length+1);
    buffer=buffer.subarray(length+1);
    if(type==='E')throw Error('Protocol error: '+body.toString());
    if(type==='Z'){assert.ok(readyResolve,'Unexpected ReadyForQuery');const resolve=readyResolve;readyResolve=undefined;resolve(body.toString());}
  }
});
function ready(){return new Promise(resolve=>{assert.equal(readyResolve,undefined);readyResolve=resolve;});}
const startupBody=Buffer.from('user\0postgres\0database\0postgres\0\0');
const startup=Buffer.alloc(8+startupBody.length);startup.writeInt32BE(startup.length);startup.writeInt32BE(196608,4);startupBody.copy(startup,8);
let response=ready();client.write(startup);assert.equal(await response,'I');
if(mode==='transaction-close'){
  const sql=Buffer.from('BEGIN; CREATE TABLE shutdown_uncommitted(id int);\0');
  const query=Buffer.alloc(5+sql.length);query[0]=81;query.writeInt32BE(sql.length+4,1);sql.copy(query,5);
  response=ready();client.write(query);assert.equal(await response,'T');
  assert.equal(db.isInTransaction(),true);
}
const clientClosed=once(client,'close');
if(mode!=='server-close'){
  // The library's close listener queues setImmediate first. Resume teardown in
  // this close event's microtask, deliberately before that callback executes.
  const peerClosed=once(peer,'close');
  client.end();await peerClosed;
}
if(unsafe){await server.stop();await db.close();}
else await closePGliteHarness(server,db);
await clientClosed;
console.log('PASS: '+mode+' teardown completed');
