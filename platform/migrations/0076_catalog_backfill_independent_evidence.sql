-- @policy expand-contract
-- Immutable, lease-fenced producer and verifier evidence for V4 catalog
-- backfill cells. A legacy observation remains semantic provenance only.

CREATE TABLE catalog_backfill_evidence_v4 (
  evidence_id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  commodity_id TEXT NOT NULL,
  store_location_id TEXT NOT NULL,
  work_item_id TEXT NOT NULL UNIQUE REFERENCES pipeline_agent_work_items_v4(id),
  kind TEXT NOT NULL CHECK (kind IN ('producer','verifier')),
  generation_id TEXT NOT NULL,
  session_id TEXT NOT NULL,
  source_url TEXT NOT NULL,
  observed_at TEXT NOT NULL,
  document_json TEXT NOT NULL,
  document_hash TEXT NOT NULL CHECK (length(document_hash) = 64),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (run_id,commodity_id,store_location_id)
    REFERENCES catalog_backfill_cells_v4(run_id,commodity_id,store_location_id),
  UNIQUE (run_id,commodity_id,store_location_id,kind,generation_id)
) STRICT;

CREATE INDEX catalog_backfill_evidence_cell_v4
  ON catalog_backfill_evidence_v4(run_id,commodity_id,store_location_id,kind,observed_at);

PRAGMA optimize;
