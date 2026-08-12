-- @policy expand-contract
-- Incrementally populated semantic fingerprints keep historical compaction
-- bounded and indexed instead of recomputing large JSON keys in one D1 query.

CREATE TABLE observation_fingerprints (
  observation_id TEXT PRIMARY KEY REFERENCES observations(id),
  semantic_hash TEXT NOT NULL CHECK (length(semantic_hash) = 64)
) STRICT;

CREATE INDEX observation_fingerprints_semantic
  ON observation_fingerprints(semantic_hash, observation_id);

PRAGMA optimize;
