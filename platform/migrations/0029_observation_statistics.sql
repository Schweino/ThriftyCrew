-- @policy expand-contract
-- Maintain O(1) capacity inputs instead of scanning the immutable observation ledger daily.

CREATE TABLE observation_statistics (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  observation_count INTEGER NOT NULL DEFAULT 0 CHECK (observation_count >= 0),
  oldest_observation_at TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO observation_statistics (singleton, observation_count, oldest_observation_at)
SELECT 1, COUNT(*), MIN(captured_at) FROM observations;

CREATE TRIGGER observations_statistics_insert
AFTER INSERT ON observations
BEGIN
  UPDATE observation_statistics
     SET observation_count = observation_count + 1,
         oldest_observation_at = CASE
           WHEN oldest_observation_at IS NULL OR NEW.captured_at < oldest_observation_at THEN NEW.captured_at
           ELSE oldest_observation_at
         END,
         updated_at = CURRENT_TIMESTAMP
   WHERE singleton = 1;
END;

CREATE TRIGGER observations_statistics_delete
AFTER DELETE ON observations
BEGIN
  UPDATE observation_statistics
     SET observation_count = observation_count - 1,
         oldest_observation_at = CASE
           WHEN OLD.captured_at = oldest_observation_at THEN (SELECT MIN(captured_at) FROM observations)
           ELSE oldest_observation_at
         END,
         updated_at = CURRENT_TIMESTAMP
   WHERE singleton = 1;
END;

PRAGMA optimize;
