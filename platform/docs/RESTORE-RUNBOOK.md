# D1 backup and restore runbook

Production D1 uses Cloudflare Time Travel for continuous point-in-time recovery within the Workers Paid 30-day window. At 04:30 America/Chicago, the Worker records the current Time Travel bookmark and current release/configuration pointers in a content-addressed R2 manifest, then reads the complete object back and verifies its SHA-256. This checkpoint does not invoke D1 export and does not create a maintenance window.

For recovery beyond the Time Travel window and independent SQL portability, `D1BackupWorkflow` performs one full export at 01:30 America/Chicago each Sunday. The verified SQL object is written to `tc-grocery-v3-backups` and copied to `tc-grocery-v3-backups-secondary`. D1 export can block other database requests while Cloudflare prepares it, so ad-hoc full exports require an explicit operator command and must be treated as maintenance.

Preferred recovery order:

1. For an incident within 30 days, select the exact `verified` row in `recovery_checkpoints` and restore its bookmark with D1 Time Travel.
2. For older recovery or an independent validation, restore the latest verified weekly SQL export into an isolated scratch D1.
3. Never restore production in place until the chosen bookmark/export and expected release/configuration IDs have been reviewed.

Quarterly restore drill (automated by `platform-restore.yml` and `D1RestoreDrillWorkflow`):

1. Trigger `pnpm tc restore trigger`; GitHub Actions remains a manual fallback and is not a recurring scheduler.
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

Any failed checkpoint, export, replica, or restore creates or preserves evidence in D1; it must be triaged rather than erased.
