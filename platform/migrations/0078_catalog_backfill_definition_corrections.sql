-- @policy expand-contract
-- Audited, reversible metadata for atomic V4 backfill definition supersession.

CREATE TABLE catalog_backfill_definition_corrections_v4 (
  correction_id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  commodity_id TEXT NOT NULL,
  ingredient_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  old_definition_version_id TEXT NOT NULL REFERENCES catalog_ingredient_versions(version_id),
  new_definition_version_id TEXT NOT NULL REFERENCES catalog_ingredient_versions(version_id),
  old_definition_hash TEXT NOT NULL CHECK (length(old_definition_hash)=64),
  new_definition_hash TEXT NOT NULL CHECK (length(new_definition_hash)=64),
  old_pointer_generation INTEGER NOT NULL CHECK (old_pointer_generation > 0),
  new_pointer_generation INTEGER NOT NULL CHECK (new_pointer_generation > old_pointer_generation),
  rollback_json TEXT NOT NULL,
  reason TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'applied' CHECK (state IN ('applied','rolled_back')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  rolled_back_at TEXT,
  UNIQUE (run_id,commodity_id,new_definition_version_id)
) STRICT;

CREATE INDEX catalog_backfill_definition_corrections_run_v4
  ON catalog_backfill_definition_corrections_v4(run_id,commodity_id,created_at);

CREATE TABLE catalog_backfill_definition_correction_stage_v4 (
  correction_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  commodity_id TEXT NOT NULL,
  ingredient_id TEXT NOT NULL,
  old_definition_version_id TEXT NOT NULL,
  new_definition_version_id TEXT NOT NULL,
  old_pointer_generation INTEGER NOT NULL,
  new_pointer_generation INTEGER NOT NULL,
  store_location_id TEXT NOT NULL,
  old_evidence_state TEXT NOT NULL,
  old_producer_work_item_id TEXT NOT NULL,
  old_verifier_work_item_id TEXT,
  old_terminal_result_hash TEXT,
  old_producer_state TEXT NOT NULL,
  old_producer_result_ref_hash TEXT,
  old_producer_lease_owner TEXT,
  old_producer_lease_generation INTEGER NOT NULL,
  old_producer_lease_expires_at TEXT,
  old_verifier_state TEXT,
  old_verifier_result_ref_hash TEXT,
  old_verifier_lease_owner TEXT,
  old_verifier_lease_generation INTEGER,
  old_verifier_lease_expires_at TEXT,
  new_work_item_id TEXT NOT NULL UNIQUE,
  new_agent_id TEXT NOT NULL,
  new_dedupe_key TEXT NOT NULL UNIQUE,
  new_input_ref_hash TEXT NOT NULL CHECK (length(new_input_ref_hash)=64),
  new_input_json TEXT NOT NULL,
  staged_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (correction_id,store_location_id)
) STRICT;

CREATE INDEX catalog_backfill_definition_correction_stage_run_v4
  ON catalog_backfill_definition_correction_stage_v4(run_id,commodity_id,correction_id);

PRAGMA optimize;
