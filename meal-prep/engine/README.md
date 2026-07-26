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
pipeline\compute-v2-perserving.ps1         costed + feed -> v2-perserving.json (everyday+cheapest)
pipeline\reanchor-machine-fields.ps1       manifest -> stat.cost_ps + head.costPerServing in specs
pipeline\reanchor-moved-prose.ps1          manifest delta -> prose $ figures in specs
engine\build-cards.ps1 [-Slugs ...]        specs + costed -> db\built (uses pipeline\build-card2.ps1)
engine\publish.ps1 -Slugs ...              db\built -> Ghost (visibility-PRESERVING upsert + live verify)
```

Daily automation (grocery\check-ad-cycles.ps1) runs: recipe-overlay -> cost-recipes ->
compute-v2-perserving -> top5-weekly -> rotate-free-dinners -> export-feed. top5-weekly reads
cheapest_ps from the manifest (legacy fallback only if a slug is missing).

## Adding recipes (any number)

1. Write a v2 spec into `db\recipes\<slug>.json` (writer/mapper agents; see NEXT-RUN-PLAYBOOK.md).
   New ingredients get a row in `db\ingredients.json` (mapping + packages + macros) and canon rules
   in `canon-rules-standing.json`.
2. `engine\cost-recipes.ps1 -Slugs <new...>` then compute + re-anchor + `build-cards -Slugs` +
   `publish -Slugs`. Add rows to recipes-db via the archive run's update-recipes-db pattern.

## Provenance + the golden test

Built from the r100/r300/orig per-run engines (identical cores, drifted data tables) - full history in
`meal-prep\archive\`. `engine\build-ingredients-db.ps1` merged every table (precedence: vetted maps
override; the orig harvest map is fill-only); `engine\golden-test.ps1` proved the port against the
per-run outputs at the same moment: r300 reproduced EXACTLY (0 diffs); r100/orig differed only by two
known correction classes (drained-can fix reaching r100, legacy-id cleanup on orig) - 142 recipes were
re-anchored + republished with the corrected numbers on 2026-07-26.

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
