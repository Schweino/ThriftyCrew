-- @policy expand-contract
-- One immutable, compact performance summary per browser capture batch.

CREATE TABLE browser_capture_metrics (
  batch_id TEXT PRIMARY KEY REFERENCES capture_batches(id),
  session_id TEXT NOT NULL UNIQUE,
  source_id TEXT NOT NULL REFERENCES capture_sources(id),
  cycle_start TEXT NOT NULL,
  coverage_mode TEXT NOT NULL CHECK (coverage_mode IN ('full', 'partial', 'targeted', 'ad_only')),
  expected_terms INTEGER NOT NULL CHECK (expected_terms > 0),
  attempted_terms INTEGER NOT NULL CHECK (attempted_terms >= 0),
  success_terms INTEGER NOT NULL CHECK (success_terms >= 0),
  empty_terms INTEGER NOT NULL CHECK (empty_terms >= 0),
  rejected_terms INTEGER NOT NULL CHECK (rejected_terms >= 0),
  blocked_terms INTEGER NOT NULL CHECK (blocked_terms >= 0),
  not_attempted_terms INTEGER NOT NULL CHECK (not_attempted_terms >= 0),
  retry_count INTEGER NOT NULL CHECK (retry_count >= 0),
  chunk_count INTEGER NOT NULL CHECK (chunk_count > 0),
  duration_ms INTEGER NOT NULL CHECK (duration_ms >= 0),
  term_duration_p50_ms INTEGER NOT NULL CHECK (term_duration_p50_ms >= 0),
  term_duration_p95_ms INTEGER NOT NULL CHECK (term_duration_p95_ms >= 0),
  projected_rows INTEGER NOT NULL CHECK (projected_rows >= 0),
  observation_count INTEGER NOT NULL CHECK (observation_count >= 0),
  taxonomy_rows INTEGER NOT NULL CHECK (taxonomy_rows >= 0 AND taxonomy_rows <= observation_count),
  recorded_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (attempted_terms + not_attempted_terms = expected_terms),
  CHECK (success_terms + empty_terms + rejected_terms + blocked_terms = attempted_terms)
) STRICT;

CREATE INDEX browser_capture_metrics_source_cycle ON browser_capture_metrics(source_id, cycle_start DESC);

CREATE TRIGGER browser_capture_metrics_no_update
BEFORE UPDATE ON browser_capture_metrics
BEGIN
  SELECT RAISE(ABORT, 'browser capture metrics are immutable');
END;

CREATE TRIGGER browser_capture_metrics_no_delete
BEFORE DELETE ON browser_capture_metrics
BEGIN
  SELECT RAISE(ABORT, 'browser capture metrics are immutable');
END;
