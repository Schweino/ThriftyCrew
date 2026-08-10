-- These adapters collect location-scoped current shelf prices. Their original
-- source rows were conservatively seeded as pickup before the adapter contracts
-- were ported. Keep browser sources unchanged: those retain the mode attested in
-- the interactive browser session.
UPDATE capture_sources
   SET price_mode = 'in_store'
 WHERE id IN ('direct-bakers-headless', 'direct-hy-vee-headless');
