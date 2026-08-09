PRAGMA foreign_keys = ON;

CREATE TABLE markets (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  timezone TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE store_brands (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  color TEXT,
  membership_required INTEGER NOT NULL DEFAULT 0 CHECK (membership_required IN (0, 1)),
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE TABLE store_locations (
  id TEXT PRIMARY KEY,
  brand_id TEXT NOT NULL REFERENCES store_brands(id),
  market_id TEXT NOT NULL REFERENCES markets(id),
  display_name TEXT NOT NULL,
  external_key TEXT,
  address_json TEXT NOT NULL DEFAULT '{}',
  identity_json TEXT NOT NULL DEFAULT '{}',
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  UNIQUE (brand_id, market_id, external_key)
) STRICT;

CREATE TABLE capture_sources (
  id TEXT PRIMARY KEY,
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  name TEXT NOT NULL,
  capture_method TEXT NOT NULL CHECK (capture_method IN ('api', 'browser', 'flipp', 'freshop', 'flyer_image', 'legacy_bridge')),
  price_mode TEXT NOT NULL CHECK (price_mode IN ('delivery', 'pickup', 'in_store', 'club', 'ad', 'mixed')),
  coverage_policy_json TEXT NOT NULL DEFAULT '{}',
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  UNIQUE (store_location_id, name)
) STRICT;

CREATE TABLE configuration_versions (
  id TEXT PRIMARY KEY,
  source_commit TEXT NOT NULL,
  content_hash TEXT NOT NULL UNIQUE,
  deployed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  active INTEGER NOT NULL DEFAULT 0 CHECK (active IN (0, 1))
) STRICT;

CREATE UNIQUE INDEX one_active_configuration ON configuration_versions(active) WHERE active = 1;

CREATE TABLE categories (
  id TEXT PRIMARY KEY,
  label TEXT NOT NULL,
  sort_order INTEGER NOT NULL DEFAULT 0
) STRICT;

CREATE TABLE commodities (
  id TEXT NOT NULL,
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  label TEXT NOT NULL,
  basis_unit TEXT NOT NULL,
  category_id TEXT REFERENCES categories(id),
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  PRIMARY KEY (id, configuration_id)
) STRICT;

CREATE TABLE match_rules (
  id TEXT PRIMARY KEY,
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  commodity_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('include', 'exclude')),
  pattern TEXT NOT NULL,
  reason TEXT NOT NULL,
  priority INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY (commodity_id, configuration_id) REFERENCES commodities(id, configuration_id),
  UNIQUE (configuration_id, commodity_id, kind, pattern)
) STRICT;

CREATE TABLE known_wrong_rules (
  id TEXT PRIMARY KEY,
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  commodity_id TEXT NOT NULL,
  store_location_id TEXT REFERENCES store_locations(id),
  external_product_key TEXT,
  normalized_name TEXT,
  ruling TEXT NOT NULL,
  evidence TEXT NOT NULL,
  FOREIGN KEY (commodity_id, configuration_id) REFERENCES commodities(id, configuration_id),
  CHECK (external_product_key IS NOT NULL OR normalized_name IS NOT NULL)
) STRICT;

CREATE TABLE capture_batches (
  id TEXT PRIMARY KEY,
  source_id TEXT NOT NULL REFERENCES capture_sources(id),
  coverage_mode TEXT NOT NULL CHECK (coverage_mode IN ('full', 'partial', 'targeted', 'ad_only')),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'sealed', 'validated', 'promoted', 'rejected', 'superseded')),
  captured_from TEXT NOT NULL,
  captured_to TEXT NOT NULL,
  ingested_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  valid_from TEXT,
  valid_to TEXT,
  expected_terms INTEGER CHECK (expected_terms IS NULL OR expected_terms >= 0),
  attempted_terms INTEGER NOT NULL DEFAULT 0 CHECK (attempted_terms >= 0),
  successful_terms INTEGER NOT NULL DEFAULT 0 CHECK (successful_terms >= 0),
  empty_terms INTEGER NOT NULL DEFAULT 0 CHECK (empty_terms >= 0),
  rejected_terms INTEGER NOT NULL DEFAULT 0 CHECK (rejected_terms >= 0),
  blocked_terms INTEGER NOT NULL DEFAULT 0 CHECK (blocked_terms >= 0),
  expected_pages INTEGER CHECK (expected_pages IS NULL OR expected_pages >= 0),
  captured_pages INTEGER CHECK (captured_pages IS NULL OR captured_pages >= 0),
  market_verified INTEGER NOT NULL CHECK (market_verified IN (0, 1)),
  location_verified INTEGER NOT NULL CHECK (location_verified IN (0, 1)),
  price_mode_verified INTEGER NOT NULL CHECK (price_mode_verified IN (0, 1)),
  agent_id TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  evidence_manifest_key TEXT,
  validation_summary_json TEXT NOT NULL DEFAULT '{}',
  sealed_at TEXT,
  promoted_at TEXT,
  superseded_by TEXT REFERENCES capture_batches(id),
  UNIQUE (agent_id, idempotency_key),
  CHECK (captured_to >= captured_from),
  CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
  CHECK (expected_pages IS NULL OR captured_pages IS NULL OR captured_pages <= expected_pages)
) STRICT;

