-- @policy expand-contract
-- Renewable immutable direct-upload attempts, bounded cleanup state, and seal-time configuration pins.

ALTER TABLE capture_validation_jobs ADD COLUMN configuration_id TEXT;
ALTER TABLE capture_validation_jobs ADD COLUMN configuration_hash TEXT;

UPDATE capture_validation_jobs
   SET configuration_id = COALESCE(
         (SELECT run.configuration_id
            FROM match_runs run
           WHERE run.batch_id = capture_validation_jobs.batch_id
           ORDER BY run.created_at DESC, run.id DESC LIMIT 1),
         (SELECT id FROM configuration_versions WHERE active = 1 LIMIT 1)
       )
 WHERE configuration_id IS NULL;

UPDATE capture_validation_jobs
   SET configuration_hash = (
         SELECT version.content_hash
           FROM configuration_versions version
          WHERE version.id = capture_validation_jobs.configuration_id
       )
 WHERE configuration_hash IS NULL;

CREATE INDEX capture_validation_jobs_configuration_pipeline_idx
  ON capture_validation_jobs(configuration_id, pipeline_completed_at);

ALTER TABLE capture_evidence_upload_sessions ADD COLUMN cleaned_at TEXT;

CREATE TABLE capture_evidence_upload_attempts (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  requested_by TEXT NOT NULL,
  evidence_id TEXT NOT NULL,
  attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
  object_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('screenshot','flyer_page','raw_payload','manifest')),
  content_type TEXT NOT NULL,
  expected_sha256 TEXT NOT NULL,
  expected_md5 TEXT NOT NULL,
  expected_bytes INTEGER NOT NULL CHECK (expected_bytes > 0),
  status TEXT NOT NULL DEFAULT 'issued' CHECK (status IN ('issued','finalized','expired','rejected','cleaned')),
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finalized_at TEXT,
  cleaned_at TEXT,
  UNIQUE(batch_id, evidence_id, attempt_number)
) STRICT;

CREATE UNIQUE INDEX capture_evidence_upload_attempts_one_issued_idx
  ON capture_evidence_upload_attempts(batch_id, evidence_id)
  WHERE status = 'issued';

CREATE INDEX capture_evidence_upload_attempts_cleanup_idx
  ON capture_evidence_upload_attempts(status, cleaned_at, expires_at);

CREATE INDEX capture_evidence_upload_attempts_batch_idx
  ON capture_evidence_upload_attempts(batch_id, evidence_id, attempt_number DESC);
