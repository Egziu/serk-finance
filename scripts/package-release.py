#!/usr/bin/env python3
"""Package source, web bundle and evidence; excludes local secrets and tools."""
import argparse,hashlib,json,pathlib,zipfile,datetime
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',required=True);p.add_argument('--build-revision',type=int,default=1);args=p.parse_args()
if args.build_revision<1:p.error('--build-revision must be positive')
output=pathlib.Path(args.output).resolve()
if output.is_relative_to(root):raise SystemExit('Archive must be written outside the repository')
excluded={'.git','.local','node_modules','__pycache__','bin','playwright-report'}
exceptions={'.env.example','.env.release.example'}
def files():
 for path in sorted(root.rglob('*')):
  rel=path.relative_to(root)
  if not path.is_file() or any(part in excluded for part in rel.parts):continue
  if path.name.startswith('.env') and path.name not in exceptions:continue
  if path.suffix in {'.zip','.dump','.db','.pyc','.key','.pem'}:continue
  yield path,rel
source={}
for path,rel in files():
 if rel.parts[0] in {'test-results','web'} and (rel.parts[0]=='test-results' or 'dist' in rel.parts):continue
 if path.suffix=='.md' or path.name in {'SHA256SUMS','SOURCE_MANIFEST.json','BUILD_INFO.json'}:continue
 source[str(rel)]=hashlib.sha256(path.read_bytes()).hexdigest()
build_id=hashlib.sha256(json.dumps(source,sort_keys=True,separators=(',',':')).encode()).hexdigest()
(root/'SOURCE_MANIFEST.json').write_text(json.dumps({'version':'0.3.0-rc1','build_revision':args.build_revision,'source_id':build_id,'files':source},indent=2)+'\n')
(root/'BUILD_INFO.json').write_text(json.dumps({'version':'0.3.0-rc1','build_revision':args.build_revision,'source_id':build_id,'created_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'production_approved':False,'source_commit':'Repository github.com/Egziu/serk-finance; identify this build by source_id and SHA256SUMS.'},indent=2)+'\n')
manifest=[]
for path,rel in files():
 if path.name!='SHA256SUMS':manifest.append(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+str(rel))
(root/'SHA256SUMS').write_text('\n'.join(manifest)+'\n')
output.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
 for path,rel in files():z.write(path,'serk-finance/'+str(rel))
with zipfile.ZipFile(output) as z:
 for line in (root/'SHA256SUMS').read_text().splitlines():
  digest,rel=line.split('  ',1)
  if hashlib.sha256(z.read('serk-finance/'+rel)).hexdigest()!=digest:raise SystemExit('Archive checksum mismatch')
print(json.dumps({'file':str(output),'bytes':output.stat().st_size,'source_id':build_id,'sha256':hashlib.sha256(output.read_bytes()).hexdigest(),'files':len(manifest)+1}))
