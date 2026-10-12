#!/usr/bin/env python3
"""Local release evidence. Fails on any failed or unavailable mandatory check.
Use --native after local checks to exercise Docker/PostgreSQL/recovery gates.
"""
import argparse,datetime,json,os,pathlib,subprocess,sys,time
root=pathlib.Path(__file__).resolve().parents[1];os.chdir(root)
p=argparse.ArgumentParser();p.add_argument('--native',action='store_true');args=p.parse_args()
out=pathlib.Path(os.environ.get('SERK_RESULTS_DIR',str(root/'test-results')));out.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env['SERK_ENV']='development'
env['SERK_RESULTS_DIR']=str(out.resolve())
commands=[
 ('immutable_dependencies',[sys.executable,'scripts/check-pins.py'],30),
 ('go_modules',['go','mod','verify'],120),
 ('web_build',['npm','--prefix','web','run','build'],120),
 ('release_gate_regression',[sys.executable,'-m','unittest','discover','-s','tests','-p','release_gate_test.py','-v'],30),
 ('test_execution_gate',['node','--test','tests/go-evidence.test.mjs'],30),
 ('embedded_shutdown',['node','tests/pglite-shutdown.mjs'],240),
 ('go_controls',['node','tests/verify.mjs'],300),
 ('remediation_upgrade_preservation',['node','tests/remediation-upgrades.mjs'],180),
 ('remediation_database_controls',['node','tests/remediation.mjs'],180),
 ('rc3_database_controls',['node','tests/rc3-controls.mjs'],120),
 ('populated_upgrade',['node','tests/upgrade.mjs'],120),
 ('populated_rc1_upgrade',['node','tests/upgrade.mjs','--from-rc1'],120),
 ('populated_rc2_upgrade',['node','tests/upgrade.mjs','--from-rc2'],120),
 ('populated_rc3_upgrade',['node','tests/upgrade.mjs','--from-rc3'],120),
 ('browser',['node','tests/verify.mjs','--e2e'],180),
 ('npm_tools_audit',['npm','audit','--audit-level=moderate','--json'],90),
 ('npm_web_audit',['npm','--prefix','web','audit','--audit-level=moderate','--json'],90),
 ('go_vulnerability_scan',['go','run','golang.org/x/vuln/cmd/govulncheck@v1.8.0','-show','verbose','./...'],180),
]
if args.native:commands.append(('native_release',[sys.executable,'scripts/native-check.py'],1800))
upgrade_results={
 'populated_upgrade':'upgrade/upgrade-result.json',
 'populated_rc1_upgrade':'upgrade-rc1/upgrade-result.json',
 'populated_rc2_upgrade':'upgrade-rc2/upgrade-result.json',
 'populated_rc3_upgrade':'upgrade-rc3/upgrade-result.json',
}
results=[];start=datetime.datetime.now(datetime.timezone.utc).isoformat()
for name,command,limit in commands:
 t=time.monotonic();evidence_status=None
 try:
  proc=subprocess.run(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=limit)
  (out/(name+'.log')).write_bytes(proc.stdout)
  status='PASS' if proc.returncode==0 else ('BLOCKED' if name=='native_release' and proc.returncode==2 else 'FAIL');code=proc.returncode
  # A PASS file never overrides a failed process. Require both a fresh final
  # result and a zero exit code for populated upgrades, including teardown.
  if name in upgrade_results:
   try:
    evidence_path=out/upgrade_results[name]
    evidence=json.loads(evidence_path.read_text())
    fresh=datetime.datetime.fromisoformat(evidence['started'].replace('Z','+00:00'))>=datetime.datetime.fromisoformat(start)
    evidence_status='PASS' if fresh and evidence['status']=='PASS' and evidence['teardown']=='PASS' else 'FAIL'
   except (OSError,ValueError,KeyError,TypeError):evidence_status='FAIL'
   if evidence_status!='PASS':status='FAIL'
 except (OSError,subprocess.TimeoutExpired) as e:
  status='BLOCKED';code=None;(out/(name+'.log')).write_text(type(e).__name__+'\n')
 results.append({'check':name,'command':command,'status':status,'exit_code':code,'evidence_status':evidence_status,'seconds':round(time.monotonic()-t,3)})
 print(status,name,flush=True)
 # Preserve all independent results; a failure is never converted to a pass.
report={'started':start,'finished':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'PASS' if all(r['status']=='PASS' for r in results) else 'FAIL',
 'scope':'local plus disposable native infrastructure' if args.native else 'local embedded verification',
 'checks':results,'production_approval':False}
(out/'release-check.json').write_text(json.dumps(report,indent=2))
sys.exit(0 if report['status']=='PASS' else 1)
