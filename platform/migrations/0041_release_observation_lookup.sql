-- @policy expand-contract
-- Retention and canonical selection protect facts by reverse release lookup;
-- the original schema only indexed the forward release/store access path.

CREATE INDEX release_cells_observation
  ON release_cells(observation_id)
  WHERE observation_id IS NOT NULL;

PRAGMA optimize;
