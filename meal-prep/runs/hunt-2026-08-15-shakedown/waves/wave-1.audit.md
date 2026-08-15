GO

# Wave 1 THIRD AUDIT - hunt-2026-08-15-shakedown (chicken-florentine, country-captain-chicken)

Audited 2026-08-15 (third pass) by recipe-batch-auditor. B5, the single blocker from round two, is
verified fixed in both parts, and the writer's bullet-by-bullet tracing was re-done independently and
holds. The new cost-line defect raised for a ruling does NOT block this wave, because its premise is
partly wrong: the blanket string never reaches a reader on the current card generation (evidence below).
The whole wave was re-verified end to end against the rebuilt specs and cards (both rebuilt 13:12).

This GO carries conditions. They are listed first because they are the part Brad needs.

## CONDITIONS ATTACHED TO THIS GO

1. HARD ORDERING (standing round-two ruling, unchanged): do not run the real wave-publish until
   grocery\out\smp-feed.json republishes with the fixed board. Both recipes contain garlic, and
   florentine contains parmesan and butter - three of the cells the live feed still serves at hijack
   prices. The cards hydrate reader prices from that feed at page load, so publishing first means new
   pages showing known-wrong prices from minute one. Feed republish first (or simultaneous), then
   publish. Owned by Brad and another session; this wave must not front-run it.
2. WHEN THE FEED REPUBLISHES: delete or refresh meal-prep\scratch-smpfeed.json (July 27) BEFORE any E2
   recompute. compute-v2-perserving.ps1 line 46 only downloads the feed when the scratch file is
   MISSING, so leaving it in place keeps pricing "cheapest" on July 27 data.
3. The "Buy 1 (lasts several batches)" engine defect ships as a separate task, not a wave hold - I
   agree with that disposition, but the task should be RE-SCOPED per my measurement below: it is spec
   metadata hygiene today, not live reader-facing copy, and the fix must sweep the 513 affected specs
   after the lib fix, plus ship a guard with a must-fire fixture.
4. Standing ruled items, unchanged and disclosed: shallots priced as onions (Brad), bacon on the
   12 g/slice constant (Brad), spinach on the frozen-chopped bid (task open), country-captain at 525
   cal with no cal_floor (round-one ruling), and the two advisory notes under VOICE below.

## RULING ON THE NEW DEFECT: does NOT block, and the premise needs correcting

The parent asked whether a card that tells a reader one carton of broth "lasts several batches" when it
barely covers one batch is a publish blocker. It would be - but no card says that. Verified:

* The blanket string is emitted at pipeline\cost-render-lib.ps1 lines 70-76 for any `bulk` line without
  starter_n >= 2, with no package-vs-usage comparison. Mechanism confirmed exactly as reported.
* But it lands only in the SPEC's cost_lines field. build-card2.ps1 never reads cost_lines (grep: zero
  references). The built cards' cost section is the v2 tabbed whole-package section, data-driven from
  scaler pkg_g/grams (e.g. country-captain raisins row carries pkg_g 340 / grams 181, "12oz bag"), so
  the reader-facing arithmetic cannot state the lie.
* Measured across the authoritative surfaces: db\built 0 of 544 cards carry the engine string (the only
  2 matches, beef-chow-mein-noodles and mississippi-pot-roast-bowls, are hand-written prose about oyster
  sauce and a pepperoncini jar, both true claims); recipes-db.json 0; planner-data.js 0. cost_lines is
  consumed only by pipeline internals (spec-guards sum reconciliation, repair sweeps).
* Live confirmation on the WORST case class: https://www.thriftycrew.com/slow-cooker-beef-and-noodles/
  (public; one of the 7 shopper-short rows, 924 g beef broth vs a 907 g carton) contains no
  "lasts several batches" anywhere and renders the v2 hydrated cost section.
* My independent catalog measurement differs from the parent's: 1630 occurrences across 513 of 544 spec
  files (not 3577 "live cost lines"); replicating the render conditions against costed.json: 537 lines
  under 3 batches/package across 342 recipes and 55 distinct ingredients, of which 7 are shopper-short
  (ratio < 1). The parent's 3577/661/380/78 likely counted archives/run copies; the engine task should
  re-measure precisely, but the direction and worst cases verify (grilled-pork broth 924 g vs 907 g
  confirmed in costed.json).
* Wave instances verified: florentine broth 1.08 batches/pkg; country-captain rice 1.19, broth 1.68,
  raisins 1.88 (guajillo at 8.1 is legitimately "several"). All spec-internal only.
* One wrinkle unique to this wave, acceptable but for the engine task to clear: the country-captain SPEC
  now contradicts itself internally - cost_lines says raisins "Buy 1 (lasts several batches)" while
  shop_smart says "Not several batches". Only shop_smart renders, so nothing reader-facing conflicts,
  but any future consumer or repair sweep quoting cost_lines resurfaces it. Note also that
  audit-spec-contradictions passed over this (it targets stat-vs-prose numbers), so the engine-fix task
  should ship a guard + frozen must-fire fixture per the guard-fixture rule.

If cost_lines ever becomes reader-facing again, this class is a publish blocker. Today it is not.

## B5 VERIFICATION - FIXED, both parts

