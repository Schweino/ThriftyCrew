GO
scope: whole-wave

# Wave 12 audit - hunt-2026-08-27-highprotein - 2026-08-28
Auditor: recipe-batch gate. Battery report: wave-12.preaudit.json (generated 2026-08-28T20:19:18,
16 checks, 0 failed). Spec mtime at audit: 2026-08-28T20:18:46 (battery ran AFTER the spec write; the
report certifies the current bytes). One slug: honey-bbq-chicken-mac-and-cheese, revived from the
wave-11 NO-GO. Both prior shared-data blockers verified closed by my own hand, not taken from the
dispatch.

## VERDICT: GO

### Prior BLOCKER 1 (shared-data, writer) - VERIFIED CLOSED, and the gate was not weakened
Re-ran audit-spec-contradictions myself at audit time: RC=0, PHANTOM 0, SPEC-CONTRADICTIONS-COMPLETE
over 588 specs. Read the full gate diff of commit 0f1a70ae before believing the exit 0, because the
fix touched the detector itself:
  - beef-rendang: the constituent map gained `coconut milk -> coconut oil`, and the WHOLE map was
    tightened from single tokens to every-word phrase matching, with a frozen must-still-fire twin
    (olive oil over a coconut-milk recipe still fires). That is teaching, not forgiving.
  - mediterranean-chicken: real defect, prose fixed to use the bought olive oil.
  - blackened-chicken: step now says it MAKES the salsa, which the existing MADE exemption reads.
  - NO re-baseline; baseline stands as written 2026-08-05. No dish-title suppression anywhere.
Residual (non-gating, under baseline 21): UNMEASURABLE-QTY 2 in OTHER recipes -
chicken-biryani-rice-bowls "Milk (Fairlife): 0 tbsp (1 g)" and turkey-cordon-bleu-casserole
"Dijon Mustard: 0.07 tbsp (1 g)". Writer hygiene, not this wave.

### Prior BLOCKER 2 (shared-data, pricer) - VERIFIED CLOSED end to end
The repair minted `reduced-fat-cheddar` (recipe-commodities.json, commit c682bfb4) instead of
refiling cheddar-cheese, and rebid this recipe's line onto it. Every link checked on disk:
  - EVIDENCE: runs\...\price-evidence\mint-reduced-fat-cheddar.rows.json - 3 carrying stores with
    shelf-shaped prices: Baker's Kroger Reduced Fat Sharp Cheddar Shredded 8 oz $2.00 ($0.2500/oz),
    Aldi Happy Farms 2% Sharp Cheddar 11 oz $2.79 ($0.2536/oz), Hy-Vee 2% Sharp 7 oz $2.48
    ($0.3543/oz). All three rows are genuinely reduced-fat cheddar. The 4 absent stores could only
    LOWER the crown, so $0.2500/oz is conservative-safe.
  - BOARD: recipe-board-everyday.json carries the id, cheapest_store Baker's, rows byte-consistent
    with the evidence.
  - FEED: local smp-feed.json AND the LIVE https://feed.thriftycrew.com/smp-feed.json both carry
    reduced-fat-cheddar cheapest 0.25 Baker's n=3 (checked live myself - the card prices client-side
    from this feed, so live coverage of the new id was the one link no battery check proves; it holds).
  - VOCAB: ingredients.json "Reduced Fat Cheddar Cheese" -> bid reduced-fat-cheddar, gpu 28.3495 oz.
  - COSTED: util 525 g = 18.519 oz x 0.2500 = $4.63 (recomputed by hand); buy 3 x 8 oz bag = $6.01
    (the extra cent is the 227 g package-gram basis: 681 g = 24.02 oz x 0.25 = 6.006 - consistent).
  - BATCH: all 17 utils hand-summed to exactly 24.98; per-serving 24.98/14 = 1.784 -> 1.78; the batch
    delta 24.98-23.17 = 1.81 equals the cheddar delta 4.63-2.82. True tier = non-bulk buys 31.76 +
    bulk utils 3.02 = 34.78; first run 34.78 + 11.09 pantry = 45.87. stat.cost_ps 3.28 derives as
    45.87/14 = 3.276 (first-run basis; wave-publish E2 re-verifies at publish).
  - SPEC prose updated: "Reduced Fat Cheddar Cheese, 4 3/4 cups shredded: ~$4.63. Buy 3 8 oz bags:
    $6.01." The old "$3.65 blocks" text is gone; the lone "2.82" remaining in the spec is the milk
    gallon buy, a coincidence, not a stale cheddar price.
  - CARD: wave-12 rebuild carries bid reduced-fat-cheddar in its scaler blob; costs are rendered at
    view time from the feed (no dollar literals in the body by design), which is why the live-feed
    check above matters and passes.
  - SWEEP: zero recipes in costed.json still bid cheddar-cheese. The wave-11 demanded cross-recipe
    sweep is satisfied by vacancy.
  - MAPPING identity: Reduced Fat Cheddar Cheese -> reduced-fat-cheddar is same-concept; the food-DB
    macro row is the genuine reduced-fat product (Kraft 2% Milk label, 90 cal / 7 p / 2 c / 6 f per
    28 g) matching the display parenthetical. Reduced-fat cheddar is a real distinct price class from
    cheddar-cheese / cheddar-cheese-shredded / fat-free-cheddar - no duplicate id minted.

