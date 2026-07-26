# R100 — 100-recipe expansion pipeline (state + invariants)

Brad's order (2026-07-18): 100 NEW recipes, per-serving >=550 cal, protein = Chicken / GROUND Beef /
Ground Turkey / Pork, source URL logged AND visible credit line ("adapted from") on every new card,
no duplicates of the existing 113, cards in the EXACT existing format. Thorough > fast; double-check
everything. Retrofit visible credit onto the existing 113 AFTER the new 100 ship (task #124).

## Decisions locked
- 550 gate applies to OUR final computed per-serving macros (food-DB math), not the source's number.
- Beef = ground only (Brad's wording); chunk/sliced-beef candidates were dropped at selection.
- Credit line: `<p><em>Recipe adapted from <a href="URL" target="_blank" rel="noopener">Site Name</a>. ...</em></p>`
  placed AFTER Portion It, BEFORE the <hr> upsell. New cards only (retrofit later).
- New cards use SiteBase https://www.thriftycrew.com + author "Thrifty Crew" in JSON-LD
  (old cards still say simplemoneyplaybook/SMP — fix during retrofit #124).
- House pantry adaptation: source ingredients normalized via canon-rules.json (folds/substitutions/drops);
  prose stays faithful to the dish, ingredient list uses our canonical items. 14 servings standard.
  Every recipe auto-includes Salt + Black Pepper.
- Visibility: paid, tag Meal Prep. recipes-db.json gains source_url + source_site fields.

## File map (this folder unless noted)
- build-card.ps1            generator (PROVEN byte-exact vs live card via test-fidelity.ps1: BODY+HEAD EXACT MATCH)
- tpl-scaler-prefix/suffix  template bytes extracted from live card (extract-templates.ps1) — do not retype
- test-fidelity.ps1         round-trip proof harness (legacy mode: old domain/author)
- canon-rules.json          ordered regex -> canonical item (DB name | NEW:x | DROP); 0 unmapped over all 100
- normalize-ingredients.ps1 applies rules; writes scratchpad recipes-canon.json + new-items.json
- Scratchpad (C:\Users\Owner\AppData\Local\Temp\claude\C--Codex\f3644374-5e4d-4c5e-a7e6-7ac3b89873f9\scratchpad\recipes100\):
  FINAL-100.json (selected set w/ source urls+ingredients+nutrition), recipes-canon.json,
  new-items.json (81), EXISTING-113.txt, candidates-*.json, labels-P1/P2/P3.json (agent outputs)
  NOTE: copy scratchpad results INTO this repo folder as they land (scratchpad is ephemeral).

## New-item coverage (81 total)
- ~40 priced by our own board (comparison-2026-07-17.json): salt, black-pepper, vegetable-oil, eggs, flour,
  green-onions, sugar (granulated `sugar` row, NOT powdered), jalapenos (fresh `jalapenos`, NOT pickled),
  dried-oregano, lemon-juice, cucumbers, ground-turmeric, pork-chops, heavy-cream, ground-cinnamon,
  worcestershire, red-pepper-flakes, ground-pork, feta, pasta row (`pasta`) covers ALL dry shapes
  (spaghetti/ziti/shells/fettuccine/orzo), egg-noodles, apple-cider-vinegar, peanuts, rice-vinegar,
  mayonnaise, celery, tomatoes-green-chilies, hummus, dried-parsley, hash-browns, pickles,
  sweet-potatoes (fresh row), cilantro, shredded-cheese (= Mexican blend), crackers (= butter crackers),
  onions (= red onion price basis)
- Agent P1: refrigerated/packaged labels+prices (chorizo, turkey sausage, ricotta, mex blend label,
  tortellini, gnocchi, biscuits, grits, corn muffin mix, Fritos, butter crackers label, hash browns label,
  rice noodles, lo mein noodles)
- Agent P2: sauces/pastes (oyster, fish sauce, mirin, sriracha, chili crisp, red curry paste, JP curry roux,
  lemongrass paste, harissa, mole, achiote, pomegranate molasses, five-spice, garam masala, cajun, berbere)
- Agent P3: spice/nut/produce prices + dry-pasta labels (cayenne, thyme, basil, dill, bay, cloves, allspice,
  coriander, nutmeg, ground ginger, smoked paprika, poppy seeds, walnuts, cherry tomatoes, fresh basil,
  fresh mint, red onion, orzo/ziti/shells/fettuccine/spaghetti)
- Remainder authored from USDA-standard label values in usda-authored.json, then a VERIFY agent checks
  every row before DB insertion. Atwater check (4P+4C+9F ~ cal) enforced on all entries.

## Status log
- 2026-07-18: #117 DONE (generator byte-exact, test-fidelity BODY+HEAD EXACT MATCH).
- #118 DONE: canon-rules 0 unmapped; recipes-canon.json + new-items.json (81) written (copies in this folder).
- Engine parse-compute.ps1 COMPLETE incl. 550-tuner (base-bump to +60% -> pf to 1.6; protein floor 25g
  +35% bump; auto-Rice base if bowl has none; Salt+Black Pepper auto-staples; manual-overrides.json 13 lines).
  Flags: ZERO hard flags across ~1100 lines. At pf=1 pre-DB: 25/100 pass 550 (understated - missing items).
- labels-P3.json LANDED: 22/22 verified (live Walmart page prices via Brad's Chrome; pasta labels 200/7/42/1@56g).
- usda-verified.json LANDED: 46 confirmed + 2 corrected (Ground Pork -> 280cal/20P/0C/22F per 112g;
  GV Hummus -> 30cal/2P/4C/1F per 28g - GV is much leaner than Sabra; recipes assume GV).
- r100-board-map.json written: 40 new items -> board bid/gpu (pasta shapes share `pasta`; mex blend =
  shredded-cheese; butter crackers = crackers; red onion = onions).
- labels-P1 LANDED (14/14 verified real labels+prices), labels-P2 LANDED (15/16; berbere macros label-exempt,
  entered as documented-manual parallel to paprika). merge-db.ps1 RUN: food-macros-db 116 -> 201 items,
  0 missing vs required 81. Backups food-macros-db.backup-*.json in this folder.
- #120 DONE. parse-compute.ps1 FINAL: 100/100 recipes >=550 cal (560-953, avg 643), protein floor 25g met,
  ZERO unparsed lines. Fixed en route: unit priority now position-based ("6 tbsp (1/3 cup)" bug),
  fraction-safe metric ("1/2 kg"), item-paren weights ("(approx 1.75 pounds)" w/ $Matches-clobber fix),
  fry-oil house rule (84g/batch), cooked/steamed/boiled rice->dry conversion, portion-realism clamps
  (protein 240g/serv cap, nuts/butter/oil/sugar/breading caps), down-tuner (>900 trims base to 880 target),
  zero-gram guard on substantive items (tuner repairs with 700g house base; hit Stuffed Shells + Lemon Orzo,
  final values correct ~house standard). Japanese Curry Roux density = 92g (matches priced S&B 3.2oz box).
- MANUAL BALANCE in spec phase (4 rich dishes >900 or >60P): Com Suon (950), Pork Katsu Curry (953),
  Chicken Katsu Curry (877/65P), Paprikash (877/61P). Trim cream/butter/cheese modestly, keep dish identity.
- #121 DONE. cost-engine.ps1: price chain = comparison board (Walmart everyday) -> smp-feed (recipe-board
  verified cheapest) -> agent label package prices. ZERO no-price flags. Cost/serving $1.09-$5.04 avg $2.40.
  true>=batch invariant 0 violations. recipes-costed.json written. BBQ Sauce added to r100-board-map
  (bbq-sauce); Red Wine canon-folded to Beef Broth (house no-alcohol). Gotcha: $true is a reserved PS var
  (renamed $trueCost); bash-inline PS mangles $ (use files/sed).
- 2026-07-18 late: ALL 5 PROSE WAVES LANDED (100 prose files in specs\prose\). During their run, four MORE
  canon/parse bugs were found + fixed (rules are ORDER-SENSITIVE; the $Matches-clobber trap struck 3x):
  (1) rotel-vs-jalapeno rule order; (2) 'butter round crackers' + 'peanut butter' hit the Butter rule first
  (both moved above it); (3) 'cider or white wine vinegar' hit the wine rule (ACV rule moved up);
  (4) PAREN-SIZE branch returned 0g for EVERY '(N oz) can' line ($Matches clobbered by a second -match in
  the condition) - fixed + container-vs-total disambiguation ('2 (14.5 oz) cans' multiplies, '24 (~8 oz)'
  pieces = total). Sun-Dried Tomatoes added to SERVE_DEFAULTS. Kofta renamed 'Turkey Kofta Bowls with
  Tahini Sauce' via NAME_OVERRIDES in build-specs (slug/prose keys unchanged).
  ENGINE FINAL: 100/100 gate, cal 560-953 avg 646, >900 only Katsu(953)+Com Suon(950) (accepted rich flags),
  protein floor met, ZERO 0g substantive rows, costs clean.
  PROSE SYNC NEEDED: prose was written against older spec numbers (specs regenerated several times).
  NEXT: spec-guards.ps1 gets AUTO-NUMERIC-SYNC (replace \$D.DD in cost_closing/upsell w/ current cost_ps;
  cal/protein numbers in intro/portion/description) then run guards -> substantive-rewrite agent for:
  baked-ziti-with-ground-turkey-and-ricotta (agent missed marinara), thai-coconut-curry-turkey-meatballs +
  thai-red-curry-chicken-rice-bowls (coconut milk restored), thai-peanut-pork-tenderloin-rice-bowl (peanut
  butter restored), poppy-seed-chicken-and-rice-casserole (butter crackers restored) + any guard survivors
  -> build-all -> publish ONE test slug -> eyeball live (mobile+dark rule) -> publish-r100 -All ->
  update-recipes-db -> push repo -> memory.
- #122 WAS IN PROGRESS: build-specs.ps1 RAN -> 100 spec skeletons in specs\ (all numeric/display/cost/scaler
  fields machine-built; slugs deduped vs existing 113). 5 PROSE AGENTS RUNNING (20 recipes each,
  alphabetical splits 1-20/21-40/41-60/61-80/81-100), writing specs\prose\prose-<slug>.json.
  READY TO RUN once prose lands: spec-guards.ps1 (merge + validate ALL invariants -> specs-ready.txt)
  -> build-all.ps1 (cards -> built\, structural lint + emdash check, TC og image set)
  -> publish-r100.ps1 -All (upsert paid posts w/ Meal Prep tag + head, live-verifies each: title present,
  paid content NOT public, JSON-LD present) -> update-recipes-db.ps1 (adds 100 w/ source_url/source_site)
  -> push repo (income folder: r100\, food-macros-db.json, recipes-db.json, ingredient additions)
  -> memory update. Publish order: run ONE test slug first, eyeball it live (mobile 375px + dark mode
  per the standing rule), then -All.
- ORIGINAL PLAN (superseded above): build-specs.ps1 assembles per-recipe spec JSONs deterministically from
  recipes-computed + recipes-costed + r100-board-map (stat line, ingredients_display, cost lines w/ Buy
  amounts summing EXACTLY to true cost, scaler data w/ bid/gpu vs 'not price-tracked'). PROSE fields
  (intro, shop_smart, make_it, portion, credit_html, head description/keywords/steps) drafted by agent
  waves (~10 recipes each, Brad voice, NO em dashes, credit = 'Recipe adapted from <a>SITE</a>' line),
  validated by spec-guards.ps1 (stat==computed macros==JSON-LD; cost lines sum check; 550 gate; format lint;
  no em-dash check; source_url present). Manual balance list (4 rich dishes) handled during spec review.
  Then #123 publish wave: publish-recipe-r100.ps1 upsert by slug (posts, tag Meal Prep, visibility paid,
  custom_excerpt, head incl paywall schema), verify PUBLIC page live per post, update recipes-db.json
  (+source_url/source_site), push repo, memory.

## Task #125: every recipe ingredient on the 7-store board (Brad: no exceptions)
- Tier-1 remaps DONE: 42 recipe items re-pointed to existing board rows (r100-board-map.json) ->
  118/165 ingredients board-priced. 'Diced Green Chiles' -> existing canned-green-chilies (my
  diced-green-chiles registration was a semantic dupe - DEREGISTERED; alternate-spelling sweep found
  no others).
- 46 genuine-new commodities REGISTERED (board 424) via register-batch (rules in grocery\out\r100\rules\,
  candidates + ids list in out\r100\). Hijack audit: clean (all board churn traced to daily data refresh).
- ENGINE LESSONS (compare-deals):
  * daily runs '-MinStores 1' (check-ad-cycles line 219); the DEFAULT is 2 - a manual run silently drops
    single-store commodities. Always pass -MinStores 1 to reproduce the daily.
  * $GLOBAL_EXCLUDE drops products NAMED sauce/mix/muffin/wine/canned/frozen/etc; commodities that ARE
    those forms need relax_global (added to 14 r100 ids incl fish/oyster/hoisin/gochujang sauce,
    mirin=wine, corn-muffin-mix, curry-roux, ranch/taco mix, tortellini=frozen, chipotle-adobo).
  * REAL collision fixed: 'Kikkoman Aji Mirin ... Rice Wine' was claimed by the rice commodity ->
    rice now excludes mirin/cooking wine/rice wine/vinegar/noodle/stick/cake/krispies/paper.
- FF + Hy-Vee primed (prime-batch-headless, 47 terms) -> 41/46 have live cells, all spot-checked clean.
  5 empty are genuinely not at FF/HV: oyster-sauce, achiote-paste, pomegranate-molasses,
  japanese-curry-roux, berbere-seasoning (Walmart carries all 5).
- IN FLIGHT: Walmart capture agent (Brad's Chrome, NEXT_DATA, 47 terms -> out\r100\walmart-r100-raw.txt,
  import via import-walmart-batch -Raw). THEN: Sam's capture (q|n|lp|up|id pipe CSV -> build-sams-deals),
  Fareway (shop.fareway DOM extract -> build-fareway-regular; MUST be stamped in-store/mode_verified or
  the price-mode gate drops it), Aldi + Baker's browser captures (must emit link_url/ids per #116).
  THEN: guards -> vet-sheet 46 -> publish board -> re-cost 100 recipes -> rebuild+republish cards ->
  push repo (commodity/category/search/band files feed the CLOUD daily - push or the 06:30 run reverts).

## Remaining phases (tasks #119-#123)
1. #119 merge labels -> food-macros-db.json (backup first; never-shrink; Atwater guard).
2. #120 qty-parse + density table -> grams per ingredient per recipe, scale x(14/source_servings),
   tune carb/fat base so per-serving >= 550 (write tuning note per recipe); protein target >=25g.
   Engine: compute-macros.ps1 (deterministic, from DB only). Flag+manually review any parse failure.
3. #121 costs: everyday Walmart/Sam's baseline per ingredient (board prices preferred), batch total =
   exact sum of util lines; true cost = round-up rule (packages ceil; bulk/pantry at utilization);
   per-line Buy amounts sum EXACTLY to true total. bid/gpu from grocery board mapping for scaler.
4. #122 prose (Brad voice, no em dashes) + spec JSONs -> build-card.ps1 -> guards:
   stat==batch/14==JSON-LD cost/macros; 550 gate; buy-line sum check; format lint (section order, credit line).
5. #123 publish via publish-recipe upsert (posts, tag Meal Prep, paid, meta title/desc, head JSON-LD incl
   paywall Article schema), verify live public HTML per post, update recipes-db.json, push repo, memory.

