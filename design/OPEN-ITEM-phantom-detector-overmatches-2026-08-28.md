# CLOSED - the PHANTOM gate is green again, on one detector fix and four spec fixes

**RESOLVED 2026-08-28** (commit below). The gate exits 0, every class is at or under the 2026-08-05
baseline, nothing was re-baselined, and publishing is unblocked. The diagnosis below stands as written and
is kept verbatim; **the resolution differs from its proposed fix on two of the three findings, and the
reasons are at the bottom.** Read the resolution before building anything from the "The fix" section - one
of the three rules it proposes would blind the class to the case it was founded on.

# OPEN ITEM - the PHANTOM gate is blocking every publish on three FALSE positives

Brad ruled 2026-08-28: "We should fix everything so we are 100% accurate." Diagnosis is complete and
below; the code change is NOT started.

## The state

`meal-prep\pipeline\audit-spec-contradictions.ps1` reports **PHANTOM: 3 now, baseline 0** and exits
FAIL. `wave-publish.ps1` runs this gate estate-wide, so **nothing can publish** until it is green.
Wave 11 (`honey-bbq-chicken-mac-and-cheese`) is NO-GO partly on this.

## It was NOT the 10:57 reanchor - the auditor's inference was wrong

The wave-11 auditor observed that all three specs carried identical mtimes of 2026-08-28T10:57:26 and
concluded "whatever ran at 10:57 introduced or exposed these". That was the catalog-wide
`reanchor-machine-fields.ps1`, and it is a red herring:

* `reanchor` rewrites **all 587 specs** on every run - the estate's own standing note is
  "Spec mtime is not evidence of a recost".
* `git diff` over `beef-rendang-rice-bowls.json` for this session's commits shows **no prose lines
  changed**, only `cost_ps` / `costPerServing`. The spec was last committed 2026-08-17.

The real cause is a **stricter detector meeting a stale baseline**:

| | |
|---|---|
| `a858fbe6` | 2026-08-27 - "a synonym became a phantom". PHANTOM detection changed. |
| `meal-prep\out\spec-contradictions-baseline.json` | last committed **2026-08-05**, records `PHANTOM: 0` |

## All three findings are FALSE POSITIVES - verified against the prose

**None of these is a real defect.** Each recipe is correct as written.

### 1. `beef-rendang-rice-bowls` - "coconut oil"
> "the beef starts frying in **the coconut oil that separates out** and everything turns deep brown"

The oil RENDERS OUT of Coconut Milk, which the recipe buys. Nobody shops for coconut oil here. This
is a substance that emerges during cooking from a bought ingredient.

### 2. `mediterranean-chicken-w-marinade` - "cooking spray"
> "a casserole dish sprayed with **cooking spray or brushed with olive oil**"

An OR-alternative whose other branch, **Olive Oil, is a bought ingredient**. The reader can already
make the dish as shopped.

### 3. `blackened-chicken-with-mango-salsa` - "salsa"
> "**Start with the salsa** so the flavors have time to get friendly. Dice the man..."

The salsa is ASSEMBLED in that very step from mango, red onion, cilantro and lime - all bought. Note
the dish is *named* "Blackened Chicken with Mango Salsa".

`PHANTOM_MADE` already covers "into a/the <x>" and "makes a/the <x>", but this sentence says neither.

## The fix - three new suppression rules, in the file's existing style

`meal-prep\pipeline\spec-contradiction-lib.ps1` already carries six named rules (`PHANTOM_TAIL`,
`PHANTOM_FREE`, `PHANTOM_MADE`, `PHANTOM_CMP`, `PHANTOM_SUBJ`, `PHANTOM_CONSTITUENT`), each commented
with the measured false positive that motivated it. Follow that convention exactly - a named variable,
a comment citing the real slug, and a fixture. They are applied in the per-occurrence loop at
**lines 393-399**, with `$spec` in scope (so `$spec.name` is available).

1. **RENDERED** - the name is followed by a rendering phrase (`that separates out`, `renders out`,
   `cooks out`, `melts out`). A substance that comes OUT of a bought ingredient is not shopped.
   Cheapest and safest of the three; pure regex on `$rest`.

