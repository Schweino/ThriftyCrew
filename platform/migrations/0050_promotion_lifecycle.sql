-- @policy expand-contract
-- Retailer-local ad calendars, durable boundary work, and publication guards.

CREATE TABLE retailer_ad_calendars (
  store_location_id TEXT PRIMARY KEY REFERENCES store_locations(id),
  store_name TEXT NOT NULL,
  capture_lane TEXT NOT NULL CHECK (capture_lane IN ('headless','browser')),
  expected_start_weekday INTEGER NOT NULL CHECK (expected_start_weekday BETWEEN 0 AND 6),
  current_valid_from TEXT,
  current_valid_to TEXT,
  detected_at TEXT,
  source_evidence_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(source_evidence_json)),
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (current_valid_to IS NULL OR current_valid_from IS NULL OR current_valid_to > current_valid_from)
) STRICT;

INSERT INTO retailer_ad_calendars
  (store_location_id, store_name, capture_lane, expected_start_weekday)
VALUES
  ('family-fare-omaha-6401', 'Family Fare', 'headless', 0),
  ('fareway-omaha-043', 'Fareway', 'browser', 0),
  ('hy-vee-omaha-1465', 'Hy-Vee', 'headless', 1),
  ('aldi-omaha-446-048', 'Aldi', 'browser', 3),
  ('bakers-saddle-creek', 'Baker''s', 'headless', 3);

CREATE TABLE promotion_capture_requests (
  id TEXT PRIMARY KEY,
  store_location_id TEXT NOT NULL REFERENCES retailer_ad_calendars(store_location_id),
  request_kind TEXT NOT NULL CHECK (request_kind IN ('prefetch','activate','expire','post_verify')),
  capture_lane TEXT NOT NULL CHECK (capture_lane IN ('headless','browser')),
  window_valid_from TEXT NOT NULL,
  window_valid_to TEXT NOT NULL,
  due_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','leased','completed','failed','cancelled')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  lease_owner TEXT,
  lease_expires_at TEXT,
  result_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(result_json)),
  last_error TEXT,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  completed_at TEXT,
  UNIQUE (store_location_id, request_kind, window_valid_from, window_valid_to)
) STRICT;

CREATE INDEX promotion_capture_requests_due
  ON promotion_capture_requests(status, due_at, capture_lane);

CREATE TABLE promotion_boundary_runs (
  id TEXT PRIMARY KEY,
  observed_at TEXT NOT NULL,
  queued_requests INTEGER NOT NULL DEFAULT 0 CHECK (queued_requests >= 0),
  expired_current_cells INTEGER NOT NULL DEFAULT 0 CHECK (expired_current_cells >= 0),
  future_current_cells INTEGER NOT NULL DEFAULT 0 CHECK (future_current_cells >= 0),
  overdue_requests INTEGER NOT NULL DEFAULT 0 CHECK (overdue_requests >= 0),
  status TEXT NOT NULL CHECK (status IN ('pass','action_required','failed')),
  detail_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(detail_json)),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description) VALUES
  ('release-offer-window', 'release', 'hard', 'Every selected offer is active at the release observation instant and ad-only offers carry a bounded window.'),
  ('release-regular-fallback', 'release', 'hard', 'Every bounded promotional offer with a retailer regular price has a distinct immutable everyday fallback.');

PRAGMA optimize;
