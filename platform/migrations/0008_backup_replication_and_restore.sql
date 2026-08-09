CREATE TABLE backup_replicas (
  id TEXT PRIMARY KEY,
  backup_id TEXT NOT NULL REFERENCES backup_exports(id),
  bucket TEXT NOT NULL,
  object_key TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
  etag TEXT,
  status TEXT NOT NULL CHECK (status IN ('started', 'completed', 'failed')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  detail_json TEXT NOT NULL DEFAULT '{}',
  UNIQUE (backup_id, bucket)
) STRICT;

CREATE INDEX backup_replicas_time ON backup_replicas(created_at DESC);

CREATE TABLE restore_drills (
  id TEXT PRIMARY KEY,
  backup_id TEXT NOT NULL REFERENCES backup_exports(id),
  scratch_database_id TEXT NOT NULL,
  dump_sha256 TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('started', 'passed', 'failed')),
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  evidence_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE INDEX restore_drills_time ON restore_drills(started_at DESC);
