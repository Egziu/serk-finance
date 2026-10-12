#!/usr/bin/env python3
"""Create and remove ONLY script-owned disposable PostgreSQL/API containers.
Runs native controls, browser workflow, backup/restore comparison and image smoke.
Requires Go, Node, installed npm dependencies, Playwright Chromium, and Docker.
"""
import datetime,hashlib,json,os,pathlib,secrets,subprocess,sys,time,urllib.request
root=pathlib.Path(__file__).resolve().parents[1]
os.chdir(root)
result=pathlib.Path(os.environ.get('SERK_RESULTS_DIR',str(root/'test-results'))).resolve()/'native';result.mkdir(parents=True,exist_ok=True)
local=root/'.local';local.mkdir(exist_ok=True,mode=0o700)
nonce=secrets.token_hex(6);container='serk-native-'+nonce;api_container=container+'-api'
dump_path=local/(nonce+'.dump')
env=os.environ.copy()
env.update(SERK_ENV='development',SERK_TEST_ROLE_OVERRIDE='0',SERK_RESULTS_DIR=str(result),
 POSTGRES_PASSWORD=secrets.token_urlsafe(32),SERK_API_PASSWORD=secrets.token_urlsafe(32),SERK_AUTH_PASSWORD=secrets.token_urlsafe(32))
steps=[];started=datetime.datetime.now(datetime.timezone.utc).isoformat()
class NativeBlocked(RuntimeError):pass
def command(args,*,data=None,log=None,timeout=300):
 r=subprocess.run(args,input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=timeout)
 if log:
  text=(r.stdout+r.stderr).decode(errors='replace')
  for key in ['POSTGRES_PASSWORD','SERK_API_PASSWORD','SERK_AUTH_PASSWORD']:
   text=text.replace(env[key],'[REDACTED]')
  (result/log).write_text(text)
 if r.returncode: raise RuntimeError(f'{args[0]} {args[1]} failed (exit {r.returncode}); see recorded log')
 return r.stdout

def sql(database,query):
 return command(['docker','exec','-i',container,'psql','-X','-v','ON_ERROR_STOP=1','-At','-U','postgres','-d',database],data=query.encode())

def snapshot(database):
 tables=sql(database,"SELECT schemaname||'.'||tablename FROM pg_tables WHERE schemaname IN ('security','organization','ledger','audit','integration') OR (schemaname='public' AND tablename='serk_migrations') ORDER BY 1").decode().splitlines()
 out={}
 for table in tables:
  # Identifiers originate in this isolated database's catalog, never in a user request.
  identifier='.'.join('"'+part.replace('"','""')+'"' for part in table.split('.'))
  data=sql(database,"SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb)::text FROM "+identifier+' t')
  out[table]=hashlib.sha256(data).hexdigest()
 return out

def stage(name,fn):
 start=time.monotonic()
 try: value=fn()
 except Exception as error:
  steps.append({'name':name,'status':'BLOCKED' if isinstance(error,NativeBlocked) else 'FAIL','seconds':round(time.monotonic()-start,3)});raise
 steps.append({'name':name,'status':'PASS','seconds':round(time.monotonic()-start,3)})
 print('PASS',name,flush=True);return value

