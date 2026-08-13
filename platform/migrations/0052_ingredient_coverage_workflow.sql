-- @policy expand-contract
-- Durable missing-ingredient discovery and recipe holds. Agent work continues to
-- use the existing recipe-request source kind so the immutable work-item table
-- and its historical CHECK constraint do not need to be rebuilt.

CREATE TABLE ingredient_discovery_batches (
  request_id TEXT PRIMARY KEY REFERENCES recipe_suggestion_requests(id),
  target_missing_ingredients INTEGER NOT NULL DEFAULT 50
    CHECK (target_missing_ingredients BETWEEN 1 AND 50),
  unique_missing_ingredients INTEGER NOT NULL DEFAULT 0
    CHECK (unique_missing_ingredients >= 0),
  source_round INTEGER NOT NULL DEFAULT 0 CHECK (source_round >= 0),
  state TEXT NOT NULL DEFAULT 'collecting'
    CHECK (state IN ('collecting', 'pricing', 'attention', 'completed')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
) STRICT;

CREATE TABLE ingredient_gaps (
  id TEXT PRIMARY KEY,
  normalized_name TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'researching', 'ready_to_publish', 'published', 'permanently_unavailable', 'needs_operator')),
  commodity_id TEXT,
  research_json TEXT,
  research_work_item_id TEXT REFERENCES agent_work_items(id),
  first_seen_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (status <> 'published' OR commodity_id IS NOT NULL),
  CHECK (status <> 'permanently_unavailable' OR research_json IS NOT NULL)
) STRICT;

CREATE INDEX ingredient_gaps_status ON ingredient_gaps(status, first_seen_at, id);

CREATE TABLE ingredient_gap_occurrences (
  gap_id TEXT NOT NULL REFERENCES ingredient_gaps(id),
  request_id TEXT NOT NULL REFERENCES recipe_suggestion_requests(id),
  candidate_id TEXT NOT NULL,
  source_line TEXT NOT NULL,
  source_url TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (gap_id, request_id, candidate_id, source_line)
) STRICT;

CREATE TABLE recipe_ingredient_holds (
  id TEXT PRIMARY KEY,
  request_id TEXT NOT NULL REFERENCES recipe_suggestion_requests(id),
  mapper_work_item_id TEXT NOT NULL REFERENCES agent_work_items(id),
  candidate_id TEXT NOT NULL,
  candidate_json TEXT NOT NULL,
  gap_ids_json TEXT NOT NULL,
  discovery_only INTEGER NOT NULL DEFAULT 0 CHECK (discovery_only IN (0, 1)),
  status TEXT NOT NULL DEFAULT 'paused'
    CHECK (status IN ('paused', 'resumed', 'completed', 'rejected')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (request_id, mapper_work_item_id, candidate_id)
) STRICT;

CREATE INDEX recipe_ingredient_holds_status ON recipe_ingredient_holds(status, request_id, created_at);

PRAGMA optimize;
