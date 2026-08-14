-- @policy expand-contract
CREATE TRIGGER catalog_backfill_definition_correction_apply_v4
AFTER INSERT ON catalog_backfill_definition_corrections_v4
BEGIN
  UPDATE catalog_ingredient_current SET current_version_id=NEW.new_definition_version_id,
    pointer_generation=NEW.new_pointer_generation,updated_at=CURRENT_TIMESTAMP
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

PRAGMA optimize;
