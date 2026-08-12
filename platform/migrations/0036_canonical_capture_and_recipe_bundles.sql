-- @policy expand-contract
-- Canonical offer facts, batch discovery memberships, and per-recipe objects.

CREATE TABLE capture_observation_memberships (
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  observation_id TEXT NOT NULL REFERENCES observations(id),
  term_key TEXT NOT NULL DEFAULT '',
  observed_at TEXT NOT NULL,
  source_payload_key TEXT,
  evidence_object_id TEXT REFERENCES evidence_objects(id),
  provenance_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(provenance_json)),
  carried INTEGER NOT NULL DEFAULT 0 CHECK (carried IN (0, 1)),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (batch_id, observation_id, term_key)
) STRICT;

CREATE INDEX capture_memberships_observation
  ON capture_observation_memberships(observation_id, observed_at DESC);
CREATE INDEX capture_memberships_batch_time
  ON capture_observation_memberships(batch_id, observed_at DESC, observation_id);

INSERT INTO capture_observation_memberships
  (batch_id, observation_id, term_key, observed_at, source_payload_key, evidence_object_id, provenance_json, carried)
SELECT batch_id, id, COALESCE(term_key, ''), captured_at, source_payload_key, evidence_object_id, '{}', 0
  FROM observations;

CREATE VIEW capture_batch_observations AS
SELECT batch_id, observation_id, MAX(observed_at) AS observed_at,
       MAX(carried) AS carried
  FROM capture_observation_memberships
 GROUP BY batch_id, observation_id;

CREATE TABLE observation_semantic_keys (
  semantic_hash TEXT PRIMARY KEY,
  observation_id TEXT NOT NULL UNIQUE REFERENCES observations(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE release_recipe_payloads (
  release_id TEXT NOT NULL REFERENCES releases(id),
  recipe_slug TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (release_id, recipe_slug)
) STRICT;

CREATE INDEX release_recipe_payload_lookup
  ON release_recipe_payloads(recipe_slug, release_id);

CREATE TABLE storage_measurements (
  measured_on TEXT PRIMARY KEY,
  d1_bytes INTEGER NOT NULL CHECK (d1_bytes >= 0),
  products INTEGER NOT NULL CHECK (products >= 0),
  product_versions INTEGER NOT NULL CHECK (product_versions >= 0),
  observation_facts INTEGER NOT NULL CHECK (observation_facts >= 0),
  batch_memberships INTEGER NOT NULL CHECK (batch_memberships >= 0),
  recipe_payload_bytes INTEGER NOT NULL CHECK (recipe_payload_bytes >= 0),
  detail_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(detail_json)),
  recorded_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description)
VALUES ('release-recipe-bundles', 'release', 'hard', 'Every authored recipe has a content-addressed per-recipe R2 bundle.');

PRAGMA optimize;
