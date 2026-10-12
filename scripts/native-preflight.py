#!/usr/bin/env python3
"""Read-only native host check. Creates no database, user or container."""
import argparse,datetime,json,os,pathlib,shutil,subprocess,sys

root=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--engine',choices=['docker','local'],default='docker')
parser.add_argument('--pg-bin',default=os.environ.get('PG_BIN'))
args=parser.parse_args()
out=pathlib.Path(os.environ.get('SERK_RESULTS_DIR',str(root/'test-results/native-preflight'))).resolve()
out.mkdir(parents=True,exist_ok=True)
checks=[]
def check(name,passed,detail):
 checks.append({'check':name,'status':'PASS' if passed else 'BLOCKED','detail':detail})
 print(checks[-1]['status']+' '+name+': '+detail)
if args.engine=='docker':
 binary=shutil.which('docker')
 if not binary:check('docker_engine',False,'Docker executable is unavailable; native/container tests were not run')
 else:
  try:
   proc=subprocess.run([binary,'info','--format','{{.ServerVersion}}'],capture_output=True,text=True,timeout=15)
   check('docker_engine',proc.returncode==0,'Docker engine responded' if proc.returncode==0 else 'Docker engine is unavailable or inaccessible')
  except (OSError,subprocess.TimeoutExpired):check('docker_engine',False,'Docker engine readiness could not be established')
else:
 pg=pathlib.Path(args.pg_bin).resolve() if args.pg_bin else None
 check('postgres_tools',pg is not None and all((pg/name).is_file() for name in ['postgres','initdb','pg_ctl']),'PG_BIN requires postgres, initdb and pg_ctl')
 if os.name!='posix':check('unprivileged_process',False,'Use a POSIX host or the Docker runner')
 elif os.geteuid()!=0:check('unprivileged_process',True,'Current process is not root')
 else:
  try:
   import pwd
   account=pwd.getpwnam('nobody')
   def mapped(path,identifier):
    p=pathlib.Path(path)
    if not p.exists():return True
    return any(start<=identifier<start+length for start,_,length in (map(int,line.split()) for line in p.read_text().splitlines()))
   possible=bool(shutil.which('runuser')) and mapped('/proc/self/uid_map',account.pw_uid) and mapped('/proc/self/gid_map',account.pw_gid)
   check('unprivileged_process',possible,'A mapped unprivileged account is available; actual setup still must succeed' if possible else 'The current namespace has no usable unprivileged account; PostgreSQL initialization was not attempted')
  except (OSError,KeyError,ValueError):check('unprivileged_process',False,'Cannot establish an unprivileged PostgreSQL account')
report={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'engine':args.engine,'status':'PASS' if all(row['status']=='PASS' for row in checks) else 'BLOCKED','checks':checks,'tests_run':False,'limits':'Read-only host prerequisite check, not execution or approval of native tests'}
(out/('native-preflight-'+args.engine+'.json')).write_text(json.dumps(report,indent=2)+'\n')
sys.exit(0 if report['status']=='PASS' else 2)
