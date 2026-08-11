-- @policy expand-contract
-- D1 Time Travel supplies continuous recovery for 30 days on Workers Paid.
-- Record a small, verified recovery manifest daily and reserve blocking SQL
-- exports for weekly long-term/off-platform recovery.

CREATE TABLE recovery_checkpoints (
  id TEXT PRIMARY KEY,
  database_id TEXT NOT NULL,
  bookmark TEXT,
  release_id TEXT REFERENCES releases(id),
  configuration_id TEXT REFERENCES configuration_versions(id),
  source_commit TEXT NOT NULL,
  object_key TEXT,
  byte_length INTEGER CHECK (byte_length IS NULL OR byte_length >= 0),
  sha256 TEXT,
  status TEXT NOT NULL CHECK (status IN ('started', 'verified', 'failed')),
  created_at TEXT NOT NULL,
  verified_at TEXT,
  detail_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE INDEX recovery_checkpoints_time ON recovery_checkpoints(created_at DESC);

INSERT INTO job_schedules
  (job, cron, max_gap_minutes, active, executor, authority_executor, timezone, owner,
   proof, dispatch_on_gap, lifecycle, authority_version, lease_minutes, monitoring_started_at)
VALUES
  ('d1-recovery-checkpoint', '30 4 * * *', 1560, 1, 'worker-cron', 'worker-cron',
   'America/Chicago', 'platform', 'recovery_checkpoints:verified', 0, 'active', 8, 30, CURRENT_TIMESTAMP)
ON CONFLICT(job) DO UPDATE SET
  cron = excluded.cron,
  max_gap_minutes = excluded.max_gap_minutes,
  active = 1,
  executor = excluded.executor,
  authority_executor = excluded.authority_executor,
  timezone = excluded.timezone,
  owner = excluded.owner,
  proof = excluded.proof,
  dispatch_on_gap = excluded.dispatch_on_gap,
  lifecycle = excluded.lifecycle,
  authority_version = excluded.authority_version,
  lease_minutes = excluded.lease_minutes,
  monitoring_started_at = CURRENT_TIMESTAMP;

UPDATE job_schedules
   SET cron = '30 1 * * 0',
       max_gap_minutes = 11520,
       proof = 'backup_exports:completed-weekly',
       authority_version = 8,
       monitoring_started_at = CURRENT_TIMESTAMP
 WHERE job = 'd1-backup';
