> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `meal-prep/`

Loaded in every ThriftyCrew session: this file has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3).

**HOW THIS FILE IS WRITTEN** (design/PLAN-rules-trim-2026-09-25.md). Each rule holds its OPERATIVE text only; the
dates, measurements and Brad's verbatim rulings behind it live in `docs/rules-history/meal-prep.md` at the anchor its
tag names (`full: mp-NN`), word for word. `ops/audit-rule-format.ps1` refuses a push that breaks the shape.

- **`set-board-cell.ps1` is the RECIPE-board corrector**, one cell at a time on `recipe-board-everyday.json`. It is
  not `known-wrong`, which corrects the main board. [[set-board-cell-is-the-recipe-board-corrector]]
  (channel: judgement; full: mp-01)
- **Recost aftercare:** `sync-recipesdb-cost` BEFORE `propagate`, and `-Slugs` has two different shapes. `propagate`
  has no `-Slugs`: it publishes the whole dirty set, and a hand run REFUSES (exit 2, `PROPAGATE-SCOPE-REFUSED`) unless
  you pass `-SlugsFile <file>` or `-AllowCatalogue`; `-DryRun` prints the scope line first.
  [[recost-needs-sync-recipesdb-cost-and-the-slugs-trap]], [[propagate-has-no-slugs]] (channel: judgement; full: mp-02)
- **A spec's bid is not a pricing input.** An unbid scaler line blacks out the card's live scaler.
  [[spec-bid-is-not-a-pricing-input]] (channel: judgement; full: mp-03)
- **A publish crash loses the journal** unless the journal is written per slug, and `-All` iterates `db/built`
  rather than the specs. [[publish-wave-crash-loses-the-journal]] (channel: judgement; full: mp-04)
- **`retire-recipe` only retires LIVE recipes.** The built-but-unpublished have no gated disposal.
  [[retire-recipe-only-retires-live-recipes]] (channel: judgement; full: mp-05)
- **The paywall split is `html|paywall|html` at `<!--TC-PAYWALL-->`**, before "What This Batch Costs".
  [[recipe-paywall-split]] (channel: judgement; full: mp-06)
- **A spec's mtime is not evidence of a recost** - reanchor rewrites every spec daily.
  [[spec-mtime-is-not-evidence-of-a-recost]] (channel: judgement; full: mp-07)
- **EVERY PRICE IS FETCHED FROM AN OMAHA STORE'S AD OR SITE, BY THE PIPELINE** (Brad's standing ruling). No
  hand-typed, one-off, agent-captured or walmart.com MARKETPLACE price is a pricing input, and `set-board-cell.ps1`
  writing a number nobody fetched is one. **`db/label-prices.json` is MACROS ONLY**; the engine refuses `costed.json`
  while any line carries a `label:` basis (`Get-LabelBasisLines`). An unpriceable ingredient stays NO PRICE BASIS and
  pages: the repair is a store fetch. The `ledger:` basis is the one interim road, a one-time in-store read bounded by
  the quarter. Retire nothing until its replacement is live. **A LIVE recipe that cannot be fully costed is TAKEN
  DOWN** (Brad's ruling): `pipeline/unpriced-takedown.ps1`. (channel: judgement; full: mp-08)
- **A PRICE IN A RECIPE POST RENDERS FROM THE FEED AT VIEW TIME; NO PRICE LITERAL SHIPS IN A BUILT CARD** (Brad's
  instruction). A price is a `data-tc-live-price` span written ONLY by `Format-TcLivePriceSpan`
  (`meal-prep/lib/render-tokens.ps1`) and filled by `fillLivePrices()`; its fallback is stamped on the FILL's basis,
  never `stat.cost_ps`. Checks: `meal-prep/lib/price-literal-gate.ps1` (build and publish), the feed contract and daily
  `-LivePosts` completeness (`meal-prep/pipeline/audit-live-price-contract.ps1`), the live monitor
  (`meal-prep/pipeline/monitor-live-recipe-prices.ps1`). A new live field needs a registry entry, a `fillLivePrices()`
  branch and a feed key. `design/PLAN-live-recipe-prices-2026-09-21.md`. (channel: judgement; full: mp-09)
- **SODIUM IS STORED, NOT SHOWN** (Brad, option A). `sodium_mg` and `sodium_source` are optional food-DB fields; absent
  is UNKNOWN, never 0. `pipeline/food_sodium_backfill.py` is the only writer and `food_provenance.py` gates it. **No
  renderer may read it** until every ingredient of a recipe has a value, and showing it is a separate ruling.
  (channel: judgement; full: mp-10)
- **A DUAL-COLUMN PANEL DECLARES TWO DIFFERENT FOODS, AND NOTHING WE CAPTURE RECORDS WHICH COLUMN A NUMBER CAME
  FROM.** Fixing it before the next label sweep costs one field; after it, a re-read of every affected label. The same
  defect as raw-versus-cooked, where the basis belongs in the name
  ([[food-db-naming-rulings]] ruling 2). (channel: judgement; full: mp-11)

Regime: this holds for files under `meal-prep/`. The grocery board has a different corrector and a
different rebuild cadence.
