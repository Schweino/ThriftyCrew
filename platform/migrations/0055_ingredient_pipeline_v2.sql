-- @policy expand-contract
-- Store-oriented ingredient pricing, immutable resolution evidence, exact
-- recipe dependency barriers, and event-driven orchestration. Legacy tables
-- remain in place for dual-write and rollback during the v2 canary.

CREATE TABLE ingredient_entities (
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL REFERENCES markets(id),
  canonical_name TEXT NOT NULL,
  identity_hash TEXT NOT NULL,
  identity_json TEXT NOT NULL DEFAULT '{}',
  state TEXT NOT NULL DEFAULT 'candidate'
    CHECK (state IN ('candidate','existing_commodity','novel','published','excluded_noncommodity','permanently_unavailable')),
  commodity_id TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (market_id, identity_hash)
) STRICT;

CREATE TABLE ingredient_aliases (
  market_id TEXT NOT NULL REFERENCES markets(id),
  normalized_alias TEXT NOT NULL,
  entity_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  resolution_source TEXT NOT NULL CHECK (resolution_source IN ('legacy','deterministic','model','operator')),
  confidence TEXT NOT NULL CHECK (confidence IN ('exact','high','reviewed')),
  evidence_hash TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (market_id, normalized_alias)
) STRICT;

CREATE TABLE recipe_source_fact_versions (
  id TEXT PRIMARY KEY,
  request_id TEXT NOT NULL REFERENCES recipe_suggestion_requests(id),
  candidate_id TEXT NOT NULL,
  source_url TEXT NOT NULL,
  accessed_at TEXT NOT NULL,
  artifact_key TEXT,
  artifact_hash TEXT NOT NULL,
  facts_json TEXT NOT NULL,
  facts_hash TEXT NOT NULL,
  verifier_version TEXT NOT NULL,
  verified_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (request_id, candidate_id, facts_hash)
) STRICT;

CREATE TABLE recipe_mapping_versions (
  id TEXT PRIMARY KEY,
  source_fact_version_id TEXT NOT NULL REFERENCES recipe_source_fact_versions(id),
  mapping_json TEXT NOT NULL,
  mapping_hash TEXT NOT NULL,
  mapper_version TEXT NOT NULL,
  verified_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (source_fact_version_id, mapping_hash)
) STRICT;

CREATE TABLE recipe_hold_requirements (
  hold_id TEXT NOT NULL REFERENCES recipe_ingredient_holds(id),
  gap_id TEXT NOT NULL REFERENCES ingredient_gaps(id),
  entity_id TEXT REFERENCES ingredient_entities(id),
  source_ingredient_index INTEGER CHECK (source_ingredient_index IS NULL OR source_ingredient_index >= 0),
  resolution_version_id TEXT,
  terminal_kind TEXT CHECK (terminal_kind IS NULL OR terminal_kind IN ('available','unavailable','alias','noncommodity')),
  satisfied_at TEXT,
  blocked_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (hold_id, gap_id)
) STRICT;

CREATE INDEX recipe_hold_requirements_gap ON recipe_hold_requirements(gap_id, hold_id);

CREATE TABLE pipeline_outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  topic TEXT NOT NULL,
  aggregate_kind TEXT NOT NULL,
  aggregate_id TEXT NOT NULL,
  dedupe_key TEXT NOT NULL UNIQUE,
  payload_json TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  available_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  delivered_at TEXT,
  acknowledged_at TEXT,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE INDEX pipeline_outbox_ready ON pipeline_outbox(acknowledged_at, available_at, id);

CREATE TABLE pipeline_stage_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  campaign_id TEXT,
  lane TEXT NOT NULL CHECK (lane IN ('discovery','pricing','recipe','publication','operator')),
  aggregate_kind TEXT NOT NULL,
  aggregate_id TEXT NOT NULL,
  stage TEXT NOT NULL,
  event_kind TEXT NOT NULL,
  detail_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE INDEX pipeline_stage_events_progress ON pipeline_stage_events(campaign_id, created_at DESC, id DESC);

CREATE TABLE pricing_waves (
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL REFERENCES markets(id),
  campaign_id TEXT,
  source_kind TEXT NOT NULL CHECK (source_kind IN ('recipe','adhoc','backfill')),
  target_available INTEGER NOT NULL CHECK (target_available > 0),
  state TEXT NOT NULL DEFAULT 'planning'
    CHECK (state IN ('planning','resolving','qa','publishing','published','attention','failed','cancelled')),
  input_hash TEXT NOT NULL,
  deadline_at TEXT,
  externally_blocked_millis INTEGER NOT NULL DEFAULT 0 CHECK (externally_blocked_millis >= 0),
  last_progress_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TEXT,
  UNIQUE (market_id, input_hash)
) STRICT;

