#!/usr/bin/env python3
"""Native PostgreSQL physical backup + WAL point-in-time recovery rehearsal.

Disposable loopback clusters only. Populates two tenants through the real command
path, takes a non-exclusive base backup with the low-level API, generates activity
before and after a recovery target, crashes the primary, restores to the target and
verifies the project's documented restore checks. Never point this at business data.
Requires: PG_BIN (initdb/pg_ctl/postgres), psycopg, Go, a running primary described
by MIGRATOR_DATABASE_URL / TEST_API_DATABASE_URL, PGDATA_PRIMARY, WAL_ARCHIVE,
RESTORE_DIR, RESTORE_PORT and an unprivileged OS account PG_OS_USER.
"""
import datetime, hashlib, json, os, pathlib, secrets, shutil, subprocess, sys, time
import psycopg

E = os.environ
PG = pathlib.Path(E['PG_BIN']); PRIMARY = pathlib.Path(E['PGDATA_PRIMARY'])
WAL = pathlib.Path(E['WAL_ARCHIVE']); RESTORE = pathlib.Path(E['RESTORE_DIR'])
PORT = E.get('RESTORE_PORT', '55433'); OSUSER = E['PG_OS_USER']
OUT = pathlib.Path(E.get('SERK_RESULTS_DIR', 'test-results/pitr')); OUT.mkdir(parents=True, exist_ok=True)
ADMIN = E['MIGRATOR_DATABASE_URL']; API = E['TEST_API_DATABASE_URL']
sha = lambda s: hashlib.sha256(s.encode()).hexdigest()
log = []
def note(k, v): log.append((k, v)); print(f'{k}: {v}', flush=True)
def pgctl(*a): subprocess.run(['runuser', '-u', OSUSER, '--', str(PG / 'pg_ctl'), *a], check=True, capture_output=True)
def swap_port(url, port): return url.replace(':55432/', f':{port}/')

def bootstrap(slug):
    pw = secrets.token_urlsafe(24)
    cfg = {'slug': slug, 'name': slug + ' rehearsal', 'companies': [{'code': 'TEST', 'name': slug + ' co', 'currency': 'ETB', 'country': 'ET',
           'branches': ['HQ'], 'year_name': '2026', 'year_start': '2026-01-01', 'year_end': '2026-12-31',
           'accounts': [{'code': '1000', 'name': 'Cash', 'type': 'ASSET', 'normal_balance': 'DEBIT'},
                        {'code': '3000', 'name': 'Capital', 'type': 'EQUITY', 'normal_balance': 'CREDIT'}]}],
           'roles': [{'name': 'Finance', 'permissions': ['ledger.read', 'journal.create', 'journal.submit', 'journal.approve', 'journal.post', 'audit.read']}],
           'users': [{'email': f'{n}@{slug}.test', 'name': n, 'password': pw, 'grants': [{'company': 'TEST', 'role': 'Finance'}]} for n in ('maker', 'checker')]}
    p = subprocess.run(['go', 'run', './cmd/bootstrap', '--file', '-'], input=json.dumps(cfg), text=True, capture_output=True)
    if p.returncode: raise SystemExit('bootstrap failed: ' + p.stderr[-500:])
    ids = json.loads(p.stdout); tokens = {n: secrets.token_urlsafe(32) for n in ('maker', 'checker')}; csrf = secrets.token_urlsafe(32)
    with psycopg.connect(ADMIN, autocommit=True) as c:
        for n in tokens: c.execute('SELECT security.issue_session(%s::uuid,%s,%s)', (ids['users'][f'{n}@{slug}.test'], sha(tokens[n]), csrf))
    return {'slug': slug, 'ids': ids, 'tokens': tokens, 'csrf': csrf, 'cid': ids['companies']['TEST']}

def as_user(url, t, user, sql, args=()):
    with psycopg.connect(url) as c:
        with c.transaction():
            c.execute('SELECT security.bind(%s,%s::uuid,%s)', (t['tokens'][user], t['cid'], t['csrf']))
            c.execute('SET LOCAL ROLE serk_api')
            return c.execute(sql, args).fetchone()[0]

