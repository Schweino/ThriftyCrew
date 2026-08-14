-- @policy expand-contract
-- Crash-safe ingredient publication receipts and exact public projections.

ALTER TABLE ingredient_publication_members ADD COLUMN expected_public_projection_json TEXT;
ALTER TABLE ingredient_publication_members ADD COLUMN expected_public_projection_hash TEXT;

CREATE TABLE ingredient_publication_transition_receipts (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES ingredient_publication_batches(id),
  from_state TEXT NOT NULL,
  to_state TEXT NOT NULL,
  actor TEXT NOT NULL,
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (batch_id, from_state, to_state, actor)
) STRICT;

CREATE TABLE ingredient_publication_artifacts (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES ingredient_publication_batches(id),
  kind TEXT NOT NULL CHECK (kind IN ('sealed_members','config_patch','configuration','match','release','public_projection','failure_bundle')),
  object_key TEXT,
  content_hash TEXT NOT NULL,
  byte_length INTEGER CHECK (byte_length IS NULL OR byte_length >= 0),
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (batch_id, kind, content_hash)
) STRICT;

CREATE INDEX ingredient_publication_receipts_batch
  ON ingredient_publication_transition_receipts(batch_id, created_at, id);
CREATE INDEX ingredient_publication_artifacts_batch
  ON ingredient_publication_artifacts(batch_id, kind, created_at, id);

PRAGMA optimize;
