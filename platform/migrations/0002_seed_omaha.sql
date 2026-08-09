INSERT INTO markets (id, name, timezone) VALUES ('omaha', 'Omaha, Nebraska', 'America/Chicago');

INSERT INTO store_brands (id, name, color, membership_required) VALUES
  ('aldi', 'Aldi', '#0050aa', 0),
  ('bakers', 'Baker''s', '#e31837', 0),
  ('family-fare', 'Family Fare', '#d71920', 0),
  ('fareway', 'Fareway', '#d71920', 0),
  ('hy-vee', 'Hy-Vee', '#ed1c24', 0),
  ('sams', 'Sam''s Club', '#0067a0', 1),
  ('walmart', 'Walmart', '#0071ce', 0);

INSERT INTO store_locations (id, brand_id, market_id, display_name, external_key, identity_json) VALUES
  ('aldi-omaha-446-048', 'aldi', 'omaha', 'Aldi Omaha 446-048', '446-048', '{"merchant_store_code":"446-048"}'),
  ('bakers-saddle-creek', 'bakers', 'omaha', 'Baker''s Saddle Creek', 'saddle-creek', '{"market":"omaha"}'),
  ('family-fare-omaha-6401', 'family-fare', 'omaha', 'Family Fare Omaha 6401', '6401', '{"store_id":"6401"}'),
  ('fareway-omaha-043', 'fareway', 'omaha', 'Fareway Omaha 043', '043', '{"store":"043","ad_group":"OmahaGroup"}'),
  ('hy-vee-omaha-1465', 'hy-vee', 'omaha', 'Hy-Vee Omaha #01', '1465', '{"store_id":"1465","zip":"68106"}'),
  ('sams-omaha', 'sams', 'omaha', 'Sam''s Club Omaha', 'omaha', '{"zip":"68137"}'),
  ('walmart-omaha', 'walmart', 'omaha', 'Walmart Omaha', 'omaha', '{"zip":"68137"}');

INSERT INTO capture_sources (id, store_location_id, name, capture_method, price_mode, coverage_policy_json) VALUES
  ('aldi-ad', 'aldi-omaha-446-048', 'Aldi weekly ad', 'flipp', 'ad', '{"max_age_days":8}'),
  ('aldi-storefront', 'aldi-omaha-446-048', 'Aldi storefront', 'browser', 'pickup', '{"max_age_days":14,"requires_full_terms":true}'),
  ('bakers-kroger', 'bakers-saddle-creek', 'Baker''s Kroger API', 'api', 'pickup', '{"max_age_days":2}'),
  ('bakers-flyer', 'bakers-saddle-creek', 'Baker''s flyer', 'browser', 'ad', '{"max_age_days":8,"requires_page_manifest":true}'),
  ('family-fare-ad', 'family-fare-omaha-6401', 'Family Fare weekly ad', 'freshop', 'ad', '{"max_age_days":8}'),
  ('family-fare-storefront', 'family-fare-omaha-6401', 'Family Fare storefront', 'freshop', 'pickup', '{"max_age_days":14,"cursor_paced":true}'),
  ('fareway-ad', 'fareway-omaha-043', 'Fareway ad images', 'flyer_image', 'ad', '{"max_age_days":8,"requires_page_manifest":true}'),
  ('fareway-storefront', 'fareway-omaha-043', 'Fareway storefront', 'browser', 'pickup', '{"max_age_days":14,"requires_full_terms":true}'),
  ('hy-vee-ad', 'hy-vee-omaha-1465', 'Hy-Vee weekly ad', 'flipp', 'ad', '{"max_age_days":8}'),
  ('hy-vee-storefront', 'hy-vee-omaha-1465', 'Hy-Vee Aisles Online', 'api', 'pickup', '{"max_age_days":2}'),
  ('sams-storefront', 'sams-omaha', 'Sam''s Club storefront', 'browser', 'club', '{"max_age_days":14,"requires_full_terms":true}'),
  ('walmart-storefront', 'walmart-omaha', 'Walmart storefront', 'browser', 'pickup', '{"max_age_days":14,"requires_full_terms":true}');

INSERT INTO job_schedules (job, cron, max_gap_minutes) VALUES
  ('daily-engine', '0 12 * * *', 1560),
  ('capture-watchdog', '15 * * * *', 180),
  ('d1-backup', '30 4 * * *', 1560);

INSERT INTO guard_definitions (id, scope, severity, description) VALUES
  ('batch-location', 'batch', 'hard', 'Capture proves the intended market, location and price mode.'),
  ('batch-completeness', 'batch', 'hard', 'Full captures meet their expected term or page envelope.'),
  ('batch-collapse', 'batch', 'hard', 'Capture volume has not silently collapsed against its comparable predecessor.'),
  ('release-category-coverage', 'release', 'hard', 'Every active commodity belongs to exactly one category.'),
  ('release-store-coverage', 'release', 'hard', 'Per-store priced-cell coverage stays above its accepted floor.'),
  ('release-cell-drops', 'release', 'hard', 'Previously priced cells cannot disappear without an explicit reason.'),
  ('release-known-wrong', 'release', 'hard', 'No selected observation is covered by a known-wrong ruling.'),
  ('release-basis', 'release', 'hard', 'Displayed normalized price agrees with captured price and package basis.'),
  ('release-capture-eviction', 'release', 'hard', 'A thin fresh partial batch cannot evict a better eligible observation.'),
  ('release-recipe-completeness', 'release', 'hard', 'Required recipe ingredients are never silently omitted from cost.'),
  ('release-surface-counts', 'release', 'hard', 'Board, feed and recipe manifests contain the expected authored entities.'),
  ('guard-not-blind', 'release', 'hard', 'A guard with eligible rows must examine at least one row.');
