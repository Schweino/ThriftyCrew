NO-GO
scope: whole-wave

# Wave 2 audit - hunt-2026-08-27-highprotein (batch hunt-2026-08-27-highprotein-w2)

Auditor: recipe-batch-auditor, 2026-08-27. Battery report read: waves\wave-2.preaudit.json
(generated 2026-08-27T14:21:18, after the spec's 14:20:07 mtime; stamps coherent). Battery: 16
checks, 2 failed. One battery failure re-derived clean, one confirmed and joined by a finding of
my own that the battery does not cover.

## VERDICT: NO-GO. Two blockers.

### BLOCKER 1 (recipe-local): ground turkey price-class / macro-basis mismatch
File: meal-prep\db\recipes\one-pan-sloppy-joe-casserole.json (scaler bid), plus the mapper's new
food-DB row "Ground Turkey" and the pending recipes-db item_id.

The spec bids the turkey line to `ground-turkey` - the board's GENERIC family (feed cheapest:
Aldi Kirkwood 3 lb at $2.66/lb, the 85/15 grind; engine basis board:ground-turkey:walmart,
$19.11 / 5 lb = $3.82/lb). Its macros come from the mapper's new food-DB row FDC 171505
(148 cal, 19.7 P, 7.66 F per 100 g) - a 93/7-CLASS number. The estate separates these two
classes on purpose: the feed carries `ground-turkey` ($2.66/lb cheapest) and
`93-7-ground-turkey` ($4.08/lb cheapest) as distinct families, and EVERY other ground-turkey
recipe in the catalog (93 recipes-db rows; I grepped all specs - exactly one spec in the whole
estate bids `ground-turkey`, and it is this one) pairs the 93/7 bid with the pre-existing
"93/7 Ground Turkey" food row (FDC 172850, 170 cal/4 oz).

Why it blocks: the published 766 cal / 45 g protein / 34 g fat assumes lean turkey, while the
price pitch rides the generic family. A reader who buys the priced family's shelf product
(85/15, ~212 cal / 15 F / 16.8 P per 100 g) lands near 860 cal and 45 g fat per serving -
OUTSIDE this run's enforced 450-800 band, at 45.4 g protein already only 5.4 g above the floor.
The recipe passes the band only as specced, not as shopped. Same class as the wave-2 shakedown's
wrong-price-class ruling.

Riders fixed by the same repair:
  a) Food-DB near-duplicate: the new "Ground Turkey" row (148 cal/100 g) duplicates the existing
     "93/7 Ground Turkey" row (~150 cal/100 g) - the sixth collision of the known class (Brad
     confirms row removals per the backfill protocol).
  b) recipes-db item_id: my re-run of update-recipes-db -DryRun shows the row would enter with
     scaler-bid fallback `ground-turkey`, minting a SECOND turkey id against 93 existing
     `93-7-ground-turkey` rows - the meal-plan-builder grocery merge cannot join them (auditor
     B4 class, documented in update-recipes-db.ps1 itself).

REPAIR OWNER: the MAPPER re-rules the turkey line - bid `93-7-ground-turkey`, reuse the existing
"93/7 Ground Turkey" food row, drop the near-duplicate row (Brad confirms). Then recost (utility
moves roughly +$1.2 batch, ~+$0.09/serving at the 93/7 family basis; run sync-recipesdb-cost
before propagate), writer rebuilds stat/prose/card, and a scoped `-Slugs
one-pan-sloppy-joe-casserole` re-audit signs it off. Keeping the generic bid and flipping the
macros to 85/15 instead is NOT available - it breaches the 800-cal ceiling.

### BLOCKER 2 (shared-data, not this wave's recipes): audit-spec-contradictions is red
The gate exits 1 (I re-ran it): STAT-PROSE 1 vs baseline 0, PHANTOM 4 vs baseline 0. No finding
is in wave 2, but a wave cannot publish over a red shared gate and the gate is not weakened.

  - STAT-PROSE (chicken-rice-and-broccoli): FALSE POSITIVE of the instrument. RX_PROTEIN in
    meal-prep\pipeline\spec-contradiction-lib.ps1 line 14 is decimal-blind: against
    "47.3g protein" the word boundary after the period lets it capture "3g", reported as
    "says 3g protein, stat says 47". The spec's own repair notes record that "47.3g protein" in
    head.description was explicitly allowed by a prior ruling. Fix the shared lib regex to
    refuse a decimal-fragment match (e.g. prefix guard `(?<![\d.])`), in the ONE shared copy -
    audit and repair dot-source it together by design.
  - PHANTOM x4 (beef-birria-burrito, beef-burrito-tex-mex, salsa-verde-chicken-burrito,
    turkey-florentine-rice-bake): steps say "shredded cheese" while the ingredient line is
    "Mexican Cheese Blend" (bid shredded-cheese). The dishes are makeable as shopped; the prose
    noun matches no ingredient line. The owning stage rules: repair the four steps' prose to
    name the cheese the reader bought, or teach the matcher the vocabulary synonym - its call,
    not mine, and not this wave's.

