-- @policy expand-contract
-- Immutable, content-addressed engine candidate shards. D1 keeps only the
-- small lookup catalog while candidate payloads live in R2.

CREATE TABLE engine_snapshot_shards (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  match_run_id TEXT NOT NULL REFERENCES match_runs(id),
  match_input_hash TEXT NOT NULL CHECK (length(match_input_hash) = 64),
  content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
  object_key TEXT NOT NULL UNIQUE,
  matched_candidates INTEGER NOT NULL CHECK (matched_candidates >= 0),
  unmatched_candidates INTEGER NOT NULL CHECK (unmatched_candidates >= 0),
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  status TEXT NOT NULL DEFAULT 'verified' CHECK (status IN ('verified', 'collected')),
  verified_at TEXT NOT NULL,
  collected_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (batch_id, configuration_id, match_run_id),
  CHECK (status = 'verified' OR collected_at IS NOT NULL)
) STRICT;

CREATE INDEX engine_snapshot_shards_lookup
  ON engine_snapshot_shards(batch_id, configuration_id, match_run_id, status);

CREATE TRIGGER engine_snapshot_shards_identity_immutable
BEFORE UPDATE OF batch_id, configuration_id, match_run_id, match_input_hash, content_hash, object_key,
                 matched_candidates, unmatched_candidates, byte_length, schema_version
ON engine_snapshot_shards
BEGIN SELECT RAISE(ABORT, 'engine snapshot shard identity is immutable'); END;

PRAGMA optimize;
