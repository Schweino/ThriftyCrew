-- @policy expand-contract
-- Authoritative full source roots plus ingredient-scoped overlays and a hot
-- catalog projection for store-oriented pricing resolution.

CREATE TABLE store_pricing_policies (
  store_location_id TEXT PRIMARY KEY REFERENCES store_locations(id),
  source_id TEXT NOT NULL REFERENCES capture_sources(id),
  plane TEXT NOT NULL CHECK (plane IN ('browser','headless')),
  price_mode TEXT NOT NULL CHECK (price_mode IN ('pickup','in_store','club')),
  minimum_interval_ms INTEGER NOT NULL CHECK (minimum_interval_ms >= 0),
  same_store_concurrency INTEGER NOT NULL CHECK (same_store_concurrency = 1),
  require_dual_price_agreement INTEGER NOT NULL CHECK (require_dual_price_agreement IN (0,1)),
  membership_required INTEGER NOT NULL CHECK (membership_required IN (0,1)),
  policy_version INTEGER NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

INSERT INTO store_pricing_policies
  (store_location_id, source_id, plane, price_mode, minimum_interval_ms, same_store_concurrency, require_dual_price_agreement, membership_required, policy_version)
VALUES
  ('aldi-omaha-446-048','direct-aldi-browser','browser','in_store',5000,1,0,0,1),
  ('bakers-saddle-creek','direct-bakers-headless','headless','in_store',180,1,0,0,1),
  ('family-fare-omaha-6401','direct-family-fare-headless','headless','pickup',500,1,0,0,1),
  ('fareway-omaha-043','direct-fareway-browser','browser','in_store',2000,1,0,0,1),
  ('hy-vee-omaha-1465','direct-hy-vee-headless','headless','in_store',500,1,0,0,1),
  ('sams-omaha','direct-sams-browser','browser','club',3000,1,1,1,1),
  ('walmart-omaha','direct-walmart-browser','browser','pickup',1500,1,1,0,1);

CREATE TABLE capture_source_roots (
  source_id TEXT PRIMARY KEY REFERENCES capture_sources(id),
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  base_batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  root_hash TEXT NOT NULL,
  coverage_mode TEXT NOT NULL CHECK (coverage_mode IN ('full','partial')),
  valid_from TEXT NOT NULL,
  valid_to TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE capture_scopes (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES capture_sources(id),
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  scope_kind TEXT NOT NULL CHECK (scope_kind IN ('ingredient','commodity','promotion')),
  bound_key TEXT NOT NULL,
  query_plan_hash TEXT NOT NULL,
  evidence_root_hash TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','validated','active','expired','rejected')),
  location_verified INTEGER NOT NULL CHECK (location_verified IN (0,1)),
  price_mode_verified INTEGER NOT NULL CHECK (price_mode_verified IN (0,1)),
  valid_from TEXT NOT NULL,
  valid_to TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  activated_at TEXT,
  UNIQUE (source_id, batch_id, scope_kind, bound_key)
) STRICT;

CREATE INDEX capture_scopes_active ON capture_scopes(store_location_id, state, bound_key, valid_to);

CREATE TABLE capture_scope_terms (
  scope_id TEXT NOT NULL REFERENCES capture_scopes(id),
  normalized_query TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('success','empty')),
  page_count INTEGER NOT NULL CHECK (page_count >= 0),
  result_count INTEGER NOT NULL CHECK (result_count >= 0),
  end_of_results INTEGER NOT NULL CHECK (end_of_results IN (0,1)),
  result_set_hash TEXT NOT NULL,
  PRIMARY KEY (scope_id, normalized_query)
) STRICT;

CREATE TABLE capture_scope_products (
  scope_id TEXT NOT NULL REFERENCES capture_scopes(id),
  product_id TEXT NOT NULL REFERENCES products(id),
  observation_id TEXT REFERENCES observations(id),
  current_status TEXT NOT NULL CHECK (current_status IN ('eligible','ineligible','unavailable','out_of_stock')),
  evidence_hash TEXT NOT NULL,
  PRIMARY KEY (scope_id, product_id)
) STRICT;

CREATE TABLE catalog_current_offers (
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  product_id TEXT NOT NULL REFERENCES products(id),
  observation_id TEXT NOT NULL REFERENCES observations(id),
  product_version_id TEXT NOT NULL REFERENCES product_versions(id),
  source_id TEXT NOT NULL REFERENCES capture_sources(id),
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  scope_id TEXT REFERENCES capture_scopes(id),
  normalized_name TEXT NOT NULL,
  product_name TEXT NOT NULL,
  size_text TEXT NOT NULL,
  product_url TEXT,
  availability_status TEXT NOT NULL,
  fulfillment_mode TEXT NOT NULL,
  seller_name TEXT,
  offer_kind TEXT NOT NULL,
  package_price_minor INTEGER NOT NULL CHECK (package_price_minor >= 0),
  normalized_basis_unit TEXT NOT NULL,
  normalized_basis_qty_micros INTEGER NOT NULL CHECK (normalized_basis_qty_micros > 0),
  per_unit_micros INTEGER NOT NULL CHECK (per_unit_micros >= 0),
  loyalty_required INTEGER NOT NULL CHECK (loyalty_required IN (0,1)),
  membership_required INTEGER NOT NULL CHECK (membership_required IN (0,1)),
  valid_from TEXT,
  valid_to TEXT,
  captured_at TEXT NOT NULL,
  evidence_hash TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (store_location_id, product_id)
) STRICT;

CREATE INDEX catalog_current_offers_name ON catalog_current_offers(store_location_id, normalized_name, captured_at DESC);
CREATE INDEX catalog_current_offers_unit_price ON catalog_current_offers(store_location_id, normalized_basis_unit, per_unit_micros, product_id);

CREATE TABLE catalog_offer_tokens (
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  token TEXT NOT NULL,
  product_id TEXT NOT NULL REFERENCES products(id),
  weight INTEGER NOT NULL DEFAULT 1 CHECK (weight > 0),
  PRIMARY KEY (store_location_id, token, product_id)
) STRICT;

CREATE INDEX catalog_offer_tokens_product ON catalog_offer_tokens(store_location_id, product_id, token);

PRAGMA optimize;