REPAIR OWNER: the spec-contradictions owning stage (lib matcher fix + the four live-spec prose
repairs). Baseline (2026-08-05) predates the 2026-08-24 detector change and the 8/23-8/27 spec
edits; either way the gate is red now and blocks.

### Battery failure re-derived CLEAN (not blocking)
recipes-db-dryrun: the battery could-not-look (rc 1, no item_id source line). I re-ran its exact
invocation (-RunDir, -SpecsDir db\recipes, -SpecList waves\wave-2.preaudit-slugs.txt, -DryRun):
exit 0, "ingredient-map 12 rows | scaler-bid fallback 3 rows | no id (null) 0 rows". Transient
failure; the fallback listing is, however, what surfaced Blocker 1's rider (b).

## CLEAN CATEGORIES (verified, not assumed)
1. MACROS: clean AS SPECCED. Independent end-to-end recompute from food-macros-db (all 15 lines,
   my own script, not the battery's): 765.51 cal / 45.41 P / 70.81 C / 34.43 F per serving vs
   stat 766/45/71/34. Full recompute done because 766 sits within 5% of the 800 ceiling. Band:
   450 <= 766 <= 800, protein 45 >= 40, biscuits (546 g carbs/batch) are the real carb source.
   But see Blocker 1 for the as-shopped basis.
2. COSTS: clean. Tiers coherent (41.68 batch / 47.08 true / 55.24 first-run; 2.98 / 3.36 per
   serving); engine row reconciles; shelf sanity per line: turkey $3.82/lb, peppers ~$1.03 each,
   biscuits $1.77/can, cheese $1.73/8oz, tomato sauce $0.84/15oz - nothing near the 3x-cheap bar.
   Blocker 1 will move the turkey line modestly upward.
3. MAPPING: rulings evidence-backed (bell-peppers refused green-only per standing rejection;
   biscuits same-form, halved is a knife cut; cheese matches the 2026-08-26 mozzarella
   precedent). Blocker 1 is the exception. Non-blocking note: `bell-peppers` will be a
   first-of-family item_id vs the per-color families (green x70, red x54); ruling is written and
   defensible, but mixed plans will list peppers on two lines.
   Biscuit food-DB collision was handled per the never-overwrite rule; the standing Grands label
   row (180 cal/58 g) is the one my recompute used, and the mapper's rejected 293/100 g figure
   would move calories DOWN ~15/serving - in band either way.
4. PROTEIN: turkey by 2117 g, claimed=derived, DryRun re-run clean, rotation-safe.
5. CARDS: battery rebuild structurally identical to the live reference card, no dash bytes,
   JSON-LD parses; template untouched so no new 375px surface.
6. VOICE: clean. No em dashes, no swearing, register holds; QA verified prose numbers and the
   deliberate oil/butter/parsley omissions are documented and defensible.
7. GATES: store-integrity, vocab, unbid, cost-plausibility, cost-line-coverage, P8 endpoint
   provenance and feed liveness all clean. Dish identity ruled distinct from the two live
   sloppy-joe bowls by the decider (written ruling in state history). State/wave/manifest tell
   one story (sourced 11:42 -> waved 14:20:59, wave file matches).

## PATH BACK TO GO
1. Mapper re-rules the turkey line (Blocker 1) -> recost -> sync-recipesdb-cost -> rebuild ->
   `wave-preaudit.ps1 -RunDir <run> -Wave 2 -Slugs one-pan-sloppy-joe-casserole` -> scoped
   re-audit.
2. Spec-contradictions owning stage fixes the lib regex and rules the four PHANTOM specs
   (Blocker 2); gate green.
Both must be green before wave-publish.
