-- @policy expand-contract
-- Separate long-running ingredient research from batched publication and give
-- discovery runs a durable published-ingredient target.

ALTER TABLE ingredient_discovery_batches ADD COLUMN target_published_ingredients INTEGER NOT NULL DEFAULT 50
  CHECK (target_published_ingredients BETWEEN 1 AND 500);
ALTER TABLE ingredient_discovery_batches ADD COLUMN desired_pricing_workers INTEGER NOT NULL DEFAULT 10
  CHECK (desired_pricing_workers BETWEEN 1 AND 10);
ALTER TABLE ingredient_discovery_batches ADD COLUMN publish_batch_size INTEGER NOT NULL DEFAULT 20
  CHECK (publish_batch_size BETWEEN 1 AND 50);
ALTER TABLE ingredient_discovery_batches ADD COLUMN paused_at TEXT;
ALTER TABLE ingredient_discovery_batches ADD COLUMN last_publication_at TEXT;

ALTER TABLE ingredient_gaps ADD COLUMN publication_attempts INTEGER NOT NULL DEFAULT 0
  CHECK (publication_attempts >= 0);
ALTER TABLE ingredient_gaps ADD COLUMN publication_error TEXT;

PRAGMA optimize;
