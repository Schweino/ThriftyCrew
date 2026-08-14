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

CREATE TRIGGER catalog_backfill_definition_correction_validate_v4
BEFORE INSERT ON catalog_backfill_definition_corrections_v4
BEGIN
  SELECT CASE WHEN NEW.new_pointer_generation <> NEW.old_pointer_generation + 1
    THEN RAISE(ABORT,'definition correction pointer generation must advance exactly once') END;
  SELECT CASE WHEN (SELECT COUNT(*) FROM catalog_backfill_definition_correction_stage_v4 s
    WHERE s.correction_id=NEW.correction_id AND s.run_id=NEW.run_id AND s.commodity_id=NEW.commodity_id
      AND s.ingredient_id=NEW.ingredient_id AND s.old_definition_version_id=NEW.old_definition_version_id
      AND s.new_definition_version_id=NEW.new_definition_version_id
      AND s.old_pointer_generation=NEW.old_pointer_generation AND s.new_pointer_generation=NEW.new_pointer_generation) <> 7
    THEN RAISE(ABORT,'definition correction requires exactly seven staged cells') END;
  SELECT CASE WHEN EXISTS(SELECT 1 FROM catalog_backfill_definition_correction_stage_v4 s
    WHERE s.correction_id=NEW.correction_id AND s.store_location_id NOT IN
      ('aldi-omaha-446-048','bakers-saddle-creek','family-fare-omaha-6401','fareway-omaha-043','hy-vee-omaha-1465','sams-omaha','walmart-omaha'))
    THEN RAISE(ABORT,'definition correction contains a noncanonical store') END;
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM catalog_ingredient_current p
    WHERE p.ingredient_id=NEW.ingredient_id AND p.current_version_id=NEW.old_definition_version_id
      AND p.pointer_generation=NEW.old_pointer_generation)
    THEN RAISE(ABORT,'definition correction lost its pointer fence') END;
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM catalog_ingredient_versions v
    WHERE v.version_id=NEW.new_definition_version_id AND v.ingredient_id=NEW.ingredient_id
      AND v.definition_hash=NEW.new_definition_hash)
    THEN RAISE(ABORT,'definition correction new version is not durable') END;
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM catalog_ingredient_versions v
    WHERE v.version_id=NEW.old_definition_version_id AND v.ingredient_id=NEW.ingredient_id
      AND v.definition_hash=NEW.old_definition_hash)
    THEN RAISE(ABORT,'definition correction old definition hash is not fenced') END;
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM catalog_backfill_ingredients_v4 i
    WHERE i.run_id=NEW.run_id AND i.commodity_id=NEW.commodity_id AND i.ingredient_id=NEW.ingredient_id
      AND i.definition_version_id=NEW.old_definition_version_id)
    THEN RAISE(ABORT,'definition correction lost its ingredient fence') END;
  SELECT CASE WHEN (SELECT COUNT(*) FROM catalog_backfill_cells_v4 c
    WHERE c.run_id=NEW.run_id AND c.commodity_id=NEW.commodity_id
      AND EXISTS(SELECT 1 FROM catalog_backfill_definition_correction_stage_v4 s
        JOIN pipeline_agent_work_items_v4 p ON p.id=s.old_producer_work_item_id
        LEFT JOIN pipeline_agent_work_items_v4 v ON v.id=s.old_verifier_work_item_id
        WHERE s.correction_id=NEW.correction_id AND s.store_location_id=c.store_location_id
          AND c.ingredient_id=NEW.ingredient_id AND c.definition_version_id=s.old_definition_version_id
          AND c.evidence_state=s.old_evidence_state AND c.producer_work_item_id=s.old_producer_work_item_id
          AND c.verifier_work_item_id IS s.old_verifier_work_item_id AND c.terminal_result_hash IS s.old_terminal_result_hash
          AND p.state=s.old_producer_state AND p.result_ref_hash IS s.old_producer_result_ref_hash
          AND p.lease_owner IS s.old_producer_lease_owner AND p.lease_generation=s.old_producer_lease_generation
          AND p.lease_expires_at IS s.old_producer_lease_expires_at
          AND ((s.old_verifier_work_item_id IS NULL AND s.old_verifier_state IS NULL)
            OR (v.state=s.old_verifier_state AND v.result_ref_hash IS s.old_verifier_result_ref_hash
              AND v.lease_owner IS s.old_verifier_lease_owner AND v.lease_generation=s.old_verifier_lease_generation
              AND v.lease_expires_at IS s.old_verifier_lease_expires_at)))) <> 7
    THEN RAISE(ABORT,'definition correction lost a cell or work snapshot fence') END;
  SELECT CASE WHEN EXISTS(SELECT 1 FROM catalog_backfill_definition_correction_stage_v4 s
    JOIN pipeline_agent_work_items_v4 w ON w.id=s.new_work_item_id OR w.dedupe_key=s.new_dedupe_key
    WHERE s.correction_id=NEW.correction_id)
    THEN RAISE(ABORT,'definition correction new work identity already exists') END;
