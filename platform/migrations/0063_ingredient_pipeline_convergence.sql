-- @policy expand-contract
-- Convergent, store-oriented ingredient orchestration. Existing v2 state
-- columns remain readable during shadow/canary rollout; operational_state is
-- the v3 transition authority until a later contract migration.

CREATE TABLE pipeline_rollouts (
  feature TEXT PRIMARY KEY,
  mode TEXT NOT NULL CHECK (mode IN ('off','shadow','canary','enforce')),
  updated_by TEXT NOT NULL,
  reason TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

INSERT INTO pipeline_rollouts (feature, mode, updated_by, reason) VALUES
  ('ingredient_model_price_authority','off','migration-0063','model-authored prices are forensic evidence only'),
  ('ingredient_coordinator_v3','off','migration-0063','enable after coordinator shadow validation'),
  ('ingredient_identity_v3','off','migration-0063','enable after atomic identity corpus passes'),
  ('ingredient_catalog_batch_v3','off','migration-0063','enable after golden candidate-set parity'),
  ('ingredient_targeted_capture_v3','off','migration-0063','enable after seven-store capability proof'),
  ('ingredient_qa_v3','off','migration-0063','enable after independent-QA property tests'),
  ('ingredient_publication_v3','off','migration-0063','enable after atomic-publication fault tests'),
  ('recipe_locked_resume_v3','off','migration-0063','enable after dependency-barrier tests');

ALTER TABLE ingredient_pricing_jobs ADD COLUMN operational_state TEXT NOT NULL DEFAULT 'queued';
ALTER TABLE ingredient_pricing_jobs ADD COLUMN state_version INTEGER NOT NULL DEFAULT 1 CHECK (state_version > 0);
ALTER TABLE ingredient_pricing_jobs ADD COLUMN cancellation_kind TEXT;
ALTER TABLE ingredient_pricing_jobs ADD COLUMN terminal_at TEXT;
ALTER TABLE ingredient_pricing_jobs ADD COLUMN attention_count INTEGER NOT NULL DEFAULT 0 CHECK (attention_count >= 0);
ALTER TABLE ingredient_pricing_jobs ADD COLUMN last_progress_at TEXT;

ALTER TABLE ingredient_store_checks ADD COLUMN operational_state TEXT NOT NULL DEFAULT 'queued';
ALTER TABLE ingredient_store_checks ADD COLUMN state_version INTEGER NOT NULL DEFAULT 1 CHECK (state_version > 0);
ALTER TABLE ingredient_store_checks ADD COLUMN lease_lane TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN resume_state TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN cancellation_kind TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN cancelled_at TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN error_class TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN evidence_generation INTEGER NOT NULL DEFAULT 0 CHECK (evidence_generation >= 0);
ALTER TABLE ingredient_store_checks ADD COLUMN qa_generation INTEGER NOT NULL DEFAULT 0 CHECK (qa_generation >= 0);
ALTER TABLE ingredient_store_checks ADD COLUMN query_plan_hash TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN capture_request_id TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN capture_scope_id TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN capture_batch_id TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN producer_version TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN verifier_version TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN capture_started_at TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN capture_completed_at TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN qa_started_at TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN qa_completed_at TEXT;
ALTER TABLE ingredient_store_checks ADD COLUMN externally_blocked_millis INTEGER NOT NULL DEFAULT 0 CHECK (externally_blocked_millis >= 0);
ALTER TABLE ingredient_store_checks ADD COLUMN last_progress_at TEXT;

ALTER TABLE pricing_wave_members ADD COLUMN outcome TEXT;
ALTER TABLE pricing_wave_members ADD COLUMN terminal_at TEXT;

ALTER TABLE pipeline_outbox ADD COLUMN lease_owner TEXT;
ALTER TABLE pipeline_outbox ADD COLUMN lease_generation INTEGER NOT NULL DEFAULT 0 CHECK (lease_generation >= 0);
ALTER TABLE pipeline_outbox ADD COLUMN lease_expires_at TEXT;
ALTER TABLE pipeline_outbox ADD COLUMN last_delivery_error TEXT;

CREATE TABLE ingredient_pricing_inbox (
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL REFERENCES markets(id),
  entity_id TEXT NOT NULL REFERENCES ingredient_entities(id),
  gap_id TEXT NOT NULL REFERENCES ingredient_gaps(id),
  pricing_job_id TEXT NOT NULL REFERENCES ingredient_pricing_jobs(id),
  campaign_id TEXT,
  priority INTEGER NOT NULL DEFAULT 100,
  state TEXT NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued','active','publish_pending','operator_attention')),
  lease_owner TEXT,
  lease_generation INTEGER NOT NULL DEFAULT 0 CHECK (lease_generation >= 0),
  lease_expires_at TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (market_id, entity_id),
  UNIQUE (pricing_job_id)
) STRICT;

CREATE INDEX ingredient_pricing_inbox_claim
  ON ingredient_pricing_inbox(state, priority, created_at, id);

CREATE TABLE ingredient_capture_challenges (
  id TEXT PRIMARY KEY,
  store_check_id TEXT NOT NULL REFERENCES ingredient_store_checks(id),
  store_location_id TEXT NOT NULL REFERENCES store_locations(id),
  ingredient_entity_id TEXT REFERENCES ingredient_entities(id),
  normalized_query TEXT NOT NULL,
  session_id TEXT,
  tab_ownership_id TEXT,
  reason TEXT NOT NULL,
  pre_canary_evidence_hash TEXT,
  post_canary_evidence_hash TEXT,
  opened_at TEXT NOT NULL,
  acknowledged_at TEXT,
  canary_passed_at TEXT,
  resolved_at TEXT,
  abandoned_at TEXT,
  UNIQUE (store_check_id, opened_at)
) STRICT;

CREATE INDEX ingredient_capture_challenges_open
  ON ingredient_capture_challenges(resolved_at, abandoned_at, opened_at, id);
CREATE INDEX ingredient_store_checks_v3_claim
  ON ingredient_store_checks(store_location_id, operational_state, next_attempt_at, created_at, id);
CREATE INDEX ingredient_store_checks_v3_progress
  ON ingredient_store_checks(last_progress_at, operational_state, id);
CREATE INDEX pipeline_outbox_v3_claim
  ON pipeline_outbox(acknowledged_at, lease_expires_at, available_at, id);

-- Seed operational state without changing the legacy CHECK-constrained state.
UPDATE ingredient_pricing_jobs
   SET operational_state = CASE
     WHEN state = 'public_verified' THEN 'public_verified'
     WHEN state = 'permanently_unavailable' THEN 'permanently_unavailable'
     WHEN state = 'ready_to_publish' THEN 'ready_to_publish'
     WHEN state = 'publishing' THEN 'publishing'
     WHEN state = 'failed' AND cancellation_kind IS NOT NULL THEN 'cancelled'
     WHEN state = 'failed' THEN 'failed_manual'
     WHEN state = 'needs_operator' THEN 'store_checks_running'
     ELSE 'store_checks_running'
   END,
       last_progress_at = updated_at;

UPDATE ingredient_store_checks
   SET operational_state = CASE
     WHEN state = 'queued' THEN 'queued'
     WHEN state = 'catalog_lookup' THEN 'catalog_lookup'
     WHEN state = 'targeted_refresh' THEN 'capture_queued'
     WHEN state = 'leased' THEN 'capture_leased'
     WHEN state = 'evidence_ready' THEN 'evidence_ready'
     WHEN state = 'qa_pending' THEN 'qa_queued'
     WHEN state = 'qa_verified_priced' THEN 'qa_verified_priced'
     WHEN state = 'qa_verified_not_found' THEN 'qa_verified_not_found'
     WHEN state = 'blocked_challenge' AND challenge_id IS NOT NULL THEN 'challenge_blocked'
     WHEN state = 'blocked_challenge' THEN 'location_blocked'
     WHEN state = 'ambiguous' THEN 'ambiguous'
     WHEN state = 'adapter_quarantined' THEN 'adapter_quarantined'
     WHEN state = 'evidence_expired' THEN 'evidence_expired'
     ELSE 'transient_backoff'
   END,
       query_plan_hash = (SELECT plan.plan_hash FROM ingredient_query_plans plan WHERE plan.id = ingredient_store_checks.query_plan_id),
       last_progress_at = updated_at;

-- Children of cancelled/excluded legacy jobs are administratively terminal.
UPDATE ingredient_store_checks
   SET operational_state = 'cancelled', cancellation_kind = 'parent_terminal',
       cancelled_at = CURRENT_TIMESTAMP, last_progress_at = CURRENT_TIMESTAMP,
       lease_owner = NULL, lease_expires_at = NULL, heartbeat_at = NULL
 WHERE pricing_job_id IN (
   SELECT job.id FROM ingredient_pricing_jobs job
   JOIN ingredient_gaps gap ON gap.id = job.gap_id
   WHERE job.state = 'failed' OR gap.qa_resolution IN ('excluded_noncommodity','alias_existing')
 );

UPDATE ingredient_pricing_jobs
   SET operational_state = 'cancelled', cancellation_kind = COALESCE(cancellation_kind, 'legacy_terminal'),
       terminal_at = COALESCE(terminal_at, CURRENT_TIMESTAMP), last_progress_at = CURRENT_TIMESTAMP
 WHERE state = 'failed'
   AND gap_id IN (SELECT id FROM ingredient_gaps WHERE qa_resolution IS NOT NULL);

INSERT OR IGNORE INTO ingredient_pricing_inbox
  (id, market_id, entity_id, gap_id, pricing_job_id, campaign_id, state, created_at, updated_at)
SELECT 'inbox_' || job.id, job.market_id, job.entity_id, job.gap_id, job.id, wave.campaign_id,
       CASE WHEN job.state = 'ready_to_publish' THEN 'publish_pending'
            WHEN job.state = 'needs_operator' THEN 'operator_attention'
            ELSE 'queued' END,
       job.created_at, job.updated_at
  FROM ingredient_pricing_jobs job
  LEFT JOIN pricing_waves wave ON wave.id = job.wave_id
 WHERE job.entity_id IS NOT NULL
   AND job.operational_state NOT IN ('public_verified','permanently_unavailable','cancelled','failed_manual');

PRAGMA optimize;
