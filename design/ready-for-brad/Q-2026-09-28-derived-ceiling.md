# Q: should the derived price-sanity ceiling ever admit a real, expensive product?

**Where this came from:** queue item `2026-09-22-0c812e`, three prior rounds (plan-2026-09-22-5,
plan-2026-09-22-9, plan-2026-09-25-6, plan-2026-09-25-15, plan-2026-09-27-3, plan-2026-09-27-4),
none of which reached you - the question was written into plan files but never into this
directory. Re-measured fresh against today's board (comparison-2026-09-28) rather than trusting
the old numbers.

## The situation

`grocery/derived-band-lib.ps1` derives a sanity ceiling for each commodity from its own price
evidence (no hard-coded bands, per your standing rule). A row priced above that ceiling is
refused and never reaches the board - the matching worklist calls this "band-refused."

There are 1,284 band-refused rows on today's worklist. Measured what they actually are:

- **1,120 of 1,284** are dear rows at a store that already shows a *cheaper* row for that same
  commodity. Admitting them could never change a price on the board - a different row is already
  winning that cell. Refusing them costs nothing.
- **12** are basis errors or wrong products the ceiling correctly caught (slices read as whole
  loaves, a trash-bag row keyed to "bleach"). Refusing them is working as designed.
- **22** are the real question: a dear row, at a store with *no other cell* for that commodity, so
  admitting it would be the only way that store shows a price at all for that item. Examples:
  - Aldi, Head & Shoulders shampoo, $0.5576/oz (band tops out at $0.4705/oz)
  - Family Fare, freeze-dried basil, $21.39/oz (band tops out at $16.60/oz)
  - Hy-Vee, Milk-Bone dog treats, $0.82/oz (band tops out at $0.51/oz)

## The choice

**Option A - keep the ceiling as an absolute wall.** These 22 stores simply show no price for
these items rather than a real but expensive one. Nothing on the board is wrong today either way;
this is a coverage gap, not a defect. **This is the recommendation** - a ceiling with an exception
is a ceiling someone has to keep re-tuning by hand, and 1,120 of the 1,284 refusals prove the
ceiling is doing real work.

**Option B - let a row through when it's the only price a store has for that commodity**, even
above the derived ceiling, so a shopper sees *some* real number instead of nothing. Costs: a wrong
product with an inflated price could now reach the board in exactly the cases where nothing else
catches it (no cheaper cell to compare against).

## If you pick A (recommended)

Queue item 2026-09-22-0c812e closes no-code-change, and `audit-band-refusals -Tighten` drops the
130 keys that are no longer flagged today. No board change.

## If you pick B

Needs a follow-up design pass: how a "no other cell" exception is proven (so it can't be gamed by
a store simply not carrying other sizes), and a MUST FIRE / CLEAN TWIN pair before it ships.
