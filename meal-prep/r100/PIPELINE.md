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
