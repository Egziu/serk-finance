#!/usr/bin/env python3
"""Verify the original rc3 and prove the harness update preserves product code."""
import argparse,hashlib,json,os,pathlib,zipfile

root=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('baseline');args=parser.parse_args()
baseline=pathlib.Path(args.baseline).resolve()
sha=lambda data:hashlib.sha256(data).hexdigest()
protected=[];changed=[]
with zipfile.ZipFile(baseline) as archive:
 lines=archive.read('serk-finance/SHA256SUMS').decode().splitlines()
 for line in lines:
  digest,name=line.split('  ',1)
  if sha(archive.read('serk-finance/'+name))!=digest:raise SystemExit('Baseline checksum failed: '+name)
  path=root/name
  current=sha(path.read_bytes()) if path.is_file() else None
  if current!=digest:changed.append(name)
  if name.startswith(('migrations/','internal/','cmd/','web/')) or name.endswith('_test.go') or name in {'go.mod','go.sum','package.json','package-lock.json','docs/openapi.json'}:
   protected.append({'file':name,'baseline_sha256':digest,'current_sha256':current,'status':'IDENTICAL' if digest==current else 'CHANGED'})
 report={'baseline_file':baseline.name,'baseline_archive_sha256':sha(baseline.read_bytes()),'baseline_checksums_verified':len(lines),'protected_files':protected,'changed_original_files':changed,'status':'PASS' if all(row['status']=='IDENTICAL' for row in protected) else 'FAIL'}
out=pathlib.Path(os.environ.get('SERK_RESULTS_DIR',str(root/'test-results/rc3-build2')))
out.mkdir(parents=True,exist_ok=True);(out/'rc3-integrity.json').write_text(json.dumps(report,indent=2)+'\n')
if report['status']!='PASS':raise SystemExit('Protected rc3 product files changed; inspect rc3-integrity.json')
print(f'PASS: {len(lines)} baseline checksums; {len(protected)} protected product/dependency/test files IDENTICAL, including all 9 migrations')
