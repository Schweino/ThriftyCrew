-- @policy expand-contract
-- Content-addressed archives for superseded release guard evidence removed
-- from the live D1 triage queue after the same guard passes on the current release.

CREATE TABLE triage_archives (
  id TEXT PRIMARY KEY,
  current_release_id TEXT NOT NULL REFERENCES releases(id),
  object_key TEXT NOT NULL UNIQUE,
  content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  result_count INTEGER NOT NULL CHECK (result_count > 0),
  finding_count INTEGER NOT NULL CHECK (finding_count > 0),
  triage_count INTEGER NOT NULL CHECK (triage_count >= 0),
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  completed_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TRIGGER triage_archives_immutable
BEFORE UPDATE ON triage_archives
BEGIN SELECT RAISE(ABORT, 'triage archives are immutable'); END;

PRAGMA optimize;
