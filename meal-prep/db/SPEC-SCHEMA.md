# v2 recipe spec schema (`db/recipes/<slug>.json`)

The canonical store for one recipe. 513 of these exist; this documents the format that until now lived
only by example. A recipe IMPORT must emit specs in this shape (engine README step 1). The consumers are
`engine/cost-recipes.ps1` (pricing), `pipeline/compute-v2-perserving.ps1` (per-serving manifest),
`pipeline/build-card2.ps1` (the published card), `engine/audit-db-agreement.ps1` (drift guard) and
`recipes-db.json` (the index, kept in sync by `update-recipes-db.ps1`).

**Never re-serialize a whole spec** (`ConvertFrom-Json | ConvertTo-Json`): the prose fields carry
`\uXXXX` escapes that a round-trip rewrites, and PS5.1 serializers have corrupted this file class before.
Edit prose key-scoped (see `engine/apply-prose-field.ps1`); patch structured fields with the brace-match
helpers in `lib/json-db-io.ps1`.

## Identity / classification
| field | type | notes |
|---|---|---|
| `slug` | string | kebab-case, unique across the catalog. The join key everywhere. |
| `name` | string | display title. |
| `protein` | string | canonical class: `chicken` \| `beef` \| `pork` \| `turkey` (or `vegetarian`/etc). r100-era specs may store `ground beef`; the guard strips a leading `ground ` before comparing to the index. |
| `cuisine` | string | freeform, drives the hub filter + digest cuisine-spread. |
| `visibility` | string | `paid` \| `public`. FIRST-PUBLISH DEFAULT ONLY — the live truth is owned by `rotate-free-dinners.ps1` + Ghost; `engine/publish.ps1` preserves the live post's visibility and the guard does NOT compare this field. |
| `source_site`, `source_url` | string | attribution; `credit_html` is the rendered callout. |

## Prose (HTML string fields — rendered verbatim into the card)
`intro_html`, `portion_html`, `cost_closing_html`, `cost_note_html`, `credit_html`, `upsell_html` — HTML
strings. `shop_smart` — HTML string (a few legacy specs store an array; both render). Numeric claims in
these are kept in sync by spec-guards' auto-numeric-sync; per-line dollar figures were stripped 2026-07-26
(prices are dynamic — see the shop_smart sweep). No em/en dashes (Brad's rule).

## Ingredient arrays (ALL parallel — same length, same order)
The card build hard-fails if `ingredients_display.Count != scaler.ing.Count`.
- `ingredients_display[]` — string, `"<strong>Name (Brand):</strong> 19.5 oz dry (556 g)"`. The
  `<strong>NAME:</strong>` prefix is parsed for the scaler display name (build-card2 regex).
- `ingredients_grams[]` — `{item, grams}` at 14 servings.
- `scaler.ing[]` — the pricing + live-widget payload, one per ingredient:
  | key | type | role |
  |---|---|---|
  | `item` | string | matches the costed line's `item` (or `canon` if present) — the pricing join key. |
  | `grams` | number | grams at 14 servings (base). The scaler multiplies this. |
  | `buy` | string | shopper-facing buy amount ("5.5 lb raw"). |
  | `bid` | string | board/feed commodity id for the LIVE cheapest lookup. **MUST resolve on the public feed** (`smp-feed.json` ingredients) OR be listed in `db/no-board-price-ok.json`, else the card's "current cheapest" silently falls back to the everyday price — the CHEAPEST-FALLBACK guard in `audit-db-agreement.ps1` enforces this. |
  | `gpu` | number | grams per feed unit for `bid`, reconciled to the FEED row's unit (the "brown-sugar 16x" lesson: a map gpu is calibrated to its era's board unit — never copy blindly). Drives `pkg_g/gpu * feed.cheapest`. |
- `scaler.cost` — legacy per-serving figure (not authoritative; the manifest recomputes).

## Cost fields (numbers; the everyday baseline)
`cost_first_run` (batch cost the "at everyday cost" stat divides by 14), `cost_batch`,
`cost_batch_true`, `cost_pantry_add`, `cost_per_serving`, `cost_per_serving_true`. `cost_lines[]` —
rendered "Ingredient, size: ~$X. **Buy N: $Y.**" strings. These are DERIVED and re-anchored by the cost
engine + reanchor scripts; the authoritative package math lives in `db/costed.json`, keyed by slug.

## stat (the blue rectangle + JSON-LD)
`{cal, protein, carbs, fat, cost_ps}` per serving. `cost_ps` is the everyday per-serving ("at everyday
cost"); the widget live-updates the rectangle to the cheapest number from the feed.

## head (Recipe JSON-LD source)
`{cookTime, prepTime, totalTime, costPerServing, description, image, keywords, recipeIngredient[], steps[]}`.
`recipeIngredient[]` is the schema.org ingredient list (14-serving amounts). `description` is also the
post's meta description + custom excerpt.

## Other
`make_it[]` — ordered method steps (strings). `tuning[]` — provenance notes (e.g. "base +5% (Pasta
Shells)"). `manual_balance` — bool, marks a spec whose macros were hand-balanced (skip auto-rebalance).

## Invariants a valid spec must satisfy
1. `ingredients_display`, `ingredients_grams`, `scaler.ing` are equal length, same order.
2. Every `scaler.ing.item` (or `.canon`) has a matching line in the recipe's `db/costed.json` entry.
3. For each line, `ceil(grams/pkg_g - 0.02) == costed.buy_n` (build-card2 self-test; pkg_g/buy_n must agree).
4. Every `scaler.ing.bid` resolves on the feed or is in `no-board-price-ok.json` (CHEAPEST-FALLBACK guard).
5. `slug` + `protein` agree with the `recipes-db.json` index row (audit-db-agreement guard).
