-- @policy expand-contract
-- Repair malformed discovery-only gaps emitted before the atomic-identity
-- boundary existed. These are exclusions, not unavailable Omaha products.
UPDATE ingredient_gaps
   SET status = 'needs_operator', qa_resolution = 'excluded_noncommodity',
       qa_resolved_at = CURRENT_TIMESTAMP,
       publication_error = 'deterministic exclusion: process water, alternative, or combined ingredient line is not one purchasable catalog identity',
       updated_at = CURRENT_TIMESTAMP
 WHERE qa_resolution IS NULL
   AND status IN ('pending','researching','needs_operator')
   AND (normalized_name IN ('water','hot water','boiling water','cold water')
        OR normalized_name LIKE '% and %' OR normalized_name LIKE '% or %');

UPDATE ingredient_pricing_jobs
   SET state = 'failed', updated_at = CURRENT_TIMESTAMP
 WHERE gap_id IN (SELECT id FROM ingredient_gaps WHERE qa_resolution = 'excluded_noncommodity')
   AND state NOT IN ('public_verified','permanently_unavailable','failed');
