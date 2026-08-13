-- @policy expand-contract
-- Converge v2 state for targeted research completed before blocked and
-- ambiguous outcomes were persisted into per-store checks.
UPDATE ingredient_store_checks
   SET state = CASE (
         SELECT json_extract(value, '$.outcome') FROM ingredient_gaps gap,
                json_each(gap.research_json, '$.stores')
          WHERE gap.id = ingredient_store_checks.gap_id
            AND json_extract(value, '$.storeLocationId') = ingredient_store_checks.store_location_id
       ) WHEN 'blocked' THEN 'blocked_challenge' WHEN 'ambiguous' THEN 'ambiguous' ELSE state END,
       result_json = COALESCE((
         SELECT value FROM ingredient_gaps gap, json_each(gap.research_json, '$.stores')
          WHERE gap.id = ingredient_store_checks.gap_id
            AND json_extract(value, '$.storeLocationId') = ingredient_store_checks.store_location_id
       ), result_json),
       updated_at = CURRENT_TIMESTAMP
 WHERE gap_id IN (SELECT id FROM ingredient_gaps WHERE status = 'needs_operator' AND qa_resolution IS NULL);

UPDATE ingredient_pricing_jobs
   SET state = 'needs_operator', updated_at = CURRENT_TIMESTAMP
 WHERE gap_id IN (SELECT id FROM ingredient_gaps WHERE status = 'needs_operator' AND qa_resolution IS NULL)
   AND state = 'store_checks_running';