2. **DISH NAME** - a food named in `$spec.name` is a component the dish is named after and assembled
   from, not a purchase. Covers case 3. Tight and principled.

3. **SATISFIED ALTERNATIVE** - the name is followed by `\s+or\s+` and the alternative span names a
   food the recipe OWNS. This is the only one needing more than a regex: it must test the alt span
   against `$own`. Suggest scanning the next ~90 characters and testing owned ingredient ITEM names
   (not whole `ingredients_display` lines, which are noisy with buy strings).

## Do NOT re-baseline

Moving `PHANTOM` from 0 to 3 in `spec-contradictions-baseline.json` would make the gate green in one
edit. It would also bury three detector bugs and permanently blind the check to the real phantom class
it exists for - the `slow-cooker-dr-pepper-pulled-pork-bowls` case, whose step pours a soda that
appears in no ingredient list at all. The self-test's dr-pepper twin must keep firing.

## Also pending, same session

* **Brad ruled**: `Reduced Fat Cheddar Cheese` becomes its OWN commodity with discovered pricing. It
  currently resolves to `cheddar-cheese`, which floor-maps to the generic `shredded-cheese` basket
  whose crown is Sam's Club part-skim MOZZARELLA at $0.1521/oz - a cheddar line priced by mozzarella.
  An attended 7-store capture was dispatched 2026-08-28 with Brad at his machine.
* **Three mints waiting only on a registrar prescription**, evidence already captured: `Baby Potatoes`
  (6 stores), `Frozen Cauliflower Rice` (4), `Whole Wheat Flour` (3).
* **Latent, not yet hit**: `build-intake-skeleton.ps1:277` joins merged buy strings only when they
  DIFFER, so two identical lines sum grams while showing one occurrence's amount. Masked today by a
  separate defect - two mapper lines sharing an identical `raw` collapse on the assembler's join key,
  which is why `honey-bbq` shows "3 1/2 teaspoons" against 22 g of garlic powder. Fix the pair
  together or neither is provable.
---

# THE RESOLUTION (2026-08-28)

Brad's standing ruling for this work was **"we should fix everything so we are 100% accurate"**. Read
against that, only ONE of the three findings is a detector bug. The other two are cards that are not
accurate, and suppressing the detector would have left both of them on the site.

## 1. beef-rendang - AGREED, detector bug. Fixed as a CONSTITUENT, not as a RENDERED regex.

The diagnosis is right that the oil comes out of the bought coconut milk. It is fixed by the rule that
already exists for exactly this - `PHANTOM_CONSTITUENT`, whose founding case is baked-ziti's turkey soaking
up "the tomato flavor" of its bought marinara - with a third entry, `'coconut milk' = @('coconut oil')`.

Preferred over the proposed **RENDERED** rule because RENDERED is keyed on the SENTENCE and the constituent
rule is keyed on the PURCHASE. "the butter that separates out" would pass a RENDERED regex in a recipe that
buys no butter; the constituent entry cannot fire unless the recipe's own ingredient line carries every word
of "coconut milk".

The entry also forced the rule's keys and values from single tokens to PHRASES, every word required. Keyed
on the bare token `coconut` with the bare value `oil`, the new entry would have forgiven a step naming Olive
Oil, Sesame Oil or Vegetable Oil in ANY recipe holding a can of coconut milk - `oil` is a token of all of
them. The two original single-word entries read identically under the stricter rule. Both halves are frozen
in the self-test, including the over-forgiveness twin.

**One thing the diagnosis missed, and it is the whole reason this fired now.** The cause was not only
`a858fbe6` meeting a stale baseline. `db\ingredients.json` gained a **Coconut Oil** row and a **Cooking
Spray** row on 2026-08-28 in `f3911bff` ("eleven of thirteen names resolved"). This class is
vocabulary-driven: it can only see a phrase the estate knows. Two of the three findings appeared that day
because the vocabulary learned two words, not because anything about the recipes changed - the same
mechanism written up for Shredded Cheese the day before. Salsa has been in the vocabulary since the engine's
founding; that third finding arrived with the prose, in `b488154a`, the same day.

