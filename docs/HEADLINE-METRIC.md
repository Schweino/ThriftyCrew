# The headline metric, and the denominator we price on

**This is a ruling, not a draft.** Brad ruled it on 2026-09-12 against backlog I140, and the paragraph
below is his, verbatim. It is recorded here because the number the whole product is sold on had an
unstated denominator: `cost_per_serving` is on every recipe card and in every board-fed dataset, and
nothing in this estate said that we chose it, over what, or why. `.claude/rules/measurement.md`
already rules that a rate is printed with its denominator and that a verdict carries its rubric. This
is that same rule one level up, applied to the business's own headline number.

## The ruling, verbatim

> Thrifty Crew prices on cost per serving, and that is a deliberate choice: our reader is a
> budget-first family deciding what dinner costs, and a serving is the unit they buy and eat. Cost per
> serving is not a claim about nutritional value, and we never present a cheaper recipe as a better one
> on that number alone. Every recipe card also carries protein per serving, so a reader sees value
> beyond calories. We will not add a nutrient-density metric, because no standard one exists that we
> could compute honestly from our data.

## What it governs

The denominator is the SERVING, everywhere, and the per-serving basis is already shared by the cost
and the macros on the same line of the card:

| Where | What it carries |
|---|---|
| `meal-prep/pipeline/build-v2-spec.ps1` | writes `cost_per_serving` and `cost_per_serving_true` into a spec, from `macros_per_serving` for the stat block |
| `meal-prep/pipeline/build-card2.ps1` | the card's stat line: servings, calories, protein, carbs, fat, live price |
| `meal-prep/build-hub-grid.ps1`, `build-dinner-data.ps1`, `build-cheapnow-data.ps1`, `build-stretcher-data.ps1`, `gen-planner-data.ps1` | the reader-facing datasets, all keyed on the same per-serving cost |
| `meal-prep/pipeline/sync-recipesdb-cost.ps1`, `audit-cost-plausibility.ps1` | keeping the published number equal to the one the board supports |

## What was checked, 2026-09-12, at commit 4fc53b55a

- **584 of 584 built recipe bodies** under `meal-prep/db/built` carry the stat line with a protein
  figure on it, read by counting `g protein` in every `*.body.html`. So the ruling's "every recipe
  card also carries protein per serving" is a measured statement, not an intention.
- That protein figure and the calorie figure beside it come from the spec's `macros_per_serving`
  (`build-v2-spec.ps1:359-362`), so the macros on the card share the cost's denominator exactly. A
  reader comparing two cards is comparing like with like in both columns.
- When I140 was filed, `cost per calorie` and `nutrient densit` were **0 of 8,423 tracked files**.
  Nothing here had ever stated the choice, which is the whole reason this file exists.

## The argument against, recorded so nobody re-derives it

The source is a course item, verbatim: *"When people talk about fast food being cheaper than fresh
food, they're often referring to the fact that the cost per calorie of highly processed food is lower
than that of fresh, whole food. ... But, if we instead look at the cost of food per unit of nutrient
density, then buying fewer calories of higher nutrient density food is a much better use of our food
budget."* The argument is real, and I140's own example is the clearest statement of it: a per-serving
cost on a 14-serving batch of a 563-calorie dish is close to a cost per calorie, and that is the
denominator which makes highly processed food look like the rational purchase.

Brad's paragraph above is the answer, and it stands. The mechanical half of "no standard one exists
that we could compute honestly from our data" is worth keeping beside it, because it is the part a
future session can check:

- `meal-prep/food-macros-db.json` holds **441 rows**. Every one carries four fields - `calories`,
  `protein_g`, `carbs_g`, `fat_g`. `fiber_g` is present on **98 of 441**. There is **no sodium field
  and no sugar field on any row**, and no micronutrient of any kind. Counted 2026-09-12 by reading
  the field names of all 441 items.
- The published nutrient-density indices of the NRF family score a food on encouraged nutrients
  (protein, fibre, vitamins, calcium, iron, potassium) against limited ones (saturated fat, added
  sugar, sodium). That is a statement about an external standard and not a measurement of ours. We
  hold **none** of the limited nutrients and, beyond protein, **one** of the encouraged ones on 98 of
  441 rows. A density score computed from that would be a number we invented, and this estate does
  not publish those.
- Related and deliberately NOT a licence to compute one: `meal-prep/db/food-label-captures.json` does
  record `sodium_mg`, and the fact that the food DB drops it is backlog I145's open question. That is
  a question about the capture-to-DB seam. Answering it yes would not produce a density index either.

## What the ruling permits, and what it forbids

- **Permitted:** ranking, sorting and filtering on cost per serving, and saying so in price words.
  "Cheapest dinner this week" is a claim about price and is true.
- **Forbidden:** presenting a cheaper recipe as a *better* recipe on cost per serving alone, and any
  wording that lets the cost number read as a nutrition verdict. The neighbouring rule already has a
  mechanism: Brad's no-health-word ruling of the same day (backlog I138) is data in
  `meal-prep/pipeline/forbidden-prose-global.json` and is gated by
  `meal-prep/pipeline/audit-forbidden-prose.ps1`, so *healthy*, *clean*, *guilt-free*, *light* and
  *nutritious* cannot reach a title or reader-facing prose at all. Backlog I141 is the measurement
  that the catalogue is clear of the wider wellness-claim shape.

## Why there is no gate behind this, deliberately

`ops/audit-ruling-drift.ps1` exists because a ruling document moves without a deploy while the script
enforcing it does not notice. It compares a ruling's stated numbers and names against what a script
contains. **This ruling states no number and names no threshold**, and what it rules is that a second
metric is NOT added, so there is nothing for a script to drift away from and no production caller for a
detector over it. `.claude/rules/ops-and-gates.md` refuses a detector over a case that cannot occur and
a gate that would be red on day one, and this would be both.

**What carries it instead is a pointer at each place the number is handled**, because a ruling in a
document nobody opens is the same as no ruling:

- `meal-prep/pipeline/build-v2-spec.ps1`, on the line that writes `cost_per_serving` - where the number
  is produced.
- `meal-prep/pipeline/build-card2.ps1`, above the stat line - where a reader sees it.
- `docs/QUALITY-ATTRIBUTES.md`, under `meal-prep/`, beside the cost-fidelity attribute it qualifies.

**One more pointer is wanted and is NOT written yet:** a line in `.claude/rules/meal-prep.md`, which
loads automatically for anyone touching that directory and is the cheapest channel there is. The run
that landed this ruling was not permitted to write under `.claude/`, so it is left as a one-line
addition for whoever next edits that file, and it is recorded here rather than left as an intention
somebody has to remember.

## If this ever changes

A different denominator, or a second metric beside this one, is a new ruling from Brad and is recorded
in this file with its date. It does not arrive because a source argues for it: the argument is above
and it has already been answered once.
