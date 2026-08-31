GO
scope: whole-wave

# Wave 14 audit - hunt-2026-08-27-highprotein (batch hunt-2026-08-27-highprotein-w14) - 2026-08-31
Slugs: healthy-hamburger-helper, classic-beef-and-bean-chili.

## Why this wave exists
On 2026-08-31 a backlog sweep found EIGHT recipes that were sourced, written and spec-built but never
published. Six of the eight did not reach GO and are deliberately NOT in this wave:

  chicken-and-potato-curry        w9 R4 unrepaired - still bids `serrano-peppers`; card still reads
                                  "Fresh Red Chili ... Buy 1 lb: $6.40" against a ruled $1.43/lb, i.e.
                                  4.5x the ruled price. Cost block also one engine generation stale.
  creamy-roasted-garlic-chicken   phase6b w2 B1+B2 unrepaired - "Salt (Morton): to taste (140 g)" and
                                  28 g pepper sit in ingredients_display AND head.recipeIngredient,
                                  so half a cup of salt ships to Google as JSON-LD. Milk prose also
                                  contradicts its own cost line.
  no-boil-chicken-pasta-casserole w9 R3 unrepaired - "Lemon Zest ... Buy 1 each: $4.83" while the same
                                  recipe prices juice lemons at $0.62 each two lines up.
  street-corn-chicken-rice-bowls  w9 R3 unrepaired - "Lime Zest ... Buy 1 each: $4.19" while limes
                                  price at 4 for $1.00 off the same board commodity.
  teriyaki-grilled-...-rice-bowls w6 B1 unrepaired - `teriyaki-chicken-bowl` is LIVE (verified in
                                  recipes-db) and two sibling dishes were rejected as dupes against
                                  that same bowl. Needs a dedup-selector re-ruling, not a publish.
                                  Do not inherit the stale w4 "GO"; the w6 desk superseded it.
  high-protein-chicken-alfredo-   mechanically clean, but its main protein is Frozen Lightly Breaded
  lasagna                         Chicken Breast Bites (1058 g, $21.95 of a $34.48 batch) against a
                                  hunt condition naming boneless skinless breast. Brad ruled on
                                  2026-08-31 to REMAP it to regular chicken breast, so it returns to
                                  the mapper rather than publishing.

The citrus-zest defects are wrong BASIS, not stale price - they stay wrong at any price level, which
is why none of them clears by waiting for a re-cost.

## Battery disposition
recipe-batch-auditor ran wave-preaudit.ps1 over the whole backlog set on 2026-08-31T12:29:37
(65 checks, 2 failed). Neither failure belongs to either slug in this wave:
  - the cost-reconcile FAIL was chicken-and-potato-curry's stale cost block (not in this wave);
  - the card-rebuild FAIL was a harness path-length artefact on a 56-char slug under a long scratch
    path, re-derived by hand as clean (also not in this wave).
A fresh per-slug battery was re-run for the chili AFTER its rename:
qa\classic-beef-and-bean-chili.battery.json (5 of 6 lanes ok; the coverage FAIL resolves to naming
pairs, disposed below). The older qa\pioneer-woman-chili.battery.json predates the rewrite and is not
this recipe's record.

## healthy-hamburger-helper - GO
- MACROS hand-recomputed end to end, 100%, not sampled: batch 7883.9 cal / 569.8 P / 828.1 C /
  260.2 F over 14 = 563.1 / 40.7 / 59.2 / 18.6 against stat 563/41/59/19. Exact.
- ITS WAVE-5 BLOCKER IS GENUINELY REPAIRED. The `Rotini Pasta` food-DB row had been carrying a
  Barilla Protein+ panel for plain rotini; it was corrected 2026-08-29 to regular Great Value
  (200/7/42 per 56 g) with a correction note in the row, and the stat rebuilt. Aftercare verified:
  all four live recipes riding that row (turkey-pesto-pasta-kale, turkey-alfredo-rotini-bake,
  pizza-pasta-bowls, ground-beef-stroganoff-pasta) still recompute exactly. The cost line stays in
  the regular pasta class ($2.74 / three 16-oz boxes) and the "any short pasta subs" prose is
  coherent with it.
