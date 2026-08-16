# HANDOVER: the vocabulary work is in, now prove it with a live 3-recipe run

Written 2026-08-16 at the end of the session that implemented V4 + V8 and landed the nineteen captured
ingredients. Read this BEFORE starting the Recipe Hunter.

## 1. What you are testing, and why a small run is the right test

`design\PLAN-ingredient-vocabulary-2026-08-16.md` is now **fully implemented** - V1-V8. Six items existed
before 2026-08-16; **V4 and V8 were built that day and have never executed.** They are prompt changes to
three agents, so the only way to know they took is to run the lanes that use them.

**The 24 in-flight intakes in `meal-prep\runs\hunt-2026-08-15-lowcarb-100` cannot test V4.** They are
already past mapping; their names and ids are fixed. Rebuilding them exercises V3 and V7 only. A FRESH hunt
that has to map ingredients it has not seen is the only thing that reaches the mapper and the registrar.

**Pick recipes that force new ingredients.** A run that maps cleanly onto the existing ~300-row vocabulary
proves nothing. Something with an unusual cheese, a spirit, or a fresh herb makes the mapper actually choose
between resolve / rename / alias / registrar.

## 2. Brad's decisions for this run (2026-08-16)

- **3 recipes, FULL end to end, INCLUDING PUBLISH.** Brad was told the board behind it has not been through
  a normal daily cycle and reaffirmed. Do not stop at QA.
- Everything was merged to `main` including `public\smp-feed.json`, which Cloudflare serves directly, so the
  refreshed board is already live. Brad was told and reaffirmed.

## 3. THE SUCCESS CRITERION - judge V4 by this, not by "it finished"

> The mapper should propose **fewer new ids than it has unrecognised ingredients**, and every id it does
> propose must carry four-namespace evidence.

If the mapper free-texts a canon name, or proposes an id without showing it checked `commodities.json`,
`recipe-commodities.json`, `out\recipe-board-everyday.json` AND the live `out\smp-feed.json`, then **V4 did
not take and the prompt needs sharpening, not the code.** Report that as the run's finding.

Why this is the bar: on 2026-08-16 nineteen "new" ingredients went to a full seven-store pricing run and
TEN were already on the board - four as live priced commodities, six as duplicates under another spelling
(`80-20-ground-beef` vs `ground-beef-8020`, `yellow-mustard` vs `mustard` whose LABEL is "Yellow Mustard",
`egg-yolk` vs `eggs`, `pork-smoked-sausage` vs `kielbasa`, `sun-dried-tomatoes-oil-packed` vs
`sun-dried-tomatoes`, `dry-white-wine` vs `white-wine`). In five of the six the freshly captured cheapest
was the SAME store at the SAME price as the existing crown. None of those pairs can be caught mechanically.
V4 exists to stop that pricing run from ever being dispatched.

## 4. Orchestration - do not build it from the skill file alone

`SKILL.md` for recipe-hunter is a reminder card. **Build the orchestration from
`design\PLAN-recipe-hunter-v2-2026-08-15.md` section 2.4** (lanes stream, no barriers; hunting never waits
on pricing). Skipping this is how a previous session ran the pricing lane per-recipe instead of per-batch.

## 5. Things that will happen, so you are not surprised

- **A 3-recipe wave trips the short-wave audit warning** (commit `aa36cb34`): a full batch audit costs the
  same for 3 recipes as for 15. Expected. Brad has accepted the economics for this run.
- **`red-wine` is wired but unpriced** by choice of scope. It has the correct unit, band, `relax_global` and
  excludes, so it will produce cells the moment any capture runs with its search term. Not a defect.
- **Anything alcoholic needs `relax_global`.** `compare-deals.ps1`'s `$GLOBAL_EXCLUDE` contains `\bwine\b`,
  `liquor`, `vodka`, `whiskey`, `tequila`, `bourbon`, `\bbeer\b`, `\bale\b` and applies to EVERY commodity.
  A new alcohol id without `relax_global` silently prices nothing forever. `brandy` escaped it only because
  "brandy" is not in the list.
- **`audit-prompt-backup.ps1 -Sync` is safe to run again now** that this is merged. It hardcodes `$PROJ` to
  the main tree, which is why the 2026-08-16 session mirrored `ops\prompt-backup\agents\` by hand instead.

## 6. OPEN QUESTION worth someone's attention

`five-spice-powder` was crowned on the LIVE board by "Spice Supreme oriental five spices, 3.5-oz. plastic
shaker" recorded at size **42.007 oz** (a 12-pack total against a single-shaker price) - $0.279/oz against a
real ~$4.75/oz, understating the commodity ~12x. That product was **already ruled in `known-wrong.json`**
and was publishing anyway. `audit-known-wrong` should have refused the cell and did not. The 2026-08-16
rebuild dropped the row and the stale link was withdrawn, so the symptom is gone - **but the gate that
failed to fire has not been investigated.** That is a guard hole, not a data typo.

## 7. Where things are

- Plan + execution record: `design\PLAN-ingredient-vocabulary-2026-08-16.md` (section **0d** is the
  2026-08-16 execution write-up; V4's spec carries an AMENDED block explaining why name resolution alone is
  insufficient)
- Agent prompts changed: `.claude\agents\recipe-ingredient-mapper.md` (rule 1b),
  `.claude\agents\commodity-registrar.md` (fourth namespace + the six-duplicate table),
  `.claude\agents\recipe-batch-auditor.md` (check 2b)
- New gated tool: `grocery\add-recipe-board-rows.ps1` (the recipe board had no writer that could ADD a row)
- Commits: `154033e4`, `e2bd68fb`, `90d6fe05` on `claude/intelligent-diffie-c6ea49`, merged to `main`
