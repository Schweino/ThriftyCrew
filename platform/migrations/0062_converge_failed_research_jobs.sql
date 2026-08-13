-- @policy expand-contract
-- A terminal targeted-agent failure already moves the durable gap to operator
-- attention; converge its v2 job so the coordinator cannot relaunch it.
UPDATE ingredient_pricing_jobs
   SET state = 'needs_operator', updated_at = CURRENT_TIMESTAMP
 WHERE gap_id IN (SELECT id FROM ingredient_gaps WHERE status = 'needs_operator' AND qa_resolution IS NULL)
   AND state = 'store_checks_running';
