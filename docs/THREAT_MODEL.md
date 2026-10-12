# Threat model — foundation release

Protected assets: financial amounts and posted history, tenant data, login credentials/session secrets, approval authority, audit evidence and deployment credentials.

| Boundary / actor | Attack | Implemented control | Remaining validation |
|---|---|---|---|
| Unauthenticated browser → API | Credential guessing, CSRF, malformed input | Argon2id, bounded queue, source/account limits, encrypted TOTP and session assurance, origin checks, strict JSON | Native MFA replay, target recovery, distributed credential-stuffing and DAST exercises |
| Ingress → API | Forged client address | Explicit proxy CIDRs, single `X-Real-IP`, ignore unsolicited forwarding | Target ingress overwrite/network test |
| User → company/branch data | IDOR, cross-tenant reads/writes | Session-derived scope, RLS, composite FKs, per-action authorization | Native credentials and independent attack review |
| Preparer/approver → ledger | Self-approval, revoked approval, duplicate/post-in-closed-period | SQL transition guards, rechecks, locks, version/receipt controls | Native races and production load |
| API login → database | Session minting, table mutation, inherited administrative privileges | Separate roles; restricted grants; startup privilege rejection | Native real-role test gate |
| Operator → database | Accidental/malicious configuration reinterpretation | Definition guards, additive/checksummed migrations, audited supported admin actions | Privileged access governance and external logs |
| Backup → restored application | Lost amounts, ACL drift, replayed external effects | Native dump/restore/table-fingerprint and access-check script | Execute drill, PITR/failover, external-effect reconciliation |
| Supply chain → runtime | Vulnerable dependency/image, substituted build | Lockfiles, verified immutable upstream pins, scans, checksum manifest, CI image/SBOM steps | Container build/scan and signed provenance |
| Future AI/document/integration → ledger | Prompt injection or unauthorized money release | No such runtime capability exposed | Implement through controlled APIs and separate evaluation gates |

The financial kernel trusts PostgreSQL's transaction and permission model, the migration operator, the configured TLS trust store and the approved deployed binary. This release does not protect against an unrestricted database superuser or compromised host. Mitigate those boundaries operationally; application triggers alone cannot do so.
