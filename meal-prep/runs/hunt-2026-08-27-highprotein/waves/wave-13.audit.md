GO
scope: whole-wave
run: hunt-2026-08-27-highprotein  wave: 13  audited: 2026-08-29
battery: wave-13.preaudit.json (generated 2026-08-29T10:51:06, 23 checks, 1 failed) - the one
fail re-derived by hand and cleared; every chain the battery showed was verified, the residue
below is my own work.

## Verdict

GO. Both recipes are clean end to end on today's bytes. The single battery fail (salt $0) is
the same cent-floor rounding artifact waves 9 and 10 already ruled on, re-derived again below.
Both revival premises the dispatch asked me to confirm are confirmed. Non-blocking findings
are listed; one of them (F1, the stale QA-fail artifact) should be handled at publish time but
blocks nothing mechanical and every claim inside it is false against current bytes.

## The two revival premises, independently confirmed

1. audit-spec-contradictions IS at baseline right now: my own battery invocation at 10:51
   today ran it fresh - SPEC-CONTRADICTIONS-COMPLETE, 0 findings across 587 specs, exit 0.
2. Wave 10's blocker really was singular and shared: wave-10.audit.md carries exactly one
   blocker heading, "### B1. Shared gate red: audit-spec-contradictions PHANTOM 3 vs baseline 0
   (shared, pipeline + shared-data)", and its verdict text states both recipes were themselves
   clean (macros, costs, mappings, cards all verified there). Neither recipe had a recipe-local
   blocker. The revival rested on true premises.

## Battery fail re-derived clean (not a blocker)

cost-engine-consistency, blackened, "'Salt' costs nothing (0)": 1 g of salt on basis
board:salt:walmart, starter 26oz/737g at $0.94 -> $0.94/737 = $0.00128/g; 1 g cent-floors to
$0.00. The line is priced (basis present, carriage CARRIED, starter $0.94), lines_unpriced=0,
and the batch total including it reconciles. Ten live recipes across the catalog carry
identical zero-cost carried lines (9 of them salt/sugar/hot-sauce pinches). Third consecutive
wave ruling on this same artifact - see F5.

## Verified clean this pass (work shown or re-derived)

- MACROS, both recipes 100% hand-recomputed from food-macros-db rows x scaler grams (not just
  the battery's spot set - chili's 544 cal sits within 5% of the 550 gate, so its entire chain
  was re-derived by rule):
  - chili, 17 lines: batch 7609.4 cal / 657.0 p / 427.8 c / 329.1 f -> per serving (÷14)
    543.5 / 46.9 / 30.6 / 23.5 vs stat 544/47/31/24. Matches within honest rounding.
  - blackened, 11 lines: batch 8614.2 / 609.0 / 812.8 / 323.0 -> 615.3 / 43.5 / 58.1 / 23.1
    vs stat 615/44/58/23. Matches. Protein 43.5 is the tightest number in the wave and still
    clears the >=40 band; 4p+4c+9f cross-check lands at 614 vs 615.
  - Blackened's macros CHANGED since wave 10 (620->615, carbs 62->58) because the rice row
    changed identity (Path of Life frozen -> Ben's Original 8.5oz pouches, commits
    91d8084b/0f1a70ae). The new chain verifies; prose, portion_html and head.description all
    carry 615/44 consistently. The QA-fail artifact's "6g protein" claim matches nothing in
    the current spec or built body (regex-swept both).
- COSTS: chili's three tiers re-add exactly by construction from costed.json lines: batch
  28.49 = sum of 17 util costs; true 37.67 = whole-package buys 34.65 + bulk utils 3.02;
  pantry add 5.21 = starters 8.23 - bulk utils 3.02; first run 42.88 = 37.67 + 5.21.
  Blackened's spec cost block (41.01/46.50/10.71/57.21) is byte-consistent with costed.json
  (battery cost-reconcile pass, numbers eyeballed against the spec diff). Movement since the
  cd3036a6 recost was a cent on chili (37.68->37.67, 42.89->42.88), as the dispatch claimed;
  blackened's larger move (41.33->41.01) came from the earlier adjudicated lime-juice remap,
  not the recost.
- PRICE CLASSES interrogated: lime-juice $0.06/floz looked 3x-cheap but is board-real -
  Walmart case pack $10.80/180floz AND independently corroborated by Aldi at $0.0684/floz
  (32oz $2.19). Rice buy $17.73/9x8.5oz = $0.232/oz sits inside the board's own
  $0.169-0.302/oz range. Chicken $2.23/lb, mango $0.75/ea, avocado $0.58/ea - no grits-class
  survivors.
- stat.cost_ps BASIS: both specs already carry the EVERYDAY basis wave-publish freezes
  (cost_first_run/14): chili 42.88/14=3.06 ✓, blackened 57.21/14=4.09 ✓, head.costPerServing
  agrees on both. NOTE for the orchestrator: the dispatch said "batch/14 is the expected
  pre-publish state" - that is not what these specs carry, and what they carry is the
  BETTER state (the exact basis E2 hard-verifies). No action.
