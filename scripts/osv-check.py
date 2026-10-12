#!/usr/bin/env python3
"""Offline Go vulnerability check: matches go.sum modules and the Go toolchain against an OSV
export of github.com/golang/vulndb (data/osv). Usage: osv-check.py <modules.txt> <vulndb/data/osv>.
Use govulncheck where vuln.go.dev is reachable; this is the fallback for restricted networks."""
import json,glob,re,sys
mods={}
for l in open(sys.argv[1]):
    p=l.split()
    if len(p)==2: mods[p[0]]=p[1]
import subprocess
gv='v'+subprocess.check_output(['go','env','GOVERSION'],text=True).strip().removeprefix('go')
mods['stdlib']=gv; mods['toolchain']=gv
imported=set(subprocess.check_output(['go','list','-deps','./...'],text=True).split())
def key(v):
    v=v.lstrip('v'); main=re.split(r"[-+]",v,maxsplit=1)[0]
    parts=[int(x) for x in (main.split('.')+['0','0'])[:3]]
    pre='-' in v.split('+')[0]
    return (parts,0 if pre else 1,v)
def lt(a,b): return key(a)<key(b)
def norm(x): return 'v0.0.0' if x in ('0','') else 'v'+x.lstrip('v')
hits=set()
for f in glob.glob(sys.argv[2]+'/*.json'):
    d=json.load(open(f))
    for a in d.get('affected',[]):
        m=a['package']['name']
        if m not in mods: continue
        v=mods[m]
        for r in a.get('ranges',[]):
            if r['type']!='SEMVER': continue
            intro=None
            for ev in r['events']:
                if 'introduced' in ev: intro=norm(ev['introduced'])
                if 'fixed' in ev:
                    if intro is not None and not lt(v,intro) and lt(v,norm(ev['fixed'])): hits.add((d['id'],m,v,d.get('summary','')[:100]))
                    intro=None
            if intro is not None and not lt(v,intro): hits.add((d['id'],m,v,d.get('summary','')[:100]))
# A module-level advisory only applies when an affected package is actually built in.
def relevant(i):
    d=json.load(open(sys.argv[2]+'/'+i+'.json'))
    pk=[p['path'] for a in d['affected'] for p in a.get('ecosystem_specific',{}).get('imports',[])]
    return not pk or any(p in imported for p in pk)
real=sorted(h for h in hits if relevant(h[0]))
for h in sorted(hits): print('RELEVANT' if h in real else 'not-imported',*h)
print('checked',len(mods),'modules incl. stdlib',gv,'; advisories matched',len(hits),'; affecting built packages',len(real))
sys.exit(1 if real else 0)
