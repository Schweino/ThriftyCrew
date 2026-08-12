-- @policy expand-contract
-- Server-owned seal enforcement for the source-native offer contract.

INSERT OR IGNORE INTO guard_definitions (id, scope, severity, description)
VALUES ('batch-offer-snapshot', 'batch', 'hard', 'Every current observation must preserve a source-native offer snapshot consistent with canonical identity, size, price, timestamp, and availability fields.');
