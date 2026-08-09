-- V3 operations: executable schedule authority, reproducible run ledger,
-- audit identity, watchdog dispatches, backup evidence, and entitlement proof.

ALTER TABLE job_schedules ADD COLUMN executor TEXT NOT NULL DEFAULT 'github-actions'
  CHECK (executor IN ('github-actions', 'worker-cron', 'cloudflare-workflow', 'pc'));
ALTER TABLE job_schedules ADD COLUMN timezone TEXT NOT NULL DEFAULT 'America/Chicago';
ALTER TABLE job_schedules ADD COLUMN owner TEXT NOT NULL DEFAULT 'platform';
ALTER TABLE job_schedules ADD COLUMN proof TEXT NOT NULL DEFAULT 'job_runs';
ALTER TABLE job_schedules ADD COLUMN dispatch_on_gap INTEGER NOT NULL DEFAULT 0
  CHECK (dispatch_on_gap IN (0, 1));

ALTER TABLE job_runs ADD COLUMN executor_run_id TEXT;
ALTER TABLE job_runs ADD COLUMN actor_id TEXT;
ALTER TABLE job_runs ADD COLUMN heartbeat_at TEXT;
ALTER TABLE job_runs ADD COLUMN prompt_hash TEXT;
ALTER TABLE job_runs ADD COLUMN input_hash TEXT;
ALTER TABLE job_runs ADD COLUMN output_hash TEXT;
ALTER TABLE job_runs ADD COLUMN model_id TEXT;
ALTER TABLE job_runs ADD COLUMN input_tokens INTEGER NOT NULL DEFAULT 0 CHECK (input_tokens >= 0);
ALTER TABLE job_runs ADD COLUMN output_tokens INTEGER NOT NULL DEFAULT 0 CHECK (output_tokens >= 0);
ALTER TABLE job_runs ADD COLUMN cache_read_tokens INTEGER NOT NULL DEFAULT 0 CHECK (cache_read_tokens >= 0);
ALTER TABLE job_runs ADD COLUMN cache_write_tokens INTEGER NOT NULL DEFAULT 0 CHECK (cache_write_tokens >= 0);
ALTER TABLE job_runs ADD COLUMN cost_microusd INTEGER NOT NULL DEFAULT 0 CHECK (cost_microusd >= 0);

CREATE UNIQUE INDEX one_scheduled_run_per_tick
  ON job_runs(job, scheduled_for)
  WHERE scheduled_for IS NOT NULL AND trigger_kind = 'schedule';

CREATE TABLE audit_events (
  id TEXT PRIMARY KEY,
  actor_id TEXT NOT NULL,
  auth_method TEXT NOT NULL,
  action TEXT NOT NULL,
  resource_kind TEXT NOT NULL,
  resource_id TEXT,
  outcome TEXT NOT NULL CHECK (outcome IN ('accepted', 'rejected', 'failed')),
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE INDEX audit_events_actor_time ON audit_events(actor_id, created_at DESC);
CREATE INDEX audit_events_resource ON audit_events(resource_kind, resource_id, created_at DESC);

CREATE TABLE watchdog_dispatches (
  id TEXT PRIMARY KEY,
  job TEXT NOT NULL REFERENCES job_schedules(job),
  idempotency_key TEXT NOT NULL UNIQUE,
  reason TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('started', 'dispatched', 'failed', 'suppressed')),
  external_run_url TEXT,
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT
) STRICT;

CREATE INDEX watchdog_dispatches_job_time ON watchdog_dispatches(job, created_at DESC);

CREATE TABLE alert_deliveries (
  id TEXT PRIMARY KEY,
  alert_key TEXT NOT NULL,
  channel TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('started', 'delivered', 'failed', 'suppressed')),
  attempt INTEGER NOT NULL DEFAULT 1 CHECK (attempt > 0),
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  UNIQUE (alert_key, channel, attempt)
) STRICT;

CREATE INDEX alert_deliveries_key_time ON alert_deliveries(alert_key, created_at DESC);

CREATE TABLE backup_exports (
  id TEXT PRIMARY KEY,
  database_id TEXT NOT NULL,
  bookmark TEXT,
  object_key TEXT,
  byte_length INTEGER CHECK (byte_length IS NULL OR byte_length >= 0),
  status TEXT NOT NULL CHECK (status IN ('started', 'completed', 'failed', 'restored')),
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  detail_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE INDEX backup_exports_time ON backup_exports(started_at DESC);

CREATE TABLE entitlement_verifications (
  id TEXT PRIMARY KEY,
  adapter_version TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('anonymous', 'free', 'paid', 'expired', 'cancelled', 'signed_out', 'cookie_expired')),
  client_kind TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pass', 'fail')),
  evidence_json TEXT NOT NULL DEFAULT '{}',
  verified_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  verified_by TEXT NOT NULL
) STRICT;

UPDATE job_schedules SET active = 0 WHERE job = 'capture-watchdog';

INSERT INTO job_schedules (job, cron, max_gap_minutes, active, executor, timezone, owner, proof, dispatch_on_gap)
VALUES
  ('ledger-watchdog', '*/15 * * * *', 30, 1, 'worker-cron', 'America/Chicago', 'platform', 'job_runs:ledger-watchdog', 0)
ON CONFLICT(job) DO UPDATE SET
  cron = excluded.cron, max_gap_minutes = excluded.max_gap_minutes, active = 1,
  executor = excluded.executor, timezone = excluded.timezone, owner = excluded.owner,
  proof = excluded.proof, dispatch_on_gap = excluded.dispatch_on_gap;

UPDATE job_schedules SET
  executor = 'cloudflare-workflow', timezone = 'America/Chicago', owner = 'platform',
  proof = 'backup_exports:completed', dispatch_on_gap = 0
WHERE job = 'd1-backup';

UPDATE job_schedules SET
  executor = 'github-actions', timezone = 'America/Chicago', dispatch_on_gap = 1
WHERE job IN ('daily-engine', 'accuracy-weekly', 'triage-daily', 'ghost-rotation-reconcile');
