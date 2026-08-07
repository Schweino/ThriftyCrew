# The Recipe Engine (2026-07-26 consolidation)

One run-agnostic engine + canonical data stores. A "recipe run" is just a batch of slugs flowing
through the same stages, whether it is 1 recipe or 500. Nothing here hardcodes counts or data.

## The database (`meal-prep\db\`)

| Store | Contents | Written by |
|---|---|---|
| `db\recipes\<slug>.json` | THE spec per recipe (ingredients, macros, prose, cost display fields, scaler payload). One per recipe, 513 at consolidation. | writers/re-anchor scripts; new recipes at intake |
| `db\ingredients.json` | one row per canonical ingredient: macros/brand, board mapping (bid/gpu/unit), BUY package (g+label), PANTRY package (g+label), bulk flag | `engine\build-ingredients-db.ps1` (migration) + hand edits going forward |
| `db\label-prices.json` | agent-captured package prices for board-untracked items | migration; append new captures |
| `db\densities.json`, `db\no-board-price-ok.json` | drained-can yields; allowlisted no-board bids | hand-maintained |
| `db\costed.json` | DERIVED: whole-catalog cost lines (pkg_g etc). Regenerated daily. | `engine\cost-recipes.ps1` |
| `db\built\<slug>.{body,head}.html` | DERIVED: the publishable v2 cards | `engine\build-cards.ps1` |
| `pipeline\v2-perserving.json` | DERIVED: everyday_ps + cheapest_ps per recipe (site-surface source) | `pipeline\compute-v2-perserving.ps1` |

Also canonical (already single-copy, unchanged): `recipes-db.json` (catalog index + visibility),
`food-macros-db.json` (label macros - mirrored into ingredients.json), `ingredient-map.json`
(weekly-board mapping used by top5 sale badges), `canon-rules-standing.json` (normalization rules).

## The stages

```
engine\cost-recipes.ps1 [-Slugs ...]       specs + ingredients db + boards -> db\costed.json
                                           (-DbRoot/-GroceryOut/-OutFile/-FlagsFile exist only so the
                                            golden test can run it over a frozen fixture; defaults are
                                            the live paths, so the daily call is unchanged)
pipeline\compute-v2-perserving.ps1         costed + feed -> v2-perserving.json (everyday+cheapest)
pipeline\reanchor-machine-fields.ps1       manifest -> stat.cost_ps + head.costPerServing in specs
pipeline\reanchor-moved-prose.ps1          manifest delta -> prose $ figures in specs
engine\build-cards.ps1 [-Slugs ...]        specs + costed -> db\built (uses pipeline\build-card2.ps1)
engine\publish.ps1 -Slugs ...              db\built -> Ghost (visibility-PRESERVING upsert + live verify)
```

INGREDIENT-LABEL REPAIRS are a separate lane (they change what a line SAYS, never what it costs), and
they all have the same tail because `buy` is copied into three more places inside the spec
(`ingredients_display`, `cost_lines`, and `head.recipeIngredient`) and a fourth in `recipes-db.json`:

```
pipeline\repair-cook-measures.ps1 -Apply   a label naming a PACKAGE the recipe does not use ("1 bottle")
pipeline\repair-unitless-buy.ps1  -Apply   a COUNT with no noun ("18.4" -> "18.4 potatoes")
pipeline\repair-range-buy.ps1     -Apply   a RANGE where the quantity belongs ("2-3 cloves" -> "8 cloves")
pipeline\repair-plural-unit.ps1   -Apply   a quantity of one against a plural unit ("1 cups" -> "1 cup")
pipeline\repair-basis-relabel.ps1 -Apply -PreImage out\basis-preimage-<date>.json
                                           labels derived against a cup/tbsp basis db\densities.json has
                                           since corrected. REQUIRES a pre-image captured BEFORE the
                                           densities edit (slug/canon/grams/stored/derived_old): the gate
                                           is "stored == what the generator wrote under the OLD basis",
                                           which is the only thing separating a machine label from a
                                           writer's ("7/8 cup grated") - and it cannot be reconstructed
                                           after the fact.
  then, for the slugs any of them touched:
pipeline\repair-head-ingredients.ps1 -Apply  re-derive the JSON-LD list from the repaired display lines
pipeline\sync-recipesdb-buy.ps1   -Apply   carry the label into recipes-db.json (planner-data reads THAT)
meal-prep\gen-planner-data.ps1             recipes-db -> planner-data.js (Meal Plan Builder grocery list)
engine\build-cards.ps1 -Slugs ...          the scaler payload embeds buy, so the cards must be rebuilt
engine\publish.ps1 -Slugs ...
```

