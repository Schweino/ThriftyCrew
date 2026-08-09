CREATE TABLE engine_parity_runs (
  id TEXT PRIMARY KEY,
  mode TEXT NOT NULL CHECK (mode IN ('legacy', 'direct', 'all')),
  current_release_id TEXT NOT NULL REFERENCES releases(id),
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  input_hash TEXT NOT NULL,
  input_batch_ids_json TEXT NOT NULL,
  compared_cells INTEGER NOT NULL CHECK (compared_cells >= 0),
  diff_count INTEGER NOT NULL CHECK (diff_count >= 0),
  status TEXT NOT NULL CHECK (status IN ('passed', 'failed')),
  detail_json TEXT NOT NULL DEFAULT '{}',
  observed_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (mode, current_release_id, input_hash, observed_at)
) STRICT;

CREATE INDEX engine_parity_time ON engine_parity_runs(mode, observed_at DESC);
