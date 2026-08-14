-- @policy expand-contract
-- V4 runtime ingredient definitions. Git owns policy and bootstrap fixtures;
-- D1 owns versioned runtime ingredients and immutable identity decisions.

INSERT INTO pipeline_rollouts (feature, mode, updated_by, reason) VALUES
  ('dynamic_ingredient_catalog_v4','off','migration-0071','enable after catalog backfill and public parity')
ON CONFLICT(feature) DO NOTHING;

CREATE TABLE catalog_ingredient_versions (
  version_id TEXT PRIMARY KEY,
  ingredient_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  version INTEGER NOT NULL CHECK (version > 0),
  slug TEXT NOT NULL,
  canonical_name TEXT NOT NULL,
  display_name TEXT NOT NULL,
  identity_json TEXT NOT NULL,
  unit_dimension TEXT NOT NULL CHECK (unit_dimension IN ('weight','volume','count','other')),
  basis_unit TEXT NOT NULL,
  source_gap_id TEXT REFERENCES ingredient_gaps(id),
  definition_hash TEXT NOT NULL CHECK (length(definition_hash) = 64),
  planner_run_id TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (ingredient_id, version),
  UNIQUE (ingredient_id, definition_hash),
  UNIQUE (slug, version)
) STRICT;

CREATE TABLE catalog_ingredient_aliases (
  ingredient_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  version_id TEXT NOT NULL REFERENCES catalog_ingredient_versions(version_id),
  normalized_alias TEXT NOT NULL,
  alias_type TEXT NOT NULL CHECK (alias_type IN ('canonical','display','source','operator')),
  confidence_millis INTEGER NOT NULL CHECK (confidence_millis BETWEEN 0 AND 1000),
  authority TEXT NOT NULL,
  source TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (version_id, normalized_alias),
  UNIQUE (normalized_alias, ingredient_id, version_id)
) STRICT;

CREATE TABLE catalog_ingredient_current (
  ingredient_id TEXT PRIMARY KEY REFERENCES ingredient_entities(id),
  current_version_id TEXT NOT NULL UNIQUE REFERENCES catalog_ingredient_versions(version_id),
  current_state TEXT NOT NULL CHECK (current_state IN ('active','permanently_unavailable','hidden')),
  pointer_generation INTEGER NOT NULL DEFAULT 1 CHECK (pointer_generation > 0),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE catalog_permanently_unavailable (
  ingredient_id TEXT PRIMARY KEY REFERENCES ingredient_entities(id),
  identity_version_id TEXT NOT NULL REFERENCES catalog_ingredient_versions(version_id),
  identity_hash TEXT NOT NULL CHECK (length(identity_hash) = 64),
  normalized_aliases_json TEXT NOT NULL,
  resolution_event_id TEXT NOT NULL UNIQUE,
  override_audit_id TEXT,
  resolved_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE INDEX catalog_ingredient_versions_slug ON catalog_ingredient_versions(slug, ingredient_id, version DESC);
CREATE INDEX catalog_ingredient_alias_lookup ON catalog_ingredient_aliases(normalized_alias, ingredient_id);
CREATE INDEX catalog_permanent_identity ON catalog_permanently_unavailable(identity_hash, ingredient_id);

PRAGMA optimize;