## Publishing notes
- Ghost admin key: meal-prep\.ghostkey (JWT works for posts; settings are browser-session-only).
- Upsert by slug; single lexical html card (scaler block + "\n" + prose). Accept-Version v5.0 still OK for posts.
- After publish: fetch PUBLIC page, verify scaler data + credit + noindex NOT set (these are indexable).
- recipes-db.json + r100 specs + scripts push to GitHub repo (cloud pipeline rebuilds depend on repo state).

## FINAL STATUS 2026-07-18 late night (#125 CLOSED)
- Board mandate DONE: all 165 recipe ingredients board-tracked. 42 remaps + 46 new commodities
  (1 semantic dupe folded into canned-green-chilies). Board live at 424 commodities / 3,093 prices.
- 7-store depth on the 46 new: 7-store:4 | 6:8 | 5:15 | 4:9 | 3:3 | 2:4 | 1:3 = 207 cells.
  The 1-store tail is honest Walmart-only specialty (achiote, pomegranate molasses, berbere).
  Captures: Walmart NEXT_DATA (46/46 terms), Sam's 17 found / 29 not-carried, Fareway 37 in-store
  verified (merged with standing 382 -> 419, no coverage collapse), Aldi 10 (+tortelloni), Baker's 42.
- Cost delta after board completion: 5 recipes moved >2c (inasal, rendang, caramelized beef,
  lemongrass pork chops, banh mi). All 100 cards rebuilt from final board.
