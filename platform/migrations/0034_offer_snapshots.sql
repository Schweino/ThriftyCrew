-- @policy expand-contract
-- Immutable source-native offer meaning and availability evidence.

ALTER TABLE observations ADD COLUMN offer_snapshot_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(offer_snapshot_json));
ALTER TABLE observations ADD COLUMN availability_status TEXT NOT NULL DEFAULT 'unknown'
  CHECK (availability_status IN ('in_stock', 'out_of_stock', 'limited', 'unknown'));
ALTER TABLE observations ADD COLUMN fulfillment_mode TEXT NOT NULL DEFAULT 'unknown'
  CHECK (fulfillment_mode IN ('pickup', 'delivery', 'shipping', 'in_store', 'unknown'));
ALTER TABLE observations ADD COLUMN seller_name TEXT;

CREATE INDEX IF NOT EXISTS idx_observations_offer_availability
  ON observations(batch_id, availability_status, fulfillment_mode, captured_at);
