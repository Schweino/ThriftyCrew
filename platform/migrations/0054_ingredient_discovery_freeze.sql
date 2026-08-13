-- @policy expand-contract

ALTER TABLE ingredient_discovery_batches ADD COLUMN discovery_frozen_at TEXT;

ALTER TABLE ingredient_gaps ADD COLUMN qa_attempts INTEGER NOT NULL DEFAULT 0;

ALTER TABLE ingredient_gaps ADD COLUMN qa_resolution TEXT
  CHECK (qa_resolution IS NULL OR qa_resolution IN ('existing_alias', 'excluded_noncommodity'));

ALTER TABLE ingredient_gaps ADD COLUMN qa_resolution_commodity_id TEXT;

ALTER TABLE ingredient_gaps ADD COLUMN qa_resolved_at TEXT;