- MAPPING deltas since wave 10 all trace to written adjudicated rulings: lime juice
  limes->lime-juice bottle (ca1939da), cilantro-lime-rice product row corrected to the food
  the reader actually buys (91d8084b, 0f1a70ae), chili cheese priced by its own row
  (5ba58b52). No null item_ids (battery dry run: every row builds with an item_id).
- UNBID_LINE (the gate added under this wave today): all 28 scaler lines across both specs
  carry a bid - checked directly against the spec bytes, 0 missing; battery
  audit-unbid-ingredients clean n=2.
- PROTEIN + rotation: chili chicken 1588 g vs pork (bacon) 175 g -> chicken; blackened sole
  protein chicken 2381 g. Both match the manifest's protein field.
- CARDS: battery card-rebuild structural compare vs the live al-pastor reference passed both.
  My byte checks on the rebuilt blackened body: three 615-cal and three 44g-protein claims,
  zero stray "6g", print button, source credit to easyeatsdietitian.com; the single "620" in
  the file is CSS (max-width:620px), not a stale calorie. Chili body: three 544 and three 47g,
  credit to wholesomelymorgan.com. Chili's built file predates today's recost but wave-publish
  E4 rebuilds all cards from specs via propagate, so no stale bytes can ship.
- VOICE: 0 em/en dashes in both specs and both built bodies.
- ONE STORY: manifest wave-13.json, both state files (waved, wave 13, full history through
  reject and revive), and ledger row hunt-2026-08-27-highprotein-w13 (open, same two slugs)
  agree. The audit stamp is the orchestrator's to add after this GO.
- SHARED GATES: store-integrity (hard=0), vocab-integrity, cost-plausibility,
  cost-line-coverage, recipes-db dry run, P8 endpoint provenance and feed liveness (565
  recipes, generated 09:16 today) all green with completion markers.

## Non-blocking findings

- F1 STALE QA-FAIL ARTIFACT, blackened (process, carried from wave 10's N1):
  qa\blackened-chicken-with-mango-salsa.json still reads verdict FAIL (mtime 2026-08-28
  07:21:59) while the state chain says qa-passed/waved. Wave 10 ordered a re-run of
  recipe-source-qa before any publish attempt; that never happened, and the spec has since
  changed again (rice identity + macros), so no QA artifact has ever judged the current
  bytes. I verified the current bytes myself: the artifact's blocking claim (6g protein
  prose) matches nothing on disk, the fidelity anchors it DID pass (grams, method, credit,
  scaling ratio) are unchanged, and no wave-publish preflight reads the qa file (P2 reads the
  ledger, P3 the states - confirmed in wave-publish.ps1). So it cannot fail the publish; it
  can only confuse the post-publish reviewer. Refresh it at or before publish so the run dir
  tells one story. Owner: orchestrator.
- F2 SALT DISPLAY MICRO-WOBBLE, blackened (writer, wave 10's N3, still present): the display
  line reads "to taste (1 1/2 g, about 1/4 tsp) (1 g)" - 1.5 g and 1 g in one line. Trivial;
  wave 10's N2 (the rice 7x10oz vs 9x8.5oz contradiction) IS fixed, this rider was not.
- F3 COOKED-GRAMS-AT-RAW-PRICE, chili bacon (pipeline, estate-wide convention): the 175 g in
  the spec is cooked weight (18 slices x ~9.7 g), priced by util at raw $/g
  (175/453.592 x $3.96 = $1.53). The reader-facing buy line is RIGHT (1 lb raw yields ~175 g
  cooked, $3.96), but the batch/util tier understates the bacon's true cost by roughly $2.40
  (~$0.17/serving) because no cook-yield factor exists in the engine. Not recipe-local - every
  cooked-bacon recipe on the site shares it - and the register-facing tiers are correct.
- F4 STARTER PRICE FROM CASE-PACK PER-UNIT, blackened (pipeline, minor): lime juice's
  synthesized starter "8floz bottle $0.48" prices a single bottle at the 12-pack's per-unit
  rate; a lone shelf bottle runs nearer $1. Feeds only cost_pantry_add (10.71), off by ~$0.50.
- F5 BATTERY TOLERANCE FOR PRICED SUB-CENT LINES (pipeline): third consecutive wave (9, 10,
  13) to re-derive the same salt cent-floor by hand. wave-preaudit's cost-engine-consistency
  should tolerate a zero util_cost when the line carries a basis and a starter/buy price.

## Repair routing summary

| finding | slugs | kind | owner | blocking |
|---|---|---|---|---|
| F1 stale QA-fail artifact vs qa-passed state | blackened | one-story | orchestrator | no |
| F2 salt 1.5g vs 1g display | blackened | prose-drift | writer | no |
| F3 cooked bacon priced at raw $/g in util tier | chili (estate-wide) | engine-convention | pipeline | no |
| F4 lime-juice starter at case-pack per-unit | blackened | engine-nuance | pipeline | no |
| F5 salt $0 cent-floor battery tolerance | blackened | battery-tolerance | pipeline | no |
