# D1 backup and restore runbook

Production D1 is exported nightly by `D1BackupWorkflow` and written to `tc-grocery-v3-backups`. Sunday runs also copy the verified object to `tc-grocery-v3-backups-secondary`. The 15-minute Worker cron starts the Workflow at 04:30 America/Chicago because native Workflow schedules require a paid Workers plan.

Quarterly restore drill:

1. Select a `completed` backup from `backup_exports` and download its exact R2 object.
2. Record byte length and SHA-256 before importing.
3. Create an isolated D1 named `tc-grocery-v3-restore-drill-YYYYMMDD`.
4. Run `pnpm restore:prepare <dump.sql> <sanitized.sql> <recovery.json>`. D1 exports can contain a single SQL literal above the import API's statement limit; the command removes only those INSERT statements and converts their values to a parameterized recovery document.
5. Import `sanitized.sql` with `wrangler d1 execute <scratch-name> --remote --file <sanitized.sql>`.
6. Set `CLOUDFLARE_ACCOUNT_ID`, the scratch `D1_DATABASE_ID`, and `D1_REST_API_TOKEN`, then run `pnpm restore:rows <recovery.json>`.
7. Compare all core table counts and the current release ID/input hash between production and scratch. Record the result in `restore_drills`.
8. Delete only the explicitly named scratch D1 and local drill directory after the evidence row is durable.

Any failed export, replica, or restore creates or preserves evidence in D1; it must be triaged rather than erased.