def post(url, t, key, amount):
    ids = t['ids']
    j = as_user(url, t, 'maker', 'SELECT ledger.command(%s,%s,%s::jsonb)', (key + '-create', 'create', json.dumps({
        'branch_id': ids['branches']['TEST:HQ'], 'accounting_date': '2026-09-01', 'description': key, 'currency': 'ETB', 'fx_rate': '1',
        'reason': 'PITR rehearsal', 'lines': [{'account_id': ids['accounts']['TEST:1000'], 'debit_minor': str(amount), 'credit_minor': '0'},
                                              {'account_id': ids['accounts']['TEST:3000'], 'debit_minor': '0', 'credit_minor': str(amount)}]})))
    for action, user in (('submit', 'maker'), ('approve', 'checker'), ('post', 'checker')):
        j = as_user(url, t, user, 'SELECT ledger.command(%s,%s,%s::jsonb)', (f'{key}-{action}', action, json.dumps({'id': j['id'], 'expected_version': j['version'], 'reason': 'rehearsal'})))
    return j['id']

TABLES = ['ledger.accounts', 'ledger.journals', 'ledger.lines', 'ledger.idempotency', 'audit.events', 'audit.heads', 'integration.outbox', 'security.sessions']
def fingerprint(url):
    with psycopg.connect(url) as c:
        return {t: sha(c.execute(f"SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]')::text FROM {t} x").fetchone()[0]) for t in TABLES}

def journals(url):
    with psycopg.connect(url) as c:
        return {r[0] for r in c.execute("SELECT description FROM ledger.journals WHERE state='POSTED'")}

checks = {}
def check(name, ok, detail=''):
    checks[name] = {'status': 'PASS' if ok else 'FAIL', 'detail': detail}; print(('PASS ' if ok else 'FAIL ') + name, detail, flush=True)

alpha, beta = bootstrap('alpha'), bootstrap('beta')
for i in range(3): post(ADMIN, alpha, f'alpha-pre-backup-{i}', 1000 + i); post(ADMIN, beta, f'beta-pre-backup-{i}', 2000 + i)

# Non-exclusive base backup using the low-level API (the session must stay open).
base = OUT / 'work-base'; shutil.rmtree(base, ignore_errors=True)
with psycopg.connect(ADMIN, autocommit=True) as c:
    c.execute("SELECT pg_backup_start('serk-rehearsal', true)")
    shutil.copytree(PRIMARY, base, ignore=shutil.ignore_patterns('postmaster.pid', 'postmaster.opts'),
                    ignore_dangling_symlinks=True, dirs_exist_ok=False)
    for d in ('pg_wal', 'pg_replslot'): shutil.rmtree(base / d, ignore_errors=True); (base / d).mkdir()
    (base / 'pg_wal' / 'archive_status').mkdir()
    lsn, label, spcmap = c.execute('SELECT lsn::text,labelfile,spcmapfile FROM pg_backup_stop(true)').fetchone()
(base / 'backup_label').write_text(label)
if spcmap: (base / 'tablespace_map').write_text(spcmap)
note('base_backup_stop_lsn', lsn)

for i in range(3): post(ADMIN, alpha, f'alpha-before-target-{i}', 3000 + i); post(ADMIN, beta, f'beta-before-target-{i}', 4000 + i)
expected = fingerprint(ADMIN); expected_posted = journals(ADMIN)
with psycopg.connect(ADMIN, autocommit=True) as c:
    target = c.execute('SELECT clock_timestamp()').fetchone()[0]
note('recovery_target_time', target.isoformat()); time.sleep(1.2)
for i in range(3): post(ADMIN, alpha, f'alpha-after-target-{i}', 5000 + i)
with psycopg.connect(ADMIN, autocommit=True) as c: c.execute('SELECT pg_switch_wal()')
time.sleep(2)

# Disaster: primary crashes without a clean shutdown.
declared = time.monotonic(); pgctl('-D', str(PRIMARY), '-m', 'immediate', '-w', 'stop'); note('primary', 'crashed (immediate stop)')

