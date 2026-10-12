#!/usr/bin/env python3
"""Offline integrity gate for reviewed upstream immutable references."""
import json,pathlib,re
root=pathlib.Path(__file__).resolve().parents[1]
pins=json.loads((root/'deploy/dependency-pins.json').read_text())
known={}
for item in pins['images']:
 name=item['repository'].removeprefix('library/')
 if item['registry']=='gcr.io':name='gcr.io/'+name
 known[name+':'+item['tag']]=item['digest']
for filename in ['Dockerfile','compose.yaml','scripts/native-check.py']:
 source=(root/filename).read_text()
 for image,digest in known.items():
  for match in re.finditer(re.escape(image)+r'(?:@sha256:[a-f0-9]{64})?',source):
   if match.group()!=image+'@'+digest:raise SystemExit('FAIL unpinned or unexpected base in '+filename)
for image in re.findall(r'^FROM (\S+)',(root/'Dockerfile').read_text(),re.M):
 name,sep,digest=image.partition('@')
 if not sep or known.get(name)!=digest:raise SystemExit('FAIL unknown Docker base')
expected={p['repository']:p['commit'] for p in pins['actions']}
for repo,sha in re.findall(r'uses:\s+([^@\s]+)@([^\s]+)',(root/'.github/workflows/ci.yml').read_text()):
 if not re.fullmatch('[a-f0-9]{40}',sha) or expected.get(repo)!=sha:raise SystemExit('FAIL action pin mismatch')
print('PASS: CI actions and build/database images match verified immutable references. This does not execute builds or scan images.')
