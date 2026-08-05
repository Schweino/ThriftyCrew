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
  | `buy` | string | the amount THIS RECIPE uses, in the unit a cook holds ("5.5 lb raw", "3 onions", "1/2 cup"). It must always name a unit: the widget re-renders the Ingredients list from this string, and a bare number ("18.4") reads as a typo on the card. Counts get their noun from `db/each-nouns.json` (see invariant 6). What to BUY is the cost section's job, not this field's. |
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
`description` is also the post's meta description + custom excerpt.

`recipeIngredient[]` is the schema.org ingredient list (14-serving amounts) and is **DERIVED, never
hand-written** — one line per `ingredients_display` line, same order, same amounts, shaped
`"<name>, <amount> (<grams> g)"` with the brand parenthetical dropped. `pipeline/head-ingredients-lib.ps1`
is the only thing that may produce it: `build-v2-spec` derives it at intake (an intake file that supplies
one is ignored with a warning) and `pipeline/repair-head-ingredients.ps1` re-derives it in place on
existing specs. It was writer-typed prose until 2026-08-04, and prose about a list of quantities drifts:
507 of 513 specs named fewer ingredients than their own card, in package units the page never used
("3 boxs Penne Pasta" against the card's "10 cups (1050 g)"). Google asks that structured data represent
the visible page, so it is now generated from the visible page's own list. See invariant 9.

## Other
`make_it[]` — ordered method steps (strings). `tuning[]` — provenance notes (e.g. "base +5% (Pasta
Shells)"). `manual_balance` — bool, marks a spec whose macros were hand-balanced (skip auto-rebalance).

## Invariants a valid spec must satisfy
1. `ingredients_display`, `ingredients_grams`, `scaler.ing` are equal length, same order.
2. Every `scaler.ing.item` (or `.canon`) has a matching line in the recipe's `db/costed.json` entry.
3. For each line, `ceil(grams/pkg_g - 0.02) == costed.buy_n` (build-card2 self-test; pkg_g/buy_n must agree).
4. Every `scaler.ing.bid` resolves on the feed or is in `no-board-price-ok.json` (CHEAPEST-FALLBACK guard).
5. `slug` + `protein` agree with the `recipes-db.json` index row (audit-db-agreement guard).
6. Every `scaler.ing.buy` NAMES ITS UNIT - it contains at least one letter (spec-guards). A count with no
   noun ("Potato (generic): 18.4 (3909 g)") is only recoverable from the gram restatement beside it, and
   661 lines across 339 specs shipped that way until 2026-08-04. The cause was `FriendlyAmt`'s `each`
   branch returning a bare number while all nine sibling branches append a unit; the noun now comes from
   `db/each-nouns.json`, and an item that reaches that branch without an entry is a BUILD ERROR rather
   than a silent bare count. Repair: `pipeline/repair-unitless-buy.ps1`.
7. `ingredients_display[i]` CONTAINS `scaler.ing[i].buy` verbatim. Two surfaces render the same list - the
   static `<ul>` the page ships and the widget's re-render when a reader changes servings - so fixing one
   without the other makes the list change under the reader the moment they touch the servings control.
8. `buy` LEADS with its quantity, because the widget's `scaleBuy` only multiplies the leading number.
   A range ("1-2") scales to nonsense ("2-2"); ~10 legacy freeform labels still carry this shape.
9. `head.recipeIngredient` EQUALS the derivation from `ingredients_display` - same length, same order,
   same amounts (HEAD-INGREDIENT guard in `audit-db-agreement.ps1`). The JSON-LD ingredient list and the
   rendered ingredient list are two views of one list; keeping them as two separately-maintained lists is
   what let the structured data drift to 6 ingredients on a 16-ingredient recipe. Repair:
   `pipeline/repair-head-ingredients.ps1 -Apply`.
10. The `recipes-db.json` row lists the SAME ingredients as the spec - same count, same canonical names
   (`scaler.canon` when present, else `scaler.item`; INGREDIENT-SET guard in `audit-db-agreement.ps1`,
   armed at zero). Two defects on 2026-08-04 proved both directions:
   `slow-cooker-dr-pepper-pulled-pork-bowls` held 8 ingredients in the index and 7 in the spec, so the
   soda the recipe is NAMED for was in no ingredient line, no cost line and no scaler row - a braise with
   no braising liquid on the list a shopper buys from; and `korean-turkey-japchae` still said
   "Cornstarch" where the spec said "Rice Noodles", a swap from the 2026-07 glass-noodle correction that
   never reached the index, so the Meal Plan Builder shopped 794 g of cornstarch for a noodle dish. The
   card reads the SPEC and the Meal Plan Builder reads the INDEX, so a disagreement here ships two
   different shopping lists for one recipe.
   REPAIR: `pipeline\update-recipes-db.ps1 -Replace <slug>` rebuilds the row from the spec. It carries
   the old row's `visibility` and `published` across (2026-08-05) - the spec owns neither. `visibility`
   belongs to `rotate-free-dinners.ps1` and the builder emits `paid` for a new row, so before that fix a
   -Replace on a recipe the weekly rotation had set PUBLIC silently paywalled a free dinner; `published`
   is the date it went live, not the date it was last repaired. If a repair only needs to ADD or RENAME
   an ingredient, a key-scoped edit to the row is smaller than a rebuild and moves nothing else - the
   rebuild also re-orders the row to the end of the array.
11. Every ingredient a `make_it` step NAMES is in the ingredient list - the mirror of the spec-guards
   "use what you buy" gate. Reported as PHANTOM by `pipeline/audit-spec-contradictions.ps1`, ratcheted
   against a baseline rather than armed at zero; the standing list and the six rules that got it from
   555 raw hits to 9 are in `out/fidelity/engine-pass-notes.md`.

## Fields that keep their own COPY of a spec value (a repair must carry across, or they go stale)
`recipes-db.json` stores each ingredient's `buy` again (`pipeline/sync-recipesdb-buy.ps1` carries a label
repair across; `update-recipes-db.ps1 -Replace` is the heavier full-row path), and `planner-data.js` is
generated from THAT copy, so the Meal Plan Builder's merged grocery list reads the index and not the
specs. `db/built/<slug>.body.html` embeds `buy` in the scaler payload, so any label change needs a card
rebuild + republish. audit-db-agreement compares slug, protein, the cost block and the ingredient SET
(count + canonical names) - it will NOT catch `buy` LABEL or gram drift inside a line whose name matches;
that is `sync-recipesdb-buy.ps1`, which carries the named repair classes and REPORTS everything else
rather than overwriting reader-facing text on its own judgement.
