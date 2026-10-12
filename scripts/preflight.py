#!/usr/bin/env python3
"""Offline deployment configuration checks, without printing secrets or connecting."""
import argparse,os,pathlib,re,sys,urllib.parse,base64
p=argparse.ArgumentParser();p.add_argument('--env-file',required=True);a=p.parse_args()
f=pathlib.Path(a.env_file)
values={}
for line in f.read_text().splitlines():
 line=line.strip()
 if line and not line.startswith('#'):
  if '=' not in line:sys.exit('FAIL malformed environment line')
  k,v=line.split('=',1)
  if k in values:sys.exit('FAIL duplicate environment setting')
  values[k]=v
errors=[]
if os.name!='nt' and f.stat().st_mode & 0o077:errors.append('environment file must be mode 0600')
if values.get('SERK_ENV') not in ('staging','production'):errors.append('SERK_ENV must be staging or production')
u=urllib.parse.urlsplit(values.get('SERK_ORIGIN',''))
if u.scheme!='https' or not u.hostname or u.username or u.path or u.query or u.fragment:errors.append('SERK_ORIGIN must be an exact HTTPS origin')
if not re.fullmatch(r'.+@sha256:[0-9a-f]{64}',values.get('SERK_IMAGE','')):errors.append('SERK_IMAGE must use an immutable sha256 digest')
identities=[]
for key in ('DATABASE_URL','AUTH_DATABASE_URL'):
 try:
  d=urllib.parse.urlsplit(values.get(key,''));q=urllib.parse.parse_qs(d.query)
  if d.scheme not in ('postgres','postgresql') or not d.hostname or not d.username or not d.password:errors.append(key+' needs explicit database credentials')
  if q.get('sslmode')!=['verify-full']:errors.append(key+' must use sslmode=verify-full')
  if q.get('sslrootcert')!=['/run/serk/db-ca.pem']:errors.append(key+' must use the mounted database CA')
  if any(marker in values.get(key,'') for marker in ('REPLACE','example.com')):errors.append(key+' still contains an example value')
  identities.append((d.hostname,d.port,d.path,d.username))
 except ValueError:errors.append(key+' is malformed')
if len(identities)==2 and (identities[0][:3]!=identities[1][:3] or identities[0][3]==identities[1][3]):errors.append('use separate API/auth logins on the same database')
ca=pathlib.Path(values.get('SERK_DB_CA_PATH',''))
if not ca.is_file() or 'BEGIN CERTIFICATE' not in ca.read_text(errors='replace'):errors.append('SERK_DB_CA_PATH must point to a readable public CA certificate')
try:
 mfa_path=pathlib.Path(values.get('SERK_MFA_KEY_PATH',''))
 if not mfa_path.is_file() or len(base64.b64decode(mfa_path.read_text().strip(),validate=True))!=32:errors.append('SERK_MFA_KEY_PATH must contain a base64-encoded 32-byte key')
 if os.name!='nt' and mfa_path.stat().st_mode & 0o007:errors.append('MFA key file must not be world-accessible')
except (ValueError,OSError):errors.append('MFA key file is missing or malformed')
if errors:
 for e in errors:print('FAIL',e)
 sys.exit(1)
print('PASS offline deployment configuration. TLS connections, database grants, scans and release acceptance still require live checks.')
