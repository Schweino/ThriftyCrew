# Deviations, recorded BEFORE the run (section 10 invariant)

Run: hunt-2026-08-24-v3-noband-drill. Brad's order, 2026-08-24 ~16:25 CDT:
"add 3 recipes end to end where Qwen has to re-extract and then send it down the
full recipe hunter path. Don't use a band for this run."

## 1. NO BAND, stated explicitly rather than bypassed

0-100000 cal, carbs <= 100000, no protein floor. The band is a run parameter and
-Init refuses a run dir without one, so "no band" is SAID OUT LOUD and lands in
run.json where a later reader can see what the gates were enforcing: nothing.

Consequence, and it is deliberate: `candidate_in_band` admits UNVERIFIED candidates
when the band constrains nothing (commit f9cf1faa). Without that, the 280
ingredient-less candidates - the whole point of this drill - would have been hidden
behind a verification requirement while nothing was being verified.

## 2. A SCRATCH POOL, because pop order would never reach the drill corpus

`dossier_rank` sorts verified candidates first (`0 if band.verified else 1`), so
every ingredient-less candidate ranks dead last and a normal pop would never see
one. `--pool C:\tmp\d3\pool.json` (commit f9cf1faa) aims the run at a chosen corpus
without editing the live pool, which harvest.py is the sole writer of. Same seam as
--ledger / --specs / --costed.

## 3. THE CORPUS IS MIXED, AND THE REASON IS A FINDING

The intent was 3 pages needing rung 2 (full-page local transcription). The pool
cannot supply them:

  - 280 available candidates carry no JSON-LD block
  - 187 of those (67%) are WordPress IMAGE ATTACHMENT pages - `baked-pork-chops-2-jpg`,
    `chicken-stir-fry-chop-suey-5-landscape-jpg`. The enumerator's SKIP_PATH does not
    exclude them. That is a harvest defect in its own right.
  - of the 93 non-image ones, only 5 have 5+ measure lines in their cached text, and
    4 of those are meal-plan roundups or technique articles
  - exactly ONE is a genuine single recipe: apple-dijon-kale-salad-meal-prep

So the corpus is 1 rung-2 page + 2 rung-1 pages. That is arguably the better test
anyway: it exercises the ESCALATION LADDER rather than one rung.

  apple-dijon-kale-salad-meal-prep   budgetbytes.com        0 ings  -> rung 2
  sausage-and-rice-one-pot           thecozycook.com       14 ings  -> rung 1
  beef-stroganoff-soup               spendwithpennies.com  13 ings  -> rung 1

## 4. GPU: llama-server hand-started at -Slots 1

16,384 tokens per slot against rung 2's ~11,465 requirement, 14,236 of 16,303 MiB -
LESS VRAM than the 4-slot shape, exactly as section 4.3 measured. Must be off the
card before the nightly's 21:30.

## 5. Publish is DRY RUN

Not ordered otherwise. The wave lane runs wave-publish -DryRun, which still
exercises the auditor. Wave size 3 so a wave actually closes rather than draining.
LIVE ledger, specs and costed - --ledger/--specs/--costed left empty.
