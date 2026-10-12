#!/usr/bin/env python3
"""Run native PostgreSQL controls in a new script-owned loopback-only cluster.
Requires PG_BIN (initdb, pg_ctl, postgres), Go, Node and installed dependencies.
Does not replace Docker/image/backup/production deployment acceptance gates.
"""
import datetime,json,os,pathlib,pwd,secrets,socket,subprocess,sys,tempfile,time
root=pathlib.Path(__file__).resolve().parents[1];os.chdir(root)
pg=pathlib.Path(os.environ['PG_BIN']).resolve()
out=pathlib.Path(os.environ.get('SERK_RESULTS_DIR',str(root/'test-results/rc3/native-local'))).resolve();out.mkdir(parents=True,exist_ok=True)
for name in ('initdb','pg_ctl','postgres'):
 if not (pg/name).is_file():raise SystemExit('PG_BIN lacks '+name)
preflight=subprocess.run([sys.executable,'scripts/native-preflight.py','--engine','local','--pg-bin',str(pg)],env={**os.environ,'SERK_RESULTS_DIR':str(out)},capture_output=True,text=True,timeout=30)
(out/'preflight.log').write_text(preflight.stdout+preflight.stderr)
if preflight.returncode:
 (out/'native-local.json').write_text(json.dumps({'status':'BLOCKED' if preflight.returncode==2 else 'FAIL','stage':'host_preflight','tests_run':False,'error':'Native host preflight did not pass; see preflight.log'},indent=2)+'\n')
 print(preflight.stdout+preflight.stderr,end='');sys.exit(preflight.returncode)
env=os.environ.copy();env.update(SERK_ENV='development',SERK_TEST_ROLE_OVERRIDE='0',SERK_DISPOSABLE_TEST_CLUSTER='1',SERK_RESULTS_DIR=str(out))
passwords={key:secrets.token_urlsafe(32) for key in ['POSTGRES_PASSWORD','SERK_API_PASSWORD','SERK_AUTH_PASSWORD']};env.update(passwords)
env['LD_LIBRARY_PATH']=str(pg.parent/'lib')+(':'+env['LD_LIBRARY_PATH'] if env.get('LD_LIBRARY_PATH') else '')
work=pathlib.Path(tempfile.mkdtemp(prefix='serk-native-local-'));data=work/'data';pw=work/'bootstrap-password'
pw.write_text(passwords['POSTGRES_PASSWORD']);pw.chmod(0o600)
prefix=[]
if os.geteuid()==0:
 try:
  nobody=pwd.getpwnam('nobody');os.chown(work,nobody.pw_uid,nobody.pw_gid);os.chown(pw,nobody.pw_uid,nobody.pw_gid)
 except (OSError,KeyError) as e:
  pw.unlink(missing_ok=True)
  detail='Cannot prepare an unprivileged PostgreSQL process: '+str(e)
  (out/'native-local.json').write_text(json.dumps({'status':'BLOCKED','stage':'unprivileged_cluster_setup','error':detail,'tests_run':False},indent=2)+'\n')
  raise SystemExit(detail+'; use a normal non-root test host. No database tests ran.')
 prefix=['runuser','-u','nobody','--']
with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
dsn=lambda role,password:f'postgres://{role}:{password}@127.0.0.1:{port}/postgres?sslmode=disable'
env['MIGRATOR_DATABASE_URL']=env['TEST_DATABASE_URL']=dsn('postgres',passwords['POSTGRES_PASSWORD'])
env['TEST_API_DATABASE_URL']=dsn('serk_api_login',passwords['SERK_API_PASSWORD']);env['TEST_AUTH_DATABASE_URL']=dsn('serk_auth_login',passwords['SERK_AUTH_PASSWORD'])
steps=[];started=False;status='FAIL'
def run(name,args,timeout=300):
 begin=time.monotonic();p=subprocess.run(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 text=p.stdout.decode(errors='replace')
 for secret in passwords.values():text=text.replace(secret,'[REDACTED]')
 (out/(name+'.log')).write_text(text)
 steps.append({'name':name,'command':args,'exit_code':p.returncode,'seconds':round(time.monotonic()-begin,3)})
 print(('PASS' if p.returncode==0 else 'FAIL')+' '+name,flush=True)
 if p.returncode:raise RuntimeError(name+' failed; inspect '+str(out/(name+'.log')))
 return text
try:
 version=run('postgres-version',[str(pg/'postgres'),'--version'])
 run('initdb',prefix+[str(pg/'initdb'),'-D',str(data),'-U','postgres','--auth-local=trust','--auth-host=scram-sha-256','--pwfile='+str(pw),'--encoding=UTF8','--locale=C'])
 run('start',prefix+[str(pg/'pg_ctl'),'-D',str(data),'-l',str(work/'server.log'),'-o',f'-h 127.0.0.1 -p {port} -k {work}','-w','start']);started=True
 run('migrate',['go','run','./cmd/migrate'])
 run('runtime-identities',['go','run','./tests/nativefixture'])
 run('native-controls',['node','tests/verify.mjs','--native'],600)
 if '--browser' in sys.argv:run('native-browser',['node','tests/verify.mjs','--native','--e2e'],300)
 status='PASS'
except Exception as e:print(type(e).__name__+': '+str(e),file=sys.stderr)
finally:
 if started:
  try:run('stop',prefix+[str(pg/'pg_ctl'),'-D',str(data),'-m','fast','-w','stop'],30)
  except Exception as e:status='FAIL';print('Cleanup: '+str(e),file=sys.stderr)
 # Keep synthetic data for local investigation; never recursively delete a path
 # supplied by the caller. The password file is only the generated test secret.
 pw.unlink(missing_ok=True)
 report={'status':status,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'steps':steps,
  'limits':'Disposable native PostgreSQL without Docker; not deployment-image, backup/restore, PITR, failover or load certification.'}
 (out/'native-local.json').write_text(json.dumps(report,indent=2)+'\n')
sys.exit(0 if status=='PASS' else 1)