`repair-head-ingredients` is not optional in that tail. `head.recipeIngredient` is DERIVED from
`ingredients_display` (2026-08-04, SPEC-SCHEMA invariant 9), so a label repair that stops before it
leaves the structured data quoting amounts the page no longer shows - the same drift the derivation was
built to end, just one revision later. It happened immediately: the 2026-08-04 label repair landed while
the derivation was in flight, and 423 of 513 specs needed re-deriving on top of it.
`audit-db-agreement.ps1` fails on HEAD-INGREDIENT drift, so a skipped step is caught, not shipped.

`build-cards`/`publish` take `[string[]] -Slugs`. Call them **in-process** (`& .\engine\build-cards.ps1
-Slugs $slugs`), never through `powershell -File`: that path marshals arguments as command-line strings,
so a 10-slug array binds as one slug and the run reports a cheerful "built 1/1".

The splice every one of these repairs shares is `pipeline\buy-label-lib.ps1` - one implementation, because
two copies of a four-surface text edit means the day someone fixes a splice bug in one, the other keeps
shipping it. Label semantics (`Test-RangeBuy`, `Resolve-RangeBuy`, `Get-CookMeasure`) live in
`pipeline\cook-measure-lib.ps1` so `sync-recipesdb-buy` can read the same predicates without
dot-sourcing a script that runs a catalog pass at the bottom.

**The label a card prints lives in exactly one function: `Get-FriendlyAmt` in
`pipeline\friendly-amt-lib.ps1`.** Until 2026-08-07 it also lived inline in `build-v2-spec.ps1` and again
in `build-run-specs.ps1`, and the two builders called their own copies. So the library's singular-cup fix
existed for days while every spec the builders wrote still shipped `Salsa: 1 cups` - 96 rows across 78
specs by the time anyone compared them. Both builders now dot-source the library. Do not re-inline it,
and do not add a second basis constant: the Rice cup used to be the literal `185.0` in four files at
once, which is how `db\densities.json` (185) and `food-macros-db.json` (200 g/cup) got to disagree about
a cup of rice without anything in the estate being able to notice.

A repair that changes a label must also write a **carry manifest** to `out\<class>-carry.json`
(`{slug, item, old, new}`, `item` = the CANONICAL name, because that is what `recipes-db.json` stores)
and register it in `sync-recipesdb-buy.ps1`. That script carries only classes a manifest proves a repair
actually performed - so a repair with no manifest silently stops at the specs and the cards, and
`planner-data.js` goes on printing the old text with nothing to say so.

Skipping the sync step leaves the Meal Plan Builder showing the old text with nothing to say so:
audit-db-agreement compares slug and protein, not labels. Run `sync-recipesdb-buy.ps1` (read-only) any
time to see the standing drift.

Daily automation (grocery\check-ad-cycles.ps1) runs: recipe-overlay -> cost-recipes ->
compute-v2-perserving -> top5-weekly -> rotate-free-dinners -> export-feed. top5-weekly reads
cheapest_ps from the manifest (legacy fallback only if a slug is missing).

## Adding recipes (any number)

1. Write a v2 spec into `db\recipes\<slug>.json` (writer/mapper agents; see NEXT-RUN-PLAYBOOK.md).
   New ingredients get a row in `db\ingredients.json` (mapping + packages + macros) and canon rules
   in `canon-rules-standing.json`.
2. `engine\cost-recipes.ps1 -Slugs <new...>` then compute + re-anchor + `build-cards -Slugs` +
   `publish -Slugs`. Add rows to recipes-db via the archive run's update-recipes-db pattern.

