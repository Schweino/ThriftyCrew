---
name: recipe-hunter
description: Hunt new dinner recipes to Brad's conditions and carry each one all the way to LIVE on the site, running the stages concurrently so hunting never waits on pricing. Per-recipe stages stream (hunt, extract, map, price, spec+write, source-QA); QA-passed recipes accumulate into waves that publish automatically once the batch auditor returns GO. Invoke when Brad wants new recipes; he supplies the conditions and a stop condition.
---

# Recipe Hunter

Brad gives conditions ("high-protein, under $2.50 a serving, slow cooker, 20 of them") and a stop
condition. You hunt recipes, prove every ingredient is buyable in Omaha, write them in his voice, and
publish them. **Publishing is automatic.** Brad is not a gate any more; the batch auditor and the
post-publish reviewer are.

## The two rules that decide everything

**Rule B - one store is enough.** An ingredient is fine if ONE of the seven Omaha stores carries it. A
recipe is rejected only when an ingredient is carried by NONE of them. Measured on the 542 live recipes:
requiring all seven to carry every ingredient leaves **1 survivor (0%)**; requiring at least one leaves
**542 (100%)**. `achiote-paste` is stocked at exactly 1 of 7 stores and is on the live board today.

**Unchecked is never not-carried.** A bot wall, timeout, or store you did not reach leaves an ingredient
PENDING and its recipe PARKED. It does not reject anything. Aldi and the Chrome extension both threw bot
walls on 2026-08-14; treating "could not look" as "not carried" throws away good recipes.

## Run it concurrently. That is the point.

Do NOT run this as sequential batches. Hunt a round, push it into the pipeline, and start hunting the next
round **without waiting**. A candidate can be in source-QA while another is still being extracted. Use the
Workflow tool's `pipeline()` so there is no barrier between per-recipe stages, and loop the producer until
Brad's stop condition is met.

```
HUNT lane (1 at a time)     recipe-sourcer            loop rounds until the stop condition
SELECT (1 per round)        recipe-dedup-selector     vs catalog digest AND accepted-slugs.json
                                    |
pipeline(), no barriers:            v
  extract                   recipe-hunter-extractor   page -> ingredients + measures + steps
  map                       recipe-ingredient-mapper  ingredient -> commodity id, food-DB rows
  price   [SINGLETON LANE]  recipe-hunter-pricer      only ABSENT terms; 7 stores per invocation
  spec+write                recipe-writer             intake JSON -> build-v2-spec -> db\recipes
  source-QA                 recipe-source-qa          the card vs the page it came from
                                    |
WAVE lane (serial)                  v
  wave close -> recipe-batch-auditor -> GO -> wave-publish.ps1 -> post-publish-reviewer -> ledger close
                                              (gates, publish, then serveability
                                               verify; a slug that cannot price
                                               is drafted and moved to `held`)
```

**The price lane is a singleton, deliberately.** Exactly ONE pricer alive at a time, each invocation taking
up to ~10 absent terms and opening its proven-safe shape: two server stores plus one tab per browser store,
one search per term. N concurrent pricers means N tabs per store domain, which is the sweep shape that
walled Walmart at 55 of 526 terms and Sam's at 205. Throughput comes from batching terms inside one pricer,
never from more pricers. If that is ever too slow, it is a measured decision for Brad, not a default.

## State, waves and resuming

`pipeline\hunt-run.ps1` owns every recipe's position. It is the only thing that writes run state.

```
hunt-run.ps1 -Init -RunDir <p> -Conditions '...' -Stop '...' [-WaveSize 10]
hunt-run.ps1 -Advance -RunDir <p> -Slug <s> -To <state> -By <stage> [-Detail '...']
hunt-run.ps1 -Advance -RunDir <p> -Slug <s> -To pricing -By mapper -Terms 'saffron,achiote paste' -OptionalTerms 'cilantro'
hunt-run.ps1 -Derive -RunDir <p>          after EVERY pricer invocation
hunt-run.ps1 -WaveClose -RunDir <p> [-Drain]
hunt-run.ps1 -Status -RunDir <p>          the resume entry point
hunt-run.ps1 -Advance -RunDir <p> -Slug <s> -To held -By <who> -Detail 'why it came down'
```

