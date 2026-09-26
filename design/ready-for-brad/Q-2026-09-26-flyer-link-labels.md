# Q-2026-09-26-flyer-link-labels: review the proposed labels for the 53 Hy-Vee flyer lines

**Open, for Brad.** Your ruling on the plan (2026-09-26, "Yes, build to that bar") said the orchestrator labels the
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