END;

CREATE TRIGGER catalog_backfill_definition_correction_apply_v4
AFTER INSERT ON catalog_backfill_definition_corrections_v4
BEGIN
  UPDATE catalog_ingredient_current
    SET current_version_id=NEW.new_definition_version_id,pointer_generation=NEW.new_pointer_generation,updated_at=CURRENT_TIMESTAMP
    WHERE ingredient_id=NEW.ingredient_id AND current_version_id=NEW.old_definition_version_id
      AND pointer_generation=NEW.old_pointer_generation;
  INSERT INTO pipeline_agent_work_items_v4
    (id,agent_id,entity_type,entity_id,dedupe_key,priority,state,input_ref_hash,correlation_id,input_json)
    SELECT s.new_work_item_id,s.new_agent_id,'catalog_backfill_cell',NEW.ingredient_id,s.new_dedupe_key,100,'queued',
      s.new_input_ref_hash,NEW.run_id,s.new_input_json FROM catalog_backfill_definition_correction_stage_v4 s
    WHERE s.correction_id=NEW.correction_id;
  UPDATE pipeline_agent_work_items_v4 SET state='superseded',terminal_at=COALESCE(terminal_at,CURRENT_TIMESTAMP),
    lease_owner=NULL,lease_expires_at=NULL
    WHERE id IN (SELECT old_producer_work_item_id FROM catalog_backfill_definition_correction_stage_v4 WHERE correction_id=NEW.correction_id)
       OR id IN (SELECT old_verifier_work_item_id FROM catalog_backfill_definition_correction_stage_v4
         WHERE correction_id=NEW.correction_id AND old_verifier_work_item_id IS NOT NULL);
  UPDATE catalog_backfill_cells_v4 SET definition_version_id=NEW.new_definition_version_id,evidence_state='queued',
    producer_work_item_id=(SELECT s.new_work_item_id FROM catalog_backfill_definition_correction_stage_v4 s
      WHERE s.correction_id=NEW.correction_id AND s.store_location_id=catalog_backfill_cells_v4.store_location_id),
    verifier_work_item_id=NULL,terminal_result_json=NULL,terminal_result_hash=NULL,updated_at=CURRENT_TIMESTAMP
    WHERE run_id=NEW.run_id AND commodity_id=NEW.commodity_id;
  UPDATE catalog_backfill_ingredients_v4 SET definition_version_id=NEW.new_definition_version_id,
    terminal_evidence_count=0,updated_at=CURRENT_TIMESTAMP
    WHERE run_id=NEW.run_id AND commodity_id=NEW.commodity_id;
END;

CREATE INDEX catalog_backfill_definition_correction_stage_run_v4
  ON catalog_backfill_definition_correction_stage_v4(run_id,commodity_id,correction_id);

PRAGMA optimize;
