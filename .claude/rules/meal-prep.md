---
description: Traps when working on recipes, the food DB, costing, or the Recipe Hunter pipeline - one line each; the account is meal-prep-depth.md.
---

# Meal-prep rules, one line each

LEAD FILE: loads in every ThriftyCrew session, because it has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3 option B, D2). The account behind each line, with
its rulings, dates and measurements, is `.claude/rules/meal-prep-depth.md`, which loads only after a session reads a
file under `meal-prep/`. A `[[name]]` is `~/.claude/projects/C--Codex-ThriftyCrew/memory/<name>.md`: read it, never
write it.

- `set-board-cell.ps1` is the RECIPE-board corrector, one cell at a time on `recipe-board-everyday.json`; it is not `known-wrong`, which corrects the main board. [[set-board-cell-is-the-recipe-board-corrector]]
- Recost aftercare runs `sync-recipesdb-cost` BEFORE `propagate`, `-Slugs` has two different shapes, `propagate` itself has no `-Slugs`, and a hand run refuses (exit 2, `PROPAGATE-SCOPE-REFUSED`) unless you pass `-SlugsFile` or `-AllowCatalogue`, so `-DryRun` first. [[propagate-has-no-slugs]]
- A spec's bid is not a pricing input, and an unbid scaler line blacks out the card's live scaler. [[spec-bid-is-not-a-pricing-input]]
- A publish crash loses the journal unless it is written per slug, and `-All` iterates `db/built`, not the specs. [[publish-wave-crash-loses-the-journal]]
- `retire-recipe` only retires LIVE recipes; the built-but-unpublished have no gated disposal. [[retire-recipe-only-retires-live-recipes]]
- The paywall split is `html|paywall|html` at `<!--TC-PAYWALL-->`, before "What This Batch Costs". [[recipe-paywall-split]]
- A spec's mtime is not evidence of a recost: reanchor rewrites every spec daily. [[spec-mtime-is-not-evidence-of-a-recost]]
- Every price is fetched from an Omaha store by the pipeline, never typed: `db/label-prices.json` is MACROS ONLY, the engine refuses to write `costed.json` while a line carries a `label:` basis, and an unpriceable ingredient stays NO PRICE BASIS until a store fetch, with nothing retired before its replacement is live.
- A price in a recipe post renders from the feed at view time and no price literal ships in a built card: only `Format-TcLivePriceSpan` (`meal-prep/lib/render-tokens.ps1`) writes one, the fallback is on the FILL's basis (never `stat.cost_ps`), and a new live field needs a registry entry, a `fillLivePrices()` branch and a feed key; `design/PLAN-live-recipe-prices-2026-09-21.md`.
- Sodium is STORED, NOT SHOWN: `sodium_mg` and `sodium_source` are optional, absent means UNKNOWN (never 0), `pipeline/food_sodium_backfill.py` is the only writer, and no renderer may read it.
- A dual-column nutrition panel declares two foods and no capture field records which column a number came from: add that field before the next label sweep, not after.

Regime: this holds for files under `meal-prep/`. The grocery board has a different corrector and a different rebuild
cadence.
