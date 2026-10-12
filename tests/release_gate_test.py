"""Exercise contradictory/stale evidence without running external checks.
The real release suite runs separately; these fixtures test only its decision.
"""
import contextlib,datetime,io,json,os,pathlib,runpy,subprocess,sys,tempfile,unittest
from types import SimpleNamespace
from unittest.mock import patch

SCRIPT=pathlib.Path(__file__).resolve().parents[1]/'scripts/release-check.py'

class UpgradeEvidenceGate(unittest.TestCase):
 def test_requires_clean_exit_and_fresh_completed_teardown(self):
  scenarios=[
   ('complete',0,'PASS','PASS',False,True,0),
   ('crash_after_pass',1,'PASS','PASS',False,True,1),
   ('failed_result',0,'FAIL','PASS',False,True,1),
   ('failed_teardown',0,'PASS','FAIL',False,True,1),
   ('stale_pass',0,'PASS','PASS',True,True,1),
   ('missing_result',0,'PASS','PASS',False,False,1),
  ]
  for name,code,status,teardown,stale,present,expected in scenarios:
   with self.subTest(name=name),tempfile.TemporaryDirectory() as directory:
    out=pathlib.Path(directory)
    def execute(command,**kwargs):
     if command[:2]==['node','tests/upgrade.mjs']:
      folder='upgrade-rc3' if '--from-rc3' in command else 'upgrade-rc2' if '--from-rc2' in command else 'upgrade-rc1' if '--from-rc1' in command else 'upgrade'
      path=out/folder/'upgrade-result.json';path.parent.mkdir(parents=True,exist_ok=True)
      if present:path.write_text(json.dumps({'status':status,'teardown':teardown,'started':'2000-01-01T00:00:00Z' if stale else datetime.datetime.now(datetime.timezone.utc).isoformat()}))
      return SimpleNamespace(returncode=code,stdout=b'synthetic upgrade fixture\n')
     return SimpleNamespace(returncode=0,stdout=b'synthetic unrelated step\n')
    with patch.dict(os.environ,{'SERK_RESULTS_DIR':directory}),patch.object(sys,'argv',[str(SCRIPT)]),patch.object(subprocess,'run',side_effect=execute),contextlib.redirect_stdout(io.StringIO()):
     with self.assertRaises(SystemExit) as stopped:runpy.run_path(str(SCRIPT),run_name='__main__')
    self.assertEqual(stopped.exception.code,expected)
    report=json.loads((out/'release-check.json').read_text())
    upgrades=[check for check in report['checks'] if check['check'].startswith('populated')]
    self.assertEqual(len(upgrades),4)
    self.assertTrue(all(check['status']==('PASS' if expected==0 else 'FAIL') for check in upgrades))
    print('PASS: release gate '+name)

if __name__=='__main__':unittest.main()