CREATE INDEX capture_batches_source_time ON capture_batches(source_id, captured_to DESC);
CREATE INDEX capture_batches_status ON capture_batches(status, source_id);

CREATE TABLE capture_terms (
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  term_key TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  outcome TEXT NOT NULL CHECK (outcome IN ('success', 'empty', 'rejected', 'blocked', 'not_attempted')),
  row_count INTEGER NOT NULL DEFAULT 0 CHECK (row_count >= 0),
  reason TEXT,
  PRIMARY KEY (batch_id, term_key)
) STRICT;

CREATE TABLE evidence_objects (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  object_key TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('screenshot', 'flyer_page', 'raw_payload', 'manifest')),
  content_type TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
  sha256 TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TEXT
) STRICT;

CREATE TABLE products (
  id TEXT PRIMARY KEY,
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  external_key TEXT NOT NULL,
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  UNIQUE (store_location_id, external_key)
) STRICT;

CREATE TABLE product_versions (
  id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id),
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  size_text TEXT NOT NULL,
  product_url TEXT,
  image_url TEXT,
  package_json TEXT NOT NULL DEFAULT '{}',
  content_hash TEXT NOT NULL,
  first_seen_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  UNIQUE (product_id, content_hash)
) STRICT;

CREATE TABLE observations (
  id TEXT PRIMARY KEY,
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  product_version_id TEXT NOT NULL REFERENCES product_versions(id),
  term_key TEXT,
  kind TEXT NOT NULL CHECK (kind IN ('sale', 'everyday', 'markdown', 'member')),
  currency TEXT NOT NULL DEFAULT 'USD' CHECK (length(currency) = 3),
  purchase_price_minor INTEGER NOT NULL CHECK (purchase_price_minor >= 0),
  regular_price_minor INTEGER CHECK (regular_price_minor IS NULL OR regular_price_minor >= purchase_price_minor),
  purchase_quantity INTEGER NOT NULL DEFAULT 1 CHECK (purchase_quantity > 0),
  package_count INTEGER NOT NULL DEFAULT 1 CHECK (package_count > 0),
  captured_basis_unit TEXT NOT NULL,
  captured_basis_qty_micros INTEGER NOT NULL CHECK (captured_basis_qty_micros > 0),
  normalized_basis_unit TEXT NOT NULL,
  normalized_basis_qty_micros INTEGER NOT NULL CHECK (normalized_basis_qty_micros > 0),
  per_unit_micros INTEGER NOT NULL CHECK (per_unit_micros >= 0),
  loyalty_required INTEGER NOT NULL DEFAULT 0 CHECK (loyalty_required IN (0, 1)),
  membership_required INTEGER NOT NULL DEFAULT 0 CHECK (membership_required IN (0, 1)),
  raw_price_text TEXT NOT NULL,
  raw_size_text TEXT NOT NULL,
  captured_at TEXT NOT NULL,
  ingested_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  valid_from TEXT,
  valid_to TEXT,
  evidence_object_id TEXT REFERENCES evidence_objects(id),
  source_payload_key TEXT,
  UNIQUE (batch_id, product_version_id, kind, captured_at),
  CHECK (valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from),
  CHECK (captured_basis_unit <> '' AND normalized_basis_unit <> '')
) STRICT;

