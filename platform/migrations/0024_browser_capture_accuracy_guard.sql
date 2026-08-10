-- @policy expand-contract
INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description)
VALUES (
  'batch-browser-accuracy',
  'batch',
  'hard',
  'Strict browser batches must reproduce exact source truth, complete bounded pagination, and independently verify every deterministic risk target.'
);
