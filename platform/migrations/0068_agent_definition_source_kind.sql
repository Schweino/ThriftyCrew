-- @policy contract
-- @restore-proof d1-time-travel-and-agent-ledger
-- Ingredient definition is an explicit pre-pricing agent stage and must have
-- its own durable source kind instead of masquerading as recipe or release work.

PRAGMA defer_foreign_keys = ON;

CREATE TABLE agent_work_items_0068_new (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agent_registry(id),
  source_kind TEXT NOT NULL CHECK (source_kind IN ('triage-item', 'accuracy-draw', 'recipe-request', 'ingredient-definition', 'source-sentinel-result', 'release-status')),
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

INSERT INTO agent_work_items_0068_new SELECT * FROM agent_work_items;
DROP TABLE agent_work_items;
ALTER TABLE agent_work_items_0068_new RENAME TO agent_work_items;

CREATE INDEX agent_work_items_claim ON agent_work_items(agent_id, state, available_at, created_at);
CREATE INDEX agent_work_items_source ON agent_work_items(source_kind, source_ref, stage);

PRAGMA foreign_key_check;
PRAGMA optimize;
