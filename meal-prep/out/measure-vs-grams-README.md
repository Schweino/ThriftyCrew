# measure-vs-grams — what was found, what was repaired, what is still open

2026-08-04. Follow-on from `pipeline\repair-scaled-notes.ps1`, which fixed seven ingredient labels that
stated the UNSCALED source quantity next to the scaled 14-serving grams. Those seven were findable only
because the writer left a literal `(scaled ~N)` note in the string. **The same defect exists without the
marker**, and `out\screen-measure-vs-grams.ps1` flagged 331 rows across 91 recipes where the label's
implied grams and the recipe's actual grams disagree by 2x or more.

## The screen was misreading its own input

Before anything was adjudicated, the screen itself had to be fixed. Its quantity regex added the decimal
part only when the whole part had *not* matched:

```
if ($m.Groups['dec'].Success -and -not $m.Groups['w'].Success) { $q += ... }
```

So `"1.5 tsp"` parsed as **1**, `"2.5 tsp"` as **2**, `"3.75 cups dry"` as **3**. Every ratio it reported
for a decimal-quantity label was inflated — Salt `1.5 tsp` @ 23 g was reported at 3.83x when it is 2.56x.
`cook-measure-lib.ps1` has parsed this correctly all along, so the screen now uses `Get-CmQty`/`Get-CmUnit`
from that library instead of a second copy. The row count is unchanged at 331; the ratios are not.

The screen also now reports the band **below** its own threshold (`out\measure-vs-grams-underbar.csv`,
241 rows), because a 2x bar hides part of the same class: Rice `"1 lb"` against 700 g is 1.54 and passed
silently while the identical label against 1000 g was flagged.

## What the sources said

87 of the 91 specs cite a source; 86 could be read. Every flagged ingredient was checked against its
recipe's `source_url`, together with the source's serving count and main-protein amount so the scale
factor was known independently. Per-row results: `out\measure-vs-grams-verdicts.csv`.

| verdict | rows | meaning |
|---|---:|---|
| `label-is-source-unscaled` | 272 | the label is the **source's** amount, verbatim, at the source's serving count |
| `filler-label` | 32 | `"1 lb"` — a label that does not move regardless of the grams |
| `label-near-source` | 5 | same shape, but the copied amount was not byte-identical |
| `own-addition` | 7 | the ingredient is **not in the source**, so nothing external decides which side is wrong |
| `unverifiable` | 13 | no `source_url` (4 specs), or the cited URL is dead |
| `grams-suspect` | 2 | the label is **right** and the grams are the doubtful side |

The copy-forward was verbatim down to the punctuation — `"1/4 cup beef broth (or water)"`,
`"1 tsp (meatballs) + 1 tsp (sauce)"`, `"1/2 tsp + 1/4 tsp (turkey + sauce)"`. These labels are not
competing measurements of this recipe; they are measurements of a different, smaller recipe.

### The two rows that prove the refusal was right

`cook-measure-lib.ps1:152-158` refuses this class deliberately, because either side can be the error and
the grams drive cost and macros. That refusal held up:

- **`slow-cooker-kalua-pork-bowls` / Salt** — `"2 tbsp"` against 15 g. The source (downshiftology,
  6 servings, 4 lb pork) calls for 1 tablespoon. This spec uses 7.5 lb, so ~2 tbsp is the correctly
  scaled amount — **exactly what the label says**. The 15 g gram figure is the one that does not fit.
- **`teriyaki-chicken-bowl` / Shredded Carrots** — source says 3 carrots (~180 g) at 6 servings; this
  spec is 14 servings and carries 200 g, barely scaled at all.

A sweep that rewrote labels to agree with grams would have replaced a correct label with `"2.5 tsp"` and
called it a repair. Both rows are untouched and need a decision on the **gram** figure, which moves
sodium in the macro block.

## What was repaired

`pipeline\repair-measure-vs-grams.ps1 -Apply` — **292 labels across 85 recipes**. No gram figure, cost
field, macro, bid or gpu moved anywhere in the catalog; only the sentence changed. Verified by diffing
every one of the 513 specs against a pre-run snapshot.

