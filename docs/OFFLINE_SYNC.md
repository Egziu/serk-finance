# Offline architecture — designed, not implemented

Offline capability is a release gate, not an optional cache. The current React workspace detects network loss and pauses actions; it does not retain a durable financial queue. The PGlite test harness is not the product's offline database.

## Client boundary

Use SQLite with encryption on Flutter/desktop clients, with keys protected by the OS keystore and device enrollment. A web client needs a separately reviewed encrypted local-store design; WebCrypto does not make an XSS-compromised session safe. Store only authorized, explicitly selected company/branch datasets. Expire and purge them according to an offline access lease, with honest handling of the fact that remote revocation cannot be observed during a disconnection.

Clients may prepare invoices, receipts, expenses, purchasing requests, and selected stock movements as provisional business intents. An offline approval is a signed decision proposal scoped to a policy snapshot and expiry, not authority to release money or post into a now-closed cloud period. The central kernel remains the posting authority. No local journal may claim global finality before server acceptance.

## Envelope and durability

Each durable envelope includes schema_version, local_id, global_operation_id, tenant/company/branch, device_id, actor_id, device_sequence, occurred_at, command_type, aggregate_id, expected_version, payload, payload_hash, authorization_lease_id, device signature, dependencies, attempts, last_error and sync status. Actor fields are claims to verify; server identity must resolve from authenticated device/user credentials. Protect queue insertion and local source mutation in one SQLite transaction.

States: PENDING → UPLOADING → VALIDATING → ACCEPTED; failures transition to CONFLICT → REVIEW → RESOLVED, or REJECTED. A restart during UPLOADING retries the identical envelope. The server stores an inbox receipt and financial effects atomically. A timeout is an unknown outcome until the same operation is replayed or queried.

## Server validation order

1. Authenticate user/device, verify signature/lease, and bind tenant/company access from server records.
2. Check size, schema, hash, sequence/replay window, dependency receipts and aggregate version.
3. Compare the persistent operation receipt and business-source uniqueness keys.
4. Apply current company, period, stock, tax, workflow and budget policy; preserve historical tax snapshots where legitimately already posted.
5. Commit source state, subledger/journal, audit, outbox, inbox receipt and final version together.
6. Return a signed receipt identifying exact accepted rows and hashes. Delete the pending local command only after durable receipt storage.

There is no distributed exactly-once delivery claim. At-least-once delivery plus durable deduplication produces one authorized financial effect.

## Conflict policy

| Conflict | Resolution |
|---|---|
| Same operation, same body | Return original receipt |
| Same operation, different hash | Reject; inspect device/software integrity |
| Stale editable draft | Explicit field comparison and user-approved merge; invalidate old approval |
| Posted journal change | Reject; propose a separate correcting/reversing journal |
| Period closed while offline | Review; propose a permitted date/period with reason, never silently redate |
| Stock exhausted elsewhere | Reject/reserve-review; never silently allow duplicate deduction |
| Tax/policy changed | Recalculate proposal with explanation and reapproval where required |
| User/device revoked | Reject upload authority; preserve locally captured evidence for authorized recovery |
| Competing approvals | Evaluate current workflow version and distinct-person rules |

Device clocks are evidence, not ordering authority. Server versions and device sequences govern causality. Documents synchronize by verified hashes before dependent approvals. Signed attachment URLs, cache keys, telemetry, and search indexes all include tenant/company scope.

## Acceptance before enabling

Test disconnect during every request/commit/receipt step, duplicate delivery across devices, reordered dependencies, lost receipts, client clock skew, exhausted stock, closed periods, revoked devices, policy/tax changes, queue corruption, key rotation, disk full, browser reload, and restart. Native concurrent server tests must prove no duplicate postings or stock deductions. All local/cloud reconciliation differences must remain visible.

PGlite's socket server multiplexes clients over one connection, so it cannot substitute for these native concurrent tests. [PGlite limitations](https://pglite.dev/docs/pglite-socket).
