# 300-commodity expansion plan (started 2026-07-12 late; resume here if context resets)

Brad: add 200 MORE commonly-purchased items (no dupes vs the 100 live staples or effectively-duplicative
includes), fetch pricing for ALL 7 stores. Proven pipeline from the 100-run applies.

## Phases
1. [ ] Register 200: new-staples2-{a,b,c}.json (authoring records) -> merge-new-staples2.ps1 into
       commodities.json / categories.json (new cats: personal 10, baby 11, pet 12) / commodity-search.json.
       TRAPS (all hit us before): bare `lb` in NAME = per-lb misread; GLOBAL tokens inside legit names
       (water/juice/flavored/soup/frozen/canned/snack/wrap/wrapped/cereal/soda/ice cream/mix/bake/cake/
       pudding/dip/sauce/kit/meal/bar/tart) -> relax_global exactly what the commodity IS; produce excludes
       need scent/cleaner/soap/wipes words; comma-inverted store-brand names ("Sugar, Brown") -> extra
       includes; sizes "N each"->"N ct", "12 x 12 fl oz"->"12 pk 12 fl oz"; sliced cheese ct->oz.
2. [ ] FF headless: pull-regular-familyfare (now ~300 terms; throttle tail self-heals daily).
3. [ ] Store agents SEQUENTIAL (shared browser tab-2), each gets: id->term map + include/exclude from the
       new-staples2 files, Omaha verification (README registry), name-safety, progressive saves to
       out/staples300/<store>-agent.json {"id","name","price","sale?","orig?","size","url"} + -missing.json:
       [ ] Walmart (in-page NEXT_DATA chunked fetch, 8 terms/call)
       [ ] Fareway (GraphQL replay shopId 16668805/68136; pricingUnitString for weighted) + Hy-Vee (Aisles DOM, Omaha #1; markdowns->sale)
       [ ] Aldi (DOM, OLA 42; dismiss cookie+mode modals) + Sam's (rendered DOM, /ip/ links hydrate late)
       [ ] Baker's (Akamai: 4-5s pacing, stop on 2 consecutive denials; daily/weekly agents own the rest)
4. [ ] Process: extend process-agents pattern -> regular/deals files + url-inputs (next free suffixes) +
       extra-deals for Hy-Vee markdowns; build-fareway-regular (PS5.1: assign-then-@() for ConvertFrom-Json).
5. [ ] compare -> diagnose dropped items (audit-all-rows + per-store counts + diag pattern) -> fix rules ->
       repeat once; recipe-overlay; publish (store-coverage gate at 300); notify-item-added advances.
6. [ ] push-data + git; memory update (grocery-deal-comparison.md); report per-store counts honestly.

## Research basis (fetched earlier + this round): BusinessNES top-sellers, Listonic, Food Network pantry,
Instacart categories, Newsweek survey, general US grocery-list canon. The 200 chosen list is in the
new-staples2-*.json files (authoring record includes category + term).
