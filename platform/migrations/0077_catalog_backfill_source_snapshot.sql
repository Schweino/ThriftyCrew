-- @policy expand-contract
-- Pin every V4 backfill run to the immutable release-board object that was
-- hashed at initialization. Release-payload metadata may later be compacted,
-- but the content-addressed object remains the authoritative source.

ALTER TABLE catalog_backfill_runs_v4 ADD COLUMN source_board_object_key TEXT;

UPDATE catalog_backfill_runs_v4
SET source_board_object_key = 'release-payloads/v2/release=' || source_release_id
  || '/kind=board/prefix=' || substr(source_board_hash, 1, 2) || '/' || source_board_hash || '.json'
WHERE source_board_object_key IS NULL;

