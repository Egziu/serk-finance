import {spawn} from 'node:child_process';
import {mkdirSync,writeFileSync,openSync,closeSync,readFileSync} from 'node:fs';

const out=(process.env.SERK_RESULTS_DIR || 'test-results')+'/pglite-shutdown';
mkdirSync(out,{recursive:true});
const started=new Date().toISOString(),cases=[];
function run(mode,unsafe=false){return new Promise((resolve,reject)=>{
  const args=['tests/pglite-shutdown-case.mjs',mode,...(unsafe?['--unsafe-baseline']:[])];
  // The expected fatal error prints a large minified source line. Use a regular
  // file so Node cannot lose the trailing stack while exiting with pipe writes
  // outstanding; do not weaken the exact error assertion to accept any exit 1.
  const log=out+'/'+String(cases.length+1).padStart(2,'0')+'-'+mode+(unsafe?'-baseline':'')+'.log';
  const fd=openSync(log,'w');
  const child=spawn(process.execPath,args,{stdio:['ignore',fd,fd]});
  let timedOut=false;
  const timer=setTimeout(()=>{timedOut=true;child.kill('SIGKILL')},20000);
  child.on('error',error=>{clearTimeout(timer);reject(error)});
  child.on('close',(code,signal)=>{
    clearTimeout(timer);
    closeSync(fd);
    const output=readFileSync(log,'utf8');
    const reproduced=code===1 && output.includes("Cannot read properties of undefined (reading '_IsTransactionBlock')");
    const passed=!timedOut && (unsafe?reproduced:code===0 && output.includes('PASS: '+mode+' teardown completed'));
    const result={command:[process.execPath,...args],expected:unsafe?'known baseline crash':'clean teardown',exit_code:code,signal,timed_out:timedOut,status:passed?'PASS':'FAIL'};
    cases.push(result);console.log(result.status+': '+(unsafe?'baseline crash reproduced':mode+' teardown'));resolve(result);
  });
})}
try{
  await run('queued-close',true);
  for(let round=0;round<3;round++)for(const mode of ['queued-close','transaction-close','server-close'])await run(mode);
}catch(error){cases.push({status:'FAIL',error:error.message});console.error(error)}
const report={started,finished:new Date().toISOString(),status:cases.length===10 && cases.every(result=>result.status==='PASS')?'PASS':'FAIL',cases};
writeFileSync(out+'/shutdown-result.json',JSON.stringify(report,null,2));
console.log(JSON.stringify({status:report.status,baseline_reproductions:cases[0]?.status==='PASS'?1:0,clean_shutdowns:cases.slice(1).filter(result=>result.status==='PASS').length}));
if(report.status!=='PASS')process.exitCode=1;