shutil.rmtree(RESTORE, ignore_errors=True); shutil.copytree(base, RESTORE)
with open(RESTORE / 'postgresql.conf', 'a') as f:
    f.write(f"\nport = {PORT}\narchive_mode = off\nrestore_command = 'cp {WAL}/%f %p'\n"
            f"recovery_target_time = '{target.isoformat()}'\nrecovery_target_action = 'promote'\n")
(RESTORE / 'recovery.signal').touch()
subprocess.run(['chown', '-R', OSUSER, str(RESTORE)], check=True); os.chmod(RESTORE, 0o700)
server_log = RESTORE.parent / 'restore-server.log'  # must be writable by the unprivileged server account
pgctl('-D', str(RESTORE), '-l', str(server_log), '-w', '-t', '300', 'start')
R_ADMIN, R_API = swap_port(ADMIN, PORT), swap_port(API, PORT)
while True:
    with psycopg.connect(R_ADMIN, autocommit=True) as c:
        if not c.execute('SELECT pg_is_in_recovery()').fetchone()[0]: break
    time.sleep(0.2)
restored_at = time.monotonic()

got = fingerprint(R_ADMIN)
check('ordered data fingerprints match the recovery target', got == expected, json.dumps({t: got[t] == expected[t] for t in TABLES}))
posted = journals(R_ADMIN)
check('all journals committed before the target are recovered', expected_posted <= posted, f'{len(expected_posted)} expected')
check('no journal committed after the target is present', not any('after-target' in d for d in posted))
with psycopg.connect(R_ADMIN) as c:
    dr, cr = c.execute("SELECT sum(l.debit_minor),sum(l.credit_minor) FROM ledger.lines l JOIN ledger.journals j ON j.id=l.journal_id WHERE j.state='POSTED'").fetchone()
check('posted debits equal posted credits after restore', dr == cr, f'{dr} / {cr}')
for t in (alpha, beta):
    status = as_user(R_ADMIN, t, 'checker', 'SELECT ledger.integrity_status()')
    check(f"{t['slug']}: audit chain, heads and outbox integrity verify", status.get('ok') is True, json.dumps({k: status.get(k) for k in ('ok', 'imbalanced', 'audit_errors', 'missing_heads', 'missing_events', 'version_errors')}))
    tb = as_user(R_ADMIN, t, 'checker', "SELECT ledger.trial_balance('2026-12-31')")
    check(f"{t['slug']}: trial balance available after restore", tb is not None)
with psycopg.connect(R_API) as c:
    check('restricted API login sees no ledger rows without a bound session', c.execute('SELECT count(*) FROM ledger.journals').fetchone()[0] == 0)
a_rows = as_user(R_API, alpha, 'checker', "SELECT count(*) FROM ledger.journals")
a_leak = as_user(R_API, alpha, 'checker', "SELECT count(*) FROM ledger.journals WHERE left(description,5)='beta-'")
check('restricted API login bound to tenant alpha sees only alpha data', a_rows > 0 and a_leak == 0, f'{a_rows} rows, {a_leak} beta rows')
post(R_ADMIN, beta, 'beta-after-restore', 6000)
check('restored primary accepts new postings', 'beta-after-restore' in journals(R_ADMIN))

rto = round(restored_at - declared, 2)
report = {'status': 'PASS' if all(v['status'] == 'PASS' for v in checks.values()) else 'FAIL',
          'finished': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'backup_method': 'physical non-exclusive base backup (pg_backup_start/stop) + WAL archive',
          'recovery_target_time': target.isoformat(), 'base_backup_stop_lsn': lsn,
          'measured_rto_seconds_crash_to_promoted': rto, 'rpo_at_target': 'zero committed transactions lost before target',
          'checks': checks, 'limits': 'Loopback disposable cluster; small dataset; no logical pg_dump/pg_restore, standby failover, encryption, off-site copy or production-scale timing.'}
(OUT / 'pitr-rehearsal.json').write_text(json.dumps(report, indent=2) + '\n')
print('RTO (crash -> promoted, verified dataset small):', rto, 's'); print('STATUS', report['status'])
pgctl('-D', str(RESTORE), '-m', 'fast', '-w', 'stop')
shutil.copy(server_log, OUT / 'restore-server.log')
sys.exit(0 if report['status'] == 'PASS' else 1)
