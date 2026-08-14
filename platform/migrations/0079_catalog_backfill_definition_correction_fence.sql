-- @policy expand-contract
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
    WHERE v.version_id=NEW.new_definition_version_id AND v.ingredient_id=NEW.ingredient_id AND v.definition_hash=NEW.new_definition_hash)
    THEN RAISE(ABORT,'definition correction new version is not durable') END;
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM catalog_ingredient_versions v
    WHERE v.version_id=NEW.old_definition_version_id AND v.ingredient_id=NEW.ingredient_id AND v.definition_hash=NEW.old_definition_hash)
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

PRAGMA optimize;
