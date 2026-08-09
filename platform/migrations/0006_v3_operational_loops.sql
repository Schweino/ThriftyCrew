-- V3 amendments: immutable engine snapshots, shelf taxonomy, accuracy,
-- durable triage, and the non-atomic Ghost rotation reconciliation ledger.

ALTER TABLE product_versions ADD COLUMN taxonomy_path TEXT;

ALTER TABLE configuration_versions
  ADD COLUMN expected_known_wrong INTEGER NOT NULL DEFAULT 0
  CHECK (expected_known_wrong >= 0);

CREATE TABLE release_input_batches (
  release_id TEXT NOT NULL REFERENCES releases(id),
  batch_id TEXT NOT NULL REFERENCES capture_batches(id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  PRIMARY KEY (release_id, batch_id),
  UNIQUE (release_id, ordinal)
) STRICT;

CREATE INDEX release_input_batches_batch ON release_input_batches(batch_id);

CREATE TABLE release_top5 (
  release_id TEXT NOT NULL REFERENCES releases(id),
  protein TEXT NOT NULL,
  rank INTEGER NOT NULL CHECK (rank BETWEEN 1 AND 100),
  recipe_slug TEXT NOT NULL,
  serving_cost_minor INTEGER NOT NULL CHECK (serving_cost_minor >= 0),
  PRIMARY KEY (release_id, protein, rank),
  UNIQUE (release_id, recipe_slug)
) STRICT;

CREATE TABLE release_free_rotation (
  release_id TEXT NOT NULL REFERENCES releases(id),
  recipe_slug TEXT NOT NULL,
  intended_visibility TEXT NOT NULL CHECK (intended_visibility IN ('public', 'members', 'paid')),
  protein TEXT,
  rank INTEGER CHECK (rank IS NULL OR rank > 0),
  PRIMARY KEY (release_id, recipe_slug)
) STRICT;

CREATE TABLE release_feed_entries (
  release_id TEXT NOT NULL REFERENCES releases(id),
  entry_key TEXT NOT NULL,
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  payload_json TEXT NOT NULL,
  PRIMARY KEY (release_id, entry_key),
  UNIQUE (release_id, ordinal)
) STRICT;

CREATE TABLE ghost_rotation_reconciliations (
  id TEXT PRIMARY KEY,
  release_id TEXT NOT NULL REFERENCES releases(id),
  status TEXT NOT NULL CHECK (status IN ('started', 'verified', 'failed')),
  expected_count INTEGER NOT NULL CHECK (expected_count >= 0),
  examined_count INTEGER NOT NULL DEFAULT 0 CHECK (examined_count >= 0),
  mismatch_count INTEGER NOT NULL DEFAULT 0 CHECK (mismatch_count >= 0),
  detail_json TEXT NOT NULL DEFAULT '{}',
  started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at TEXT,
  CHECK (examined_count <= expected_count)
) STRICT;

CREATE INDEX ghost_rotation_release
  ON ghost_rotation_reconciliations(release_id, started_at DESC);

CREATE TABLE accuracy_draws (
  id TEXT PRIMARY KEY,
  market_id TEXT NOT NULL REFERENCES markets(id),
  release_id TEXT NOT NULL REFERENCES releases(id),
  seed TEXT NOT NULL,
  protocol_version TEXT NOT NULL,
  requested_size INTEGER NOT NULL CHECK (requested_size > 0),
  sampled_count INTEGER NOT NULL CHECK (sampled_count >= 0),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'completed', 'overdue', 'cancelled')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  due_at TEXT NOT NULL,
  completed_at TEXT,
  UNIQUE (market_id, seed, protocol_version)
) STRICT;

CREATE TABLE accuracy_draw_cells (
  draw_id TEXT NOT NULL REFERENCES accuracy_draws(id),
  ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
  release_id TEXT NOT NULL,
  commodity_id TEXT NOT NULL,
  store_location_id TEXT NOT NULL,
  observation_id TEXT NOT NULL REFERENCES observations(id),
  PRIMARY KEY (draw_id, ordinal),
  UNIQUE (draw_id, commodity_id, store_location_id),
  FOREIGN KEY (release_id, commodity_id, store_location_id)
    REFERENCES release_cells(release_id, commodity_id, store_location_id)
) STRICT;

CREATE TABLE operator_verdicts (
  id TEXT PRIMARY KEY,
  draw_id TEXT NOT NULL,
  cell_ordinal INTEGER NOT NULL,
  verdict TEXT NOT NULL CHECK (verdict IN ('right', 'wrong', 'cannot_tell')),
  verified_by TEXT NOT NULL,
  verified_at TEXT NOT NULL,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  FOREIGN KEY (draw_id, cell_ordinal) REFERENCES accuracy_draw_cells(draw_id, ordinal),
  UNIQUE (draw_id, cell_ordinal)
) STRICT;

CREATE INDEX operator_verdicts_draw ON operator_verdicts(draw_id, verdict);

CREATE TABLE triage_items (
  id TEXT PRIMARY KEY,
  source_kind TEXT NOT NULL CHECK (source_kind IN ('guard_finding', 'accuracy_gap', 'operational_alert')),
  source_ref TEXT NOT NULL UNIQUE,
  severity TEXT NOT NULL CHECK (severity IN ('hard', 'warning', 'info')),
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'planned', 'resolved', 'needs_operator')),
  title TEXT NOT NULL,
  evidence_json TEXT NOT NULL DEFAULT '{}',
  plan_ref TEXT,
  resolution_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  resolved_at TEXT
) STRICT;

CREATE INDEX triage_queue ON triage_items(status, severity, created_at);

INSERT OR IGNORE INTO job_schedules (job, cron, max_gap_minutes) VALUES
  ('accuracy-weekly', '0 15 * * 1', 11520),
  ('triage-daily', '30 13 * * *', 1560),
  ('ghost-rotation-reconcile', '0 16 * * *', 1560);

INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description) VALUES
  ('release-input-snapshot', 'release', 'hard', 'Every selected observation belongs to an explicitly snapshotted promoted batch'),
  ('release-aisle-taxonomy', 'release', 'hard', 'Aisle decisions examine captured store taxonomy and cannot pass blind');