CREATE INDEX pricing_waves_state ON pricing_waves(state, last_progress_at, id);

CREATE TABLE ingredient_pricing_jobs (
  id TEXT PRIMARY KEY,
  wave_id TEXT REFERENCES pricing_waves(id),
  gap_id TEXT NOT NULL REFERENCES ingredient_gaps(id),
  entity_id TEXT REFERENCES ingredient_entities(id),
  market_id TEXT NOT NULL REFERENCES markets(id),
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued','store_checks_running','aggregate_qa','ready_to_publish','publishing','public_verified','permanently_unavailable','needs_operator','failed')),
  semantic_plan_hash TEXT,
  terminal_store_count INTEGER NOT NULL DEFAULT 0 CHECK (terminal_store_count BETWEEN 0 AND 7),
  priced_store_count INTEGER NOT NULL DEFAULT 0 CHECK (priced_store_count BETWEEN 0 AND 7),
  not_found_store_count INTEGER NOT NULL DEFAULT 0 CHECK (not_found_store_count BETWEEN 0 AND 7),
  resolution_version_id TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (gap_id, market_id)
) STRICT;

CREATE INDEX ingredient_pricing_jobs_state ON ingredient_pricing_jobs(state, updated_at, id);

CREATE TABLE ingredient_query_plans (
  id TEXT PRIMARY KEY,
  pricing_job_id TEXT NOT NULL REFERENCES ingredient_pricing_jobs(id),
  version INTEGER NOT NULL CHECK (version > 0),
  canonical_term TEXT NOT NULL,
  aliases_json TEXT NOT NULL DEFAULT '[]',
  exclusions_json TEXT NOT NULL DEFAULT '[]',
  plan_hash TEXT NOT NULL,
  planner_version TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (pricing_job_id, version),
  UNIQUE (pricing_job_id, plan_hash)
) STRICT;

CREATE TABLE ingredient_store_checks (
  id TEXT PRIMARY KEY,
  pricing_job_id TEXT NOT NULL REFERENCES ingredient_pricing_jobs(id),
  gap_id TEXT NOT NULL REFERENCES ingredient_gaps(id),
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued','catalog_lookup','targeted_refresh','leased','evidence_ready','qa_pending','qa_verified_priced','qa_verified_not_found','blocked_challenge','ambiguous','transient_failed','adapter_quarantined','evidence_expired')),
  terminal_outcome TEXT CHECK (terminal_outcome IS NULL OR terminal_outcome IN ('priced','not_found')),
  query_plan_id TEXT REFERENCES ingredient_query_plans(id),
  evidence_id TEXT,
  qa_attestation_id TEXT,
  candidate_count INTEGER NOT NULL DEFAULT 0 CHECK (candidate_count >= 0),
  eligible_count INTEGER NOT NULL DEFAULT 0 CHECK (eligible_count >= 0),
  lease_owner TEXT,
  lease_generation INTEGER NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
  lease_expires_at TEXT,
  heartbeat_at TEXT,
  next_attempt_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  challenge_id TEXT,
  last_error TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (pricing_job_id, store_location_id)
) STRICT;

CREATE INDEX ingredient_store_checks_claim ON ingredient_store_checks(store_location_id, state, next_attempt_at, created_at, id);
CREATE INDEX ingredient_store_checks_job ON ingredient_store_checks(pricing_job_id, state, id);

CREATE TABLE ingredient_query_coverage (
  id TEXT PRIMARY KEY,
  store_check_id TEXT NOT NULL REFERENCES ingredient_store_checks(id),
  normalized_query TEXT NOT NULL,
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  price_mode TEXT NOT NULL CHECK (price_mode IN ('pickup','in_store','club')),
  scope_root_id TEXT NOT NULL,
  page_count INTEGER NOT NULL CHECK (page_count >= 0),
  result_count INTEGER NOT NULL CHECK (result_count >= 0),
  complete INTEGER NOT NULL CHECK (complete IN (0,1)),
  termination_reason TEXT NOT NULL,
  result_set_hash TEXT NOT NULL,
  location_verified INTEGER NOT NULL CHECK (location_verified IN (0,1)),
  price_mode_verified INTEGER NOT NULL CHECK (price_mode_verified IN (0,1)),
  completed_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  evidence_hash TEXT NOT NULL,
  UNIQUE (store_check_id, normalized_query, scope_root_id)
) STRICT;

