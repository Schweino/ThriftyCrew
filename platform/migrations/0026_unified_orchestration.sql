-- @policy expand-contract
-- One concurrency authority across PC jobs, Worker cron, and Cloudflare Workflows.

ALTER TABLE job_schedules ADD COLUMN lease_minutes INTEGER NOT NULL DEFAULT 180
  CHECK (lease_minutes BETWEEN 1 AND 10080);

ALTER TABLE job_runs ADD COLUMN lease_resource TEXT;
ALTER TABLE job_runs ADD COLUMN lease_fence INTEGER
  CHECK (lease_fence IS NULL OR lease_fence > 0);

CREATE TABLE operation_leases (
  resource TEXT PRIMARY KEY,
  holder_id TEXT NOT NULL,
  owner_kind TEXT NOT NULL CHECK (owner_kind IN ('job', 'workflow', 'deployment', 'maintenance')),
  fence INTEGER NOT NULL CHECK (fence > 0),
  acquired_at TEXT NOT NULL,
  heartbeat_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  released_at TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  CHECK (expires_at > acquired_at),
  CHECK (released_at IS NULL OR released_at >= acquired_at)
) STRICT;

CREATE INDEX operation_leases_active
  ON operation_leases(expires_at, resource)
  WHERE released_at IS NULL;

CREATE TABLE deployment_checks (
  id TEXT PRIMARY KEY,
  source_commit TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('clear', 'blocked')),
  blocker_count INTEGER NOT NULL CHECK (blocker_count >= 0),
  blockers_json TEXT NOT NULL DEFAULT '[]',
  checked_at TEXT NOT NULL
) STRICT;

CREATE INDEX deployment_checks_time ON deployment_checks(checked_at DESC);

CREATE TABLE configuration_archives (
  configuration_id TEXT PRIMARY KEY REFERENCES configuration_versions(id),
  content_hash TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  sha256 TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('written', 'verified', 'failed')),
  written_at TEXT NOT NULL,
  verified_at TEXT,
  detail_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE TABLE match_rule_definitions (
  id TEXT PRIMARY KEY,
  commodity_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('include', 'exclude')),
  pattern TEXT NOT NULL,
  reason TEXT NOT NULL,
  priority INTEGER NOT NULL DEFAULT 0,
  UNIQUE (commodity_id, kind, pattern, reason, priority)
) STRICT;

CREATE TABLE configuration_match_rules (
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  definition_id TEXT NOT NULL REFERENCES match_rule_definitions(id),
  PRIMARY KEY (configuration_id, definition_id)
) STRICT;

CREATE INDEX configuration_match_rules_definition ON configuration_match_rules(definition_id);

CREATE TABLE configuration_compactions (
  configuration_id TEXT PRIMARY KEY REFERENCES configuration_versions(id),
  archive_sha256 TEXT NOT NULL,
  legacy_rule_rows INTEGER NOT NULL CHECK (legacy_rule_rows >= 0),
  membership_rows INTEGER NOT NULL CHECK (membership_rows >= 0),
  compacted_by TEXT NOT NULL,
  compacted_at TEXT NOT NULL,
  detail_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE TABLE transition_retirements (
  schedule_id TEXT PRIMARY KEY REFERENCES job_schedules(job),
  retirement_gate TEXT NOT NULL,
  evidence_json TEXT NOT NULL,
  retired_by TEXT NOT NULL,
  retired_at TEXT NOT NULL
) STRICT;

CREATE TABLE control_plane_proofs (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('pass', 'fail')),
  source_commit TEXT NOT NULL,
  checks_json TEXT NOT NULL,
  observed_at TEXT NOT NULL
) STRICT;

CREATE INDEX control_plane_proofs_time ON control_plane_proofs(observed_at DESC);
