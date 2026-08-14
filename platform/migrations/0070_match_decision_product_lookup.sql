-- @policy expand-contract
-- Release guards and batch-integrity checks start from a bounded product set.
-- Without this product-leading index each lookup scans the entire historical
-- decision ledger, which exceeds D1 CPU as configuration history grows.

CREATE INDEX match_decisions_product_configuration_status
  ON match_decisions(product_id, configuration_id, superseded_at, decided_by, commodity_id);

