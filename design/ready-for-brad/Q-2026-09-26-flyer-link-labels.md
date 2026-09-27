# Q-2026-09-26-flyer-link-labels: review the proposed labels for the 53 Hy-Vee flyer lines

**Items 1 (set shape) and 2 RULED 2026-09-26; two label questions below are still open.** Your ruling on the plan (2026-09-26, "Yes, build to that bar") said the orchestrator labels the
53-line answer set and you review the labels. The labels are in `grocery/hyvee/flyer-link-gold.jsonl`. Each row
gives the line, the proposed product id (or a SET of equally priced flavours, or NO-MATCH), why, and the store read it
rests on. Every row is marked `labels: proposed, awaiting Brad review`.

What the first run said (`design/MEASURE-flyer-line-link-2026-09-26.md`): 8 links out of 53, 0 of them wrong, and
0 false wrong-price verdicts on replay. **The bar is missed on coverage**, because 8 is under the floor of 20. So the
linker stays in shadow. One of the 8 (bottled water) links the right product but would confirm a board cell whose
per-unit is about 17 times too high, because the linker and the board share one size reader.

## What needs you

1. The labels. Check especially the SET rows (several flavours at one price counted as all correct) and the 14
   NO-MATCH rows.
2. Whether to try a rule variant 2, which would widen rule 2 for Hy-Vee's abbreviations or rule 4 for sets of
   flavours, or to keep the lines under A.

## Rulings (Brad, in chat, 2026-09-26)

- Item 2: **"Both loosenings"**. (a) map Hy-Vee's abbreviations (Ckn, BC, Qkr, ...) to brand/family words, and (b) accept
  any flavour in a same-price set; re-score against the SAME bar; stays shadow.
- Item 1: **"Accept sets"**. The 13 set-shaped labels are accepted as the label shape.

## What variant 2 did

18 links out of 53, 0 wrong, 0 false wrong-price on replay (was 8). **Still under the floor of 20, so the linker stays in
shadow.** It now runs every day in the chain so the one-ad-cycle shadow record builds up. The abbreviation list was
built from the same store reads it was scored on, so the 18 is a best case until the shadow days say otherwise. The 21
lines still unlinked are mostly names that DROP a word (no "Hy-Vee", no "soap", no "Entenmann's") rather than
abbreviate it, which your ruling did not cover. Full account: `design/MEASURE-flyer-line-link-2026-09-26.md`.

## Still open: two labels that look questionable (not changed)

1. **Peanuts.** The set label includes two Cocktail Peanuts products that the peanuts commodity's own rule refuses, so
   nothing can ever link them. Should that rule admit cocktail peanuts, or should they come out of the label?
2. **Bagels.** The set label accepts 12 oz Sola bagels for a flyer line that says "14 or 22 oz". Is the label right
   (and the flyer's sizes wrong), or should bagels be NO-MATCH?
