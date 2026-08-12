-- @policy expand-contract
-- Materialized canonical pointers turn cleanup planning into a bounded indexed
-- join. Selection is refreshed from live release protection before each run.

CREATE TABLE semantic_fact_canonicals (
  semantic_hash TEXT PRIMARY KEY CHECK (length(semantic_hash) = 64),
  observation_id TEXT NOT NULL REFERENCES observations(id),
  selected_at TEXT NOT NULL
) STRICT;

CREATE INDEX semantic_fact_canonicals_observation
  ON semantic_fact_canonicals(observation_id);

PRAGMA optimize;
