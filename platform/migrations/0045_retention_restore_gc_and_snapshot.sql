-- @policy expand-contract
-- Dependency-aware hot retention, two-phase reference-safe object collection,
-- transitive recovery evidence, and snapshot performance measurements.

CREATE TABLE r2_gc_runs (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('planned', 'sweeping', 'completed', 'failed')),
  grace_before TEXT NOT NULL,
  scanned_objects INTEGER NOT NULL DEFAULT 0 CHECK (scanned_objects >= 0),
  reachable_objects INTEGER NOT NULL DEFAULT 0 CHECK (reachable_objects >= 0),
  candidate_objects INTEGER NOT NULL DEFAULT 0 CHECK (candidate_objects >= 0),
  candidate_bytes INTEGER NOT NULL DEFAULT 0 CHECK (candidate_bytes >= 0),
  deleted_objects INTEGER NOT NULL DEFAULT 0 CHECK (deleted_objects >= 0),
  deleted_bytes INTEGER NOT NULL DEFAULT 0 CHECK (deleted_bytes >= 0),
  root_set_hash TEXT NOT NULL CHECK (length(root_set_hash) = 64),
  detail_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(detail_json)),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TEXT
) STRICT;

CREATE TABLE r2_gc_candidates (
  run_id TEXT NOT NULL REFERENCES r2_gc_runs(id),
  bucket TEXT NOT NULL CHECK (bucket IN ('archive', 'evidence')),
  object_key TEXT NOT NULL,
  content_hash TEXT CHECK (content_hash IS NULL OR length(content_hash) = 64),
  byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
  last_modified TEXT NOT NULL,
  reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'quarantined' CHECK (status IN ('quarantined', 'deleted', 'retained', 'missing')),
  marked_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  swept_at TEXT,
  PRIMARY KEY (run_id, bucket, object_key)
) STRICT;

CREATE INDEX r2_gc_candidates_sweep
  ON r2_gc_candidates(status, marked_at, run_id);

CREATE TABLE engine_snapshot_measurements (
  id TEXT PRIMARY KEY,
  input_hash TEXT NOT NULL CHECK (length(input_hash) = 64),
  release_id TEXT,
  encoding TEXT NOT NULL,
  matched_candidates INTEGER NOT NULL CHECK (matched_candidates >= 0),
  unmatched_candidates INTEGER NOT NULL CHECK (unmatched_candidates >= 0),
  response_bytes INTEGER NOT NULL CHECK (response_bytes >= 0),
  snapshot_fetch_ms INTEGER NOT NULL CHECK (snapshot_fetch_ms >= 0),
  native_build_ms INTEGER NOT NULL CHECK (native_build_ms >= 0),
  publish_ms INTEGER NOT NULL CHECK (publish_ms >= 0),
  total_ms INTEGER NOT NULL CHECK (total_ms >= 0),
  detail_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(detail_json)),
  measured_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE INDEX engine_snapshot_measurements_time
  ON engine_snapshot_measurements(measured_at DESC);

PRAGMA optimize;