CREATE INDEX ingredient_query_coverage_lookup ON ingredient_query_coverage(store_location_id, normalized_query, complete, expires_at DESC);

CREATE TABLE ingredient_store_candidates (
  id TEXT PRIMARY KEY,
  store_check_id TEXT NOT NULL REFERENCES ingredient_store_checks(id),
  product_id TEXT,
  product_version_id TEXT,
  observation_id TEXT REFERENCES observations(id),
  retailer_product_key TEXT NOT NULL,
  product_name TEXT NOT NULL,
  package_text TEXT NOT NULL,
  package_price_minor INTEGER CHECK (package_price_minor IS NULL OR package_price_minor >= 0),
  normalized_basis_unit TEXT,
  normalized_basis_qty_micros INTEGER CHECK (normalized_basis_qty_micros IS NULL OR normalized_basis_qty_micros > 0),
  per_unit_micros INTEGER CHECK (per_unit_micros IS NULL OR per_unit_micros >= 0),
  offer_kind TEXT CHECK (offer_kind IS NULL OR offer_kind IN ('sale','everyday','markdown','member')),
  valid_from TEXT,
  valid_to TEXT,
  loyalty_required INTEGER NOT NULL DEFAULT 0 CHECK (loyalty_required IN (0,1)),
  membership_required INTEGER NOT NULL DEFAULT 0 CHECK (membership_required IN (0,1)),
  eligible INTEGER NOT NULL CHECK (eligible IN (0,1)),
  rejection_codes_json TEXT NOT NULL DEFAULT '[]',
  evidence_hash TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (store_check_id, retailer_product_key, evidence_hash)
) STRICT;

CREATE INDEX ingredient_store_candidates_rank ON ingredient_store_candidates(store_check_id, eligible, per_unit_micros, id);

CREATE TABLE ingredient_evidence_refs (
  id TEXT PRIMARY KEY,
  store_check_id TEXT NOT NULL REFERENCES ingredient_store_checks(id),
  kind TEXT NOT NULL CHECK (kind IN ('catalog','query','product','offer','not_found','challenge','qa_bundle')),
  object_key TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  byte_length INTEGER NOT NULL CHECK (byte_length >= 0),
  content_type TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  source_url TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (store_check_id, kind, sha256)
) STRICT;

CREATE TABLE ingredient_qa_attestations (
  id TEXT PRIMARY KEY,
  store_check_id TEXT NOT NULL REFERENCES ingredient_store_checks(id),
  input_hash TEXT NOT NULL,
  validator_versions_json TEXT NOT NULL,
  verdict TEXT NOT NULL CHECK (verdict IN ('priced','not_found','ambiguous','blocked','failed')),
  winner_candidate_id TEXT REFERENCES ingredient_store_candidates(id),
  findings_json TEXT NOT NULL DEFAULT '[]',
  output_hash TEXT NOT NULL,
  model_execution_id TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (store_check_id, input_hash, output_hash)
) STRICT;

CREATE TABLE ingredient_resolution_versions (
  id TEXT PRIMARY KEY,
  pricing_job_id TEXT NOT NULL REFERENCES ingredient_pricing_jobs(id),
  gap_id TEXT NOT NULL REFERENCES ingredient_gaps(id),
  disposition TEXT NOT NULL CHECK (disposition IN ('available','unavailable','alias','noncommodity')),
  evidence_root_hash TEXT NOT NULL,
  commodity_proposal_hash TEXT,
  qa_policy_version TEXT NOT NULL,
  qa_result_hash TEXT NOT NULL,
  evidence_bundle_key TEXT NOT NULL,
  sealed_at TEXT NOT NULL,
  UNIQUE (pricing_job_id, evidence_root_hash)
) STRICT;

