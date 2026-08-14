-- @policy expand-contract
-- One ingredient, seven terminal rows, one atomic pointer. This path has no
-- dependency on Git configuration, product rematching, or global releases.

INSERT INTO pipeline_rollouts (feature, mode, updated_by, reason) VALUES
  ('incremental_ingredient_publish_v4','off','migration-0073','enable after database-only canary and origin rollback drill'),
  ('incremental_recipe_resume_v4','off','migration-0073','enable after exact dependency resume tests')
ON CONFLICT(feature) DO NOTHING;

CREATE TABLE public_ingredient_versions (
  public_version_id TEXT PRIMARY KEY,
  ingredient_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  ingredient_definition_version_id TEXT NOT NULL REFERENCES catalog_ingredient_versions(version_id),
  snapshot_json TEXT NOT NULL,
  snapshot_hash TEXT NOT NULL CHECK (length(snapshot_hash) = 64),
  state TEXT NOT NULL CHECK (state IN ('staged','current','superseded','rolled_back')),
  previous_public_version_id TEXT REFERENCES public_ingredient_versions(public_version_id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  published_at TEXT,
  UNIQUE (ingredient_id, snapshot_hash)
) STRICT;

CREATE TABLE public_ingredient_store_rows (
  public_version_id TEXT NOT NULL REFERENCES public_ingredient_versions(public_version_id),
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  store_ordinal INTEGER NOT NULL CHECK (store_ordinal BETWEEN 0 AND 6),
  terminal_status TEXT NOT NULL CHECK (terminal_status IN ('priced','not_found')),
  row_json TEXT NOT NULL,
  producer_result_ref TEXT NOT NULL,
  verifier_result_ref TEXT NOT NULL,
  row_hash TEXT NOT NULL CHECK (length(row_hash) = 64),
  PRIMARY KEY (public_version_id, store_location_id),
  UNIQUE (public_version_id, store_ordinal)
) STRICT;

CREATE TABLE public_ingredient_current (
  ingredient_id TEXT PRIMARY KEY REFERENCES ingredient_entities(id),
  current_public_version_id TEXT NOT NULL UNIQUE REFERENCES public_ingredient_versions(public_version_id),
  pointer_generation INTEGER NOT NULL DEFAULT 1 CHECK (pointer_generation > 0),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE public_ingredient_origin_proofs (
  public_version_id TEXT NOT NULL REFERENCES public_ingredient_versions(public_version_id),
  origin TEXT NOT NULL,
  url TEXT NOT NULL,
  expected_hash TEXT NOT NULL,
  observed_hash TEXT,
  verified_at TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('verified','failed')),
  PRIMARY KEY (public_version_id, origin)
) STRICT;

CREATE TABLE public_ingredient_catalog_manifest (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
  content_hash TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;
INSERT INTO public_ingredient_catalog_manifest(singleton, revision, content_hash) VALUES (1, 0, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');

CREATE TABLE recipe_ingredient_dependencies_v2 (
  recipe_candidate_id TEXT NOT NULL,
  source_occurrence_id TEXT NOT NULL,
  ingredient_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  required_definition_version_id TEXT REFERENCES catalog_ingredient_versions(version_id),
  resolved_public_version_id TEXT REFERENCES public_ingredient_versions(public_version_id),
  status TEXT NOT NULL CHECK (status IN ('unresolved','resolved','permanently_unavailable')),
  resolved_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (recipe_candidate_id, source_occurrence_id)
) STRICT;

CREATE TABLE recipe_incremental_projection_events (
  id TEXT PRIMARY KEY,
  ingredient_public_version_id TEXT NOT NULL REFERENCES public_ingredient_versions(public_version_id),
  affected_recipe_id TEXT NOT NULL,
  projection_type TEXT NOT NULL CHECK (projection_type IN ('recipe_resume','recipe_scenario','ranking','promotion')),
  state TEXT NOT NULL CHECK (state IN ('queued','running','complete','failed')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (ingredient_public_version_id, affected_recipe_id, projection_type)
) STRICT;

CREATE INDEX public_ingredient_versions_current ON public_ingredient_versions(ingredient_id, state, created_at DESC);
CREATE INDEX public_origin_proofs_version ON public_ingredient_origin_proofs(public_version_id, origin);
CREATE INDEX recipe_dependencies_unresolved ON recipe_ingredient_dependencies_v2(ingredient_id, status, recipe_candidate_id);
CREATE INDEX recipe_projection_work ON recipe_incremental_projection_events(state, created_at, id);

PRAGMA optimize;