- ORDERING LESSON: the 5-slug republish ran BEFORE the final board rebuild regenerated cards,
  so live went stale by one generation. Caught by a full byte-sweep (admin html vs built body;
  normalize: strip <!--kg-card-begin/end: html--> wrappers + CRLF->LF). Republished the 5;
  final sweep = 100/100 byte-identical live. recipes-db (22:41:43) carries final costs (verified 4.09/4.84).
  RULE: any republish must run AFTER the last card rebuild, then byte-sweep to confirm.
- All state pushed through da62dac (incl. final public/board.json). 06:30 daily runs over this state.
- Still open elsewhere: #124 credit retrofit on the original 113 + their SMP-branded JSON-LD heads.

## 2026-07-19: 3-PART COST MODEL (Brad option 3) + two accuracy fixes
- Every recipe now shows THREE labeled cost views: Batch total (food the batch uses, "not a
  register receipt"), True shopping cost (register trip with a STOCKED pantry; whole packages
  for meat/produce/packaged, utilization for pantry staples), and NEW "Starting with an empty
  pantry? Add about $X one time" (full containers of every pantry staple; first trip near
  $true+$X exactly). Fields cost_pantry_add + cost_first_run flow engine -> spec -> db.
  pantry-packages.json = whole-container grams for all 89 BULK staples (hard-flag on miss).