CREATE TABLE ingredient_current_resolutions (
  gap_id TEXT PRIMARY KEY REFERENCES ingredient_gaps(id),
  resolution_version_id TEXT NOT NULL REFERENCES ingredient_resolution_versions(id),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE permanently_unavailable_ingredients (
  entity_id TEXT PRIMARY KEY REFERENCES ingredient_entities(id),
  resolution_version_id TEXT NOT NULL REFERENCES ingredient_resolution_versions(id),
  identity_hash TEXT NOT NULL,
  aliases_json TEXT NOT NULL,
  reopened_at TEXT,
  reopen_reason TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE ingredient_publication_batches (
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL REFERENCES markets(id),
  parent_release_id TEXT REFERENCES releases(id),
  parent_configuration_id TEXT REFERENCES configuration_versions(id),
  target_configuration_id TEXT REFERENCES configuration_versions(id),
  source_commit TEXT,
  member_root_hash TEXT NOT NULL,
  capture_root_hash TEXT,
  match_root_hash TEXT,
  release_id TEXT REFERENCES releases(id),
  state TEXT NOT NULL DEFAULT 'open'
    CHECK (state IN ('open','sealed','git_committed','config_materialized','match_ready','release_built','validated','pointer_published','edge_verified','completed','failed','rolled_back')),
  lease_owner TEXT,
  lease_generation INTEGER NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
  lease_expires_at TEXT,
  failure_class TEXT,
  failure_detail TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TEXT
) STRICT;

CREATE INDEX ingredient_publication_batches_state ON ingredient_publication_batches(state, created_at, id);

CREATE TABLE ingredient_publication_members (
  batch_id TEXT NOT NULL REFERENCES ingredient_publication_batches(id),
  gap_id TEXT NOT NULL REFERENCES ingredient_gaps(id),
  resolution_version_id TEXT NOT NULL REFERENCES ingredient_resolution_versions(id),
  commodity_id TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending','configured','matched','released','public_verified','failed')),
  content_hash TEXT,
  public_proof_id TEXT,
  failure_detail TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (batch_id, gap_id)
) STRICT;

CREATE TABLE public_verification_proofs (
  id TEXT PRIMARY KEY,
  publication_batch_id TEXT NOT NULL REFERENCES ingredient_publication_batches(id),
  release_id TEXT NOT NULL REFERENCES releases(id),
  origin_kind TEXT NOT NULL CHECK (origin_kind IN ('worker','custom_domain')),
  url TEXT NOT NULL,
  expected_hash TEXT NOT NULL,
  observed_hash TEXT NOT NULL,
  response_status INTEGER NOT NULL,
  etag TEXT,
  response_release_id TEXT,
  response_object_key TEXT,
  verified INTEGER NOT NULL CHECK (verified IN (0,1)),
  checked_at TEXT NOT NULL,
  UNIQUE (publication_batch_id, origin_kind, url, observed_hash)
) STRICT;

CREATE TABLE recipe_resume_events (
  id TEXT PRIMARY KEY,
  hold_id TEXT NOT NULL REFERENCES recipe_ingredient_holds(id),
  dependency_root_hash TEXT NOT NULL,
  configuration_id TEXT NOT NULL REFERENCES configuration_versions(id),
  release_id TEXT NOT NULL REFERENCES releases(id),
  state TEXT NOT NULL DEFAULT 'ready' CHECK (state IN ('ready','consumed','cancelled')),
  consumed_work_item_id TEXT REFERENCES agent_work_items(id),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  consumed_at TEXT,
  UNIQUE (hold_id, dependency_root_hash, release_id)
) STRICT;

-- Compatibility backfill. Identity hashes are explicitly legacy-scoped until
-- the deterministic canonical identity resolver replaces them.
INSERT INTO ingredient_entities
  (id, market_id, canonical_name, identity_hash, state, commodity_id, created_at, updated_at)
SELECT 'entity_' || id, 'omaha', display_name, 'legacy:' || normalized_name,
       CASE status WHEN 'published' THEN 'published' WHEN 'permanently_unavailable' THEN 'permanently_unavailable' ELSE 'novel' END,
       commodity_id, first_seen_at, updated_at
  FROM ingredient_gaps;

INSERT INTO ingredient_aliases
  (market_id, normalized_alias, entity_id, resolution_source, confidence, created_at)
SELECT 'omaha', normalized_name, 'entity_' || id, 'legacy', 'exact', first_seen_at
  FROM ingredient_gaps;

INSERT INTO recipe_hold_requirements (hold_id, gap_id, entity_id)
SELECT hold.id, value.value, 'entity_' || value.value
  FROM recipe_ingredient_holds hold, json_each(hold.gap_ids_json) value;

PRAGMA optimize;
