GO
scope: stuffed-chicken-breast,slow-cooker-pork-loin-roast-or-pork-shoulder

# Wave 1 pre-publish RE-AUDIT - hunt-2026-08-24-v3-phase6b
Auditor: recipe-batch-auditor (final gate), 2026-08-24, after the 12:54-13:06 repair pass.
Battery report: waves\wave-1.preaudit.json, generated 2026-08-24T13:06:21, whole-wave scope, 22 checks, 0 failed
(exit 0 path: clean mechanical bill). Prior audit of 12:53 NO-GO'd on two blockers; both are verified repaired
below, by construction, not by taking the green report's word.

## Freshness of the evidence
The battery's recorded spec mtimes match the bytes on disk right now: stuffed-chicken-breast 12:48:05,
slow-cooker-pork 13:03:55. The lib edit landed 13:02:36 and costed.json is 12:48:24; the battery ran at
13:06:21, after every edit it certifies. Nothing moved during this audit.

## Blocker 1 (prior audit): PHANTOM gate red, 5 findings. VERIFIED REPAIRED, the sanctioned way.
- The fix is in spec-contradiction-lib.ps1 (Get-PhantomIngredients): $own now reads the scaler BUY string and
  the whole de-HTML'd display line, not just the pre-colon key, so composite-rider foods (dried thyme, onion
  powder, dried basil, the sauce black pepper) named after the colon count as bought. Read the diff myself.
- The baseline was NOT bumped: spec-contradictions-baseline.json still says PHANTOM: 0. The prior audit's
  explicit "not acceptable" path was not taken.
- The MUST-FIRE twin exists and fires: new frozen fixture puts a zero-sugar soda in the SAME spec with the
  composite riders; the riders stay silent and the soda still fires. I ran audit-spec-contradictions -SelfTest
  myself: SELF-TEST PASS, rc=0, all 33 checks including the dr-pepper founding case. The gate got stronger,
  not weaker.
- Live gate over all 572 specs: rc 0, SPEC-CONTRADICTIONS-COMPLETE. The fifth finding (pork shoulder in step 5)
  was closed by the writer's rephrase to "a heavier, fattier roast" so no step names an unbought commodity.

## Blocker 2 (prior audit): pork spec shipped the SHOULDER cook time on a LOIN build. VERIFIED REPAIRED.
head.cookTime is now PT4H30M and head.totalTime PT4H40M in the spec on disk, matching the loin path the card
actually shops (scaler bid pork-loin, 8 1/4 lb, $2.14/lb). Step 5 and head.steps lead with the loin 4 to 5
hour time and give the heavier-roast alternate as advisory timing only. The card was rebuilt over these bytes
(preaudit card-rebuild pass, 7 step anchors, JSON-LD parses). The repair is documented in writer_notes.

## Run conditions (400-650 cal AND <=35 g carb, 14 servings, budget, no seafood)
- stuffed-chicken-breast: 524 cal, 9.6 g carb, 63.8 g protein, 14 servings, $1.97/serving. PASS.
- slow-cooker-pork...: 602 cal, 28 g carb, 54.9 g protein, 14 servings, $1.70/serving. PASS.
- I re-derived both independently of the battery. Pork: subtracting honey (445 g), butter (219 g), oil,
  cornstarch, garlic, vinegar and spices from the batch total leaves the loin at ~135 cal, ~20.5 g protein,
  ~5.3 g fat per 100 g raw, which is exactly the food-DB LEAN trimmed loin row (155 cal/112 g). Carbs are
  essentially all honey plus cornstarch/garlic, ~394 g batch vs 392 claimed. Chicken cross-summed within
  1.6% on calories and 1% on protein from the DB rows. The battery's arithmetic is corroborated, not trusted.
- No seafood in either build; forbidden_prose_terms hold.

## Category verdicts
1. MACROS: clean (recomputed by battery, corroborated by hand above; all food-DB rows present).
2. COSTS: clean. Batch/true/first-run tiers re-sum to the cent in both specs (27.54/31.46/45.36 and
   23.79/27.27/46.16); cost_ps matches cost_per_serving (1.97 / 1.70). Shelf sanity: breast $2.23/lb,
   loin $2.14/lb, butter $2.98/lb, honey ~$0.22/oz. The cheapest-looking line, mozzarella at $0.152/oz,
   traces to a real Sam's Club Member's Mark 5-lb shredded capture on the everyday board, so it is a
   captured price, not a class survivor. Zero unpriced lines; nothing routes to mapper, bid wiring or capture.
2b. No cost findings, so no repair owners to name.
3. MAPPING: clean. Loin-vs-shoulder is an adjudicated band-driven ruling (shoulder would breach 650 at ~738).
   Cream cheese to 1/3-fat GV is documented and sold honestly. Mozzarella/parmesan resolve to shredded/grated
   cells matching the buy strings.
4. PROTEIN + rotation: clean. chicken 3178 g / pork 3719 g, exclusive tallies, claimed == derived;
   update-recipes-db -DryRun green, zero null item_ids; both specs are visibility "paid" so the free-dinner
   rotation and hub Top 5 sets are untouched.
5. CARDS: clean. Both rebuilt to scratch, structurally identical to the live al-pastor reference: scaler,
   print, 3-part cost section, credit line, JSON-LD Recipe parses, zero dash bytes. Standard template, which
   is the 375px-verified layout.
6. VOICE: clean. Zero em/en dashes in specs and rebuilt cards; no swearing; plain punctuation.
7. GATES: all green and none weakened; the contradiction gate gained three permanent fixtures.

## Advisories (recorded, NOT blocking; no published claim is falsified by either)
- Sun-dried tomato form (mapper, future touch): the chicken spec books the DRY food-DB row at 63 g (the dry
  density for 1 1/4 cups) while the prose and shop_smart sell the oil-packed jar ("drained", "use the drained
  oil to sear"). Adjudicated immaterial: at the oil-packed drained volume (~137 g) the serving moves +9 cal
  and +1.3 g fat with carbs essentially unchanged (dry is more carb-dense per gram), so 524 stays deep in the
  400-650 band and the "under 10 grams of carbs" claim still holds (~9.6-9.8 g). The DB carries both rows
  (Brad's 2026-08-16 distinct-rows ruling); a future touch should book the oil-packed row with the drained
  volume weight and let the numbers move inside tolerance.
- Chicken intro "under 10 grams of carbs" beside a displayed stat of 10 (actual 9.6): true as computed,
  mildly tense next to the rounding; carried over from the prior audit as advisory.
- Mozzarella buy string says "2 8oz bags: $2.44" priced at the Sam's 5-lb per-oz rate; an 8 oz retail bag
  runs higher per oz. That is the standing everyday-cost board model, uniform across the catalog, and worth
  cents per serving; noted so nobody reads it as a wave defect.

## Left to wave-publish by contract
stat.cost_ps re-anchor and hard-verify (E2); manifest/ledger/states one-story (P2/P3). Both specs carry
cost_ps == cost_per_serving today, and costed.json (12:48:24) predates only the pork HEAD repair, which
touched no cost or macro field, so E2 should find nothing.

## Verdict: GO. No blockers. Publish wave 1.
