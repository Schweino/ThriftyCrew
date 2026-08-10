-- @policy expand-contract
-- Phase 2 agent execution plane: exact OIDC identity, semantic evaluation,
-- fenced work-item leases, split routine/reserve budgets, recipe waves, and
-- login-canary evidence. All changes are additive.

ALTER TABLE agent_registry ADD COLUMN provider TEXT NOT NULL DEFAULT 'openai';
ALTER TABLE agent_registry ADD COLUMN reasoning_effort TEXT NOT NULL DEFAULT 'medium'
  CHECK (reasoning_effort IN ('none', 'low', 'medium', 'high', 'xhigh', 'max'));
ALTER TABLE agent_registry ADD COLUMN reserve_budget_percent INTEGER NOT NULL DEFAULT 0
  CHECK (reserve_budget_percent BETWEEN 0 AND 100);
ALTER TABLE agent_registry ADD COLUMN workflow_ref TEXT;
ALTER TABLE agent_registry ADD COLUMN reusable_workflow_ref TEXT;
ALTER TABLE agent_registry ADD COLUMN execution_config_hash TEXT;

ALTER TABLE agent_budget_months ADD COLUMN routine_spent_microusd INTEGER NOT NULL DEFAULT 0
  CHECK (routine_spent_microusd >= 0);
ALTER TABLE agent_budget_months ADD COLUMN reserve_spent_microusd INTEGER NOT NULL DEFAULT 0
  CHECK (reserve_spent_microusd >= 0);
ALTER TABLE agent_budget_months ADD COLUMN routine_reserved_microusd INTEGER NOT NULL DEFAULT 0
  CHECK (routine_reserved_microusd >= 0);
ALTER TABLE agent_budget_months ADD COLUMN reserve_reserved_microusd INTEGER NOT NULL DEFAULT 0
  CHECK (reserve_reserved_microusd >= 0);
ALTER TABLE job_runs ADD COLUMN budget_class TEXT CHECK (budget_class IS NULL OR budget_class IN ('routine', 'reserve'));

CREATE TABLE agent_evaluations (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agent_registry(id),
  execution_config_hash TEXT NOT NULL,
  model_id TEXT NOT NULL,
  corpus_hash TEXT NOT NULL,
  evaluator_version TEXT NOT NULL,
  case_count INTEGER NOT NULL CHECK (case_count > 0),
  passed_count INTEGER NOT NULL CHECK (passed_count >= 0),
  score_millis INTEGER NOT NULL CHECK (score_millis BETWEEN 0 AND 1000),
  threshold_millis INTEGER NOT NULL CHECK (threshold_millis BETWEEN 0 AND 1000),
  passed INTEGER NOT NULL CHECK (passed IN (0, 1)),
  detail_json TEXT NOT NULL,
  evaluated_at TEXT NOT NULL,
  actor_id TEXT NOT NULL
) STRICT;

CREATE INDEX agent_evaluations_gate
  ON agent_evaluations(agent_id, execution_config_hash, passed, evaluated_at DESC);

CREATE TABLE agent_work_items (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agent_registry(id),
  source_kind TEXT NOT NULL CHECK (source_kind IN ('triage-item', 'accuracy-draw', 'recipe-request', 'source-sentinel-result', 'release-status')),
  source_ref TEXT NOT NULL,
  stage TEXT NOT NULL,
  adapter_version TEXT NOT NULL,
  input_contract TEXT NOT NULL,
  output_contract TEXT NOT NULL,
  execution_config_hash TEXT NOT NULL,
  execution_fingerprint TEXT NOT NULL UNIQUE,
  severity TEXT NOT NULL CHECK (severity IN ('safety', 'operational', 'optional')),
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued', 'leased', 'completed', 'retryable', 'deadletter', 'cancelled')),
  input_json TEXT NOT NULL,
  output_json TEXT,
  lease_id TEXT,
  lease_generation INTEGER NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
  lease_expires_at TEXT,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  max_attempts INTEGER NOT NULL DEFAULT 3 CHECK (max_attempts BETWEEN 1 AND 10),
  available_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TEXT,
  last_error TEXT,
  github_run_id TEXT
) STRICT;

CREATE INDEX agent_work_items_claim
  ON agent_work_items(agent_id, state, available_at, created_at);
CREATE INDEX agent_work_items_source
  ON agent_work_items(source_kind, source_ref, stage);

CREATE TABLE agent_work_item_attempts (
  id TEXT PRIMARY KEY,
  work_item_id TEXT NOT NULL REFERENCES agent_work_items(id),
  lease_id TEXT NOT NULL,
  lease_generation INTEGER NOT NULL CHECK (lease_generation > 0),
  github_run_id TEXT,
  status TEXT NOT NULL CHECK (status IN ('leased', 'completed', 'failed', 'late-discarded')),
  input_hash TEXT NOT NULL,
  output_hash TEXT,
  detail_json TEXT NOT NULL DEFAULT '{}',
  started_at TEXT NOT NULL,
  finished_at TEXT,
  UNIQUE (work_item_id, lease_generation)
) STRICT;

CREATE TABLE recipe_suggestion_requests (
  id TEXT PRIMARY KEY,
  request_text TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'running', 'staged', 'reviewed', 'promoted', 'rejected')),
  work_item_id TEXT REFERENCES agent_work_items(id),
  content_batch_id TEXT REFERENCES content_batches(id),
  requested_at TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE recipe_wave_runs (
  id TEXT PRIMARY KEY,
  content_batch_id TEXT NOT NULL REFERENCES content_batches(id),
  pre_wave_release_id TEXT NOT NULL REFERENCES releases(id),
  wave_release_id TEXT REFERENCES releases(id),
  corrective_release_id TEXT REFERENCES releases(id),
  snapshot_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('snapshotted', 'published', 'corrective_draft', 'corrected', 'accepted', 'failed')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE login_canary_probes (
  id TEXT PRIMARY KEY,
  store_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal IN (1, 2)),
  status TEXT NOT NULL CHECK (status IN ('healthy', 'expired', 'inconclusive')),
  signal TEXT NOT NULL,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  observed_at TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  UNIQUE (run_id, store_id, ordinal)
) STRICT;

CREATE INDEX login_canary_latest ON login_canary_probes(store_id, observed_at DESC);
