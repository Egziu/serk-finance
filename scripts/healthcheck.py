#!/usr/bin/env python3
"""Read-only smoke probe; never writes a journal or prints response data."""
import argparse,sys,urllib.request,urllib.error
p=argparse.ArgumentParser();p.add_argument('origin');args=p.parse_args()
origin=args.origin.rstrip('/')
if not origin.startswith(('http://localhost:','http://127.0.0.1:','https://')):
 sys.exit('Use HTTPS or a loopback development origin')
for path in ('/health/live','/health/ready','/'):
 try:
  with urllib.request.urlopen(origin+path,timeout=10) as r:
   if r.status!=200: raise RuntimeError(f'Unexpected HTTP {r.status}')
   if path=='/' and b'<html' not in r.read(2048).lower(): raise RuntimeError('Web bundle unavailable')
  print('PASS',path)
 except Exception as e: sys.exit(f'FAIL {path}: {type(e).__name__}')
