# ADR 0003 — Distinguish embedded PostgreSQL verification from native concurrency evidence

Status: accepted due to authoring-environment constraints.

The environment exposes only a root user mapping and cannot start native PostgreSQL under its required non-root account. PGlite supplies PostgreSQL SQL, RLS, transaction and trigger checks without claiming native concurrency equivalence. Its socket multiplexer runs over one engine connection.

Keep native tests in the same repository and run them with real restricted login identities in CI. Explicitly skip the native races in the embedded harness. Native tests, Docker builds/scans and recovery drills are release gates. Never describe a sequential embedded replay test as proof of concurrent native transaction safety.
