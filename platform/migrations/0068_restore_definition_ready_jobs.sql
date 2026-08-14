-- @policy expand-contract
-- Definition readiness is a prerequisite within the running pricing job, not
-- a replacement for the job's externally visible active state.

UPDATE ingredient_pricing_jobs
SET operational_state = 'store_checks_running',
    last_progress_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE state = 'store_checks_running'
  AND operational_state = 'definition_ready';

PRAGMA optimize;
