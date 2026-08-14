-- @policy expand-contract
-- Independently captured warm generations. Raw payloads remain in R2; only
-- searchable hot products for the current and previous generation live in D1.

INSERT INTO pipeline_rollouts (feature, mode, updated_by, reason) VALUES
  ('store_catalog_batch_v4','off','migration-0072','enable after seven-lane shadow benchmark')
ON CONFLICT(feature) DO NOTHING;

CREATE TABLE store_catalog_generations (
  generation_id TEXT PRIMARY KEY,
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  fulfillment_mode TEXT NOT NULL,
  session_kind TEXT NOT NULL CHECK (session_kind IN ('producer','verifier')),
  adapter_version TEXT NOT NULL,
  coverage_kind TEXT NOT NULL CHECK (coverage_kind IN ('full','targeted')),
  started_at TEXT NOT NULL,
  completed_at TEXT,
  status TEXT NOT NULL CHECK (status IN ('running','complete','challenge_blocked','failed')),
  result_count INTEGER NOT NULL DEFAULT 0 CHECK (result_count >= 0),
  coverage_count INTEGER NOT NULL DEFAULT 0 CHECK (coverage_count >= 0),
  coverage_hash TEXT,
  raw_manifest_key TEXT,
  challenge_id TEXT,
  failure_class TEXT,
  failure_detail TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE store_catalog_generation_products (
  generation_id TEXT NOT NULL REFERENCES store_catalog_generations(generation_id),
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  stable_product_id TEXT NOT NULL,
  normalized_identity TEXT NOT NULL,
  product_name TEXT NOT NULL,
  brand TEXT,
  package_json TEXT NOT NULL,
  price_json TEXT NOT NULL,
  valid_from TEXT,
  valid_to TEXT,
  evidence_ref_id TEXT NOT NULL REFERENCES ingredient_evidence_refs(id),
  source_hash TEXT NOT NULL CHECK (length(source_hash) = 64),
  captured_at TEXT NOT NULL,
  PRIMARY KEY (generation_id, stable_product_id)
) STRICT;

CREATE TABLE pipeline_agent_work_items_v4 (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  dedupe_key TEXT NOT NULL UNIQUE,
  priority INTEGER NOT NULL DEFAULT 100,
  state TEXT NOT NULL CHECK (state IN ('queued','claimed','running','blocked_challenge','needs_operator','succeeded','failed_transient','failed_permanent','superseded')),
  available_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  lease_owner TEXT,
  lease_generation INTEGER NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
  lease_expires_at TEXT,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  input_ref_hash TEXT NOT NULL,
  result_ref_hash TEXT,
  correlation_id TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  started_at TEXT,
  heartbeat_at TEXT,
  terminal_at TEXT,
  blocked_at TEXT,
  metrics_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE INDEX store_generations_current ON store_catalog_generations(store_location_id, session_kind, status, completed_at DESC);
CREATE INDEX store_generation_products_search ON store_catalog_generation_products(store_location_id, generation_id, normalized_identity);
CREATE UNIQUE INDEX store_generation_product_identity ON store_catalog_generation_products(store_location_id, generation_id, stable_product_id);
CREATE INDEX pipeline_agent_work_claim ON pipeline_agent_work_items_v4(agent_id, state, available_at, priority, id);
CREATE INDEX pipeline_agent_work_lease ON pipeline_agent_work_items_v4(state, lease_expires_at, id);

PRAGMA optimize;
