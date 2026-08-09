ALTER TABLE configuration_versions ADD COLUMN expected_categories INTEGER NOT NULL DEFAULT 0 CHECK (expected_categories >= 0);
ALTER TABLE configuration_versions ADD COLUMN expected_commodities INTEGER NOT NULL DEFAULT 0 CHECK (expected_commodities >= 0);
ALTER TABLE configuration_versions ADD COLUMN expected_rules INTEGER NOT NULL DEFAULT 0 CHECK (expected_rules >= 0);

CREATE TABLE configuration_categories (
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  category_id TEXT NOT NULL REFERENCES categories(id),
  PRIMARY KEY (configuration_id, category_id)
) STRICT;

INSERT INTO capture_sources (id, store_location_id, name, capture_method, price_mode, coverage_policy_json) VALUES
  ('legacy-aldi', 'aldi-omaha-446-048', 'Legacy published-board bridge', 'legacy_bridge', 'mixed', '{"migration_only":true}'),
  ('legacy-bakers', 'bakers-saddle-creek', 'Legacy published-board bridge', 'legacy_bridge', 'mixed', '{"migration_only":true}'),
  ('legacy-family-fare', 'family-fare-omaha-6401', 'Legacy published-board bridge', 'legacy_bridge', 'mixed', '{"migration_only":true}'),
  ('legacy-fareway', 'fareway-omaha-043', 'Legacy published-board bridge', 'legacy_bridge', 'mixed', '{"migration_only":true}'),
  ('legacy-hy-vee', 'hy-vee-omaha-1465', 'Legacy published-board bridge', 'legacy_bridge', 'mixed', '{"migration_only":true}'),
  ('legacy-sams', 'sams-omaha', 'Legacy published-board bridge', 'legacy_bridge', 'mixed', '{"migration_only":true}'),
  ('legacy-walmart', 'walmart-omaha', 'Legacy published-board bridge', 'legacy_bridge', 'mixed', '{"migration_only":true}');
