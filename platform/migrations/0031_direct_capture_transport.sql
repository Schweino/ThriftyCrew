-- @policy expand-contract
CREATE TABLE capture_evidence_upload_sessions (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  requested_by TEXT NOT NULL,
  evidence_id TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('screenshot','flyer_page','raw_payload','manifest')),
  content_type TEXT NOT NULL,
  expected_sha256 TEXT NOT NULL,
  expected_md5 TEXT NOT NULL,
  expected_bytes INTEGER NOT NULL CHECK (expected_bytes > 0),
  status TEXT NOT NULL DEFAULT 'issued' CHECK (status IN ('issued','finalized','expired','rejected')),
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finalized_at TEXT,
  UNIQUE(batch_id, evidence_id)
);

CREATE INDEX capture_evidence_upload_sessions_batch_status_idx
  ON capture_evidence_upload_sessions(batch_id, status, expires_at);

ALTER TABLE capture_validation_jobs ADD COLUMN pipeline_stage TEXT NOT NULL DEFAULT 'validation';
ALTER TABLE capture_validation_jobs ADD COLUMN match_run_id TEXT;
ALTER TABLE capture_validation_jobs ADD COLUMN promoted_at TEXT;
ALTER TABLE capture_validation_jobs ADD COLUMN pipeline_completed_at TEXT;

ALTER TABLE commodities ADD COLUMN match_priority INTEGER NOT NULL DEFAULT 0;
UPDATE commodities
   SET match_priority = (
     SELECT COUNT(*) FROM commodities ordered
      WHERE ordered.configuration_id = commodities.configuration_id
        AND ordered.rowid >= commodities.rowid
   );