**`held` is a live page that has been taken down** - a serveability rollback, or any deliberate takedown.
Legal both ways between `published` and `held`; `held -> verified` is refused. It exists because on
2026-08-15 two recipes were set back to draft by hand while their state files still read `published`, and
the run record asserted two live pages that were not live.

**Pending counts are derived, never stored.** A recipe is `priced` when zero blocking ingredients are
PENDING and zero are NOT-CARRIED, recomputed from `ingredient-queue.ps1`'s own verdicts every time it is
read. A stored counter incremented at enqueue can race - every task can finish before the count lands, and
the recipe ships at zero having been checked zero times. Run `-Derive` after each pricer invocation; it is
the only thing that moves a recipe out of `pricing` or `parked`.

**A wave never waits on a parked recipe.** Waves close at the wave size, or short with `-Drain` once the
pipeline has emptied. Parked recipes carry to the next wave or to the final report.

**Resuming:** `-Status` prints the three buckets and the parked worklist. Every stage skips work whose
output file already exists, so a killed run re-enters and continues.

## Before the first round

1. **Refresh the dedup digest.** `powershell -File C:\Codex\income\meal-prep\pipeline\make-catalog-digest.ps1`
   The digest is what both the sourcer and the dedup-selector judge "already have it" against. A stale
   digest means re-finding recipes you already published. `-Init` records its date; check it.
2. **Confirm the board is current.** `grocery\out\comparison-<today>.json` should exist. Pricing reads it.
3. **Self-tests green:** `hunt-run.ps1 -SelfTest`, `wave-publish.ps1 -SelfTest`, `ingredient-queue.ps1 -SelfTest`,
   `feed-covers-published.ps1 -SelfTest`.
4. **Ask Brad for the stop condition** if he did not give one: a target count, a time box, or a protein mix.

## Stage notes that are easy to get wrong

**Hunting.** The sourcer already dedupes against the digest, and the dedup-selector adjudicates near
duplicates afterwards. Both, not either. Because the run streams, the candidate pool never exists as a
whole: give every round the digest AND `accepted-slugs.json` (everything selected so far this run), or
round 4 re-finds what round 1 already took. "Beef chili" and "beef chili mac" are different dishes;
"chicken tikka masala" twice is not.

**Extraction is transcription.** The extractor must not convert units, estimate a missing measurement, or
reconstruct a recipe it could not read. `state: "unreadable"` is a complete answer. A plausible invented
recipe is the worst outcome in this flow because nothing downstream can tell.

**Pricing asks the cheap question first.** `price-ingredient.ps1 <term>` answers from the board and today's
captures in milliseconds and reads BOTH boards - the weekly `comparison-*.json` AND `recipe-board.json`.
Reading only the weekly one makes `pork-loin` and `boneless-skinless-chicken-thigh` look like zero coverage
and falsely rejects recipes. Only genuinely ABSENT terms go to the pricer.

**A candidate row is not a price.** `probe-ingredient.ps1` deliberately refuses to rule on carriage. Probing
"saffron" at Baker's ranks "Saffron Road Drunken Noodles" ABOVE the real jar of saffron, because the brand
name contains the word. The pricer adjudicates; the script only gathers.

**No stage mints a commodity id on its own.** When mapping or pricing concludes an ingredient needs a NEW
commodity, that proposal goes through the `commodity-registrar` agent first. The id namespace spans three
files, and the last duplicate (bread-crumbs vs breadcrumbs) had two recipes paying 2.9x the site's own
price until Brad caught it by eye. The run itself never edits commodity files: a registrar-approved new id
is a flagged follow-up for the capture pipeline, and the ingredient maps `item_id: null` meanwhile, which
is safe pantry-static pricing.

