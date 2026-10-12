#!/usr/bin/env python3
"""Prove released SQL and inherited Go tests are unchanged from a supplied rc2 ZIP."""
import argparse,hashlib,json,pathlib,zipfile
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('baseline');p.add_argument('--output',default='test-results/rc3/migration-integrity.json');args=p.parse_args()
sha=lambda b:hashlib.sha256(b).hexdigest()
checks=[]
with zipfile.ZipFile(args.baseline) as archive:
 for line in archive.read('serk-finance/SHA256SUMS').decode().splitlines():
  expected,relative=line.split('  ',1)
  if sha(archive.read('serk-finance/'+relative))!=expected:raise SystemExit('FAIL baseline checksum '+relative)
 for name in sorted(archive.namelist()):
  relative=name.removeprefix('serk-finance/')
  migration=relative.startswith('migrations/') and relative.endswith('.sql') and relative.split('/')[-1][:3] in {f'{n:03}' for n in range(1,8)}
  go_test=relative.endswith('_test.go')
  if not migration and not go_test:continue
  before=sha(archive.read(name));after=sha((root/relative).read_bytes())
  checks.append({'file':relative,'rc2_sha256':before,'rc3_sha256':after,'identical':before==after})
report={'baseline_archive_sha256':sha(pathlib.Path(args.baseline).read_bytes()),'status':'PASS' if all(c['identical'] for c in checks) else 'FAIL','checks':checks}
out=root/args.output;out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(report,indent=2)+'\n')
for c in checks:print(('IDENTICAL' if c['identical'] else 'CHANGED')+' '+c['file']+' '+c['rc3_sha256'])
print(report['status']+': baseline archive checksums, migrations 001-007 and all inherited Go test files verified')
raise SystemExit(0 if report['status']=='PASS' else 1)
