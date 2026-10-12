# ADR 0002 — Preserve originals; represent correction with a linked reversal

Status: accepted.

Mutating a posted header's status to REVERSED would break strict header immutability and make old snapshots harder to verify. Keep the original state POSTED; expose REVERSED as a query projection when an inverse linked journal is posted. The inverse journal needs its own creation, submission, independent approval and posting. A unique active source link prevents duplicate reversal.

Reports sum both original and reversal. Original amounts/rates/dimensions remain unchanged. Void an unposted incorrect reversal before creating another. Adjustments that are not exact inverses require a separately designed correcting-journal source relationship, not direct mutation.