**Spec + write is the v2 intake path.** The writer produces ONE intake JSON per recipe and
`pipeline\build-v2-spec.ps1 -InFile <intake> -RunCost` assembles the spec into `db\recipes\<slug>.json`,
running its own write-time guards. `db\recipes` is the only spec home; there is no run-local specs folder
any more. **Never run `spec-guards.ps1` full mode against these specs** - it merges prose from
`specs\prose\` files the engine no longer produces and re-serialises the whole spec, which is the
documented \uXXXX prose-corruption trap. Its invariants live on in build-v2-spec's guards,
`audit-spec-contradictions.ps1`, `audit-store-integrity.ps1` and `engine\audit-db-agreement.ps1`, all of
which `wave-publish.ps1` runs.

**Source-QA anchors on the extraction.** `recipe-source-qa` compares the built recipe to its transcription
always, and to the live page when the domain is fetchable. A blocked domain is NEVER a finding against the
recipe. A failed recipe gets exactly ONE owner-routed repair cycle (writer / extractor / mapper) and is
re-QA'd; a second failure is `rejected-qa`. Unbounded repair loops hide systemic defects.

**The write-up must fit the existing framework**, not invent one. The writer knows the voice rails (Brad's
Morgan-Freeman-meets-Dave-Ramsey tone, no em dashes) and assembles cards through the existing generators.

## The wave gate and publishing

1. `hunt-run.ps1 -WaveClose` writes `waves\wave-<k>.json` and opens batch-ledger batch `<run-id>-w<k>`,
   stamping the four streamed stages (select, map, write, build-specs).
2. Dispatch `recipe-batch-auditor` on the wave. Its report goes to `waves\wave-<k>.audit.md` and **its
   first line must be exactly `GO` or `NO-GO`**. Then stamp it:
   `batch-ledger.ps1 -Stamp -Batch <run-id>-w<k> -Stage audit -Detail '<n>/<n> GO'`
3. `wave-publish.ps1 -RunDir <p> -Wave <k>` - the only sanctioned publish path. It refuses unless the audit
   reads GO, **the audit is NEWER than every spec it certifies**, the ledger carries the audit stamp, every
   slug is sitting in that wave, every spec exists, the three v2 audits are clean, no slug already exists
   live that this pipeline did not publish, and **the cards' price source is an endpoint this estate
   actually produces and is serving**. Then it runs prose tokens, recipes-db, and `propagate-recipes.ps1`
   (db-agreement hard gate -> planner -> cards -> hash-gated `engine\publish.ps1`), commits and pushes,
   rebuilds the feed, verifies every published slug against it, and pushes the feed. Use `-DryRun` to walk
   every gate and publish nothing.
4. Dispatch `post-publish-reviewer` scoped to the wave's slugs, stamp `post-publish-review`, then
   `batch-ledger.ps1 -Close`. **Give the reviewer BOTH numbers** - the wave slugs AND the collateral count
   `wave-publish` prints ("<n> wave slugs + <m> collateral carried by propagate"). propagate carries every
   dirty spec by design, so a 2-recipe wave can republish 359 recipes; a review scoped to the wave alone
   samples a fraction of what actually shipped.

**A NO-GO blocks publish, full stop.** Blocking recipes leave the wave (back to repair, or `rejected-audit`
after one failed repair). The auditor is never overruled and no gate is ever weakened to pass a wave.

**THE SERVEABILITY GATE, and why a refusal there is never something to work around.** Every other gate
compares data to other data. This one asks whether the published page will WORK for a reader, which is the
question nothing asked on 2026-08-15 when two audited, complete, GO recipes went live fetching prices from
a platform deleted the day before and rendered an empty cost section.
- **P8, before anything ships:** it reads the `SMPFEED=` assignment out of `pipeline\tpl2-scaler-prefix.html`
  and refuses if that URL is not one `grocery\export-feed.ps1` produces, refuses if `feed-covers-published.ps1`
  is validating a different URL from the one the cards read, then probes the feed for a real 200.
- **E6, after publish:** rebuilds the feed (`top5-weekly.ps1 -NoPublish` FIRST, because export-feed builds
  its recipes map from `grocery\out\recipe-costs.json`, not from recipes-db) and re-runs
  `feed-covers-published.ps1` scoped to the wave. **A slug that cannot price is drafted in Ghost and moved
  to `held` automatically**, per slug. The recipes are not lost; they are drafts awaiting a fix.
If P8 refuses because the cards point somewhere unproducible, the Hunter genuinely cannot ship a working
recipe. Fix the template. Do not add the URL to the allowlist, and say so in your report.

**A rolled-back recipe is `held`, not published and not rejected.** `held` means a page that WAS live and
is down now. It can only go back to `published` (by actually re-publishing), never straight to `verified` -
verifying a drafted page is exactly the lie the state exists to prevent. `-Status` prints HELD on its own
line; treat anything there as an open item, because it is a recipe readers cannot see.

**SCOPE THE RE-AUDIT, and mean it.** The audit is the most expensive stage in the flow, so re-running it
whole on every repair is the single easiest way to waste a run:
- The blocker was RECIPE-LOCAL (prose, a card, one spec's own field): re-audit ONLY the repaired slugs.
  Nothing else moved, so a whole-wave pass re-checks what nothing touched.
- The blocker was SHARED DATA (a map entry, a DB row, the cost basis, a board cell): re-audit the WHOLE
  wave, because the fix moved every recipe's numbers.
Measured on the 2026-08-15 shakedown: three audit rounds cost 485k tokens, 31% of the entire run, and the
third round was a whole-wave re-verification ordered after a single prose field changed in a single spec.
Round two was correctly whole-wave (the cost basis had moved for both recipes). Round three should have
been one slug.

**Declare the scope in the dispatch, always.** No code gate can decide it - that judgment is yours - so the
requirement is that the choice is stated rather than defaulted:
- Every re-audit dispatch MUST carry `scope: <slug,slug>` or `scope: whole-wave`, plus one sentence naming
  which kind of blocker was fixed.
- The auditor echoes that scope on the SECOND line of its report, under the GO/NO-GO.
An unscoped whole-wave re-run then becomes a visible choice instead of the path of least resistance.

**Re-audit AFTER the repair, never before.** `wave-publish` refuses when the audit file is older than any
spec in the wave, because a GO that predates a spec edit certifies bytes that no longer exist. So the order
is always: repair the spec, then re-audit, then publish. If you see P1b refuse, you re-audited too early or
edited a spec after the GO.

**Visibility belongs to the rotation, not to this flow.** `engine\publish.ps1` preserves it on update; a
hardcoded 'paid' upsert would re-paywall every hand-freed free dinner. Never publish a recipe card any
other way.

## What you hand back

Report the three buckets separately, never rounding PENDING up into accepted or down into rejected:

- **PUBLISHED** - live URLs, per wave, with the auditor and reviewer verdicts.
- **PARKED** - the recipe, the ingredient, and exactly which stores are still unchecked and why. This is
  the resume worklist, not a failure list.
- **HELD** - anything rolled back by the serveability gate: the slug, what the feed could not price, and
  what has to be fixed before it goes back up. Never report a held recipe as published.
- **REJECTED** - which ingredient failed and which stores were checked, or the dupe/unreadable/QA reason.

Plus: registrar rulings and their follow-ups, and the ledger status of every wave.

## Do not

- Do not publish any way except `wave-publish.ps1` after a GO. Never call `publish-recipe.ps1` or
  `engine\publish.ps1` directly from this flow.
- Do not run `spec-guards.ps1` full mode against `db\recipes` specs.
- Do not run more than one pricer at a time.
- Do not write board cells. If an ingredient deserves a permanent cell, say so; the capture pipeline adds it.
- Do not weaken a guard to get a recipe through. A recipe that needs a gate turned off is a rejected recipe.
- Do not add a URL to the P8 allowlist to unblock a publish. The allowlist is "endpoints this estate
  produces"; editing it to match a broken template is how the dead-feed failure ships again.
- Do not report a `held` recipe as published, and do not advance one to `verified` without republishing it.
- Do not `git add -A`. `wave-publish.ps1` stages an explicit path list for a reason.
