UPDATE capture_sources
   SET coverage_policy_json = '{"migration_only":true,"max_age_days":14}'
 WHERE capture_method = 'legacy_bridge';

INSERT INTO guard_definitions (id, scope, severity, description)
VALUES ('release-freshness', 'release', 'hard', 'Every selected observation is within the source-specific freshness window.');