- FIX 1 (pork): Pork Loin was priced off pork-shoulder (weekly board $2.24/lb Walmart). Real
  pork-loin row lives on the RECIPE board ($2.14/lb Walmart, 5 stores). Engine now loads
  recipe-board rows for ids the weekly board lacks; map remapped; scaler bids fixed. 4 R100
  recipes moved down ~2-5%.
- FIX 2 (THE BIG ONE, unit reconciliation): a map's gpu is calibrated to ITS ERA's board unit.
  Old map had Brown Sugar gpu per-OZ; the weekly board re-registered brown-sugar per-LB ->
  16x OVERPRICE on every R100 card using brown sugar (caramelized beef batch was $57.27,
  really $47.96). Soy sauce + 3 vinegars were 4% off (oz vs floz). Engine + retrofit now
  rescale gpu across standard units (lb/oz/floz/kg/g) and HARD-FLAG non-standard mismatches.
  AUDIT RULE: whenever a map feeds a board, diff map.unit vs row.unit for every used item.
- 28 corrected cards republished; sweep 100/100 byte-identical; recipes-db resynced
  (new fields incl.). costed-prev baseline advanced.
- retrofit-cost-113.ps1: splices the same 3 labeled lines into the 113 OLD posts (add computed
  from CURRENT board; first run anchored to each card's PRINTED true cost so eras never mix
  inside a number; Ranch map-unit override each->oz; fajita pilot-variant handled; add=0 cards
  get copy-only). Dry 113/113.

