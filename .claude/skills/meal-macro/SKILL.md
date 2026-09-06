---
name: meal-macro
description: Log a food nutrition label into the Thrifty Crew meal-prep macro database, compute batch/per-serving macros from it, or publish a recipe to the site in the standard model. Invoke when Brad sends or reads off a nutrition label (to capture/verify an item), asks what a food's macros are, says something like "I used 5 lbs of this chicken, made 10 containers" (to compute a recipe), or wants to add/update a Meal Prep recipe on the site. Enforces 100% label-accurate data, captures BOTH the household serving measure (cup/tbsp/etc) and grams, keeps every recipe in the one standard framework, and never overwrites the DB on a conflict without asking.
---

# Meal Macro — Thrifty Crew

Brad and his wife meal prep. Instead of hand-entering macros in a spreadsheet, we keep a **local food macro database** and compute macros on demand. This skill covers three jobs: **logging a label**, **computing a recipe**, and **publishing a recipe to the site in the standard model**.

**The database:** `C:\Codex\ThriftyCrew\meal-prep\food-macros-db.json`
Shape: `{ "readme": "...", "items": [ ... ] }`

**Per-item schema** (all macros are PER SERVING):
`item`, `brand`, `serving_grams`, `serving_qty`, `serving_unit`, `calories`, `protein_g`, `carbs_g`, `fat_g`, optional `fiber_g`, `notes`

- `serving_grams` = grams in one serving (used to scale by weight, e.g. pounds).
- `serving_qty` + `serving_unit` = the **household measure** for that serving (e.g. `0.5` + `cup`, `2` + `tbsp`, `13` + `pieces`, `1` + `tortilla`, `4` + `oz`, `16` + `slices`). This is what lets Brad measure with a cup or spoon instead of a scale.
- `fiber_g` = only when notably high (tortilla 18g, keto bun 18g, protein pasta 5g) so net carbs can be computed.
- `brand` = empty string `""` **only** for fresh produce (e.g. shredded carrots, green peppers). Everything packaged has a brand.
- `notes` = human context: raw vs cooked, dry vs cooked, "from label", package/packet size, any correction made.

**The recipe database:** `C:\Codex\ThriftyCrew\meal-prep\recipes-db.json` — one record per published recipe (see JOB 3).

---

## THE HARD RULES (never break these)

