-- @policy expand-contract
-- Target the measured engine and matching hot paths without weakening immutable inputs.

CREATE INDEX observations_batch_product_time
  ON observations(batch_id, product_version_id, captured_at DESC, id DESC);

CREATE INDEX capture_batches_promoted_source_latest
  ON capture_batches(status, source_id, captured_to DESC, promoted_at DESC, id DESC);

CREATE INDEX known_wrong_external_lookup
  ON known_wrong_rules(configuration_id, commodity_id, external_product_key, store_location_id)
  WHERE external_product_key IS NOT NULL;

CREATE INDEX known_wrong_name_lookup
  ON known_wrong_rules(configuration_id, commodity_id, normalized_name, store_location_id)
  WHERE normalized_name IS NOT NULL;

PRAGMA optimize;
