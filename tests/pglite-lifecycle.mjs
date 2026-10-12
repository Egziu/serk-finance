import {setImmediate as nextCheckPhase} from 'node:timers/promises';

// Verification only. The pinned pglite-socket 0.2.11 queues socket close/data
// handlers with setImmediate; stop() waits for TCP closure, not those callbacks.
// Callers must stop/await their client processes before invoking this helper.
export async function closePGliteHarness(server,db){
  await server.stop();
  // Let deferred disconnect handlers start while their database is still alive.
  await nextCheckPhase();
  // Wait for queries/rollback initiated by those handlers to leave PGlite's
  // exclusive execution queue, then finish their promise/Immediate continuations.
  await db.runExclusive(async()=>{});
  await nextCheckPhase();
  const stats=server.getStats();
  if(stats.activeConnections!==0 || stats.queuedQueries!==0 || db.isInTransaction()){
    throw new Error('PGlite shutdown did not drain connections, queries and transactions');
  }
  await db.close();
}