a) STRUCTURE: intake prose.shop_smart is now a 5-element array, every bullet <strong>-led; the spec's
   shop_smart is byte-identical to the intake array (verified element by element); the built card
   renders exactly 5 <li> each with a bold lead, matching the florentine/catalog pattern; 0 unresolved
   tokens, 0 nested/empty <p>. Verified at a real 375x812 viewport: zero horizontal overflow, zero
   off-canvas elements, section eyeballed and clean.
b) RAISINS CLAIM: now "One box of golden raisins covers this batch and most of a second... Not several
   batches, but the box is not a one-and-done either." Verified against the costed row: 340 g package,
   181 g used (= the stated cup and a quarter at 145 g/cup), 159 g remainder = 0.88 of a second batch.
   Correct.

TRACING (re-done independently, not taken on trust) - all five country-captain bullets check out:
1. Thighs "biggest line by a mile": $12.88 of the $26.32 batch; next-largest line is $2.64. True.
2. Bacon "nine slices, a one-pound pack carries more": 9 slices vs 1 lb; true at the 12 g/slice
   constant and at real thick-cut weights.
3. Raisins: as above.
4. Spices "jars you already own" + guajillo "several batches": guajillo 113 g pkg / 14 g used = 8.1
   batches, true. ADVISORY: "one batch barely dents any of them" is generous for curry powder and garam
   masala - each batch uses 14 g of a 57 g (2 oz) jar, a quarter of the jar (4.1 batches/jar). True for
   salt/pepper/cayenne (17-64 batches/jar). Not the refuted-claim class; ships, worth softening on any
   future touch.
5. Almonds "close to five batches", "three quarters of a cup": 397 g bag / 81 g used = 4.9; 81 g = 0.75
   cup slivered. True.
ADVISORY: bullet 3 says "box" of raisins; the costed package label is "12oz bag". Nothing on the card
renders the package label beside it, so no visible conflict; cosmetic only.
Florentine's four bullets: spec byte-identical to the round-two-verified intake; all four previously
traced to the buy lines (pre-grated tub $2.74, two pints with half a cup left, cutlets, wine-skip).

## FULL WAVE RE-VERIFICATION (spec changed, so everything re-checked)

1. MACROS: CLEAN. stat unchanged from my round-two hand recompute (florentine 573/45/14/37 from
   573.2/45.1/13.5/37.1; country-captain 525/35/66/12 from 524.8/35.1/65.5/12.1); food-macros-db.json
   untouched since 08-07; ingredients_grams cross-checked against costed.json by the builder's own
   self-test at the 13:12 rebuild (it throws on any disagreement, and it built).
2. COSTS: CLEAN (everyday tier). Machine fields exact vs db\costed.json (12:29): florentine
   23.45/32.88/13.14/46.02, country-captain 26.32/35.80/16.71/52.51; per-serving 1.68/2.35 and
   1.88/2.56 at /14; stat cost_ps 3.29/3.75 agrees with v2-perserving.json; scaler.cost =
   cost_batch_true both. Every distinct money literal in prose re-swept against machine fields -
   re-anchor pairing clean, no fact published twice. Cheapest tier rides the standing scratch-smpfeed
   staleness ruling (condition 2).
3. MAPPING: CLEAN. update-recipes-db -DryRun rc=0, identical to round two: 32 item_ids from
   ingredient-map, 1 allowlisted scaler-bid fallback (dried-guajillo-chiles), 0 null. Ruled exceptions
   stand per Brad.
4. PROTEIN + ROTATION: CLEAN. protein=chicken on both (florentine chicken-only; country-captain 1814 g
   chicken vs 108 g bacon); both visibility=paid; neither is protein rank 1, so the free rotation and
   hub Top 5 sets are untouched. normalize-recipe-ids.ps1 NOT run, per the 2026-07-25 correction.
5. CARDS: CLEAN. 0 unresolved tokens both; Shop Smart renders 4 and 5 strong-led bullets respectively;
   375px re-verified on the rebuilt country-captain card (zero overflow); serving scaler present;
   round-two skeleton parity (96/96 markers vs live teriyaki) unaffected by a prose-only change.
6. VOICE + COPY: CLEAN with the two advisories above. 0 em dashes, 0 en dashes, 0 swearing in both
   specs and both built cards (UTF-8 scan).
7. GATES: CLEAN. audit-spec-contradictions -Quiet rc=0; audit-store-integrity hard=0 (same 19
   pre-existing catalog warns, none on these slugs); test-guards ALL PASS; batch-ledger -Verify clean
   (wave row in flight, correctly owing audit..review); audit-db-agreement exactly the two expected
   SPEC-ONLY lines (index rows land at E3). Bonus: wave-publish preflight was exercised and correctly
   REFUSED on the round-two NO-GO first line, so the GO/NO-GO wiring in this file is proven live. No
   gate weakened.

## SEPARATE TASKS (not wave-blocking, carried forward)
* Engine blanket-string fix, re-scoped per the ruling above: compare starter_pkg_g to grams in
  cost-render-lib.ps1, then SWEEP the 513 affected specs (the lib fix alone leaves every derived
  cost_lines stale - repair stops at the source of truth), and ship a guard + must-fire fixture.
* Two-slug ledger -File marshalling fixture (round-two advisory).
* Composition-bar "Share of the batch cost" label vs mass weighting - design backlog, site-wide.
* scratch-smpfeed refresh rule (with the delete-after-feed-republish interaction in condition 2).
