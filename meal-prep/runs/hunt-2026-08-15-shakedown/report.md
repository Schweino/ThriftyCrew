# hunt-2026-08-15-shakedown - final run report

## Outcome

2 recipes carried end to end through every stage of Recipe Hunter v2. Both published live and verified,
then set to DRAFT the same hour for a reason unrelated to their quality (see BLOCKED below).

  country-captain-chicken   525 cal / 35 g protein / $3.75 per serving / 19 ingredients
  chicken-florentine        573 cal / 45 g protein / $3.29 per serving / 14 ingredients

Ledger batch hunt-2026-08-15-shakedown-w1: every stage stamped through post-publish-review, CLOSED.

## Buckets

PUBLISHED then drafted  2
REJECTED                7   all dupes, killed by the dedup selector
PARKED                  0
Pricing stage           not exercised: the board answered every ingredient from disk

Rejected detail: mississippi-pot-roast and loco-moco were HARD dupes already live on the site that the
sourcer had reported as absent. classic-beef-stroganoff and chinese-beef-and-broccoli were near-dupes of
existing ground-beef versions. marry-me-chicken, chicken-fricassee and pork-lo-mein were borderline
near-dupes not needed for a 2-recipe run.

## BLOCKED: why they are drafts

Recipe cards fetch live prices from www.thriftycrew.com/api/v2/recipe-feed/<slug>, served by the V3
platform deleted 2026-08-14. It returns 200 for recipes that existed at the last release and 404 for
anything new, so both pages showed "current release price loading" twice and an empty cost section.
Brad chose to repoint the cards at smp-feed; a task is open with the reconnaissance. Republishing these
two is a visibility flip once that lands.

## What the gates caught

The batch auditor returned NO-GO twice across three rounds and found five blockers, every one of them
passed clean by every stage upstream:
  B1 spec cost blocks went stale against costed.json when a board hijack was fixed mid-run
  B2 hunt-run recorded 1 of 2 slugs in the ledger (array marshalling through powershell -File)
  B3 country-captain shipped nested <p> from self-wrapped prose
  B4 two shop_smart claims the recipe's own cost lines refuted
  B5 shop_smart stored as a string where 504 of 544 store a bullet array, plus a raisins claim of
     "several batches" against a real 1.88

Separately, and not found by any agent: new recipes are absent from v2-perserving.json when their spec is
built, so stat.cost_ps fell back to batch/14 - about HALF the everyday basis every live recipe uses. Both
would have advertised half price and falsely dominated the cheapest rankings. wave-publish now runs the
cost-basis stages and verifies per slug.

The auditor also disproved the orchestrator twice: the garlic hijack was AT Walmart, the store the wave
had been cleared against, and a catalog-wide measurement of a durability defect had counted archive copies.

## Collateral

propagate found 517 dirty specs and carried them: 359 recipes published+verified, 158 skipped-unchanged.
Those specs were dirtied by a concurrent session fixing a false durability claim. Correct behaviour, but
this wave's ledger must not be read as having shipped only 2.
