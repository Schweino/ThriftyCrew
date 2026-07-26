# R300 run state (started 2026-07-25)
Goal: +300 recipes, evening the 4 proteins. Census at start: chicken 69, beef 55, pork 50, turkey 37 (+2 other).
Targets: turkey +90, pork +78, beef +73, chicken +59 (=300; ~128 each final).
Pipeline: NEXT-RUN-PLAYBOOK.md stages; r100 pipeline reused; agents pinned (sourcer/writer=opus-4.8 high, mapper/auditor/reviewer=fable high).
No seafood. Publish in batches; auditor GO required per batch; post-publish-reviewer after every publish.

## Board registration - 21 new commodities REGISTERED LOCALLY 2026-07-25 (NOT pushed)
**!! THE REPO PUSH MUST HAPPEN AT THE PUBLISH STAGE OR THE 06:30 CENTRAL CLOUD RUN REVERTS EVERY ONE OF THESE
REGISTRATIONS !!** (commodities.json / categories.json / commodity-search.json + out\regular\{family-fare,hyvee,
bakers}-regular-2026-07-25.json are all edited locally only; the nightly rebuild uses the COMMITTED files.)
All 21 registered from meal-prep\r300\mapper\decisions.json needs-registration list, 0 rejected. Board 424 -> 445
commodities. Hijack audit CLEAN (diff-board pre-r300 vs final: changed=0 dropped=0, +40 cells; the only 2
"changed" rows are identical-per-unit tie-flips at Baker's caused by the same-day comprehensive Kroger re-pull,
not by the rules - proven by the isolated registration-only diff which was changed=0/dropped=0/added=4).
Coverage 39 cells over 17 of 21 ids: horseradish-sauce 5 stores; poultry-seasoning/brown-gravy-mix/chicken-livers/
diced-ham/corned-beef-brisket/ground-fennel 3; caraway-seeds/snow-peas/sweet-soy-sauce/turkey-breast/
dried-arbol-chiles/eggplant 2; pigeon-peas/dried-ancho-chiles/wild-rice/sazon-seasoning 1.
ZERO coverage (honest gaps, NOT errors): dried-guajillo-chiles, doubanjiang, aji-amarillo-paste (none of the
three headless stores carry them - exactly the mapper's coverage flags), and rye-bread which is BLOCKED ON UNIT:
31 real rye loaves sit in the FF/Hy-Vee/Baker's files but the commodity unit is `each` and every one of those
rows carries an oz size, which the engine refuses to convert to a count. DECISION NEEDED: either switch
rye-bread to `oz` (and change the mapper gpu from 454 g/each to 28.3495 g/oz to match) or let a Walmart capture
supply an `each`-sized row. Left as `each` per the mapper's decision rather than silently desyncing the gpu.
corned-beef-brisket is seasonal but is actually carried TODAY at 3 stores.
Walled stores (Walmart/Sam's/Aldi/Fareway) get zero free coverage: worklist at
meal-prep\r300\board-capture-worklist.json (Walmart 20, Sam's 21, Aldi 21, Fareway 20 ids).
Work files + rerunnable scripts: grocery\out\r300\ (rules, reciprocal-exclude and relax patches, probe,
purge, fill validator, capture-worklist builder, engine-backup\ pre-registration copies of the 3 engine files).

## Stage 1: sourcing wave (10 slices) - COMPLETE 2026-07-25
452 candidates: T 135 (45/45/45), P 120 (40/40/40), B 105 (55/50), C 92 (45/47). All 10 files valid JSON,
per-file slugs unique; 9 exact cross-slice slug collisions (same dish, two sourcers) left for the selector.
Sourcer notes worth keeping: recurring board gaps = turkey-sausage, whole-muscle turkey (breast/thigh),
chicken-drumsticks, ground chicken, ricotta, kimchi, eggplant, dried chiles (guajillo/ancho), pork-belly,
wild rice, dry lentils, pearl barley. Near-dupe judgment calls embedded in each candidate's "why".
## Stage 2: dedup + selection - COMPLETE 2026-07-25
selected.json: 300 exact (T90 P78 B73 C59), 152 cuts all reasoned (33 dupe-of-live, 61 dupe-in-pool,
29 unmappable, 19 surplus, 6 batch-risk, 4 under-bar). Validated: 300 unique slugs, 0 collisions vs
live 213. 169/300 carry unmapped_flags (mostly named-substitute tier); 8 borderline calls flagged
in-file for Brad (incl. steak-fajita 3rd-protein keep, musakhan/sumac, cooked-turkey-breast commodity
suggestion, Indian/Thai chicken concentration). Selector took ~38 min - see playbook stage-2 speed note.

## Stage 2.6: source harvest - COMPLETE 2026-07-25 (300/300 ok)
297 clean via WebFetch agents; 3 x 403-blocked (mexicoinmykitchen albondigas, marionskitchen lok lak,
thespruceeats chile relleno) recovered via browser and patched into H5.json. 7 records have
source_servings=0 (no published yield) -> manual yield at spec stage: turkey-chile-relleno-casserole-
skillet, middle-eastern-turkey-green-bean-stew, spanish-turkey-albondigas-over-rice,
turkey-tsukune-meatball-rice-bowls, turkey-chili-verde-white-beans, caribbean-curry-beef-potatoes,
georgian-chicken-chakhokhbili. Parser watch-list from harvest notes: section-header lines (some chunks
kept them, H6 dropped), Budget Bytes inline ($X.XX) costs, choose-ONE alternative lines (japchae 3 beef
options, panang prawn-vs-chicken), unquantified to-serve lines, Portuguese card (galinhada), ~20+
cross-protein sources needing protein swap to target, "rice bowl" targets whose source has no rice line,
caldereta whole-recipe-total nutrition, several suspect published protein figures (transcribed+flagged).

## Stage 2.5: normalize -> canon worklist - COMPLETE 2026-07-25 (verified 0 unmapped)
r300-canon-rules.json (430 rules; authored 207 + re-based r100 set so post-r100 DB items aren't
re-minted). 50 NEW items / 212 uses (top: Pork Shoulder 28 - deliberate policy shadow of r100's
shoulder->loin fold; Turkey Breast 19; dried arbol/guajillo/ancho 29 combined). 279 lines dropped.
PROTEIN-SWAP-LAMB x2 to resolve at spec stage (xinjiang turkey stir-fry, kafta bil sanieh).
10 drumstick recipes mapped to Chicken Thighs + tsukune ground-chicken->thigh (flagged).
Audit fixed hijacks in own drafts AND 9 latent r100 rule bugs (sage-in-sausage, mushroom-vs-cream-of,
egg-in-eggplant, butter-in-butternut, etc.) - see canon-notes.md. Rules candidates for promotion to
the standing base after run completes (playbook note).

## Stage 4 engine: PORTED + dry-run 2026-07-25 (awaiting mapper DB entries to run for real)
parse-compute.ps1 + cost-engine.ps1 live in r300\ (deps copied; manual-overrides EMPTY; map loader
merges ingredient-map <- r100-board-map <- r300 mapper\map-extensions.json, warns if missing).
Dry run: 300/300 computed, 0 unparsed qty, 550-pass already 174/300 with 50 NEW items missing from DB.
Cost: 300 costed, avg $1.90/serv, 0 invariant violations, 138 unpriced lines pending mapper.
Port fixed 2 real parse bugs (flank/flour 'fl' guard -> 500 lb; bare-700 x can density) + unified the
drained-can rule (gated so explicit smaller cans win). Parity vs r100 canon: 89/100 identical, all 40
line diffs are improvements. TODO before stage 5: fix canon bugs (Sausages + dressing-mix -> Italian
Seasoning; bare 'Chicken' -> Breast noqty), tortilla map alias (Corn Tortillas), 35 no-qty-anywhere
canon/harvest gap lines, densities for NEW items (Turkey Breast cup-lines drive 16 zero-gram flags),
salt/pepper TO_TASTE clamp at spec phase, 7 assumed-servings recipes.

## Stage 3: mapper - COMPLETE 2026-07-25
mapper\decisions.json: 25 existing-board, 21 needs-registration, 4 null (incl PROTEIN-SWAP-LAMB
sentinel, resolved via resolve-protein-swaps.ps1: xinjiang->Turkey Breast, kafta->93/7 Ground Beef).
46 USDA entries + 3 browser-captured labels (ABC Kecap Manis via OFF label photo EU per-100ml
DERIVED - needs_verify flag for auditor; LKK Toban Djan 1tsp/6g FULL PANEL - resolves FDC
contradiction; Goya Aji Amarillo 1Tbsp/14g FULL PANEL). merge-db-r300.ps1: food DB 201->250
(backup food-macros-db.backup-r300-20260725-154318.json; 3 USDA specific-factor Atwater deviations
logged+kept: baking powder, cocoa, capers). Canon rules rebased both sections (147 rebased) -> only
sentinel remained. map-extensions.json: 54 rows + 8 nulls incl Cherry-Tomatoes/Red-Onion standing
rejections OVERRIDING old r100-board-map rows - flag to auditor. Sausages->Bratwurst canon fix +
sage \b patch applied (engine port had found these).

## Stage 4: COMPLETE 2026-07-25 - ZERO cost flags
Package/bulk classification done (267->0 flags): 19 pantry containers + ~30 $PKG entries, all real
sizes with per-entry source comments. TRUE avg $2.81->$2.94 (+$0.13, turkey-breast 3-lb-roast reality),
first-run avg $58.06. Musakhan -$0.47 correct (sumac -> pantry util). Jerk Seasoning closed with
captured Walkerswood 10oz $4.52. FINAL: batch avg $2.44/serv, 0 unpriced, 0 invariant violations,
0 flags of any kind. Stage 5 opened: toolchain port agent generating 300 spec skeletons.

## Stage 5 infrastructure: COMPLETE 2026-07-25 - 300/300 skeletons, guards green
Ported from r100 (r100 untouched): build-card.ps1 + tpl-scaler-prefix/suffix.html copied BYTE-EXACT
(md5 verified; the generator is proven byte-identical vs live cards, never retype it), build-specs.ps1,
spec-guards.ps1 (NEW -Skeleton mode), build-all.ps1, publish-r300.ps1, update-recipes-db.ps1
(v5 string-splice design - PS5.1 serializers cannot rewrite a 1.6 MB recipes-db).
RUN: build-specs -> 300 skeletons in specs\ ; spec-guards -Skeleton -> READY 300/300, 0 fails
(specs-skeleton-ok.txt). Slugs: 300 unique, 0 collisions vs the live 213 (hard-fail gate).
Index: T90 P78 B73 C59, cal 550-886 avg 618, protein 25-69 avg 38, batch $0.78-$6.48 avg $2.44/serv,
true avg $2.94/serv. 4223 scaler rows, 6 with no board id (Sumac, Bulgur Wheat, Keto Bun,
Korean Rice Cakes, Pasta Shells - jumbo x2 -> widget says "not price-tracked").
PORT DELTAS (all deliberate, all guarded):
 1. SCALER GPU IS UNIT-RECONCILED to the live feed/board unit (brown-sugar 16x lesson). r100 wrote the
    raw map gpu; 5 items were mis-scaled there (brown sugar oz vs lb = 16x; soy sauce + 3 vinegars oz vs
    floz = 4%). LIVE R100 CARDS STILL CARRY THE RAW GPU - worth a sweep during the credit retrofit.
 2. PANTRY FOLD IS EXACTNESS-GATED: a line folds into "Pantry seasonings" only if its true-cost
    contribution equals its utilization. r100 also folded tiny non-bulk PACKAGE items (red bell pepper,
    ginger, fresh basil, garlic...) whose package price still hit the true total, so printed lines did
    not sum to the printed true cost - measured 63/300 recipes, up to $2.21 each. Now exact, and guarded.
 3. Slugs come from selected.json verbatim (no re-slugify, no auto -2 suffix); source_url cross-checked
    selected vs computed (0 diffs).
 4. Friendly amounts never print "0 <unit>" (2-decimal fallback under a quarter unit); package labels
    pluralize properly ("Buy 3 each", not "3 eachs").
 5. DISPLAY_OVERRIDES per notes_for_spec_stage: korean-turkey-japchae Cornstarch, plus the two other
    dangmyeon dishes' Rice Noodles, DISPLAY as "Korean glass noodles (dangmyeon)". Canonical names stay
    in ingredients_grams + scaler (macro + price basis); brand paren suppressed on renamed items.
    forbidden_prose_terms bans "cornstarch" on the japchae card - guards enforce it on reader-facing text.
 6. Spec gains servings=14, writer_notes[] (SELECTOR/HARVEST + source yield + tuning + override rationale)
    and forbidden_prose_terms[]. build-card ignores unknown fields, so the card format is unchanged.
 7. update-recipes-db writes protein + per-ingredient item_id (from the MERGED map) so the new rows match
    the existing 213. DO NOT re-run normalize-recipe-ids.ps1 over them: it reads ingredient-map.json only
    and would null the r100/r300-only ids.
SMOKE TEST (then reverted): one synthetic prose file with deliberately stale numbers ($2.05/640 cal/30g)
-> full-mode guards auto-synced to $1.87/569/35, passed all guards, build-all rendered the card with
0 lint failures, credit line after Portion It and before <hr>, JSON-LD author "Thrifty Crew",
TC og image, scaler payload well-formed. Artifacts removed; specs-ready.txt deliberately NOT left behind.
NEXT: prose waves write specs\prose\prose-<slug>.json -> spec-guards (full) -> build-all -> publish-r300
(ONE test slug, eyeball at 375px + dark, then batches with auditor GO) -> update-recipes-db -> REPO PUSH
(the 21 local board registrations revert at the 06:30 cloud run without it).

## Stage 5: IN FLIGHT 2026-07-25 - toolchain ported, 300 skeletons green, 8 writer waves running
Toolchain: build-card byte-exact copy (md5 vs r100); build-specs with 12 documented deltas (notably:
scaler gpu unit-reconciled - LIVE r100 cards still carry raw gpu incl 16x brown sugar, spawned as
separate task; pantry-fold exactness gate fixes r100's 63/300-style sum mismatch; glass-noodle display
overrides; slugs verbatim + hard-fail gates). spec-guards has -Skeleton mode: READY 300/300. Smoke test:
prose->guards(auto-numeric-sync)->build-all->card lint 0 failures, then reverted. specs-ready.txt
deliberately ABSENT until prose passes guards. publish-r300.ps1 + update-recipes-db.ps1 ported NOT run;
CRITICAL: do NOT run normalize-recipe-ids.ps1 over new rows (it only reads ingredient-map.json and
would null r100/r300-only item_ids; update-recipes-db writes protein+item_id itself).
8 writer waves (W1-W8, opus, chunk-H* slug lists) writing specs\prose\prose-<slug>.json per the
enumerated contract (writer_notes[] + forbidden_prose_terms[] per spec; only cost_ps/cal/protein
quotable; make_it[0] verbatim weigh-pot line).
NEXT after prose: spec-guards full mode -> fix survivors -> build-all -> stage 6 auditor GO gate ->
ONE test slug publish + Brad-rule mobile/dark eyeball -> batch publishes ~50-75 (visibility paid) ->
update-recipes-db + rotate/planner/hub rebuilds (normalize-recipe-ids for the OLD rows only per its
design, gen-planner-data + build-meal-planner + publish-resource, free-dinner rotation untouched=paid
default) -> REPO PUSH (board registrations + engine files + specs + db - the 06:30 revert warning) ->
stage 8 post-publish-reviewer after every batch.

## Stage 5 prose: ALL 8 WAVES COMPLETE 2026-07-25 (300/300 prose files, all self-validated clean)
Writers surfaced ~60 real data flags -> two repair passes dispatched pre-audit:
TUNER (fable): 30-item fix list - fresh-vs-can tomato blowups (cassoulet 21 cans, izmir 11kg, albondigas,
jalfrezi, seco, morisqueta), bourguignon 45-onions pearl misparse, japchae choose-one beef double-take,
vindaloo guajillo 231g, xiu-mai garlic 350g, a-la-king missing noodles, tallarines missing pasta,
diced-ham DB fat field (soup fat=3g), gumbo missing sausage + $22 pantry line, rice-base misfires
(remove x5 double-starch, add x5 titled-starch + 2 potato), bulgogi ground->sliced flank, breast->thigh
braise swaps x3, wild-rice keep/swap decisions, trace-line zeroing, chile-relleno re-derive.
PORT AGENT: Buy-line undercount (drained-vs-full can basis - systemic), cups->weight display for
meat/leafy bulk, pantry mis-bucket + <=$5 pantry-line guard, zero-line rendering, true==batch guard,
then FULL spec-guards over 300 with prose merged.
Writer notes for auditor dossier: kielbasa-class -> Smoked Turkey Sausage in 8 pork dishes (honest
prose, protein-integrity call), red curry paste in green/massaman-named dishes (prose hedged),
lap-cheong->Bratwurst, salsa $5.48/16oz + chuck ~$8/lb board price checks, marketplace premiums
(doubanjiang/rice cakes/basil-heavy Thai), 6 sausage-slice recipes 780-880 cal (pass gate, rich-ish).

## Stage 5 fix pass: COMPLETE 2026-07-25 (writer-wave findings) - FULL guards 297/300
Ran after the data-repair pass settled (recipes-computed 18:46:39, quiet 150s), then cost-engine ->
build-specs -> spec-guards FULL. specs-ready.txt deliberately NOT created (stage-6 auditor GO first);
a validation run now writes specs-full-ok.txt and only `spec-guards -WriteReady` arms a publish.
FIXES
 1. BUY-LINE UNDERCOUNT (cost-engine.ps1, real money bug): parse-compute weighs canned beans/hominy in
    DRAINED grams (densities 'can' = 255 g), the board prices the can by NET label weight (425 g), and
    $PKG carried the net figure - so util under-priced a can by 1.67x AND buy_n was ceil(drained/net),
    printing "5.6 cans ... Buy 4 cans" on 32 lines. Engine now derives a DRAINED table (any $PKG item
    with a smaller densities 'can' yield), prices per drained gram and rounds packages on the drained
    yield. One can costs exactly its shelf price on both sides. 32 -> 0 undercounts; a spec-guard now
    re-checks every printed "N cans ... Buy M cans" pair independently.
 2. DISPLAY UNITS: weight-first rendering for meat + leafy/bulk produce (lb at a pound or more, oz
    below). "Turkey Breast 14.25 cups" -> "4.25 lb", kale/mushrooms/broccoli/cabbage/spinach likewise;
    105 cup-lines fixed, 0 remain. Broth/stock now render as cartons/cups instead of r100's "4.25 lb"
    (the old meat regex matched "Chicken Broth"). Machine data untouched.
 3. PANTRY BUCKET: broth/stock/milk/cream/juice can never fold into the "Pantry seasonings" line
    (sopa-de-fideo showed chicken broth there). NEW GUARD: pantry line > $5.00 = hard fail, and any
    broth/stock/milk word in that line = hard fail.
 4. "Buy 1 (lasts several batches)" is now "Pantry staple; this batch alone uses about N <container>"
    whenever the batch consumes 2+ containers (175 lines: 63 broth, 59 rice...). No dollar figure is
    added, so the 3-part cost model and the printed-sum-equals-true guard are both untouched.
 5. NEW GUARD: cost_batch_true == cost_batch with any package line = VERIFY fail (nigerian-chicken-suya).
 6. Zero-gram/trace lines: display, scaler, ingredients_grams and cost lines all drop them, amounts
    never round to "0 unit", and guards fail on "(0 g)" or a zero-rounding amount. 0 present.
 7. Guard auto-sync now re-anchors cal/protein in cost_closing_html + upsell_html too (a writer put
    "51 grams of protein" in a closing line). 75 of 300 specs needed some number re-anchored.
STATE: 300 prose files merged, 297 specs full-validated, cal 550-886 avg 621, protein 25-69 avg 38,
batch $0.78-$6.14 avg $2.42/serv, true avg $2.92/serv. 0 cost flags, 0 unpriced lines.
3 OPEN (all flagged for the auditor, all DATA not spec):
  * musakhan-sumac-chicken - pantry line $7.13, driver Ground Allspice 134 g ($5.01) - implausible qty
  * zanzibar-chicken-pilau - pantry line $5.64, driver Poultry Seasoning 90 g ($4.17) - implausible qty
  * nigerian-chicken-suya-bowls - true == batch because 3175 g chicken thigh is exactly 7 lb and it is
    the only package line; verify then whitelist or accept.

## Stage 5: COMPLETE 2026-07-25 - guards [FULL] READY 300/300, 300 cards built, 0 lint failures
Data repair (tuner wave 4+5): all ~30 writer-flag fixes applied w/ before/afters (cassoulet/izmir/
bourguignon/japchae/vindaloo/gumbo-5th-sausage-victim/bulgogi-sliced-flank/rice-base corrections/
breast->thigh swaps/wild-rice decisions/musakhan+zanzibar spice weights); 1 principled refusal
(Diced Ham fat=2g IS the John Morrell 96%-fat-free label). Build fixes (port agent): drained-vs-net
can basis bug (under-priced beans 1.67x + Buy undercounts - fixed in cost-engine, 32 lines -> 0),
cups->weight display x105, broth-in-meat-regex r100 bug, pantry-bucket guard <=$5, zero-line
suppression, true==batch VERIFY guard, auto-sync extended to cost_closing/upsell macros (75 specs
re-anchored). guard-accepts.json mechanism added (VERIFY-class only, reason required): suya 7.0-lb
arithmetic truth accepted. specs-ready.txt NOT written (armed only by -WriteReady after auditor GO).

## Stage 6 AUDIT ROUND 1: NO-GO with 4 blockers (2026-07-25) - fixes in flight
CLEAN: macros (100% recompute, worst dev 0.173%), cost invariants, cards (byte-parity vs live),
voice (0 dashes/swears in 900 files), publish gates. Dossier rulings: chuck/ground-beef prices REAL,
marketplace premiums accept-with-note, red-curry-paste + lap-cheong ACCEPT, kecap math VERIFIED,
suya accept CONFIRMED, 18 rich recipes accept, map-extension nulls documentation-only (cherry-tomato
~2x understate in 2 recipes = accept-and-annotate).
BLOCKERS: B1 salsa|Walmart cell was a Wholly Guacamole hijack ($0.342/oz, 8 recipes overpriced) -
FIXED by main session (exclude guacamole/avocado/wholly; cell now GV Thick+Chunky $0.1231; diff =
exactly 1 changed cell). B2 protein fields: 12 turkey-sausage dishes labeled pork -> turkey + cassoulet
turkey -> pork by heaviest rule (census ~T101/P67) - TUNER fixing. B3 sauerbraten cloves 61g +
musakhan salt 117g - TUNER fixing. B4 recipes-db item_id convention: stamp ingredient-map ids where
they exist (scaler bids stay) - PORT AGENT fixing + japchae widget string + 2 prose touch-ups, then
full regen + guards with fresh timestamps.
PS 5.1 LESSON (bit twice): ConvertTo-Json wraps arrays as {value,Count} unpredictably even with
-InputObject; the reliable path is text-level unwrap + [IO.File]::WriteAllText. NEVER round-trip
commodities.json through ConvertTo-Json again - use targeted text edits or the registration scripts.
After fixes: auditor re-verify (SendMessage) -> GO -> -WriteReady -> test slug + 375px -> batches.

## Stage 6 dispatch history
Full checklist + 10-item dossier (board-price plausibility salsa/chuck/ground-beef, marketplace
premiums, kielbasa->turkey-sausage protein-field ruling, red-curry-paste display, lap cheong,
ABC kecap DERIVED label verify, suya accept confirm, map-extension null overrides, 6 rich sausage
recipes, spice-fix sanity). Amendment briefed: update-recipes-db writes protein/item_id directly;
normalize-recipe-ids must NOT run over new rows. Auditor cannot create specs-ready/publish/push.
After GO: test slug publish + 375px/dark eyeball -> batches ~75 -> update-recipes-db -> planner/hub
rebuilds -> REPO PUSH (06:30 revert protection) -> post-publish-reviewer per batch.

## Stage 5 B4 + regen pass: COMPLETE 2026-07-25 19:27 - FULL guards 300/300, all 300 cards rebuilt
Ran after the data agent settled (recipes-computed/costed 19:23:53-54, quiet 150s incl. the corrected
comparison board), then cost-engine -> build-specs -> guards FULL -> build-all(300) -> guards FULL again.
specs-full-ok.txt (19:27:48.0298) is the NEWEST artifact in the folder, so it postdates every spec and
every card write - the ordering the auditor flagged last round. specs-ready.txt still NOT written.
B4 ITEM_ID CONVENTION (update-recipes-db.ps1): item_id is now looked up in ingredient-map.json FIRST
(the live 213's convention) and falls back to the card's scaler bid only for items ingredient-map lacks.
Card scaler payloads keep their own bids (live r100 precedent; the feed carries both families), so the
divergence is resolved in the database only. Header claim corrected; the old header said normalize-
recipe-ids would null these ids, which is no longer true for ingredient-map items.
DRY RUN (300 recipes, 4221 ingredient rows): ingredient-map 3928 | scaler-bid fallback 287 | null 6.
40 distinct items re-pointed (rice->jasmine-rice x162, russet-potatoes->potato x60, carrots->shredded-
carrots x58, chicken-thighs->boneless-skinless-chicken-thigh x46, ground-beef-8020->93-7-ground-beef x20
- the $5.56 vs $6.17 pair the auditor called out). 6 nulls are the label-priced items with no board row
(Sumac, Bulgur Wheat, Keto Bun, Korean Rice Cakes, Pasta Shells - jumbo x2).
OPEN FOR THE AUDITOR: 12 of the 55 fallback items inherit a PROXY id (the commodity the card is priced
off, not the item itself): sirloin-steak, kielbasa (smoked turkey sausage), onions (red onion),
tortillas, bread, cottage-cheese (ricotta), pesto, tomatoes (cherry), tomatoes-green-chilies,
canned-pumpkin, cookies (gingersnaps), potato-chips (corn chips). Correct for pricing, but a grocery
merge will fuse ricotta with cottage cheese and red onion with yellow. Registering these as their own
commodities is the durable fix.
FIX-IN-PASSING (auditor advisories, all verified in the rebuilt cards):
 * japchae scaler payload now renders "Korean glass noodles (dangmyeon)"; the spec carries scaler.canon
   = "Cornstarch" for machines, bid/gpu/pricing untouched, and 0 occurrences of "Cornstarch" remain on
   the card. New guard: a renamed scaler item must be a name the rest of the card actually uses.
 * prose-sheet-pan-chicken-sweet-potato-brussels no longer claims "the top of our price range".
 * zuppa-toscana-sausage-potato-kale-soup now uses the indirect "a certain endless-breadstick chain"
   form, matching its sibling card. No other branded restaurant references exist in the 300.
VERIFICATION: build-all lint 0 failures over 300 cards (section order, credit, scaler, JSON-LD, author,
em/en dash). Spec hash is IDENTICAL before and after the final guard pass, which proves the built cards
were rendered from the exact spec bytes that passed. nigerian-chicken-suya-bowls now clears via the main
session's ACCEPTED-VERIFY allowlist (exact 7 lb thigh); musakhan + zanzibar pantry lines cleared once the
data agent corrected the allspice/poultry-seasoning quantities.

## Stage 4 history: NEARLY COMPLETE 2026-07-25 - gates green, pricing green, package-def polish in flight
MACROS: 300/300 >=550 cal (min 550/avg 618/max 886, >900 EMPTY), 300/300 >=25g protein. 169 documented
manual-overrides incl 18 title-protein swaps (turkey giouvetsi/iskender/kabsa etc now computed on TITLE
protein; mafe -> chicken thigh) + a 4th hidden sausage-canon bug fixed (2 lb breakfast sausage was
computing as Italian Seasoning). Glass-noodle=Cornstarch macro basis kept; writer must say "Korean glass
noodles (dangmyeon)" - notes_for_spec_stage in manual-overrides.json.
PRICING: Walmart captures imported (38 rows, ADD-only merge, board diff vs pre-r300 clean: the only 2
changed cells are documented same-price Kroger tie-flips). Guajillo fix (relax_global sauce + salsa(?!,)
+ sauces?(?!-) excludes - marketing-text trap) and rye-bread unit flip each->oz (+map gpu sync to
28.3495/oz) landed 5 more cells, diff surgical (changed=0 dropped=0 added=5). labels-r300.json covers
bulgur/jumbo-shells/keto-bun/rice-cakes/sumac package prices (marketplace premiums noted). Cost-engine
label loader fix: raw-name registration so 'Pasta Shells - jumbo' can't be orphaned by the r100 fold.
FINAL: 0 unpriced lines, 0 true<batch, 0 firstrun<true, $0.78-$6.48 avg $2.44. Guards: price-mode OK,
food-class OK (2663 cells). IN FLIGHT: tuner agent adding r300 package/bulk defs ($PKG +
pantry-packages) so TRUE/starter costs stop undercounting new items (~267 advisory flags).
GOTCHA for next runs: ConvertTo-Json on a bare array wraps it in {value:[]} - always -InputObject.

## Stage 4 dispatch history (superseded)
Engine state pre-tuning: 0 missing DB, 0 zero-gram, 0 unparsed; 21 under-550, 47 under-25g-protein
(driver: 35 no-qty substantive lines), 7 over-900 (caldereta 1286 = fry-oil discard case).
FABLE tuner agent: manual-overrides for no-qty lines + protein bumps + rich-dish judgments ->
gates 300/300 (<=2 documented rich acceptances). OPUS board agent: register 21 commodities
(collision exclusions both ways, guards, hijack audit, FF/HV prime + Kroger API; walled-store
capture worklist for main session; NO repo push - publish stage must push or 06:30 reverts).

## Stage 2.5 dispatch (superseded)
build-final-300.ps1 merges selected+harvest -> FINAL-300.json (4576 lines, 51 headers skipped,
418 no-qty garnish-tier lines; splitter handles unicode fractions, BB costs, "500g", "tsp." units).
normalize-ingredients.ps1 (r300 port) loads r300-canon-rules.json FIRST then r100 canon-rules.json.
Round 1 vs r100 rules alone: 73 new items already recognized, 680 distinct unmapped.
Rule-writing agent (FABLE) dispatched: writes r300-canon-rules.json to 0 unmapped + hijack audit +
canon-notes.md. House folds pre-briefed (no-alcohol, pork-belly->shoulder, PROTEIN-SWAP-LAMB marker,
NEW gates at 3+ uses, seafood drops).

## Stage 2.6 dispatch (superseded)
selected.json only carries main_ingredients name-lists; the normalize/compute engine needs VERBATIM
ingredient lines + source_servings + published nutrition (r100 had these in FINAL-100.json).
8 agents (opus, general-purpose fallback) fetch the 300 source pages -> harvest\H1-H8.json
(chunk worklists in harvest\chunk-H*.json, 38x7+34). Fetch failures marked, never fabricated;
failed slugs will need re-source or manual capture before stage 2.5 normalize.

## Stage 1 dispatch history (re-dispatched 2026-07-25 after app restart)
Slices: T1-T3 turkey (135 target), P1-P3 pork (120), B1-B2 beef (100), C1-C2 chicken (90). ~445 candidates for 300 slots.
Output: candidates/<slice>.json
NOTE: custom agent registry did not load this session (only recipe-dedup-selector registered);
sourcers dispatched as general-purpose agents pinned to Opus with recipe-sourcer.md instructions
inlined verbatim - same model class + same brief, so no quality change. If later stages need
recipe-writer/mapper/auditor/reviewer and the registry is still missing them, use the same
inline-instructions fallback with the model from each .claude\agents\*.md frontmatter.
