-- Direct capture identities. The migration bridge remains separate so the
-- engine cannot relabel imported state as direct evidence.
INSERT OR IGNORE INTO capture_sources
  (id, store_location_id, name, capture_method, price_mode, coverage_policy_json)
VALUES
  ('direct-aldi-headless', 'aldi-omaha-446-048', 'Aldi direct headless', 'api', 'in_store', '{"max_age_days":14}'),
  ('direct-bakers-headless', 'bakers-saddle-creek', 'Bakers direct headless', 'api', 'pickup', '{"max_age_days":7}'),
  ('direct-family-fare-headless', 'family-fare-omaha-6401', 'Family Fare direct headless', 'freshop', 'pickup', '{"max_age_days":7}'),
  ('direct-fareway-headless', 'fareway-omaha-043', 'Fareway direct headless', 'api', 'pickup', '{"max_age_days":7}'),
  ('direct-hy-vee-headless', 'hy-vee-omaha-1465', 'Hy-Vee direct headless', 'api', 'pickup', '{"max_age_days":7}'),
  ('direct-sams-headless', 'sams-omaha', 'Sams Club direct headless', 'api', 'club', '{"max_age_days":14}'),
  ('direct-walmart-headless', 'walmart-omaha', 'Walmart direct headless', 'api', 'pickup', '{"max_age_days":7}'),
  ('direct-aldi-browser', 'aldi-omaha-446-048', 'Aldi direct Chrome', 'browser', 'in_store', '{"max_age_days":14}'),
  ('direct-bakers-browser', 'bakers-saddle-creek', 'Bakers direct Chrome', 'browser', 'pickup', '{"max_age_days":7}'),
  ('direct-family-fare-browser', 'family-fare-omaha-6401', 'Family Fare direct Chrome', 'browser', 'pickup', '{"max_age_days":7}'),
  ('direct-fareway-browser', 'fareway-omaha-043', 'Fareway direct Chrome', 'browser', 'pickup', '{"max_age_days":7}'),
  ('direct-hy-vee-browser', 'hy-vee-omaha-1465', 'Hy-Vee direct Chrome', 'browser', 'pickup', '{"max_age_days":7}'),
  ('direct-sams-browser', 'sams-omaha', 'Sams Club direct Chrome', 'browser', 'club', '{"max_age_days":14}'),
  ('direct-walmart-browser', 'walmart-omaha', 'Walmart direct Chrome', 'browser', 'pickup', '{"max_age_days":7}');