try:
 def preflight():
  proc=subprocess.run([sys.executable,'scripts/native-preflight.py','--engine','docker'],env=env,capture_output=True,text=True,timeout=30)
  (result/'preflight.log').write_text(proc.stdout+proc.stderr)
  if proc.returncode==2:raise NativeBlocked('Native host preflight blocked; no database tests ran')
  if proc.returncode:raise RuntimeError('Native host preflight failed')
 stage('native_host_preflight',preflight)
 stage('docker_available',lambda:command(['docker','info'],log='docker-info.log'))
 stage('start_postgresql',lambda:command(['docker','run','--detach','--name',container,
  '-p','127.0.0.1::5432','-p','127.0.0.1::8080','-e','POSTGRES_DB=serk','-e','POSTGRES_PASSWORD','postgres:17.11-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652'],log='start-db.log'))
 deadline=time.monotonic()+60
 while True:
  probe=subprocess.run(['docker','exec',container,'pg_isready','-U','postgres','-d','serk'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  if probe.returncode==0:break
  if time.monotonic()>deadline:raise RuntimeError('PostgreSQL readiness timed out')
  time.sleep(.5)
 port=command(['docker','port',container,'5432/tcp']).decode().strip().rsplit(':',1)[1]
 env['TEST_DATABASE_URL']=env['MIGRATOR_DATABASE_URL']=f"postgres://postgres:{env['POSTGRES_PASSWORD']}@127.0.0.1:{port}/serk?sslmode=disable"
 env['TEST_API_DATABASE_URL']=f"postgres://serk_api_login:{env['SERK_API_PASSWORD']}@127.0.0.1:{port}/serk?sslmode=disable"
 env['TEST_AUTH_DATABASE_URL']=f"postgres://serk_auth_login:{env['SERK_AUTH_PASSWORD']}@127.0.0.1:{port}/serk?sslmode=disable"
 stage('migration',lambda:command(['go','run','./cmd/migrate'],log='initial-migration.log'))
 stage('runtime_roles',lambda:command(['docker','exec','-i','-e','SERK_API_PASSWORD','-e','SERK_AUTH_PASSWORD',container,'psql','-X','-v','ON_ERROR_STOP=1','-U','postgres','-d','serk'],data=(root/'scripts/runtime-roles.psql').read_bytes(),log='runtime-roles.log'))
 stage('native_controls_no_skips',lambda:command(['node','tests/verify.mjs','--native'],log='native-control-run.log',timeout=600))
 stage('native_browser',lambda:command(['node','tests/verify.mjs','--native','--e2e'],log='native-browser-run.log',timeout=300))
 before=snapshot('serk')
 def dump():
  data=command(['docker','exec',container,'pg_dump','-Fc','-U','postgres','serk'])
  fd=os.open(dump_path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
  with os.fdopen(fd,'wb')as f:f.write(data)
 stage('backup',dump)
 stage('create_isolated_restore_target',lambda:sql('postgres','CREATE DATABASE serk_restore'))
 stage('restore',lambda:command(['docker','exec','-i',container,'pg_restore','--exit-on-error','-U','postgres','-d','serk_restore'],data=dump_path.read_bytes(),log='restore.log'))
 def compare():
  after=snapshot('serk_restore')
  if before!=after:raise RuntimeError('Restored tables differ')
  (result/'restore-fingerprints.json').write_text(json.dumps({'tables':len(before),'source':before,'restored':after},indent=2))
 stage('exact_restored_data_comparison',compare)
 # Fresh fixture against restored ACLs/RLS proves access boundaries survived restore.
 for key in ['TEST_DATABASE_URL','TEST_API_DATABASE_URL','TEST_AUTH_DATABASE_URL']:
  env[key]=env[key].replace('/serk?','/serk_restore?')
 stage('restored_access_controls',lambda:command(['go','test','-race','-count=1','-v','./tests','-run','^TestIsolationAndHTTP$'],log='restore-access-tests.log'))
 stage('runtime_image_build',lambda:command(['docker','build','--target','runtime','-t','serk-finance:verification','.'],log='image-build.log',timeout=900))
 env.update(DATABASE_URL=f"postgres://serk_api_login:{env['SERK_API_PASSWORD']}@127.0.0.1:5432/serk?sslmode=disable",
 AUTH_DATABASE_URL=f"postgres://serk_auth_login:{env['SERK_AUTH_PASSWORD']}@127.0.0.1:5432/serk?sslmode=disable",
 SERK_ORIGIN='http://localhost:8080')
 stage('runtime_image_start',lambda:command(['docker','run','-d','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges:true',
 '--name',api_container,'--network','container:'+container,'-e','SERK_ENV','-e','SERK_ORIGIN','-e','DATABASE_URL','-e','AUTH_DATABASE_URL','serk-finance:verification'],log='image-start.log'))
 api_port=command(['docker','port',container,'8080/tcp']).decode().strip().rsplit(':',1)[1]
 def smoke():
  deadline=time.monotonic()+30
  while True:
   try:
    command([sys.executable,'scripts/healthcheck.py','http://127.0.0.1:'+api_port],log='image-smoke.log',timeout=20)
    return
   except RuntimeError:
    if time.monotonic()>deadline:raise
    time.sleep(.5)
 stage('runtime_image_smoke',smoke)
 status='PASS'
except Exception as e:
 status='BLOCKED' if isinstance(e,NativeBlocked) else 'FAIL';print(type(e).__name__+': '+str(e),file=sys.stderr)
finally:
 for name in [api_container,container]:
  try: subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
  except (OSError,subprocess.TimeoutExpired):pass
 dump_path.unlink(missing_ok=True)
 (result/'native-release-gate.json').write_text(json.dumps({'started':started,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':status,'tests_run':any(step['name']=='native_controls_no_skips' for step in steps),'steps':steps,'limits':'One disposable local PostgreSQL instance. Not a production failover, PITR, load, or penetration-test certification.'},indent=2))
 if status!='PASS':sys.exit(2 if status=='BLOCKED' else 1)
