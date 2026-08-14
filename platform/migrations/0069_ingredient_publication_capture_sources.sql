-- @policy expand-contract
-- Durable, merge-forward sources for independently QA-verified ingredient prices.

INSERT INTO capture_sources
  (id, store_location_id, name, capture_method, price_mode, coverage_policy_json, active)
VALUES
  ('ingredient-targeted-aldi', 'aldi-omaha-446-048', 'Ingredient targeted ALDI', 'browser', 'in_store', '{"max_age_days":14,"scope":"ingredient-targeted"}', 1),
  ('ingredient-targeted-bakers', 'bakers-saddle-creek', 'Ingredient targeted Bakers', 'api', 'in_store', '{"max_age_days":14,"scope":"ingredient-targeted"}', 1),
  ('ingredient-targeted-family-fare', 'family-fare-omaha-6401', 'Ingredient targeted Family Fare', 'freshop', 'pickup', '{"max_age_days":14,"scope":"ingredient-targeted"}', 1),
  ('ingredient-targeted-fareway', 'fareway-omaha-043', 'Ingredient targeted Fareway', 'browser', 'in_store', '{"max_age_days":14,"scope":"ingredient-targeted"}', 1),
  ('ingredient-targeted-hy-vee', 'hy-vee-omaha-1465', 'Ingredient targeted Hy-Vee', 'api', 'in_store', '{"max_age_days":14,"scope":"ingredient-targeted"}', 1),
  ('ingredient-targeted-sams', 'sams-omaha', 'Ingredient targeted Sams Club', 'browser', 'club', '{"max_age_days":14,"scope":"ingredient-targeted"}', 1),
  ('ingredient-targeted-walmart', 'walmart-omaha', 'Ingredient targeted Walmart', 'browser', 'pickup', '{"max_age_days":14,"scope":"ingredient-targeted"}', 1)
ON CONFLICT(id) DO UPDATE SET
  store_location_id = excluded.store_location_id,
  name = excluded.name,
  capture_method = excluded.capture_method,
  price_mode = excluded.price_mode,
  coverage_policy_json = excluded.coverage_policy_json,
  active = 1;