### Prior BLOCKER 3 (recipe-local) - stayed fixed
Doubled gram token repair verified in wave 11; wave-12 card rebuild is structurally clean, no
"(10 g) (10 g)" regression (battery card-rebuild pass, spot-read confirms).

## Checks re-derived or judged clean this pass
- BAND (the run's enforced band, not the prose): cal 751 in [450,800] PASS; protein 50.5 >= 40 PASS;
  carbs 85 unrestricted; real carb source pasta PASS; main protein boneless skinless chicken breast
  PASS; 14 servings PASS; no seafood PASS.
- MACROS: battery recompute 751.1/50.5/84.7/24.4 vs stat 751/50/85/24 in tolerance; PLUS an
  independent coarse recompute of the dominant chain (chicken 1400 g, pasta 1050 g, cheddar 525 g,
  cottage 525 g, cream cheese 700 g, honey/BBQ/milk) lands ~730 cal / ~50 g protein per serving,
  within 3% of stat. Rebid changed price only, never grams or the macro row.
- PROTEIN FIELD: chicken; 1400 g chicken vs 0 g others by construction; recipes-db-dryrun RC=0 with
  0 null item_ids (the wave-11 Start-Job harness defect did not recur this run).
  normalize-recipe-ids NOT run (new-era rows), per standing correction.
- COST PLAUSIBILITY line-by-line: chicken $2.23/lb Walmart, cottage $2.73/24 oz, cream cheese
  $1.84/8 oz, milk $2.82/gal, pasta $0.97/lb, honey ~$3.58/lb - nothing 3x under shelf reality.
- VOICE: no em/en dash bytes in spec or card (battery + my own byte sweep); prose is warm, plain,
  no swearing.
- CARDS: scaler, print button, cost nav section, source credit (theproteinplayground) all present;
  structural compare vs the live al-pastor card passed.
- STATE STORY: state waved wave 12 updated 20:17:52 = manifest created = ledger w12 opened. One story.
- Shared gates green at battery time and spec-contradictions re-proved by hand; store-integrity
  hard=0 warn=13; p8 endpoint + live feed (565 recipes; this slug correctly absent pre-publish).

## Non-blocking findings (none block this wave; owners named)
1. pricer - the cheddar-cheese board id is STILL mozzarella-crowned (Sam's Part-Skim Mozzarella
   $0.1519/oz; 4 of 6 rows are not cheddar) and still on the public feed (cheapest 0.1521, n=7).
   No recipe bids it any more, but misfiled content on a served feed is a data-hygiene defect
   waiting for the next mapper to trust it. Refile or retire the row content.
2. pricer - milk board rows still carry empty item/size strings (carried from wave-11;
   store-integrity warns).
3. writer - pasta prose still states two noodle identities: "Ziti Pasta ... (about 10 cups elbow
   macaroni)". Fix at next writer touch.
4. writer - UNMEASURABLE-QTY x2 in other recipes (chicken-biryani-rice-bowls 0 tbsp,
   turkey-cordon-bleu-casserole 0.07 tbsp), under baseline, not gating.
5. vocab hygiene - the "Reduced Fat Cheddar Cheese" ingredients.json note still reads as a
   map-lane reuse note; the row now stands on the c682bfb4 mint. Cosmetic.
6. pipeline - reduced-fat-cheddar board rows omit the per-store "unit"/"membership" keys that
   older entries carry; store-integrity passed, but schema drift is how a later reader breaks.
7. publisher - batch-ledger closure is estate-wide loose (only w8 of 15 hunt batches marked
   closed; w11, the rejected batch, is still open). Wave-publish P2/P3 territory, noted so the
   one-story check there is not surprised.

## For wave-publish
P1b will re-check spec mtimes against this audit: spec 2026-08-28T20:18:46, battery 20:19:18,
audit written after both. If anything rewrites the spec (including the ~07:00 bot's autoStash
rebase bumping mtimes), this GO is spent and the wave re-audits.
