// PGlite runs only in this verification/development harness, never the server image.
import {PGlite} from '@electric-sql/pglite';
import {PGLiteSocketServer} from '@electric-sql/pglite-socket';
import {spawn} from 'node:child_process';
import {mkdirSync,writeFileSync,readFileSync} from 'node:fs';
import {randomBytes} from 'node:crypto';
import {fixtureSecret,fixtureCode} from './totp.mjs';
import {closePGliteHarness} from './pglite-lifecycle.mjs';
import {assessGoEvidence,requireUnfilteredGoFlags} from './go-evidence.mjs';

const e2e=process.argv.includes('--e2e');
const native=process.argv.includes('--native');
if(native && (!process.env.TEST_DATABASE_URL || !process.env.TEST_API_DATABASE_URL || !process.env.TEST_AUTH_DATABASE_URL || process.env.SERK_TEST_ROLE_OVERRIDE==='1')) throw new Error('Native verification requires three database URLs and forbids test role override');
const resultDir=process.env.SERK_RESULTS_DIR || 'test-results';
const fixtureDir='.local/verification';
const started=new Date().toISOString();
const commands=[];
const serve=process.argv.includes('--serve')||e2e;
const db=native?null:await PGlite.create();
const port=55432;
const server=native?null:new PGLiteSocketServer({db,port,host:'127.0.0.1',maxConnections:30});
if(server)await server.start();
const dsn=native?process.env.TEST_DATABASE_URL:`postgres://postgres@127.0.0.1:${port}/postgres?sslmode=disable`;
const env={...process.env,MIGRATOR_DATABASE_URL:dsn,TEST_DATABASE_URL:dsn,DATABASE_URL:native?process.env.TEST_API_DATABASE_URL:dsn,AUTH_DATABASE_URL:native?process.env.TEST_AUTH_DATABASE_URL:dsn,
 SERK_ENV:'development',SERK_TEST_ROLE_OVERRIDE:native?'0':'1',SERK_ORIGIN:'http://localhost:8080',SERK_WEB_DIR:'web/dist',SERK_FIXTURE_FILE:fixtureDir+'/bootstrap.json'};
