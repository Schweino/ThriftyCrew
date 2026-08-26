# PLAN: closing the nutrition gaps in the food DB — provenance first, labels second

Date: 2026-08-26. Author: Fable session, written after an end-to-end audit of one live recipe's
macros exposed the shape of the problem. Status: **WRITTEN FOR RATIFICATION — nothing here is built,
and no rung is ordered.** Every number below was measured today; where a claim is an inference it
says so.

## 0. The one-paragraph verdict

`meal-prep\food-macros-db.json` holds 376 rows and **204 of them (54%) carry no `source`**. That is a
real gap, but it is an **auditability** gap, not a pile of known errors: the one unsourced row this
session checked against a photographed label — Cheese Tortellini — turned out to be **exactly
correct**, and the conflict rule that has been refusing to overwrite it was right to do so. The cost
of the gap is that nobody can tell a good row from a bad one without driving a browser to a label
photo, which is what this plan is about. The work is smaller than it looks, because the rows used in
hundreds of recipes are generic whole foods that need no store label at all, and the rows that need a
store label are used once or twice each.

## 1. What was measured today, with the numbers

**The DB.** 376 rows; 204 without `source`; **200 of those 204 appear in at least one live recipe**,
so this is not dead weight.

**Frequency is inverted against difficulty.** The most-used unsourced rows, by count of live recipes
mentioning them:

| row | recipes | row | recipes |
|---|---|---|---|
| salt | 515 | olive oil | 218 |
| black pepper | 492 | chicken broth | 194 |
| garlic | 466 | vegetable oil | 152 |
| yellow onion | 369 | butter | 145 |
| rice | 317 | sugar | 114 |

Every one of those is a generic whole food or commodity staple. **The rows that appear hundreds of
times are the rows that do not need a store label.** An onion is an onion.

**Brand spread is real, and it is large, but it lives in the tail.** FDC Branded rows for cheese
tortellini, measured live: 141, 180, 207, 208, 216, 270, 287, 290, 368, 376 cal per 100 g — a **2.7x
spread**, protein 5.9 to 19.5 g. For a manufactured product a generic figure means nothing. For an
onion the spread does not exist.

**The audit that started this.** italian-chicken-tortellini-skillet computed 535 cal / 36.8 g protein
per serving against a source page claiming 562 / 46. Recomputing by hand from the DB rows reproduced
535 / 36.8 / 39.9 / 24.4 **exactly** — the engine and the scaling are sound.

**And the row was right.** The Great Value Family Size Cheese Tortellini 36 oz label, read off the
product photo in Brad's own Chrome:

```
8.5 servings per container      Serving size  1 cup (120g)
Calories 210   Total Fat 2.5 g   Total Carbohydrate 38 g   Protein 7 g
```

The stored row is `120 g, 210 cal, 7 g protein, 38 g carbs, 2.5 g fat` — an exact match. Great Value
frozen tortellini is genuinely lighter than the premium brands; comparing it against Wegmans (270)
and World Finer (368) is what produced this session's wrong claim that the row was "half of real".

**One real defect did surface**, and it is the only one: the row's `serving_unit` string says
`4.5 servings per container` where the label says **8.5** (36 oz = 1.02 kg / 120 g = 8.5). The macros
are right; the container note is wrong, and nothing reads it today.

**The conflict rule was vindicated.** During the same run the mapper proposed replacing this row with
307 cal / 13.5 g protein per 100 g. The rule refused — "Nothing was written and the existing row
stands" — and it was refusing a WORSE reading in favour of a correct one. Any change to that rule
must keep that outcome.

## 2. So the gap is provenance, not correctness

Nothing measured today supports "the DB is drifting" or "unsourced rows are mispricing recipes". What
it supports is narrower and still worth fixing:

- A row with no `source` cannot be audited without a browser session and a human eye.
- A row with no `source` cannot be **re-checked** when a product changes.
- A reviewer cannot tell a label-accurate row from a guess, so every disagreement becomes a research
  task from scratch — which is exactly what this session spent an hour doing for one row.

**The deliverable of this plan is therefore that every row states where its numbers came from**, and
that a proxy is visibly a proxy. Reaching a store label every time is NOT the goal.

## 3. Three classes of food, three right answers

Splitting the 204 by what they actually are is what makes the work tractable.

**Class A — generic whole foods and commodity staples.** Salt, garlic, onion, rice, potato, butter,
oils, sugar, flour, plain spices. There is no meaningful brand variation, and USDA SR Legacy /
Foundation entries are curated whole-food references — for these they are *better* than a store label,
not a fallback. `fdc_lookup.py` already queries them (`DEFAULT_TYPES = ("SR Legacy", "Foundation",
"Branded")`, curated first). **Unattended, no browser, no images.** This is the bulk of the 204 by
frequency.

**Class B — branded manufactured products.** Tortellini, jarred sauces, packaged mixes, anything where
the 2.7x spread lives. These need the label of the product the board actually prices. **This is the
only class that needs a browser**, and it is the long tail: each row serves one or two recipes.

