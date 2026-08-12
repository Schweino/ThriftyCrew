-- @policy expand-contract
-- Object-storage data plane: immutable Parquet capture partitions,
-- content-addressed release graphs, current recipe scenarios, and manifest backups.

CREATE TABLE object_store_objects (
  content_hash TEXT PRIMARY KEY CHECK (length(content_hash) = 64),
  object_key TEXT NOT NULL UNIQUE,
  object_kind TEXT NOT NULL CHECK (object_kind IN ('observation-partition', 'release-node', 'release-manifest', 'backup-manifest')),
  format TEXT NOT NULL CHECK (format IN ('parquet', 'json')),
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  row_count INTEGER CHECK (row_count IS NULL OR row_count >= 0),
  schema_version INTEGER NOT NULL CHECK (schema_version > 0),
  verified_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE INDEX object_store_objects_kind_created
  ON object_store_objects(object_kind, created_at DESC);

CREATE TABLE observation_partitions (
  batch_id TEXT PRIMARY KEY REFERENCES capture_batches(id),
  source_id TEXT NOT NULL REFERENCES capture_sources(id),
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  partition_date TEXT NOT NULL CHECK (partition_date GLOB '????-??-??'),
  content_hash TEXT NOT NULL REFERENCES object_store_objects(content_hash),
  row_count INTEGER NOT NULL CHECK (row_count >= 0),
  min_observed_at TEXT NOT NULL,
  max_observed_at TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (max_observed_at >= min_observed_at)
) STRICT;

CREATE INDEX observation_partitions_lookup
  ON observation_partitions(source_id, partition_date DESC);

CREATE TRIGGER observation_partitions_no_update
BEFORE UPDATE ON observation_partitions
BEGIN SELECT RAISE(ABORT, 'observation partitions are immutable'); END;

CREATE TRIGGER observation_partitions_no_delete
BEFORE DELETE ON observation_partitions
BEGIN SELECT RAISE(ABORT, 'observation partitions are immutable'); END;

CREATE TABLE release_graphs (
  release_id TEXT PRIMARY KEY REFERENCES releases(id),
  parent_release_id TEXT REFERENCES releases(id),
  root_hash TEXT NOT NULL CHECK (length(root_hash) = 64),
  object_key TEXT NOT NULL UNIQUE,
  node_count INTEGER NOT NULL CHECK (node_count >= 0),
  changed_node_count INTEGER NOT NULL CHECK (changed_node_count >= 0),
  reused_node_count INTEGER NOT NULL CHECK (reused_node_count >= 0),
  dependency_hash TEXT NOT NULL CHECK (length(dependency_hash) = 64),
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  finalized_at TEXT NOT NULL,
  CHECK (changed_node_count + reused_node_count = node_count)
) STRICT;

CREATE INDEX release_graphs_parent ON release_graphs(parent_release_id);

-- Draft/current working set only. Publishing atomically replaces the prior
-- market projection and deletes the superseded release's rows.
CREATE TABLE release_graph_nodes (
  release_id TEXT NOT NULL REFERENCES releases(id),
  node_kind TEXT NOT NULL CHECK (node_kind IN ('cell', 'recipe', 'payload', 'top5', 'free-rotation')),
  node_key TEXT NOT NULL,
  dependency_hash TEXT NOT NULL CHECK (length(dependency_hash) = 64),
  content_hash TEXT NOT NULL REFERENCES object_store_objects(content_hash),
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  reused_from_release_id TEXT REFERENCES releases(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (release_id, node_kind, node_key)
) STRICT;

CREATE INDEX release_graph_nodes_dependency
  ON release_graph_nodes(node_kind, node_key, dependency_hash, release_id);

CREATE TABLE current_recipe_scenarios (
  market_id TEXT NOT NULL REFERENCES markets(id),
  release_id TEXT NOT NULL REFERENCES releases(id),
  recipe_slug TEXT NOT NULL,
  scenario_kind TEXT NOT NULL CHECK (scenario_kind IN ('utilized', 'register-checkout', 'non-member-checkout', 'everyday-baseline', 'selected-store-checkout')),
  store_location_key TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK (status IN ('complete', 'incomplete')),
  batch_cost_minor INTEGER,
  serving_cost_minor INTEGER,
  missing_ingredients_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(missing_ingredients_json)),
  content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (market_id, recipe_slug, scenario_kind, store_location_key),
  CHECK ((status = 'complete' AND batch_cost_minor IS NOT NULL) OR status = 'incomplete')
) STRICT;

CREATE INDEX current_recipe_scenarios_release
  ON current_recipe_scenarios(release_id, recipe_slug);

CREATE TABLE release_recipe_scenarios (
  release_id TEXT NOT NULL REFERENCES releases(id),
  recipe_slug TEXT NOT NULL,
  scenario_kind TEXT NOT NULL CHECK (scenario_kind IN ('utilized', 'register-checkout', 'non-member-checkout', 'everyday-baseline', 'selected-store-checkout')),
  store_location_key TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL CHECK (status IN ('complete', 'incomplete')),
  batch_cost_minor INTEGER,
  serving_cost_minor INTEGER,
  missing_ingredients_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(missing_ingredients_json)),
  content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
  PRIMARY KEY (release_id, recipe_slug, scenario_kind, store_location_key),
  CHECK ((status = 'complete' AND batch_cost_minor IS NOT NULL) OR status = 'incomplete')
) STRICT;

CREATE TABLE lake_backup_manifests (
  id TEXT PRIMARY KEY,
  bookmark TEXT NOT NULL,
  object_key TEXT NOT NULL UNIQUE,
  content_hash TEXT NOT NULL CHECK (length(content_hash) = 64),
  byte_length INTEGER NOT NULL CHECK (byte_length > 0),
  release_root_count INTEGER NOT NULL CHECK (release_root_count >= 0),
  partition_count INTEGER NOT NULL CHECK (partition_count >= 0),
  replica_verified INTEGER NOT NULL DEFAULT 0 CHECK (replica_verified IN (0, 1)),
  status TEXT NOT NULL CHECK (status IN ('started', 'completed', 'failed')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT
) STRICT;

INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description) VALUES
  ('batch-parquet-partition', 'batch', 'hard', 'Every capture batch is durably represented by a verified immutable Parquet partition.'),
  ('release-object-graph', 'release', 'hard', 'The release has a verified content-addressed object graph and immutable manifest root.'),
  ('release-recipe-scenarios', 'release', 'hard', 'Every recipe exposes authoritative first-class cost scenarios from the release graph.');

PRAGMA optimize;
