-- @policy expand-contract
-- Legacy board rows are useful semantic input, but absence is not evidence of
-- exhaustive not-found and a single historical observation is not independent
-- producer/verifier proof. Keep that distinction durable during the V4 backfill.

CREATE TABLE catalog_backfill_runs_v4 (
  run_id TEXT PRIMARY KEY,
  source_release_id TEXT NOT NULL UNIQUE REFERENCES releases(id),
  source_board_hash TEXT NOT NULL CHECK (length(source_board_hash) = 64),
  state TEXT NOT NULL CHECK (state IN ('staging','capturing','evidence_ready','parity_ready','complete','failed')),
  commodity_count INTEGER NOT NULL CHECK (commodity_count >= 0),
  expected_cell_count INTEGER NOT NULL CHECK (expected_cell_count >= 0),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE catalog_backfill_ingredients_v4 (
  run_id TEXT NOT NULL REFERENCES catalog_backfill_runs_v4(run_id),
  commodity_id TEXT NOT NULL,
  ingredient_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  definition_version_id TEXT NOT NULL REFERENCES catalog_ingredient_versions(version_id),
  legacy_semantic_json TEXT NOT NULL,
  legacy_semantic_hash TEXT NOT NULL CHECK (length(legacy_semantic_hash) = 64),
  semantic_state TEXT NOT NULL CHECK (semantic_state IN ('staged','matched','mismatch')),
  terminal_evidence_count INTEGER NOT NULL DEFAULT 0 CHECK (terminal_evidence_count BETWEEN 0 AND 7),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (run_id, commodity_id),
  UNIQUE (run_id, ingredient_id),
  UNIQUE (run_id, definition_version_id)
) STRICT;

CREATE TABLE catalog_backfill_cells_v4 (
  run_id TEXT NOT NULL,
  commodity_id TEXT NOT NULL,
  ingredient_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  definition_version_id TEXT NOT NULL REFERENCES catalog_ingredient_versions(version_id),
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  semantic_state TEXT NOT NULL CHECK (semantic_state IN ('priced_provenance_recovered','legacy_unknown')),
  evidence_state TEXT NOT NULL CHECK (evidence_state IN ('queued','producer_ready','terminal_verified','challenged','needs_operator')),
  legacy_observation_id TEXT REFERENCES observations(id),
  legacy_row_json TEXT,
  legacy_row_hash TEXT,
  producer_work_item_id TEXT REFERENCES pipeline_agent_work_items_v4(id),
  verifier_work_item_id TEXT REFERENCES pipeline_agent_work_items_v4(id),
  terminal_result_json TEXT,
  terminal_result_hash TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (run_id, commodity_id, store_location_id),
  FOREIGN KEY (run_id, commodity_id) REFERENCES catalog_backfill_ingredients_v4(run_id, commodity_id),
  CHECK ((semantic_state = 'priced_provenance_recovered' AND legacy_observation_id IS NOT NULL AND legacy_row_json IS NOT NULL AND length(legacy_row_hash) = 64)
      OR (semantic_state = 'legacy_unknown' AND legacy_observation_id IS NULL AND legacy_row_json IS NULL AND legacy_row_hash IS NULL)),
  CHECK ((evidence_state = 'terminal_verified' AND terminal_result_json IS NOT NULL AND length(terminal_result_hash) = 64)
      OR evidence_state <> 'terminal_verified')
) STRICT;

CREATE INDEX catalog_backfill_cells_progress_v4
  ON catalog_backfill_cells_v4(run_id, store_location_id, evidence_state, commodity_id);
CREATE UNIQUE INDEX catalog_backfill_producer_work_v4
  ON catalog_backfill_cells_v4(producer_work_item_id) WHERE producer_work_item_id IS NOT NULL;
CREATE UNIQUE INDEX catalog_backfill_verifier_work_v4
  ON catalog_backfill_cells_v4(verifier_work_item_id) WHERE verifier_work_item_id IS NOT NULL;

PRAGMA optimize;
