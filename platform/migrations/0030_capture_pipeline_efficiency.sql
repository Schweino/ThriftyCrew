-- @policy expand-contract
-- Durable asynchronous capture validation plus product-centric efficiency telemetry.

CREATE TABLE capture_validation_jobs (
  batch_id TEXT PRIMARY KEY REFERENCES capture_batches(id),
  workflow_instance_id TEXT NOT NULL UNIQUE,
  requested_by TEXT NOT NULL,
  seal_json TEXT NOT NULL CHECK (json_valid(seal_json)),
  status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'completed', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  result_status TEXT,
  error TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  started_at TEXT,
  completed_at TEXT
) STRICT;

CREATE INDEX capture_validation_jobs_status ON capture_validation_jobs(status, created_at);

ALTER TABLE browser_capture_metrics ADD COLUMN unique_products INTEGER NOT NULL DEFAULT 0 CHECK (unique_products >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN discovery_edges INTEGER NOT NULL DEFAULT 0 CHECK (discovery_edges >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN duplicate_product_references INTEGER NOT NULL DEFAULT 0 CHECK (duplicate_product_references >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN product_reads_required INTEGER NOT NULL DEFAULT 0 CHECK (product_reads_required >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN verification_reuse INTEGER NOT NULL DEFAULT 0 CHECK (verification_reuse >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN immutable_shard_count INTEGER NOT NULL DEFAULT 0 CHECK (immutable_shard_count >= 0);
