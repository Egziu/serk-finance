# Native acceptance on a suitable test host

This procedure gathers the native evidence that this workspace cannot execute. It is not a live deployment. Run it on a dedicated acceptance host from the extracted `serk-finance` directory. The Docker runner creates and removes its own containers and synthetic data. Never point the integration suite at a business database.

## Preferred route: Docker on Linux

Provide Go 1.27.1, Node 24, Python 3, Docker Engine access and network access to the pinned package/image registries. A working Docker CLI alone is insufficient; the daemon must respond.

```bash
make install
web/node_modules/.bin/playwright install --with-deps chromium
python3 scripts/native-preflight.py --engine docker
GOFLAGS=-buildvcs=false SERK_RESULTS_DIR=test-results/acceptance \
python3 scripts/release-check.py --native
```

The explicit Go archive flag disables VCS stamping when the source is an extracted ZIP. Test-selection flags are rejected for release verification. A successful native profile needs all 16 steps to pass, no missing Go tests and no native skips. Examine both the process exit and recorded results.

| Required native test | Required behavior |
|---|---|
| `TestNativeConcurrentIdempotency` | Concurrent duplicate commands retain one financial effect |
| `TestNativeConcurrentPosting` | Concurrent posting does not duplicate financial effects |
| `TestNativeCloseSerializesWithPosting` | Period close and posting obey locking/state boundaries |
| `TestNativeCloseSerializesWithCreation` | Period close cannot strand a concurrently created journal |
| `TestNativeMFAReplaySerialization` | A consumed MFA counter cannot issue multiple sessions |
| `TestNativeDimensionChangeSerializesWithPosting` | Posting waits for and validates dimension deactivation |
| `TestNativeChartCycleSnapshotConflict` | A stale repeatable-read chart update fails serialization |
| `TestNativeRuntimeIdentityBoundaries` | Real login privileges and role boundaries are enforced |

After native controls, the runner exercises the browser against native PostgreSQL, restores a real dump into a separate database, compares application-table hashes, verifies restored isolation, and builds/starts/smokes the runtime image. PostgreSQL's container image remains pinned to the checked-in digest.

CI in `.github/workflows/ci.yml` additionally performs the image scan and emits a CycloneDX SBOM. Those two steps are not performed by the local Python runner. No remote CI run has been executed in this delivery; the correct accessible repository must be supplied before that can happen.

## Alternative: existing native PostgreSQL binaries

On a POSIX host with a normal unprivileged account and PostgreSQL binaries:

```bash
PG_BIN=/absolute/path/to/postgresql/bin \
SERK_RESULTS_DIR=test-results/acceptance-local \
python3 scripts/native-preflight.py --engine local

PG_BIN=/absolute/path/to/postgresql/bin GOFLAGS=-buildvcs=false \
SERK_RESULTS_DIR=test-results/acceptance-local \
python3 scripts/native-local-check.py --browser
```

This creates a private disposable loopback cluster with distinct generated operator/API/authentication identities. A root caller needs a mapped unprivileged account; the restricted current workspace lacks one. Successful local native execution would address database and native browser checks only. Docker/image, dump/restore, scan/SBOM and target recovery gates still need separate evidence.

## Collect and review the evidence

For the Docker route:

```bash
python3 -m zipfile -c serk-native-evidence.zip \
test-results/acceptance BUILD_INFO.json SOURCE_MANIFEST.json
```

Return that archive for review. Do not include `.local`, `.env.release`, passwords, MFA keys or database dumps. Preserve failed attempts in separate result directories when correcting an issue; never submit a stale PASS file as a new run.

Review `release-check.json`, `native/native-release-gate.json`, native test discovery/events/summary, `restore-fingerprints.json`, restore-authorization results and image build/smoke logs. When CI ran, retain its exact commit/run identity, image scan and SBOM. A count alone is insufficient: all named required tests and stages must be present.

Native success still does not establish target PITR/failover, RTO/RPO, production-scale load, TLS/proxy/secrets/MFA operations, accounting sign-off or complete AP/AR/banking functionality. Those gates remain in `PRODUCTION_READINESS.md`.