mkdirSync(resultDir,{recursive:true});
if(!serve)writeFileSync(resultDir+'/test-summary.json',JSON.stringify({status:'RUNNING',started,backend:native?'native-postgresql':'pglite'},null,2));
function run(cmd,args,file,input=''){return new Promise((resolve,reject)=>{
 const child=spawn(cmd,args,{env,stdio:['pipe','pipe','pipe']});child.stdin.end(input);let output='';
 for(const stream of [child.stdout,child.stderr])stream.on('data',d=>{output+=d;process.stdout.write(d)});
 child.on('error',reject);child.on('close',code=>{if(file)writeFileSync(resultDir+'/'+file,output);commands.push({command:[cmd,...args],exit_code:code});code===0?resolve(output):reject(new Error(`${cmd} exited ${code}`))});
})}
try{
 await run('go',['run','./cmd/migrate'],'migration.log');
 await run('go',['run','./cmd/migrate'],'migration-repeat.log');
 if(!serve){
  requireUnfilteredGoFlags(await run('go',['env','GOFLAGS']));
  const discovered=await run('go',['test','-json','-list','^(Test|Fuzz)','./...'],'go-test-discovery.jsonl');
  const output=await run('go',['test','-json','-race','-count=1','-covermode=atomic','-coverpkg=./internal/...','-coverprofile='+resultDir+'/coverage.out','./...'],'go-tests.jsonl');
  const summary={...assessGoEvidence(discovered,output,{native}),started,finished:new Date().toISOString()};
  writeFileSync(resultDir+'/test-summary.json',JSON.stringify(summary,null,2));
  if(summary.status!=='PASS')throw new Error('Incomplete or failed Go verification: '+summary.errors.join('; '));
  await run('go',['tool','cover','-func='+resultDir+'/coverage.out'],'coverage-summary.log');
  await run('go',['vet','./...'],'go-vet.log');
  await run('go',['build','./...'],'go-build.log');
 }else{
  // Synthetic, empty local workspace; passwords are generated and never built into the product.
  const pass=randomBytes(24).toString('base64url');
  env.SERK_MFA_KEY=randomBytes(32).toString('base64');
  const allPermissions=[
    'ledger.read','journal.create','journal.submit','journal.approve','journal.post','journal.reverse','journal.void',
    'period.close','audit.read','configuration.manage','user.manage','role.manage',
    'sales.read','sales.manage','purchases.read','purchases.manage','taxes.read','taxes.manage',
    'payroll.read','payroll.manage','inventory.read','inventory.manage'
  ];
  const financePermissions=[
    'ledger.read','journal.create','journal.submit','journal.approve','journal.post','journal.reverse','journal.void',
    'audit.read','period.close','sales.read','sales.manage','purchases.read','purchases.manage',
    'taxes.read','taxes.manage','payroll.read','payroll.manage','inventory.read','inventory.manage'
  ];
  const config={slug:'local',name:'SERK Finance local workspace',companies:[{code:'LOCAL',name:'Local company',currency:'ETB',country:'ET',branches:['HQ'],year_name:'FY2026',year_start:'2026-01-01',year_end:'2026-12-31',accounts:[
   {code:'1000',name:'Bank',type:'ASSET',normal_balance:'DEBIT'},
   {code:'3000',name:'Capital',type:'EQUITY',normal_balance:'CREDIT'},
   {code:'4000',name:'Revenue',type:'REVENUE',normal_balance:'CREDIT'},
   {code:'5000',name:'Operating expense',type:'EXPENSE',normal_balance:'DEBIT'},
   {code:'7999',name:'FX rounding',type:'OTHER_EXPENSE',normal_balance:'DEBIT'}]}],
   roles:[
     {name:'Super Admin',permissions:allPermissions},
     {name:'Finance',permissions:financePermissions}
   ],
   users:[
     {email:'accountant@local.test',name:'accountant',password:pass,grants:[{company:'LOCAL',role:'Finance'}]},
     {email:'approver@local.test',name:'approver',password:pass,grants:[{company:'LOCAL',role:'Finance'}]},
     {email:'admin@local.test',name:'Super Admin',password:pass,grants:[{company:'LOCAL',role:'Super Admin'}]}
   ]};
  mkdirSync(fixtureDir,{recursive:true,mode:0o700});writeFileSync(fixtureDir+'/bootstrap.json',JSON.stringify(config),{mode:0o600});
  writeFileSync(fixtureDir+'/sign-in.txt',`Workspace: local\nSuper Admin: admin@local.test\nApprover: approver@local.test\nAccountant: accountant@local.test\nPassword: ${pass}\n`,{mode:0o600});
  const ids=JSON.parse(await run('go',['run','./cmd/bootstrap','--file',fixtureDir+'/bootstrap.json'],'local-provisioning.log'));

  await run('go',['run','./cmd/configure'],'rounding-fixture.log',JSON.stringify({company_id:ids.companies.LOCAL,account_id:ids.accounts['LOCAL:7999'],max_difference_minor:2,reason:'Synthetic browser rounding policy'}));
  console.log('Sign-in details: .local/verification/sign-in.txt. Local data resets when stopped.');
  if(e2e){
   env.SERK_REQUIRE_MFA='true';env.SERK_MFA_KEY=randomBytes(32).toString('base64');
   for(const user of config.users){
    user.mfaSecret=fixtureSecret();
    await run('go',['run','./cmd/mfa'],undefined,JSON.stringify({tenant:config.slug,email:user.email,secret:user.mfaSecret,code:fixtureCode(user.mfaSecret,Date.now()-30000),reason:'Synthetic browser authenticator enrollment'}));
   }
   writeFileSync(fixtureDir+'/bootstrap.json',JSON.stringify(config),{mode:0o600});
   await run('go',['build','-o',fixtureDir+'/api','./cmd/api']);
   const child=spawn(fixtureDir+'/api',[],{env,stdio:['ignore','pipe','pipe']});let logs='';
   child.stdout.on('data',d=>{logs+=d;process.stdout.write(d)});child.stderr.on('data',d=>{logs+=d;process.stderr.write(d)});
   try{
    let ready=false;
    for(let i=0;i<40;i++){try{ready=(await fetch('http://127.0.0.1:8080/health/ready',{signal:AbortSignal.timeout(500)})).ok}catch{}if(ready||child.exitCode!==null)break;await new Promise(r=>setTimeout(r,250))}
    if(!ready)throw new Error('API did not become ready: '+logs);
    await run('node',['tests/e2e.mjs'],'browser-tests.log');
   }finally{if(child.exitCode===null){const exit=new Promise(r=>child.once('exit',r));child.kill('SIGTERM');await exit}writeFileSync(resultDir+'/e2e-api.log',logs)}
  }else await run('go',['run','./cmd/api']);
 }
}catch(e){
 console.error(e.message);process.exitCode=1;
 if(!serve){
  const summary=JSON.parse(readFileSync(resultDir+'/test-summary.json','utf8'));
  writeFileSync(resultDir+'/test-summary.json',JSON.stringify({...summary,status:'FAIL',error:e.message,finished:new Date().toISOString()},null,2));
 }
}finally{
 let teardown=native?'NOT_APPLICABLE':'PASS',teardown_error;
 try{if(server)await closePGliteHarness(server,db)}
 catch(e){console.error(e);process.exitCode=1;teardown='FAIL';teardown_error=e.message}
 writeFileSync(resultDir+(e2e?'/browser-run.json':'/verification-run.json'),JSON.stringify({started,finished:new Date().toISOString(),backend:native?'native-postgresql':'pglite',status:process.exitCode?'FAIL':'PASS',teardown,teardown_error,commands},null,2));
}
