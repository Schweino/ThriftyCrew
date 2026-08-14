-- @policy expand-contract
-- Reserved migration number after Cloudflare's remote migration endpoint rejected
-- CREATE TRIGGER. Atomic fencing is performed by one transactional D1 batch whose
-- correction-row INSERT gates every mutable statement.
PRAGMA optimize;
