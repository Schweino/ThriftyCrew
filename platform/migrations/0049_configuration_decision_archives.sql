-- @policy expand-contract
-- Preserve configuration-scoped match history in R2 before removing it from
-- the bounded D1 working set.

CREATE TABLE configuration_decision_archives (
  configuration_id TEXT PRIMARY KEY REFERENCES configuration_versions(id),
  object_key TEXT NOT NULL UNIQUE,
  content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  decision_count INTEGER NOT NULL CHECK (decision_count >= 0),
  verified_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

PRAGMA optimize;