## 2. mediterranean-chicken - NOT a false positive. The card was fixed.

> "a casserole dish sprayed with cooking spray or brushed with olive oil"

The proposed **SATISFIED ALTERNATIVE** rule would teach the gate that a card may tell a reader to use a food
the shopping list never bought, as long as some other branch of the sentence is covered. That is the
opposite of "100% accurate", and it is a strange thing for a check whose whole message is *it cannot be made
as shopped* to start accepting.

The honest fix is one word of prose: the unbought branch goes, and the dish is brushed with the olive oil the
recipe already buys 11 tablespoons of. Nothing is lost to the reader, and the gate keeps its meaning.
Catalogue-wide sweep first: `cooking spray` appears in the steps of exactly ONE recipe. This was not a
pattern that needed a rule.

## 3. blackened-chicken - the prose was fixed, and the proposed DISH NAME rule must NOT be built.

The salsa is genuinely assembled in that step, so the finding IS false. But the proposed suppression -
**a food named in `$spec.name` is a component the dish is named after** - is unsafe, and this document
already contains the proof:

> the `slow-cooker-dr-pepper-pulled-pork-bowls` case, whose step pours a soda that appears in no ingredient
> list at all

**That recipe is NAMED after the missing bottle.** The lib's own comment says so in as many words. A
DISH NAME rule is precisely a rule that forgives the founding case, and the fact that the self-test's twin
happens to survive it - the fixture's food is "Zero-Sugar Soda", which shares no word with the slug - is
luck, not safety. A recipe called "Chicken with Mango Salsa" that genuinely forgot to book its salsa would
be waved through forever.

So the prose was fixed instead. "Start with the salsa" is indistinguishable, to any matcher, from "start
with the rice" in a recipe that buys no rice. The step now says it MAKES the salsa - which is both true and
what the existing `PHANTOM_MADE` exemption already reads. No new rule.

## Also fixed: the two advisory UNUSED findings, which are this same defect pointed the other way

UNUSED is not in the ratchet's class list, so it never gated - but 4 against a baseline of 0 is a reader
paying for a food and never being told to use it.

* `chicken-rice-and-broccoli` bought dried basil, dried parsley, garlic powder and onion powder, then folded
  all four into "all of the dried spices". The step names them now. (Onion powder was never reported: the
  matcher forgives it on the "onion" in "the diced onion", which is Yellow Onion's mention. A real miss,
  left alone - it is the documented generous-containment trade, not a new bug.)
* `ground-beef-cottage-cheese-bowl` stopped after browning the beef. The cottage cheese, the hot honey, the
  avocado and the red pepper flakes ARE the bowl, and nothing told anyone to build it. It has an assembly
  step now.

## Do NOT re-baseline - confirmed, and it was never necessary

Every class came back to the baseline as written on 2026-08-05: **PHANTOM 0, UNUSED 0, UNMEASURABLE-QTY 21,
ABSURD-UNIT 0.** The ratchet was not out of date. It was right, and two live cards were wrong.

## What run-gates could not tell anyone

`run-gates` runs `-SelfTest`. `audit-spec-contradictions.ps1`'s self-test was GREEN on main the entire time
its catalogue-wide run was red, and 139/139 gates passed on the broken tree. The full read only happens in
the daily chain and in `wave-publish`. A green gate run is not evidence this class is clean.

## Verification

* audit + repair self-tests pass; the audit gains 2 assertions (the coconut clean twin and its
  over-forgiveness twin).
* the full audit over 587 specs exits 0.
* `run-gates` from a worktree OUTSIDE `.claude\worktrees\` (with `catalog-digest.json`, `db\built` and the
  board copied in): **139 passed / 0 failed before AND after, identical case-name set.**

## Still open

The four edited specs need their **cards rebuilt and republished** before a reader sees any of this. The
spec layer is fixed; the built cards are gitignored and unchanged.

The four unrelated items under "Also pending, same session" below are untouched by this work.
