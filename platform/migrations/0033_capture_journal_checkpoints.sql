-- @policy expand-contract
CREATE TABLE capture_journal_checkpoints (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  ciphertext_sha256 TEXT NOT NULL,
  plaintext_sha256 TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  journal_schema INTEGER NOT NULL CHECK (journal_schema > 0),
  created_at TEXT NOT NULL,
  verified_at TEXT NOT NULL
) STRICT;

CREATE INDEX capture_journal_checkpoints_agent_time_idx
  ON capture_journal_checkpoints(agent_id, created_at DESC);
