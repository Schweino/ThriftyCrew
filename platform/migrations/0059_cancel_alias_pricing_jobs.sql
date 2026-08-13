-- @policy expand-contract
-- A QA alias resolution means the ingredient already exists in the public
-- catalog. It must never continue through the new-ingredient pricing lane.
UPDATE ingredient_pricing_jobs
   SET state = 'failed', updated_at = CURRENT_TIMESTAMP
 WHERE gap_id IN (SELECT id FROM ingredient_gaps WHERE qa_resolution IS NOT NULL)
   AND state NOT IN ('public_verified','permanently_unavailable','failed');

UPDATE pricing_waves
   SET state = 'cancelled', completed_at = COALESCE(completed_at, CURRENT_TIMESTAMP),
       last_progress_at = CURRENT_TIMESTAMP
 WHERE state IN ('planning','resolving','qa','publishing')
   AND EXISTS (SELECT 1 FROM pricing_wave_members member WHERE member.wave_id = pricing_waves.id)
   AND NOT EXISTS (
     SELECT 1 FROM pricing_wave_members member
     JOIN ingredient_pricing_jobs job ON job.id = member.pricing_job_id
     WHERE member.wave_id = pricing_waves.id AND job.state != 'failed'
   );
