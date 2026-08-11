-- @policy expand-contract
-- Capture-time identity, offer meaning, source-shape, and change-point evidence.

ALTER TABLE capture_batches ADD COLUMN source_contract_fingerprint TEXT;
ALTER TABLE capture_batches ADD COLUMN source_shape_fingerprint TEXT;
ALTER TABLE capture_batches ADD COLUMN source_schema_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(source_schema_json));

ALTER TABLE product_versions ADD COLUMN identity_fingerprint TEXT;
ALTER TABLE product_versions ADD COLUMN identity_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(identity_json));

ALTER TABLE observations ADD COLUMN price_semantics_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(price_semantics_json));

ALTER TABLE browser_capture_metrics ADD COLUMN page_state_attested_rows INTEGER NOT NULL DEFAULT 0 CHECK (page_state_attested_rows >= 0);
ALTER TABLE browser_capture_metrics ADD COLUMN promotion_semantics_rows INTEGER NOT NULL DEFAULT 0 CHECK (promotion_semantics_rows >= 0);

INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description) VALUES
  ('batch-sku-identity', 'batch', 'hard', 'Stable retailer identifiers do not conflict or get silently reused for a materially different product.'),
  ('batch-source-schema', 'batch', 'hard', 'Direct API source field paths and value types match the last promoted semantic contract.'),
  ('batch-change-point', 'batch', 'hard', 'Product price, package basis, and identity history contains no unexplained discontinuity.'),
  ('batch-price-semantics', 'batch', 'hard', 'Every current capture explicitly preserves offer type, qualification conditions, quantity, and total price.');