**Class C — zero-macro or trivial-weight rows.** Salt carries no macros at all; black pepper at 4 g in
a 14-serving batch cannot move a number. These need provenance for tidiness and nothing else, and they
must never be allowed to consume Class B effort just because they are frequent.

The ordering rule that falls out: **within Class B, work by grams-in-live-recipes, not by recipe
count.** Tortellini at 1,225 g in one recipe outranks garlic powder in 95.

## 4. The provenance ladder

Every row records which rung answered it. A lower rung is not a failure; an unrecorded rung is.

1. **The retailer's own label photo**, read in Brad's Chrome. Confirmed reachable today. Highest
   fidelity for Class B, and the only source that names the exact package the shopper buys.
2. **FDC Branded** by brand + product. Already wired. Coverage is whoever submitted data — neither
   Priano nor Great Value tortellini were present, so this is a partial answer for house brands.
3. **A same-class branded row, explicitly recorded as a proxy** — "Rosina cheese tortellini standing
   in for Great Value". Honest, useful, and visibly not the real thing.
4. **FDC SR Legacy / Foundation.** The RIGHT answer for Class A, a weak one for Class B.
5. **Mapper label transcription**, which is what happens today when a food has no row at all.

## 5. The rungs, in order, each with a gate

Not ordered. Rung 1 is the one worth doing regardless of what follows.

1. **Make provenance mandatory and classify what exists.** Every new row must carry a `source`
   naming its rung; every existing row gets classified A/B/C. No label fetching yet.
   *Gate:* a fixture refuses a new row with no `source`; a report lists the 204 by class and, for
   Class B, by grams-in-live-recipes, so the tail is a worklist rather than a number.
2. **Backfill Class A from FDC, unattended.** One batch pass over the generic rows, curated types
   only, writing `source` with the FDC id — the shape `Mozzarella Cheese` already has
   (`USDA FDC 170900 (SR Legacy) ... fetched 2026-0...`).
   *Gate:* every Class A row carries an FDC id; a row whose FDC candidate DISAGREES with the stored
   numbers beyond a stated tolerance is REPORTED, never silently overwritten — the tortellini lesson.
3. **Fix the conflict rule's reporting, not its verdict.** Keep refusing to overwrite. Change what it
   says: normalise both rows to a common basis before calling them different, and record the
   disagreement somewhere a human can review it rather than only in a run's findings.
   *Gate:* the Great Value tortellini case still refuses the mapper's 307/13.5 row, and the refusal is
   readable a week later.
4. **Class B labels through the 09:00 browser agent.** It already drives Brad's Chrome to Walmart and
   Aldi every morning. Add: for N commodities per run, taken off rung 1's worklist, open the product
   URL already on file, capture the label from the product image set, write the row with `source`.
   *Gate:* a captured row matches the photographed label field for field; a commodity whose label
   cannot be found is recorded as such and drops to rung 2 or 3 rather than being retried forever.
5. **Optional, only if rungs 1-4 leave a real problem:** revisit whether macros should follow the
   board's cheapest cell or a fixed anchor store. Do not decide this in advance — rung 1's
   classification will show how many Class B rows have a materially different label across stores,
   and that number decides whether the question matters at all.

## 6. What must not happen — every one of these was done today, by this author

- **Do not fetch a retailer page with an automated client.** WebFetch on the Walmart product URL
  returned "Activate and hold the button to confirm that you're human"; the same URL in Brad's Chrome
  returned the product. The bot wall is a fact about the instrument, not about Walmart.
- **Do not look for the label in the page text, the JSON, or the filename.** Walmart's
  `__NEXT_DATA__` is 354 KB and mentions nutrition only as `NutritionValuePlaceholderConfigs` with
  `expandedOnPageLoadV2: "False"`. No `calorieContent`, no `servingSize`, no `nutrientName`. The label
  is a **photograph in the product image set** — 11 images, the back-of-pack around index 8, with
  hashed URLs and empty `alt` text. A filename or alt-text regex finds nothing and proves nothing.
- **Do not judge a house brand against premium brands.** That is what produced this session's false
  "the row is half of real", and acting on it would have replaced a correct row with a worse one.
- **Do not treat "no source" as "wrong".** One row was checked; it was right. The correct prior for an
  unsourced row is UNKNOWN, and the fix is to make it knowable.

## 7. What Brad has not ruled on

- Whether rung 5 (anchor store vs cheapest cell) is even a question worth asking — deferred to rung 1's
  numbers on purpose.
- How many Class B labels per morning run is acceptable in a session that also owns the browser
  captures.
- Whether the `4.5 servings per container` error on the tortellini row should be corrected now as a
  one-off, or left until rung 4 reaches it.

Co-authored with the measurements above; every figure in section 1 is reproducible from the repo and
the run dirs of 2026-08-26.