Four surfaces, the same four `repair-scaled-notes.ps1` learned to patch: `scaler.ing[].buy`,
`ingredients_display[]`, `cost_lines[]`, and `head.recipeIngredient[]` (the JSON-LD Google reads — a
three-surface fix leaves the structured data stale while the visible card reads clean).

Carried onward so the copies do not go stale (`repair-stops-at-source-of-truth`):
- `out\measure-vs-grams-carry.json` → `sync-recipesdb-buy.ps1 -Apply` → **292 labels into `recipes-db.json`**
- `gen-planner-data.ps1` → `planner-data.js` + `public\planner-data.json`

### Knowing which side is wrong is not the same as being able to write the right one

Every replacement is re-derived from the grams by the generator's own function, then put through a gate
that refuses anything that would not read as a recipe. **39 rows failed that gate or had no verdict** and
were reported rather than guessed:

- a fraction of a tablespoon (nobody owns a quarter-tablespoon measure)
- a package noun on an Ingredients list — the defect `cook-measure-lib` exists to prevent
- a fractional count of a countable thing (`6.7 peppers, from a jar`)
- a writer tail carrying a **second quantity**, where splicing the head leaves the label arguing with
  itself (`3 oz cubed + 3/4 cup shredded`, `1 tsp (patties) + 1/2 tsp (gravy)`)

## Two things that came out of the plumbing

**`pipeline\friendly-amt-lib.ps1` is new.** `FriendlyAmt` wrote most of the catalog's labels but lived as
an inline copy in `build-v2-spec.ps1` and a second in `build-run-specs.ps1`. Anything needing to
re-derive a label had a choice between a fourth copy and hand-computing. It now lives in one place;
`Test-FriendlyAmtAgainstCatalog` re-derives **5,704 of 6,999** stored labels byte for byte, which is what
keeps the port pinned to the builder that wrote them.

**The library gained a teaspoon rung.** `FriendlyAmt`'s small-amount branch was `if ($tb -and $g -lt 120)
{ ... ' tbsp' }` with nothing under it, so a spice lighter than one tablespoon printed as a *fraction* of
one — `Black Pepper: 0.25 tbsp`. Items with no tbsp density at all printed `0.07 oz`. Both are on live
cards today. `Get-FriendlyAmt -Faithful` still reproduces the old behaviour and is what the fidelity test
grades against.

## Still open

1. **The 39 refused rows** — `repair-measure-vs-grams.ps1 -Report` lists every one with its reason. The
   2 `grams-suspect` rows are the ones that matter; the rest need a hand-written label.
2. **`out\filler-1lb-underbar.csv` — 46 rows, 45 recipes.** The `"1 lb"` filler class continues below the
   screen's 2x bar (41 Rice, 4 Carrots, 1 Shredded Carrots). These are the *same* defect and the same
   argument applies, but **they have not been individually source-checked** and are not swept in on that
   basis. Note 23 further `"1 lb"` rows in the catalog are TRUE (bacon, ham, peas, kale at ~454 g) and
   must be left alone — this is not a "replace every 1 lb" job.
3. **Cards are not rebuilt or republished.** `db\built\<slug>.body.html` embeds `buy` in the scaler
   payload, so the 85 slugs in `out\measure-vs-grams-slugs.txt` need `build-card2.ps1` + a republish
   before readers see any of this. Nothing has been pushed to Ghost.
4. **`cheeseburger-rice-bowls` cites a dead source** (`budgetbytes.com/cheeseburger-rice/` → HTTP 404),
   and 4 specs carry no `source_url` at all: `chicken-parmesan-pasta`, `turkey-taco-rice-skillet`,
   `beef-burrito-bowls`, `turkey-bolognese-penne`. Their 13 flagged rows cannot be adjudicated this way.
5. **Two fidelity items noticed in passing, not acted on:** `ground-beef-gyro-bowls` buys **dried** dill
   where the source calls for 2 tbsp **fresh** (not the same amount), and `salisbury-steak-potato-bowls`
   buys Dijon where the source uses regular mustard. These belong on `out\fidelity\engine-pass-notes.md`.
