# OPEN ITEM - the food DB now carries two Panko rows and they disagree on fat

Surfaced 2026-08-28 by the daemon self-test's LOCKSTEP fixture, which watches the live food DB for a
FIFTH near-name collision. It found one, which is the fixture doing exactly its job.

## The two rows

| item | basis | cal | protein | carbs | fat | source |
|---|---|---|---|---|---|---|
| `Panko Breadcrumbs`  | 30 g  | 110 | 4    | 24   | **0**    | Kikkoman 8 oz label |
| `Panko Bread Crumbs` | 100 g | 357 | 14.3 | 71.4 | **3.57** | fdc:1862715 |

Normalised per gram they agree closely on calories, protein and carbs - and disagree on FAT:

* label row: 0 g per 30 g serving
* FDC row: 3.57 g per 100 g, i.e. about 1.07 g on that same 30 g serving

## Why it was not merged

This is not a spelling. It is a real question about which basis is right, and the estate's rule is
that Brad confirms row removals. The label almost certainly rounds - a US label may print 0 g when
the serving is under 0.5 g, but 1.07 g would round to 1 g, not 0 - so the two cannot both be correct
and the label is the likelier error. That is a judgement, not a fact I can prove from here.

Note the write path handled this correctly and unprompted: the 2026-08-28 reuse rule declines to mint
a duplicate ONLY when the colliding rows agree on every macro. These disagree, so it wrote the row and
named the collision, which is the intended behaviour and the reason the rule is scoped to agreement.

## To resolve

1. Read the Kikkoman label's fat line at the 30 g serving (and one other panko brand for a second
   reading).
2. Keep one row. If the FDC figure stands, the label row's 0 g is the error and the Kikkoman row
   should be corrected or dropped; if the label stands, the FDC row is a different product.
3. Point `Panko Breadcrumbs` and the 2026-08-28 vocabulary alias `Panko Bread Crumbs` at whichever
   survives.
4. Drop the pair from the LOCKSTEP `want` list in `meal-prep\pipeline\hunt_daemon_selftest.py` so the
   alarm returns to four.

Stakes are low per recipe - panko is a coating, grams are small - but the row is shared, so the error
is shared too.

Brad's call. Not started.