CREATE INDEX observations_batch ON observations(batch_id);
CREATE INDEX observations_product_time ON observations(product_version_id, captured_at DESC);

CREATE TRIGGER observations_no_update
BEFORE UPDATE ON observations
BEGIN
  SELECT RAISE(ABORT, 'observations are append-only');
END;

CREATE TRIGGER observations_no_delete
BEFORE DELETE ON observations
BEGIN
  SELECT RAISE(ABORT, 'observations are append-only; archive through the retention workflow');
END;

CREATE TABLE match_decisions (
  id TEXT PRIMARY KEY,
  product_id TEXT NOT NULL REFERENCES products(id),
  commodity_id TEXT NOT NULL,
  configuration_id TEXT NOT NULL,
  decided_by TEXT NOT NULL CHECK (decided_by IN ('rule', 'aisle', 'manual', 'legacy_bridge')),
  reason TEXT NOT NULL,
  decided_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  superseded_at TEXT,
  FOREIGN KEY (commodity_id, configuration_id) REFERENCES commodities(id, configuration_id)
) STRICT;

CREATE UNIQUE INDEX one_active_match_per_product ON match_decisions(product_id) WHERE superseded_at IS NULL;
CREATE INDEX active_matches_by_commodity ON match_decisions(configuration_id, commodity_id) WHERE superseded_at IS NULL;

CREATE TABLE job_schedules (
  job TEXT PRIMARY KEY,
  cron TEXT NOT NULL,
  max_gap_minutes INTEGER NOT NULL CHECK (max_gap_minutes > 0),
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE TABLE job_runs (
  id TEXT PRIMARY KEY,
  job TEXT NOT NULL REFERENCES job_schedules(job),
  trigger_kind TEXT NOT NULL CHECK (trigger_kind IN ('schedule', 'dispatch', 'watchdog', 'operator', 'test')),
  scheduled_for TEXT,
  started_at TEXT,
  finished_at TEXT,
  status TEXT NOT NULL CHECK (status IN ('scheduled', 'started', 'completed', 'failed', 'missed', 'timed_out', 'cancelled')),
  input_json TEXT NOT NULL DEFAULT '{}',
  stats_json TEXT NOT NULL DEFAULT '{}',
  error TEXT,
  CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
) STRICT;

CREATE INDEX job_runs_latest ON job_runs(job, started_at DESC);

CREATE TABLE releases (
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL REFERENCES markets(id),
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  engine_run_id TEXT REFERENCES job_runs(id),
  input_manifest_json TEXT NOT NULL,
  input_hash TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'validating', 'rejected', 'validated', 'published', 'superseded')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  validated_at TEXT,
  published_at TEXT,
  board_hash TEXT,
  recipe_hash TEXT,
  summary_json TEXT NOT NULL DEFAULT '{}',
  UNIQUE (market_id, input_hash)
) STRICT;

CREATE TABLE release_cells (
  release_id TEXT NOT NULL REFERENCES releases(id),
  commodity_id TEXT NOT NULL,
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  observation_id TEXT REFERENCES observations(id),
  status TEXT NOT NULL CHECK (status IN ('priced', 'missing', 'not_carried', 'held')),
  is_crown INTEGER NOT NULL DEFAULT 0 CHECK (is_crown IN (0, 1)),
  display_per_unit_micros INTEGER,
  display_unit TEXT,
  reason_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY (release_id, commodity_id, store_location_id),
  CHECK ((status = 'priced' AND observation_id IS NOT NULL AND display_per_unit_micros IS NOT NULL) OR status <> 'priced')
) STRICT;

