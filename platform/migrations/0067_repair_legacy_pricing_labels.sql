-- @policy expand-contract
-- Repair legacy labels that would otherwise hide resumable work from the V3
-- coordinator. A challenge without a durable challenge id is not a challenge.

UPDATE ingredient_store_checks
   SET state = 'targeted_refresh', operational_state = 'capture_queued',
       error_class = CASE WHEN last_error LIKE '%location%' OR last_error LIKE '%store%'
                          THEN 'location_unverified' ELSE 'coverage_missing' END,
       resume_state = NULL, next_attempt_at = CURRENT_TIMESTAMP,
       last_progress_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
 WHERE state = 'blocked_challenge' AND challenge_id IS NULL
   AND cancellation_kind IS NULL;

UPDATE ingredient_pricing_jobs
   SET state = 'store_checks_running', operational_state = 'store_checks_running',
       attention_count = 0, last_progress_at = CURRENT_TIMESTAMP,
       updated_at = CURRENT_TIMESTAMP
 WHERE state = 'needs_operator'
   AND EXISTS (
     SELECT 1 FROM ingredient_store_checks check_row
      WHERE check_row.pricing_job_id = ingredient_pricing_jobs.id
        AND check_row.operational_state IN ('queued','catalog_lookup','capture_queued','transient_backoff','evidence_expired')
   );

UPDATE ingredient_pricing_inbox
   SET state = 'active', updated_at = CURRENT_TIMESTAMP
 WHERE pricing_job_id IN (
   SELECT id FROM ingredient_pricing_jobs WHERE operational_state = 'store_checks_running'
 );

PRAGMA optimize;
