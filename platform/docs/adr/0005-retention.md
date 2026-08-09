# ADR 0005: Retention and recovery

Observations are append-only in ordinary operation. Evidence is private and lifecycle-managed in R2. Nightly
D1 exports and quarterly restore drills are rollout gates; removal happens only through documented archival
workflows, never an application delete.
