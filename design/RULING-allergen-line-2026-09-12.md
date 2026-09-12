# RULING - every recipe card carries a generated allergen line

**Brad, 2026-09-12, backlog I144.** This is a ratified ruling, not a draft or a proposal.

## The ruling, verbatim

> Every recipe card carries a 'Contains' line listing which of the nine major allergens (milk, eggs,
> fish, shellfish, tree nuts, peanuts, wheat, soy, sesame) its ingredients include, derived
> mechanically from the ingredient map, naming the specific nut or shellfish, and explicitly calling
> out hidden sources such as anchovy in Worcestershire sauce and shellfish in oyster sauce. The line is
> generated, never hand-written, and a publish check refuses a card whose allergen line is missing or
> disagrees with its ingredients. A short note says it reflects the recipe as written and readers
> should check the labels of the brands they buy.

So the answer to the question I144 rung 1 put to Brad - top-nine set, or only the hidden ones a reader
cannot infer from the names - is **the top nine, with the hidden ones called out separately on top**.

## Why the ingredient list was not disclosure enough

Measured at rung 1 on 2026-09-12 and re-measured here after the derivation existed. **217 of 584
recipes (37.2%) carry at least one of the nine that a reader could not get from the ingredient
NAMES.** Rung 1 saw the two biggest cases and put the figure at 7.2%, because it could only count
Worcestershire sauce and oyster sauce by hand; the mechanical derivation finds the rest.

| | recipes of 584 |
|---|---|
| carry at least one of the nine | 484 (82.9%) |
| carry at least one HIDDEN source | 217 (37.2%) |
| carry none of the nine | 100 (17.1%) |

Hidden-source recipes by allergen: wheat 132, soy 45, fish 42, tree nuts 32, shellfish 24, milk 18,
sesame 2, eggs 1. The fish figure of 42 is exactly rung 1's Worcestershire count, which is the
cross-check that the derivation is finding the thing that started the item.

Per allergen, over the same 584: milk 308, wheat 309, soy 132, eggs 100, fish 68, sesame 43,
tree nuts 41, shellfish 24, peanuts 17.

## What was built

| Piece | File |
|---|---|
| The vocabulary, the derivation, and the only spelling of the line | `meal-prep/lib/allergen-lib.ps1` |
| The classification of all 353 food rows of the ingredient map | `meal-prep/db/allergens.json` |
| The generator that writes it and proves it is complete | `meal-prep/pipeline/gen_allergen_table.py` |
| The renderer, above the paywall | `meal-prep/pipeline/build-card2.ps1` |
| The publish check that refuses a missing or disagreeing line | `meal-prep/pipeline/audit-allergen-line.ps1` |
| Where the refusal is wired | `meal-prep/pipeline/wave-publish.ps1` P5 gate table |

## The four decisions the ruling left open, and what was chosen

**1. The line sits ABOVE the paywall.** A reader with a peanut allergy must not have to buy a
membership to learn the recipe has peanuts. The ingredient list is already free - the paywall cut was
moved below it on 2026-08-31 precisely so the ingredients are crawlable and readable - so putting the
mechanical summary of that same list behind the gate would have the page publish the evidence and sell
the conclusion. It renders directly under the list it derives from, which is also where a reader looks.

**2. The classification lives in its own file, `db/allergens.json`, not as a field on each row of
`db/ingredients.json`.** Brad's ruling says "derived mechanically from the ingredient map", and it
still is: the key is the ingredient map's own item name, and the generator refuses to write unless
every row of `ingredients.json` is classified. The separate file buys three things. It keeps the nine
readable as one document with the classification rule stated once at the top, which matters because
this is a judgement about food and not a lookup. It avoids reformatting a 117 KB hand-authored file
that many scripts read, where a style-only rewrite is a large diff and a real risk for no gain. And it
gives the reader-safety data its own review surface and its own history. The drift risk that a second
file creates is answered by the completeness check, which is a named case in the push gate.

**3. What counts as "contains", stated before any row was classified.** An allergen is listed when it
is inherent to the food the ingredient NAMES: the food cannot be that food without it, or the standard
US supermarket formulation of that named product carries it as a defining component. An allergen only
SOME brands add is not listed, because that is a guess rather than a derivation, and the card's own
note is what covers it. Two consequences that look like omissions and are not: refined oils are exempt
from FALCPA allergen labelling, so soybean oil alone does not make a row soy; and "may contain" is not
recognised by FALCPA and is voluntary, so it never appears. The rule is repeated in `allergens.json`'s
own `rule` field, where the next person to add a row will actually read it.

**4. Coconut is listed, as a named tree nut.** The FDA's tree-nut list includes it. Because the ruling
already requires naming the specific nut, a reader who is allergic to almonds and eats coconut reads
"tree nuts (coconut)" and is not misled, which is the outcome that made this safe to decide either way.

## What makes the check worth having

It does not re-implement the rule and compare conclusions. It re-derives the line through the same
`Format-TcAllergenLine` the card was rendered with and compares the bytes, so the only way to pass is
to carry the line this estate's one allergen rule produces for that spec's CURRENT ingredients. Two
implementations of one rule drift: the price formatter had five copies, and the notes-vs-bid check
still has two.

The failure it exists for is the one the build cannot catch. `build-card2` generates the line, so a
freshly built card can never be missing one. A STALE card can: a spec whose ingredients changed after
the card was built, or a card built before this ruling landed. Those cards are on disk and publishable,
and their line is wrong in the direction that matters.

## What is NOT done, and it is the larger half

**The 584 cards already live carry no allergen line.** Measured here: `audit-allergen-line` over the
whole catalogue reports `584 of 584 missing`, exit 1. The mechanism is what landed; the backfill is a
rebuild and republish of the live catalogue, which is a Ghost operation against a live paid site and
the expensive part of any card change. It is filed as its own backlog item rather than smuggled into
this one.

Until that backfill runs, the unscoped `audit-allergen-line` is a RED REPORT on purpose and is
deliberately not wired into any gate. What IS wired is the wave-scoped run in `wave-publish`, and it is
green on a freshly built wave - measured on `american-goulash-pasta`, exit 0, `clean n=1`. The ops rule
against adding a gate that is red on day one is kept, and the number that says how far there is to go
is a command anybody can run rather than a claim in a document.

## Verified

- `audit-allergen-line.ps1 -SelfTest`: exit 0, 23 of 23 cases.
- `build-card2.ps1 -SelfTest`, `wave-publish.ps1 -SelfTest`, `audit-unbid-ingredients.ps1 -SelfTest`: exit 0.
- `gen_allergen_table.py`: exit 0, 353 items classified, 104 carrying at least one of the nine, 35
  carrying a hidden source. Its completeness assertion caught a genuinely unclassified row on its first
  run (`Sweet Potatoes`), which is the reason it asserts rather than defaults.
- A real card built end to end: `american-goulash-pasta`, whose ingredient list names Lea & Perrins and
  never says anchovy, now renders `Contains: milk, fish (anchovy), wheat.` with
  `Easy to miss: fish, from the anchovies in Worcestershire sauce.`
- All 584 specs derive a line with zero `unclassified` findings, which is the evidence that the table
  covers the live catalogue and not just the rows somebody happened to think of.

**Not looked at, and said plainly rather than implied:** the 375px mobile check was NOT performed. This
session has no browser tool, so no screenshot was taken and no rendered page was read. The line is a
single `<p>` with no fixed width, no `white-space: nowrap` and no unbreakable token, so there is no
mechanism in it for a horizontal scroll, but that is reasoning about CSS and not a look. **The backfill
item owes the 375px check before the republish ships.**
