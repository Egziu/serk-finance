#!/usr/bin/env python3
"""Repeat populated upgrades to exercise the independent review's teardown race.
Every subprocess exit and post-teardown result must pass; no retry hides failure.
"""
import argparse,datetime,json,os,pathlib,subprocess,sys

root=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--rounds',type=int,default=5)
args=parser.parse_args()
if not 1<=args.rounds<=20:parser.error('--rounds must be between 1 and 20')
out=pathlib.Path(os.environ.get('SERK_RESULTS_DIR',str(root/'test-results'))).resolve()/'upgrade-repeats'
out.mkdir(parents=True,exist_ok=True)
started=datetime.datetime.now(datetime.timezone.utc).isoformat()
results=[]
for round_number in range(1,args.rounds+1):
 for name,flags,folder in [('0.1.0',[],'upgrade'),('rc1',['--from-rc1'],'upgrade-rc1'),('rc2',['--from-rc2'],'upgrade-rc2'),('rc3',['--from-rc3'],'upgrade-rc3')]:
  destination=out/f'{round_number:02d}-{name}'
  destination.mkdir(parents=True,exist_ok=True)
  command=['node','tests/upgrade.mjs',*flags]
  env={**os.environ,'SERK_RESULTS_DIR':str(destination)}
  result={'round':round_number,'baseline':name,'command':command,'status':'FAIL','exit_code':None}
  try:
   proc=subprocess.run(command,cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
   (destination/'process.log').write_bytes(proc.stdout)
   evidence=json.loads((destination/folder/'upgrade-result.json').read_text())
   result.update(exit_code=proc.returncode,evidence_status=evidence.get('status'),teardown=evidence.get('teardown'))
   if proc.returncode==0 and evidence.get('status')=='PASS' and evidence.get('teardown')=='PASS':result['status']='PASS'
  except (OSError,ValueError,subprocess.TimeoutExpired) as error:
   result['error']=str(error)
  results.append(result)
  print(result['status'],f'round={round_number}',f'baseline={name}',f'exit={result["exit_code"]}',flush=True)
report={'started':started,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'PASS' if all(result['status']=='PASS' for result in results) else 'FAIL','passed':sum(result['status']=='PASS' for result in results),'failed':sum(result['status']!='PASS' for result in results),'runs':results}
(out/'repeat-result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({key:report[key] for key in ['status','passed','failed']}))
sys.exit(0 if report['status']=='PASS' else 1)
