---
description: Traps when working on recipes, the food DB, costing, or the Recipe Hunter pipeline.
globs: "meal-prep/**"
alwaysApply: false
---

# Working in `meal-prep/`

Loaded only when you touch a file under `meal-prep/`. Pointers, not copies - the full account lives in
the named memory or file.

- **`set-board-cell.ps1` is the RECIPE-board corrector**, one cell at a time on
  `recipe-board-everyday.json`. It is not `known-wrong`, which corrects the main board.
  [[set-board-cell-is-the-recipe-board-corrector]]
- **Recost aftercare:** `sync-recipesdb-cost` BEFORE `propagate`, and `-Slugs` has two different shapes.
  `propagate` itself has no `-Slugs` at all - it publishes the whole dirty set, and dirty is
  spec-hash-versus-stamps. [[recost-needs-sync-recipesdb-cost-and-the-slugs-trap]], [[propagate-has-no-slugs]]
- **A spec's bid is not a pricing input.** An unbid scaler line blacks out the card's live scaler.
  [[spec-bid-is-not-a-pricing-input]]
- **A publish crash loses the journal** unless the journal is written per slug, and `-All` iterates
  `db/built` rather than the specs. [[publish-wave-crash-loses-the-journal]]
- **`retire-recipe` only retires LIVE recipes.** The built-but-unpublished have no gated disposal.
  [[retire-recipe-only-retires-live-recipes]]
- **The paywall split is `html|paywall|html` at `<!--TC-PAYWALL-->`**, before "What This Batch Costs".
  [[recipe-paywall-split]]
- **A spec's mtime is not evidence of a recost** - reanchor rewrites every spec daily.
  [[spec-mtime-is-not-evidence-of-a-recost]]

Regime: this holds for files under `meal-prep/`. The grocery board has a different corrector and a
different rebuild cadence.
