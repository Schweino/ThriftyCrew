-- @policy expand-contract
-- Verified, reversible-before-delete canonical compaction workflow.

CREATE TABLE canonical_cleanup_runs (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL CHECK (status IN ('planned', 'verified', 'completed', 'failed')),
  row_count INTEGER NOT NULL CHECK (row_count > 0),
  protected_refs_hash TEXT NOT NULL,
  object_key TEXT,
  byte_length INTEGER CHECK (byte_length IS NULL OR byte_length > 0),
  sha256 TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  verified_at TEXT,
  completed_at TEXT,
  detail_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(detail_json))
) STRICT;

-- Intentionally no foreign keys: this immutable ledger remains after duplicate
-- facts are deleted and is the durable R2 restoration index.
CREATE TABLE canonical_cleanup_rows (
  run_id TEXT NOT NULL REFERENCES canonical_cleanup_runs(id),
  duplicate_observation_id TEXT NOT NULL,
  canonical_observation_id TEXT NOT NULL,
  semantic_key TEXT NOT NULL,
  PRIMARY KEY (run_id, duplicate_observation_id)
) STRICT;

CREATE UNIQUE INDEX canonical_cleanup_duplicate_once
  ON canonical_cleanup_rows(duplicate_observation_id);

CREATE TABLE maintenance_leases (
  kind TEXT PRIMARY KEY CHECK (kind IN ('canonical-cleanup')),
  run_id TEXT NOT NULL,
  expires_at TEXT NOT NULL
) STRICT;

DROP TRIGGER observations_no_delete;
CREATE TRIGGER observations_no_delete
BEFORE DELETE ON observations
WHEN NOT EXISTS (
  SELECT 1 FROM maintenance_leases
   WHERE kind = 'canonical-cleanup' AND expires_at > CURRENT_TIMESTAMP
)
BEGIN
  SELECT RAISE(ABORT, 'observations are append-only; verified canonical cleanup lease required');
END;

PRAGMA optimize;
