-- @policy expand-contract
-- Capture shards, offer confirmations, cross-store entities, governed conversions,
-- and content-addressed release detail metadata.

CREATE TABLE browser_capture_shards (
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  shard_date TEXT NOT NULL CHECK (shard_date GLOB '????-??-??'),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
  term_count INTEGER NOT NULL CHECK (term_count >= 0),
  row_count INTEGER NOT NULL CHECK (row_count >= 0),
  chunk_count INTEGER NOT NULL CHECK (chunk_count > 0),
  first_observed_at TEXT NOT NULL,
  last_observed_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (batch_id, shard_date),
  UNIQUE (batch_id, ordinal)
) STRICT;

CREATE INDEX browser_capture_shards_date
  ON browser_capture_shards(shard_date DESC, batch_id);

ALTER TABLE browser_capture_metrics ADD COLUMN daily_shard_count INTEGER NOT NULL DEFAULT 0 CHECK (daily_shard_count >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN likely_winner_rows INTEGER NOT NULL DEFAULT 0 CHECK (likely_winner_rows >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN confirmed_winner_rows INTEGER NOT NULL DEFAULT 0 CHECK (confirmed_winner_rows >= 0);

CREATE TRIGGER browser_capture_shards_no_update
BEFORE UPDATE ON browser_capture_shards
BEGIN SELECT RAISE(ABORT, 'browser capture shards are immutable'); END;

CREATE TRIGGER browser_capture_shards_no_delete
BEFORE DELETE ON browser_capture_shards
BEGIN SELECT RAISE(ABORT, 'browser capture shards are immutable'); END;

CREATE TABLE capture_offer_confirmations (
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  product_key TEXT NOT NULL,
  discovery_hash TEXT NOT NULL CHECK (length(discovery_hash) = 64),
  purchase_price_minor INTEGER NOT NULL CHECK (purchase_price_minor >= 0),
  discovered_at TEXT NOT NULL,
  confirmed_at TEXT NOT NULL,
  confirmation_kind TEXT NOT NULL CHECK (confirmation_kind IN ('browser-independent-read', 'repeat-capture-fact')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (batch_id, product_key, discovery_hash)
) STRICT;

CREATE INDEX capture_offer_confirmations_product
  ON capture_offer_confirmations(product_key, confirmed_at DESC);

CREATE TABLE product_entities (
  id TEXT PRIMARY KEY,
  canonical_name TEXT NOT NULL,
  canonical_brand TEXT,
  canonical_size_text TEXT,
  confidence TEXT NOT NULL CHECK (confidence IN ('strong', 'moderate')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE product_entity_identifiers (
  identifier_type TEXT NOT NULL CHECK (identifier_type IN ('gtin', 'upc')),
  identifier_value TEXT NOT NULL,
  entity_id TEXT NOT NULL REFERENCES product_entities(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (identifier_type, identifier_value)
) STRICT;

CREATE TABLE product_entity_links (
  product_id TEXT PRIMARY KEY REFERENCES products(id),
  entity_id TEXT NOT NULL REFERENCES product_entities(id),
  link_method TEXT NOT NULL CHECK (link_method IN ('gtin', 'upc', 'operator')),
  confidence_millis INTEGER NOT NULL CHECK (confidence_millis BETWEEN 0 AND 1000),
  evidence_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(evidence_json)),
  linked_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE INDEX product_entity_links_entity ON product_entity_links(entity_id, product_id);

CREATE TABLE product_entity_suggestions (
  id TEXT PRIMARY KEY,
  left_product_id TEXT NOT NULL REFERENCES products(id),
  right_product_id TEXT NOT NULL REFERENCES products(id),
  score_millis INTEGER NOT NULL CHECK (score_millis BETWEEN 0 AND 999),
  evidence_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(evidence_json)),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'rejected')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  resolved_at TEXT,
  CHECK (left_product_id < right_product_id),
  UNIQUE (left_product_id, right_product_id)
) STRICT;

CREATE TABLE ingredient_conversion_registry_versions (
  content_hash TEXT PRIMARY KEY CHECK (length(content_hash) = 64),
  version INTEGER NOT NULL CHECK (version > 0),
  policy_json TEXT NOT NULL CHECK (json_valid(policy_json)),
  entry_count INTEGER NOT NULL CHECK (entry_count > 0),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE recipe_cost_detail_objects (
  release_id TEXT NOT NULL REFERENCES releases(id),
  recipe_slug TEXT NOT NULL,
  content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
  object_key TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  verified_at TEXT,
  compacted_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (release_id, recipe_slug),
  FOREIGN KEY (release_id, recipe_slug) REFERENCES release_recipe_costs(release_id, recipe_slug)
) STRICT;

CREATE INDEX recipe_cost_detail_objects_hash
  ON recipe_cost_detail_objects(content_hash, release_id);

CREATE TABLE release_reason_blobs (
  content_hash TEXT PRIMARY KEY CHECK (length(content_hash) = 64),
  reason_json TEXT NOT NULL CHECK (json_valid(reason_json)),
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

ALTER TABLE release_cells ADD COLUMN reason_hash TEXT REFERENCES release_reason_blobs(content_hash);

CREATE INDEX release_cells_reason_hash ON release_cells(reason_hash);

CREATE VIEW release_cells_with_reasons AS
SELECT cells.release_id, cells.commodity_id, cells.store_location_id, cells.observation_id,
       cells.status, cells.is_crown, cells.display_per_unit_micros, cells.display_unit,
       COALESCE(reason.reason_json, cells.reason_json) AS reason_json,
       cells.reason_hash
  FROM release_cells cells
  LEFT JOIN release_reason_blobs reason ON reason.content_hash = cells.reason_hash;

INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description) VALUES
  ('release-offer-confirmation', 'release', 'hard', 'Every selected offer is independently confirmed by a browser re-read or a separate capture membership.'),
  ('release-conversion-registry', 'release', 'hard', 'Every recipe conversion is resolved through the immutable governed conversion registry.');

PRAGMA optimize;
