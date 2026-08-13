-- @policy expand-contract
-- Immutable source artifacts, independent fact/mapping verification, canonical
-- ingredient identities, and indexed recipe dependency occurrences.

CREATE TABLE recipe_hunt_candidates (
  request_id TEXT NOT NULL REFERENCES recipe_suggestion_requests(id),
  candidate_id TEXT NOT NULL,
  source_url TEXT NOT NULL,
  canonical_url TEXT NOT NULL,
  lead_json TEXT NOT NULL,
  lead_hash TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('hunted','duplicate','accepted','source_rejected')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (request_id, candidate_id),
  UNIQUE (request_id, canonical_url)
) STRICT;

CREATE TABLE recipe_source_artifacts (
  id TEXT PRIMARY KEY,
  request_id TEXT NOT NULL REFERENCES recipe_suggestion_requests(id),
  candidate_id TEXT NOT NULL,
  source_url TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  sha256 TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  content_type TEXT NOT NULL,
  http_status INTEGER NOT NULL CHECK (http_status BETWEEN 200 AND 299),
  fetched_at TEXT NOT NULL,
  UNIQUE (request_id, candidate_id, sha256)
) STRICT;

CREATE TABLE recipe_fact_verifications (
  id TEXT PRIMARY KEY,
  source_fact_version_id TEXT NOT NULL REFERENCES recipe_source_fact_versions(id),
  source_artifact_id TEXT NOT NULL REFERENCES recipe_source_artifacts(id),
  verifier_version TEXT NOT NULL,
  input_hash TEXT NOT NULL,
  verdict TEXT NOT NULL CHECK (verdict IN ('verified','rejected')),
  findings_json TEXT NOT NULL DEFAULT '[]',
  output_hash TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (source_fact_version_id, input_hash, output_hash)
) STRICT;

CREATE TABLE recipe_mapping_verifications (
  id TEXT PRIMARY KEY,
  mapping_version_id TEXT NOT NULL REFERENCES recipe_mapping_versions(id),
  verifier_version TEXT NOT NULL,
  input_hash TEXT NOT NULL,
  verdict TEXT NOT NULL CHECK (verdict IN ('verified','rejected')),
  findings_json TEXT NOT NULL DEFAULT '[]',
  output_hash TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (mapping_version_id, input_hash, output_hash)
) STRICT;

CREATE TABLE ingredient_identity_versions (
  id TEXT PRIMARY KEY,
  entity_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  version INTEGER NOT NULL CHECK (version > 0),
  base_product TEXT NOT NULL,
  form_json TEXT NOT NULL DEFAULT '[]',
  aliases_json TEXT NOT NULL DEFAULT '[]',
  exclusions_json TEXT NOT NULL DEFAULT '[]',
  expected_unit_dimension TEXT NOT NULL CHECK (expected_unit_dimension IN ('mass','volume','count','variable')),
  identity_hash TEXT NOT NULL,
  resolver_version TEXT NOT NULL,
  verified_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (entity_id, version),
  UNIQUE (entity_id, identity_hash)
) STRICT;

CREATE TABLE ingredient_identity_decisions (
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL REFERENCES markets(id),
  normalized_input TEXT NOT NULL,
  entity_id TEXT REFERENCES ingredient_entities(id),
  identity_version_id TEXT REFERENCES ingredient_identity_versions(id),
  decision TEXT NOT NULL CHECK (decision IN ('existing','novel','alias','permanently_unavailable','noncommodity','ambiguous')),
  method TEXT NOT NULL CHECK (method IN ('exact','deterministic','model','operator')),
  evidence_hash TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (market_id, normalized_input, evidence_hash)
) STRICT;

CREATE TABLE recipe_hold_requirement_occurrences (
  hold_id TEXT NOT NULL REFERENCES recipe_ingredient_holds(id),
  source_ingredient_index INTEGER NOT NULL CHECK (source_ingredient_index >= 0),
  split_component_index INTEGER NOT NULL CHECK (split_component_index >= 0),
  gap_id TEXT REFERENCES ingredient_gaps(id),
  entity_id TEXT REFERENCES ingredient_entities(id),
  source_line TEXT NOT NULL,
  normalized_requirement TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('purchased','process','optional','alternative')),
  resolution_version_id TEXT,
  terminal_kind TEXT CHECK (terminal_kind IS NULL OR terminal_kind IN ('available','unavailable','alias','noncommodity')),
  satisfied_at TEXT,
  blocked_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (hold_id, source_ingredient_index, split_component_index)
) STRICT;

CREATE INDEX recipe_hold_requirement_occurrences_gap
  ON recipe_hold_requirement_occurrences(gap_id, hold_id, source_ingredient_index, split_component_index);

CREATE TABLE recipe_write_verification_versions (
  id TEXT PRIMARY KEY,
  request_id TEXT NOT NULL REFERENCES recipe_suggestion_requests(id),
  writer_work_item_id TEXT NOT NULL REFERENCES agent_work_items(id),
  dependency_root_hash TEXT NOT NULL,
  input_hash TEXT NOT NULL,
  output_hash TEXT NOT NULL,
  verifier_version TEXT NOT NULL,
  verdict TEXT NOT NULL CHECK (verdict IN ('verified','rejected')),
  findings_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (writer_work_item_id, input_hash, output_hash)
) STRICT;

ALTER TABLE recipe_source_fact_versions ADD COLUMN source_artifact_id TEXT REFERENCES recipe_source_artifacts(id);
ALTER TABLE recipe_source_fact_versions ADD COLUMN fact_verification_id TEXT REFERENCES recipe_fact_verifications(id);
ALTER TABLE recipe_mapping_versions ADD COLUMN mapping_verification_id TEXT REFERENCES recipe_mapping_verifications(id);

PRAGMA optimize;