## The golden test

`engine\golden-test.ps1` is the engine's regression suite. Exit 0 pass, 2 fail. It runs in the daily
`grocery\check-ad-cycles.ps1` sequence right after `cost-recipes`, and alerts on failure.

```
engine\golden-test.ps1                 both gating lanes (this is what the daily run invokes)
engine\golden-test.ps1 -Structural     lane 1 only
engine\golden-test.ps1 -Frozen         lane 2 only
engine\golden-test.ps1 -Rebaseline     accept today's engine output over the frozen inputs
engine\golden-test.ps1 -Provenance -Force   the 2026-07-26 port diff (informational, cannot pass)
```

| lane | what it asserts | what makes it durable |
|---|---|---|
| **STRUCTURAL** | the live `db\costed.json` against its own specs and the ingredient db: no missing or orphan rows, costed grams equal spec grams, `buy_n`/`starter_n` equal the engine's ceil, the pantry fold and every total add up, package sizes are ones the db actually defines | reads **no price board**, so no price move can make it lie |
| **FROZEN** | the engine over pinned inputs in `regression-inputs\golden\inputs\` must reproduce `expected\costed.json` byte for byte, plus the `-Slugs` splice in both directions | the **inputs are frozen too**, so the output can only move when the *engine* moves |

Both ship must-fire fixtures (`regression-inputs\golden\structural-fixtures\`, and the FROZEN lane
perturbs a copied input and demands the output change), because a check that reports nothing is
indistinguishable from a check that is broken.

**When the engine changes on purpose:** run the test, read the per-slug diff it prints, and if the change
is intended accept it with `-Rebaseline`. That rewrites *only* `expected\`, never the inputs, and records
the engine hash + timestamp in `MANIFEST.json`. There is no refresh schedule to miss - the baseline moves
when the engine moves. `seed-golden-fixture.ps1` built the input fixture once; re-running it is almost
never right (regenerating a fixture from live data is how a fixture stops testing anything).

WHY IT LOOKS LIKE THIS (2026-08-06). v1 diffed the daily-regenerated `db\costed.json` against outputs
frozen on 2026-07-26. That is true for one day. By 2026-08-04 it emitted 10,339 diffs - nine days of
grocery prices - and honestly disabled itself rather than report a false pass. The refusal was right and
the consequence was still bad: THE engine behind every price on the site went eleven days with no
regression test, and was modified on 2026-08-06 with nothing but a hand-rolled one-off diff to check it.
A fresher output baseline just re-runs that clock. Freezing the inputs stops it.

## Provenance of the port

Built from the r100/r300/orig per-run engines (identical cores, drifted data tables) - full history in
`meal-prep\archive\`. `engine\build-ingredients-db.ps1` merged every table (precedence: vetted maps
override; the orig harvest map is fill-only); the golden test's PROVENANCE lane proved the port against
the per-run outputs at the same moment: r300 reproduced EXACTLY (0 diffs); r100/orig differed only by two
known correction classes (drained-can fix reaching r100, legacy-id cleanup on orig) - 142 recipes were
re-anchored + republished with the corrected numbers on 2026-07-26. That lane is kept so the history is
re-readable, but it compares today's output to a 2026-07-26 baseline and so can never pass again; it is
informational and does not gate.

## Traps (learned the hard way)

- PowerShell variable names are CASE-INSENSITIVE: `$ppg` (price/gram) vs `$ppG` (package grams) was a
  silent 250,000x cost bug during the port. Never name a variable a case-variant of another in scope.
- Never re-serialize spec JSON whole (prose carries \uXXXX escapes); use key-scoped text edits
  (see reanchor-*.ps1) or Save-JsonArray from lib\json-db-io.ps1.
- publish.ps1 PRESERVES visibility on update (the free-dinner rotation owns visibility, not content
  publishing). Never hardcode visibility='paid' on an upsert.
- The print module + other injections scrape card DOM; any card-markup change needs a print re-test.
- specs\prose\ mirrors in archive\ are STALE relics of the old spec-guards merge flow. db\recipes specs
  are the ONLY prose home now; nothing merges over them.
