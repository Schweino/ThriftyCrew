-- @policy expand-contract
-- SQLite cannot widen the legacy executor CHECK without rebuilding a table
-- referenced by live run, watchdog and agent ledgers. Preserve that dispatch
-- compatibility column and add the exact authored executor independently.

ALTER TABLE job_schedules ADD COLUMN authority_executor TEXT;

UPDATE job_schedules
   SET authority_executor = executor
 WHERE authority_executor IS NULL;