- SOURCE-QA PASS on both anchors: the live page fetched and matches the transcription line-for-line
  (14 ingredients, 4 servings, same 4-step method); one clean 3.5x scaling across all 13 lines;
  method maps one-to-one with no technique swap. Two NOTES, neither blocking: the source's 2 cups
  water is uncosted by site convention and carried in the method as "an equal amount of water"
  beside the 7 cups broth (the source's own equal-parts ratio at 3.5x); and the source's olive-oil
  spray renders as an optional uncosted "light coat of nonstick". Both flagged in writer_notes.
  Substitutions (lean ground beef -> 93/7, onion -> yellow onion, broth/cheddar branded to Great
  Value) are identity-preserving, same head noun.
- Card byte-matches a fresh rebuild. Cost tiers derive to the cent; no batch/14 fallback.
- Known non-defect: the battery's beef tally of 3268 g includes 1680 g of beef broth (a known tally
  artefact). Real meat is 1588 g and the label is correct.

## classic-beef-and-bean-chili - GO
- MACROS hand-recomputed end to end, 100%: batch 9518.6 / 584.6 / 591.1 / 532.1 over 14 =
  679.9 / 41.8 / 42.2 / 38.0 against stat 680/42/42/38. Exact.
- THE RENAME RULING IS APPLIED. Brad ruled 2026-08-29 to rename off the trademark; no "Pioneer
  Woman" or "Drummond" string appears on any rendered surface. The source URL inside the credit
  anchor keeps the source's own slug, which the ruling explicitly preserved.
- THE LEDGER STILL CARRIED THE OLD SLUG, and that is worth recording because it caused a real
  misreading today: `pioneer-woman-chili` has no spec and no card on disk, so the backlog sweep first
  read this recipe as an empty shell, and an earlier GO recorded against the old slug looked like a
  GO for a recipe that did not exist. Ledger, state and manifest should be reconciled to one story.
- SOURCE-QA PASS on both anchors. This recipe was REJECTED by an earlier desk and then rewritten, so
  the rewrite was checked specifically for invented or dropped content: it introduced nothing and
  dropped nothing beyond a documented garnish ruling. Four NOTES, none blocking:
    1. the battery coverage FAIL is naming pairs, not inventions - "Cheddar Cheese, Shredded" =
       source "Shredded Cheddar", "Lime" = source "Lime Wedges" (house-style leading-qualifier
       naming, which the head-noun pairer misses on the reordered form);
    2. the one true drop, "Tortilla Chips or Fritos", was ruled out at mapping as an unquantified
       either/or garnish naming two foods; it is in the state history and forbidden_prose_terms;
    3. source garnish "Sour Cream" became "Light Sour Cream" - a deliberate budget/macro swap on an
       unquantified garnish;
    4. the source offers three methods; the card ships ONE stovetop method that folds in the diced
       tomatoes the source marks "Instant Pot only", so every bought ingredient is used. The cooked
       dish is the source's Instant Pot variant executed on the stove, with brown / season / 1-hr
       simmer / masa slurry / beans / 10-min finish preserved in order. Documented in writer_notes.
- SCALING: one consistent 6 -> 14 ratio (2.333x) on every line. Garlic 2 -> 5 cloves is whole-clove
  rounding of 4.67 on a countable unit.
- ATTRIBUTION IS HONEST POST-RENAME: the credit links thecozycook.com, the page actually transcribed
  and live-verified, which itself credits Ree Drummond / Food Network.
- Cost lines shelf-plausible (80/20 beef; limes 4 for $1.00; masa starter $4.36 at Sam's). Tiers
  derive to the cent.
- KNOWN LATENT, NOT BLOCKING: head.keywords still leads with "pioneer woman chili". It is not
  rendered into the built head today. Strip on the next writer touch.

## Shared gates, 2026-08-31
audit-unbid-ingredients clean n=586; audit-spec-contradictions 0 findings; audit-cost-plausibility
clean n=586; audit-cost-line-coverage clean n=586; audit-paid-not-public checked=576 leaks=0 skew=0;
guards hard=0 "safe to publish"; run-gates 154 passed 0 failed; feed live at 576 recipes.

## Price-move note
Both recipes reconcile against the current board (comparison-2026-08-31, built 09:26). A
comprehensive Walmart capture (11,694 rows) landed later the same day and reaches the board at the
next 08:00 chain; E2 re-verifies cost_ps at publish and the daily reanchor absorbs ordinary moves.
Neither recipe has a basis-wrong line, so a normal price move does not invalidate this verdict.

## GO / NO-GO
GO on both slugs. Each carried exactly one outstanding condition - a source-QA pass that had never
been run - and both passed on both anchors with notes only.
