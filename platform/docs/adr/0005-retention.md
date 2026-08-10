# ADR 0005: Retention and recovery

Observations are append-only in ordinary operation. Evidence is private and lifecycle-managed in R2. Batch
evidence and immutable release payloads transition to Infrequent Access after 30 days and expire after 400
days. Primary nightly D1 exports transition after 30 days and expire after 90 days; independently replicated
exports transition after 30 days and expire after 400 days. Incomplete multipart uploads abort after seven
days. The machine-readable policies live in `config/r2-lifecycle/` and are applied by
`scripts/apply-r2-lifecycle.ps1`.

Nightly D1 exports and quarterly restore drills are rollout gates; removal happens only through documented
archival workflows, never an application delete.

The Plan of Record called for a weekly second copy committed to git. This repository is public, and a D1
export contains operational provenance, audit identities, and private object references. Committing that dump
would contradict the same plan's rule that operational state does not enter git. V3 therefore uses a separate
private R2 bucket as the second failure domain, verifies the replicated object's size and readability, and
retains it longer. The quarterly restore drill separately verifies the export's recorded SHA-256 before it is
accepted. This is a deliberate security-strengthening substitution, not an omitted backup.
