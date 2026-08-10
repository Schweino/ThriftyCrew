-- @policy expand-contract
-- Hardening control plane: schedule lifecycle, agent registry/budgets,
-- immutable content batches, source sentinels, restore evidence and archive planning.

ALTER TABLE job_schedules ADD COLUMN lifecycle TEXT NOT NULL DEFAULT 'active'
  CHECK (lifecycle IN ('active', 'transition', 'retired'));
ALTER TABLE job_schedules ADD COLUMN authority_version INTEGER NOT NULL DEFAULT 1;
ALTER TABLE job_schedules ADD COLUMN retirement_gate TEXT;
ALTER TABLE job_schedules ADD COLUMN workflow_file TEXT;

ALTER TABLE job_runs ADD COLUMN agent_id TEXT;
ALTER TABLE job_runs ADD COLUMN ledger_mode TEXT NOT NULL DEFAULT 'normal'
  CHECK (ledger_mode IN ('normal', 'diagnostic'));
ALTER TABLE job_runs ADD COLUMN mutation_authorized INTEGER NOT NULL DEFAULT 1
  CHECK (mutation_authorized IN (0, 1));
ALTER TABLE job_runs ADD COLUMN estimated_cost_microusd INTEGER NOT NULL DEFAULT 0
  CHECK (estimated_cost_microusd >= 0);

CREATE TABLE agent_registry (
  id TEXT PRIMARY KEY,
  registry_version INTEGER NOT NULL CHECK (registry_version > 0),
  enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
  plane TEXT NOT NULL CHECK (plane IN ('ci', 'pc')),
  schedule_id TEXT REFERENCES job_schedules(job),
  prompt_file TEXT NOT NULL,
  prompt_sha256 TEXT NOT NULL,
  model_id TEXT NOT NULL,
  fallback_model_id TEXT,
  monthly_budget_microusd INTEGER NOT NULL CHECK (monthly_budget_microusd >= 0),
  criticality TEXT NOT NULL CHECK (criticality IN ('safety', 'operational', 'optional')),
  capabilities_json TEXT NOT NULL,
  input_contracts_json TEXT NOT NULL,
  output_contract TEXT NOT NULL,
  fixture_files_json TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  synced_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE agent_budget_months (
  agent_id TEXT NOT NULL REFERENCES agent_registry(id),
  month_key TEXT NOT NULL,
  spent_microusd INTEGER NOT NULL DEFAULT 0 CHECK (spent_microusd >= 0),
  reserved_microusd INTEGER NOT NULL DEFAULT 0 CHECK (reserved_microusd >= 0),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (agent_id, month_key)
) STRICT;

CREATE TABLE content_batches (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind = 'recipe-pack'),
  status TEXT NOT NULL DEFAULT 'staging'
    CHECK (status IN ('staging', 'audited', 'promoted', 'rejected')),
  input_hash TEXT NOT NULL,
  prompt_hash TEXT NOT NULL,
  source_refs_json TEXT NOT NULL,
  created_by TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  sealed_at TEXT,
  promoted_at TEXT,
  content_hash TEXT
) STRICT;

CREATE TABLE content_batch_items (
  batch_id TEXT NOT NULL REFERENCES content_batches(id),
  slug TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  content_json TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  PRIMARY KEY (batch_id, slug),
  UNIQUE (batch_id, ordinal)
) STRICT;

CREATE TABLE content_batch_audits (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES content_batches(id),
  auditor_agent_id TEXT NOT NULL,
  prompt_hash TEXT NOT NULL,
  findings_json TEXT NOT NULL,
  hard_findings INTEGER NOT NULL CHECK (hard_findings >= 0),
  warning_findings INTEGER NOT NULL CHECK (warning_findings >= 0),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE content_promotions (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL UNIQUE REFERENCES content_batches(id),
  promoted_by TEXT NOT NULL,
  deterministic_guard_version TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  detail_json TEXT NOT NULL DEFAULT '{}',
  promoted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TRIGGER content_items_immutable_after_staging
BEFORE UPDATE ON content_batch_items
WHEN (SELECT status FROM content_batches WHERE id = OLD.batch_id) <> 'staging'
BEGIN SELECT RAISE(ABORT, 'sealed content batch items are immutable'); END;

CREATE TRIGGER content_items_no_delete
BEFORE DELETE ON content_batch_items
BEGIN SELECT RAISE(ABORT, 'content batch items are immutable'); END;

CREATE TABLE source_sentinel_results (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES capture_sources(id),
  contract_version INTEGER NOT NULL CHECK (contract_version > 0),
  status TEXT NOT NULL CHECK (status IN ('pass', 'fail')),
  checks_json TEXT NOT NULL,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  observed_at TEXT NOT NULL,
  actor_id TEXT NOT NULL
) STRICT;

CREATE INDEX source_sentinel_source_time ON source_sentinel_results(source_id, observed_at DESC);

CREATE TABLE archival_forecasts (
  id TEXT PRIMARY KEY,
  database_bytes INTEGER NOT NULL CHECK (database_bytes >= 0),
  database_limit_bytes INTEGER NOT NULL CHECK (database_limit_bytes > 0),
  observation_count INTEGER NOT NULL CHECK (observation_count >= 0),
  monthly_growth_bytes INTEGER NOT NULL,
  oldest_observation_at TEXT,
  protected_observation_count INTEGER NOT NULL CHECK (protected_observation_count >= 0),
  threshold_percent INTEGER NOT NULL CHECK (threshold_percent BETWEEN 1 AND 99),
  usage_percent_millis INTEGER NOT NULL CHECK (usage_percent_millis >= 0),
  projected_limit_at TEXT,
  status TEXT NOT NULL CHECK (status IN ('healthy', 'armed', 'critical')),
  observed_at TEXT NOT NULL
) STRICT;

CREATE TABLE archive_manifests (
  id TEXT PRIMARY KEY,
  cutoff_at TEXT NOT NULL,
  object_key TEXT,
  format TEXT NOT NULL CHECK (format IN ('parquet')),
  row_count INTEGER NOT NULL DEFAULT 0 CHECK (row_count >= 0),
  byte_length INTEGER CHECK (byte_length IS NULL OR byte_length >= 0),
  sha256 TEXT,
  status TEXT NOT NULL CHECK (status IN ('planned', 'written', 'verified', 'failed')),
  protected_refs_hash TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  verified_at TEXT,
  detail_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE TABLE archive_manifest_observations (
  manifest_id TEXT NOT NULL REFERENCES archive_manifests(id),
  observation_id TEXT NOT NULL REFERENCES observations(id),
  PRIMARY KEY (manifest_id, observation_id)
) STRICT;

CREATE TRIGGER archive_manifest_rows_no_update
BEFORE UPDATE ON archive_manifest_observations
BEGIN SELECT RAISE(ABORT, 'archive manifest membership is immutable'); END;

CREATE TRIGGER archive_manifest_rows_no_delete
BEFORE DELETE ON archive_manifest_observations
BEGIN SELECT RAISE(ABORT, 'archive manifest membership is immutable'); END;
