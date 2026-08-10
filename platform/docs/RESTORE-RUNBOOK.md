# D1 backup and restore runbook

Production D1 is exported nightly by `D1BackupWorkflow` and written to `tc-grocery-v3-backups`. Sunday runs also copy the verified object to `tc-grocery-v3-backups-secondary`. The 15-minute Worker cron starts the Workflow at 04:30 America/Chicago because native Workflow schedules require a paid Workers plan.

Quarterly restore drill (automated by `platform-restore.yml` and `D1RestoreDrillWorkflow`):

1. Trigger `pnpm tc restore trigger`, or allow the quarterly GitHub schedule to call it using GitHub OIDC.
2. The Workflow selects the latest `completed` backup and reads its exact R2 object.
3. It creates an isolated, explicitly named D1 through the scoped D1 REST token and imports the SQL using the
   D1 import init/upload/ingest/poll protocol.
4. It compares `capture_batches`, `observations`, `products`, `releases`, `release_cells`, and `job_runs`, then
   compares the current release ID and input hash.
5. It writes a terminal `restore_drills` record before deleting only the returned scratch database UUID.

Manual fallback:

1. Select a `completed` backup from `backup_exports` and download its exact R2 object.
2. Record byte length and SHA-256 before importing.
3. Create an isolated D1 named `tc-grocery-v3-restore-drill-YYYYMMDD`.
4. Run `pnpm restore:prepare <dump.sql> <sanitized.sql> <recovery.json>`.
5. Import `sanitized.sql`, restore parameterized recovery rows, compare the automated drill's core checks, record
   the result, then delete only the explicit scratch UUID after evidence is durable.

Any failed export, replica, or restore creates or preserves evidence in D1; it must be triaged rather than erased.
