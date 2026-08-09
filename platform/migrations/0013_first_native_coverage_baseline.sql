-- The legacy bridge and direct-native engine do not have identical catalog semantics.
-- These one-time floors are the browser-attested, full direct captures accepted during
-- cutover. After the first native release publishes, release-to-release 90% ratcheting
-- resumes automatically and these values are no longer consulted.
UPDATE capture_sources
   SET coverage_policy_json = json_set(coverage_policy_json, '$.first_native_min_priced', 402)
 WHERE id IN ('direct-hy-vee-headless', 'direct-hy-vee-browser');

UPDATE capture_sources
   SET coverage_policy_json = json_set(coverage_policy_json, '$.first_native_min_priced', 276)
 WHERE id IN ('direct-sams-headless', 'direct-sams-browser');

UPDATE capture_sources
   SET coverage_policy_json = json_set(coverage_policy_json, '$.first_native_min_priced', 385)
 WHERE id IN ('direct-walmart-headless', 'direct-walmart-browser');