CREATE INDEX release_cells_store ON release_cells(release_id, store_location_id);

CREATE TABLE release_recipe_costs (
  release_id TEXT NOT NULL REFERENCES releases(id),
  recipe_slug TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('complete', 'incomplete', 'held')),
  batch_cost_minor INTEGER,
  serving_cost_minor INTEGER,
  servings INTEGER NOT NULL CHECK (servings > 0),
  missing_ingredients_json TEXT NOT NULL DEFAULT '[]',
  detail_json TEXT NOT NULL DEFAULT '{}',
  PRIMARY KEY (release_id, recipe_slug),
  CHECK ((status = 'complete' AND batch_cost_minor IS NOT NULL AND serving_cost_minor IS NOT NULL) OR status <> 'complete')
) STRICT;

CREATE TABLE release_payloads (
  release_id TEXT NOT NULL REFERENCES releases(id),
  kind TEXT NOT NULL CHECK (kind IN ('board', 'feed', 'top5', 'free_rotation', 'recipes')),
  payload_json TEXT NOT NULL,
  content_hash TEXT NOT NULL,
  PRIMARY KEY (release_id, kind)
) STRICT;

CREATE TABLE guard_definitions (
  id TEXT PRIMARY KEY,
  scope TEXT NOT NULL CHECK (scope IN ('ingest', 'batch', 'release')),
  severity TEXT NOT NULL CHECK (severity IN ('hard', 'warning', 'info')),
  description TEXT NOT NULL,
  active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
) STRICT;

CREATE TABLE guard_results (
  id TEXT PRIMARY KEY,
  guard_id TEXT NOT NULL REFERENCES guard_definitions(id),
  batch_id TEXT REFERENCES capture_batches(id),
  release_id TEXT REFERENCES releases(id),
  status TEXT NOT NULL CHECK (status IN ('pass', 'fail', 'warn', 'blind', 'error')),
  eligible_count INTEGER NOT NULL CHECK (eligible_count >= 0),
  examined_count INTEGER NOT NULL CHECK (examined_count >= 0),
  finding_count INTEGER NOT NULL CHECK (finding_count >= 0),
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK ((batch_id IS NOT NULL) <> (release_id IS NOT NULL)),
  CHECK (examined_count <= eligible_count),
  CHECK (NOT (eligible_count > 0 AND examined_count = 0 AND status = 'pass'))
) STRICT;

CREATE INDEX guard_results_release ON guard_results(release_id, status);
CREATE INDEX guard_results_batch ON guard_results(batch_id, status);

CREATE TABLE guard_findings (
  id TEXT PRIMARY KEY,
  result_id TEXT NOT NULL REFERENCES guard_results(id),
  finding_key TEXT NOT NULL,
  message TEXT NOT NULL,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  UNIQUE (result_id, finding_key)
) STRICT;

CREATE TABLE current_releases (
  market_id TEXT PRIMARY KEY REFERENCES markets(id),
  release_id TEXT NOT NULL REFERENCES releases(id),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE publication_attempts (
  id TEXT PRIMARY KEY,
  release_id TEXT NOT NULL REFERENCES releases(id),
  surface TEXT NOT NULL CHECK (surface IN ('api', 'edge', 'ghost', 'route')),
  status TEXT NOT NULL CHECK (status IN ('started', 'verified', 'failed', 'rolled_back')),
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  detail_json TEXT NOT NULL DEFAULT '{}'
) STRICT;

CREATE TABLE request_nonces (
  agent_id TEXT NOT NULL,
  nonce TEXT NOT NULL,
  used_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TEXT NOT NULL,
  PRIMARY KEY (agent_id, nonce)
) STRICT;
