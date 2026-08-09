CREATE TABLE match_runs (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  input_hash TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('passed', 'failed')),
  product_count INTEGER NOT NULL CHECK (product_count >= 0),
  matched_count INTEGER NOT NULL CHECK (matched_count >= 0),
  unmatched_count INTEGER NOT NULL CHECK (unmatched_count >= 0),
  collision_count INTEGER NOT NULL CHECK (collision_count >= 0),
  aisle_rejected_count INTEGER NOT NULL CHECK (aisle_rejected_count >= 0),
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (batch_id, configuration_id, input_hash),
  CHECK (matched_count + unmatched_count + collision_count + aisle_rejected_count = product_count)
) STRICT;

CREATE INDEX match_runs_batch_time ON match_runs(batch_id, created_at DESC);

CREATE TABLE evidence_gate_events (
  id TEXT PRIMARY KEY,
  gate TEXT NOT NULL CHECK (gate IN (
    'shadow-ingest-day',
    'semantic-parity-day',
    'direct-chrome-week',
    'beta-release-day',
    'beta-week',
    'entitlement-state',
    'accuracy-week',
    'chaos-drill',
    'route-rollback'
  )),
  period_key TEXT NOT NULL,
  source_ref TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pass', 'fail')),
  evidence_json TEXT NOT NULL DEFAULT '{}',
  observed_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (gate, period_key, source_ref)
) STRICT;

CREATE INDEX evidence_gate_period ON evidence_gate_events(gate, period_key, status);
