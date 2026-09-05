# BRIEF: when neither the name's quantity nor Walmart's own arithmetic is defensible

queue_id: walmart-size-conflict-2026-09-05
shipped_commit: (none yet - if this field names a commit, the work is DONE: verify it and report,
do not rebuild)
author: Opus 5, 2026-09-05. Every number below was measured today against the live capture files and
the live board.
ruled by: Brad, 2026-09-05 - the bouillon cell is ruled wrong now (done, see below) and the parser
question is written up rather than patched at the end of a session.
found by: the SANITY guard's own price flag on 2026-09-05, queue item 2026-09-05-521f1c.

## 1. What happened, and it reached readers

`bouillon` crowned Walmart at **$0.0813/oz, 7.6x too cheap**, and published.

    product name  "Knorr Select Vegetable Base, Shelf Stable Granulated Bouillon, 1.82 pounds"
    Walmart says  $17.97, unit price $1.65/lb
    capture kept  size 10.891 lb  (= 17.97 / 1.65)
    qty_basis     "package; qty derived lp/up; no name quantity (1.82) reproduces Walmart's 1.65"
    truth         1.82 lb -> ~$0.62/oz, which sits with Baker's $0.38 and Hy-Vee $0.63

Walmart's own displayed unit price is wrong for this item. The capture believed it over the name.

A second, independent fault on the same cell: the board quoted **$14.18 from a 2026-07-15** Bellevue
capture, while the two most recent captures of item id 198431752 both read **$17.97**. That is the
90-day union holding a stale row - the shape of `walmart-marketplace-rows-pollute-the-union`,
arriving from the price side rather than the seller side. **Not addressed here.**

RULED AND BLOCKED 2026-09-05: `known-wrong.json` now carries
`bouillon|Walmart|knorr-select-vegetable-base-shelf-stable-granula` with verdict `wrong-size` and
evidence saying it MUST BE REVERSED once the parser is fixed - the product really is bouillon, so the
entry is not a wrong-product claim. `audit-known-wrong.ps1` fires on it (`BLOCKED ... crown=True`) and
the gate is red on purpose until the 08:00 rebuild drops the cell.

## 2. The rule, and why it is NOT simply wrong

`grocery\build-walmart-deals.ps1:275-297`. It asks one exact question: **does a quantity stated in the
product name reproduce the unit price Walmart displays?** If yes the name is precise and is used; if
no, the name "is describing something else" and Walmart's arithmetic is kept.

That rule is load-bearing and its comment records why a percent-drift threshold cannot replace it:
Sam's prints Q-tips at "$0.01/ea" because it rounds 0.0053 up, so lp/up derived 888 swabs for a box
the name correctly calls 1665 ct - an 87% "drift" that a 51% threshold rejected, publishing $0.01 for
a $0.0053 swab. **Do not reintroduce a drift threshold, and do not flip the preference to the name.**

What the rule lacks is a third branch: *neither number is defensible*. It has "the name reproduces
their arithmetic" and "it does not, so keep theirs" - and no "so keep nothing".

## 3. The blast radius, measured 2026-09-05

    walmart rows carrying a qty_basis            57,111
      name-vs-derived CONFLICT branch             4,207   (7.4%)
    Walmart cells on the live board                 529
      whose size came from the conflict branch       32
      ...of those, holding the CROWN                 10

The ten crowns: bouillon, chicken-livers, corned-beef-brisket, facial-tissues, fresh-oregano,
fresh-sweet-italian-turkey-sausage, deli-ham, hand-soap, veggie-sausages, whole-chicken.

**MOST OF THE CONFLICT IS NOT AN ERROR, and this is the trap for whoever builds the fix.** The largest
disagreements are unit mismatches, not faults:

    3706.8x  (4 pack) Scott ComfortPlus Toilet Paper, 12 Mega Rolls   derived 14827   name 4
    1699.0x  Charmin Ultra Soft Forever Roll Refill                   derived  5097   name 3
     720.0x  (24 pack) Kleenex Ultra Soft Facial Tissues              derived 17281   name 24

Walmart prices tissue per SHEET; the name counts PACKS. Both numbers are correct about different
things. A fix that refuses on magnitude alone would refuse all of these, and they are fine.

## 4. What is open, and the bars any fix must clear

**The question for the builder:** how does a capture tell "Walmart's unit price is for a different
unit than the name counts" (fine, keep the derived value) from "Walmart's unit price is simply wrong"
(publish nothing)? Bouillon is the second case: name and derived are BOTH in pounds, the units agree,
and the numbers disagree 6x. The tissue rows are the first case: the derived quantity is in sheets
while the name counts packs, and nothing in the row says so.

A candidate shape, NOT a decision - the builder measures before choosing:
  - when the name states a quantity IN THE SAME UNIT the derived one is expressed in, and the two
    disagree beyond some factor, neither is defensible: emit no price for that row and say why in
    `qty_basis`. Fail closed, like every other undefendable number in this estate.
  - the tissue class is then untouched, because "4 packs" and "14,827 sheets" are not the same unit.

**Bars, before the build:**
- Re-measure the 4,207 split by same-unit vs different-unit. The same-unit conflicts are the target
  set; report its size. If it is not materially smaller than 4,207, this shape is wrong.
- The Q-tips case must still resolve to the NAME (1665 ct, not 888). It is the reason the rule exists;
  a fixture pins it or the fix is refused.
- No cell that is correct today may lose its price. Diff the board's 529 Walmart cells before and
  after; every drop is named and justified individually.
- bouillon resolves to ~$0.62/oz, at which point the `known-wrong` entry is REVERSED with
  `add-known-wrong.ps1 -Reverse` naming this brief.

## 5. What this brief deliberately does NOT do

- It does not change `build-walmart-deals.ps1`. Nothing was patched.
- It does not touch the drift-threshold question - that road is closed by the Q-tips measurement.
- It does not address the stale-price half (a July row winning over two newer captures of the same
  item id). That is a separate defect in the 90-day union and deserves its own brief.
- It does not verify the other nine crowned cells. They look plausible on inspection and plausible is
  not verified; checking them is the cheapest way to learn whether bouillon was alone.