1. **100% accurate. Never assume or hallucinate** a brand or a macro value. If the brand isn't visible on a cropped panel and isn't already known, **ask** — don't guess.
2. **When a label conflicts with the DB, STOP and surface it. Do NOT silently overwrite.** Show a small before/after table and ask Brad which is right.
3. **No em dashes** anywhere in chat replies, notes, or site copy. Plain punctuation only (Brad's rule — reads as AI otherwise). See memory `brand-voice-brad` / `writing-no-em-dashes`.
4. **The label is the source of truth** over an old spreadsheet. Trust the label, correct the DB, note the correction.
5. **Grams must equal the real amount used**, not a serving and not a guess. This is the #1 macro-corruption risk (see the fajita packet lesson in JOB 3).

---

## JOB 1 — Logging a label

Brad sends a photo of a Nutrition Facts panel (or reads one off). Capture EVERY field.

### Step 1 — Read these off the label
- **Item + brand.** If the panel is cropped and the brand isn't shown, use the brand already on the DB item; if none is known, **ask**.
- **Serving size — BOTH forms:** the household measure ("1/2 cup", "2 Tbsp", "13 pieces", "1 tortilla", "4 oz") **and** the gram weight in parentheses ("(113g)"). Always grab the cup/spoon measure too.
- **The 4 tracked macros:** Calories, Total Fat, Total Carbohydrate, Protein.
- **Fiber** — only if high enough to matter for net carbs (`fiber_g`).
- **State-of-food:** raw vs cooked for meats; dry vs cooked for pasta/rice. Note it.
- **Package/packet size when relevant:** if the item is bought in discrete units used whole (seasoning packets, cans), record the net weight PER PACKAGE in `notes` (e.g. "1 packet = 1.4 oz / ~40g"). This prevents the packet-vs-tbsp error in JOB 3.

### Step 2 — Find the matching DB item, note current macros.

### Step 3 — Compare and decide
- **Match** → confirm brand, add `serving_qty` + `serving_unit`, refresh `notes`.
- **Differ a little** (label is truth) → correct the DB, note `"...; from label (corrected from old sheet: was <old>)"`.
- **Differ wildly / looks like a different product** → **do not write.** Show before/after and ask Brad.

### Step 4 — Write the edit
Exact-string `Edit` on the one item line. Fractions to decimals in `serving_qty` (1/4 -> `0.25`, 2/3 -> `0.667`).

### Step 5 — Validate
```
powershell -Command "$db = Get-Content 'C:\Codex\ThriftyCrew\meal-prep\food-macros-db.json' -Raw | ConvertFrom-Json; $db.items.Count"
```
**Gotcha:** the LAST item has no trailing comma — don't add one.

### Step 6 — Tell Brad what's captured (one line) and how many items still need a label.

---

## JOB 2 — Computing a recipe / batch

When Brad says *"I used 5 lbs of Member's Mark chicken, 2 cups dry Barilla rotini, 1 cup GV alfredo, made 10 containers"*:

Use `recipe-macros.ps1` (invoke it in-session so the array binds; a nested `powershell -File` flattens the array):
```
& "C:\Codex\ThriftyCrew\.claude\skills\meal-macro\recipe-macros.ps1" -Servings 14 -CostTotal 31.72 -Ingredients @('Boneless Skinless Chicken Breast|2495','Rice|800', ...)
```
It scales each item by `grams / serving_grams`, sums the batch, and divides by `-Servings`. Convert amounts to grams first: 1 lb = 453.592 g, 1 oz = 28.3495 g; by household measure `grams = (amount / serving_qty) * serving_grams`. Report BOTH batch and per-serving; add cost/serving if `-CostTotal` given.

---

## JOB 3 — Publishing a recipe to the site (THE STANDARD MODEL)

> **STOP — MODEL SUPERSEDED 2026-07-26.** The catalog moved to the v2 tabbed-cost card and a unified
> engine. **DO NOT publish via this section's flow or `publish-recipe.ps1`** — a card published this way
> bypasses the canonical stores (`meal-prep\db\recipes\`, `db\costed.json`, the per-serving manifest,
> top5/planner data) and lands as an orphan old-format page. THE current intake path is documented in
> **`C:\Codex\ThriftyCrew\meal-prep\engine\README.md`** ("Adding recipes"): write a v2 spec into
> `db\recipes\<slug>.json`, add any new ingredient rows to `db\ingredients.json` + canon rules, then run
> `engine\cost-recipes.ps1 -Slugs`, `pipeline\compute-v2-perserving.ps1`, the reanchor scripts,
> `engine\build-cards.ps1 -Slugs`, `engine\publish.ps1 -Slugs`, and add the recipes-db row. JOB 1/JOB 2
> (label logging + macro math) below remain fully current — only this publishing flow changed. The rest
> of JOB 3 is kept as historical reference for the data standards (14 servings, grams=amount-used, sync
> rules), which still apply.

**Every Meal Prep recipe follows this exact model. Match it precisely so new recipes fit the set.** Recipe sources/scratch live under `C:\Codex\ThriftyCrew\meal-prep\`. Confirm Brad's REAL cooking method before writing steps — never fabricate.

### A. The standard
- **14 servings, always** (a week of dinners for two = 2 x 7). Scale any recipe to 14 by multiplying every ingredient's grams by `14 / current_servings`; per-serving macros and per-serving cost then stay constant, only batch totals grow.
- Macros come ONLY from `food-macros-db.json` via `recipe-macros.ps1`. **Every ingredient must exist in the food DB first** (log it via JOB 1 if not).
- **`grams` = the amount ACTUALLY used in the batch.** It must match the real quantity cooked, cross-checked against the `buy`. If the recipe uses 6 whole seasoning packets, grams = 6 x packet weight (a Taco Bell fajita packet is 1.4 oz / ~40g, so ~238g), NOT 6 tbsp. Getting this wrong silently corrupts calories/carbs — it bit the fajita bowl (48g stored vs 238g real, under-counted ~40 cal/serving). For canned/packet items used whole, `grams ~= buy_count x package_net_weight`.

### B. The record (append to recipes-db.json)
`{name, slug, visibility:"paid", cuisine, servings:14, ingredients:[{item (exact food-db name), grams, buy}], grocery_list[], per_serving{calories,protein_g,carbs_g,fat_g}, batch{...}, cost_per_serving, cost_batch, cost_per_serving_true, cost_batch_true, published, notes}`. Compute per_serving/batch with `recipe-macros.ps1`.

### C. The card body (in this order; convert to clean semantic HTML, no wrapper div, no h1)
1. **Stat line:** `<p><strong>Makes 14 servings &middot; ~<cal> cal &middot; <p>g protein &middot; <c>g carbs &middot; <f>g fat &middot; ~$<cost/serving> per serving.</strong></p>`
2. **Intro** paragraph (warm, budget voice, no em dashes).
3. `## Ingredients` — bulleted, each `**Item (brand):** <grams> g (household equivalent)`.
4. `## Estimated Cost` — see cost model (D). Order: one `<li>` per ingredient, then Batch total `<li>`, then True shopping cost `<li>`, then a per-bowl-vs-takeout line.
5. `## Shop Smart` — money-saving buying tips (sales, bulk, store-brand, price-per-ounce).
6. `## Make it` — numbered steps. **Step 1 is always "weigh your empty pot"** (tare for portioning). Confirm Brad's method.
7. `## Portion it` — weigh full pot, subtract empty-pot weight, divide by 14.

### D. The cost model (MUST be internally consistent)
- Per-ingredient **utilization** cost = what the batch uses (`used_units x unit_price`), shown as `~$X`.
- **Batch total = the exact SUM of the per-ingredient utilization lines.** `per-serving = batch / 14`. Do NOT round per-serving then multiply back (that creates the mismatch we had to true up).
- **True shopping cost = sum of per-line "Buy" contributions.** Round UP discrete packages (meat -> whole lb; boxes, jars, cans, bags, pepperoni, produce -> `ceil(used) x unit_price`, always >= util). **BULK / long-lasting items stay at utilization** (rice, oil, dry seasoning, grated parmesan, hot honey, BBQ sauce, tomato paste, broth) — show the buy quantity but keep the amortized cost, since one package covers several batches. `per-serving_true = true / 14`.
- **Buy line format** appended to each ingredient `<li>`: round-up item `<strong>Buy 4 lb: $23.88.</strong>`; already-whole `<strong>Buy 2 cans.</strong>`; bulk `<strong>Buy 1 bottle (lasts several batches).</strong>`. Singularize the unit at qty 1 ("Buy 1 bag" not "bags").
- **Tooling:** `add-buy-lines.ps1` (in the recipe scratch dir) parses each body's util lines (first-$ = unit price, last-$ = util) and regenerates the Buy clauses + the True-cost line idempotently.
- **Every price figure must agree:** stat line, batch line, closing line, any spelled-out intro price ("about a dollar fifteen"), the meta description, and the JSON-LD `costPerServing`.

### E. The head (Recipe JSON-LD) — REQUIRED, never empty
`-HeadFile` MUST contain a Recipe JSON-LD script + the Article paywall script. **It powers the blue stats bar** (client-side JS in the site's global Code Injection reads `costPerServing`, `recipeYield`, `nutrition.calories`, `nutrition.proteinContent`). An empty head = no stats bar AND no rich result — this happened to fajita when an empty head file was passed; never do that, keep a real `head.html` per recipe. Include: name, description, author (Organization "Thrifty Crew"), recipeCategory "Meal Prep", recipeCuisine, recipeYield "14 servings", **`costPerServing` as a BARE number** (e.g. `2.27`, renders as `$2.27` — no `$`), keywords, nutrition (servingSize "1 bowl", calories "<n> calories", proteinContent "<n> g", carbohydrateContent, fatContent), recipeIngredient[], recipeInstructions[] (HowToStep with `url` `.../#stepN`), image `https://storage.ghost.io/c/4b/5b/4b5b2999-07b7-4733-88cc-1bc0e25912c6/content/images/2026/07/smp-og-card.png`, prepTime/cookTime/totalTime. **Keep nutrition + costPerServing in SYNC with the DB whenever macros or cost change.**

### F. Meta description
~150 chars, benefit-led: `"A <descriptor> meal prep: 14 servings at <cal> cal and <p>g protein each, about $<cost> a bowl. <key ingredients>."` Update it whenever macros/cost change.

### G. Publish + verify
Publish (upserts by slug; tags Meal Prep; paid by default). Invoke IN-SESSION with real args (a `powershell -File` splat can mangle long/quoted args):
```
& "C:\Codex\ThriftyCrew\.claude\skills\meal-macro\publish-recipe.ps1" -Title "..." -Slug "..." -HtmlFile "...body.html" -Excerpt "..." -MetaTitle "... | Thrifty Crew" -MetaDesc "..." -HeadFile "...head.html" -Visibility paid
```
**Verify on the PUBLIC page, NOT the Admin API.** The Admin API GET with `fields=meta_description` (also meta_title/og_/twitter_) returns EMPTY even when set and rendering — a quirk that will mislead you. Fetch `https://www.thriftycrew.com/<slug>/` (Invoke-WebRequest) and confirm the rendered `<title>`, `<meta name="description">`, og tags, and the Recipe JSON-LD `nutrition` + `costPerServing`.

### H. Done-checklist
- [ ] every ingredient in the food DB; `grams` = real used amount (packets/cans counted whole, cross-checked vs `buy` + real package size)
- [ ] `recipe-macros.ps1` macros match the card stat line AND the JSON-LD nutrition AND the DB record
- [ ] batch total = sum of util lines; per-serving = batch / 14
- [ ] true shopping cost = sum of per-line buys; each buy cost >= its util
- [ ] every price agrees (stat, batch, closing, spelled-out intro, meta, costPerServing)
- [ ] head has full Recipe JSON-LD (blue stats bar renders) + Article paywall
- [ ] verified on the public page

---

## Cheat-sheet
- Food DB: `C:\Codex\ThriftyCrew\meal-prep\food-macros-db.json`. Recipe DB: `C:\Codex\ThriftyCrew\meal-prep\recipes-db.json`. Both local, not on Ghost.
- Macros are PER SERVING. Meats note raw/cooked; pasta/rice note dry/cooked. Blank brand = fresh produce only.
- 1 lb = 453.592 g, 1 oz = 28.3495 g.
- Standard package sizes: canned beans ~15.5 oz (drained ~255g), corn ~15.25 oz (drained ~300g), enchilada sauce 10 oz, tomato paste 6 oz, Barilla Protein Plus box 14.5 oz (411g), sauce jar 24 oz, cheese bag 8 oz, parmesan container ~8 oz, Taco Bell fajita packet 1.4 oz (~40g), taco packet ~1 oz (28g), broccoli bag ~12 oz, broth carton 32 oz.
- `costPerServing` in JSON-LD is a BARE number (drives the blue stats bar). Empty head = no stats bar.
- Related memory: `meal-prep-macros-db`, `meal-prep-recipe-template`, `content-factory`, `brand-voice-brad`, `writing-no-em-dashes`.

---

## Wait for the brief

**This is the last statement in this file on purpose, and it must stay last.** Everything above is
rules, and a rules-first prompt with no closing instruction invents its own first input.

This skill covers **three different jobs** - logging a label, computing a recipe, publishing a recipe -
and they take different inputs and write to different places. Guessing which one is meant is the
expensive mistake here, because two of the three write to the food DB or to the live site.

So: **when it is not already obvious which job is being asked for, ask.** Use the question tool with
the three jobs as options plus Other, never a prose question (memory `always-prompt-for-direction`).
Then ask for that job's input if it is not already in hand: a label needs every field on the panel, a
recipe computation needs the quantities used and the container count, a publish needs the recipe id.

Regime: this holds when the job or its input is **missing or ambiguous**. A photographed label, or
"I used 5 lbs of this chicken and made 10 containers", has already named the job and supplied the
input - act on it. Never ask for something the message already contains, and never guess at a number
the message does not: a missing macro is a question, not an estimate.