## 2026-07-25: SCALER PAYLOAD unit reconciliation (FIX 2 finished on the WIDGET side)
FIX 2 corrected the COST engine, but the live cards' SCALER payloads (smp-sc-data, what the widget
prices against feed units at view time) still carried raw map-era gpu. Found by the r300 toolchain
port (r300\build-specs.ps1 delta #3). Swept BOTH generations:
- r100 (100 cards): patch-scaler-gpu.ps1 reconciles specs\*.json scaler gpu in place (specs carry
  merged prose, so build-specs must NEVER re-run - header now says so). 28 specs / 34 entries fixed:
  Brown Sugar oz->lb 16x (11), Soy Sauce oz->floz (20), White Vinegar oz->floz (3). Rebuilt 28 via
  build-card, republished via publish-r100 (28/28 OK), full byte-sweep via NEW sweep-live-bytes.ps1:
  100/100 byte-identical.
- old 113: audit-scaler-113.ps1 (read-only, extracts live smp-sc-data, checks every priced entry
  against merged-map calibration rescaled to live feed/board unit) found 37 cards / 66 entries:
  soy/vinegars/hoisin/sesame oz-era->floz 4%, brown sugar + sugar 16x, Ranch 35.44->28.3495 (packet
  era vs per-oz row, see retrofit override), Fresh Mint 20->28.3495. fix-scaler-113.ps1 patched ONLY
  the flagged gpu numbers inside the payload (targeted regex, parse + refetch verified, pre-fix html
  backed up in scaler-113-backups\), lexical-card PUT. Re-audit: 113/113 clean, 0 bugs.
- gen-planner-data.ps1 already reconciles (post-lesson); planner unaffected.
- AUDIT RULE stands: any payload that stores gpu must be reconciled against the unit of the live
  price source THE CONSUMER reads, at build time; audit-scaler-113.ps1 is the reusable checker.
