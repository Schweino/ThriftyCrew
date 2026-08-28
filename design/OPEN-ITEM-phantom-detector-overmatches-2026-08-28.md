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
