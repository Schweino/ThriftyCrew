-- @policy expand
-- Give newly registered schedules a truthful first-run grace window. The
-- watchdog uses this timestamp only until the first durable run is recorded.

ALTER TABLE job_schedules ADD COLUMN monitoring_started_at TEXT;

UPDATE job_schedules
   SET monitoring_started_at = CURRENT_TIMESTAMP
 WHERE monitoring_started_at IS NULL;
