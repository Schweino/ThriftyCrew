# Q-2026-09-26-sirloin-tip and Q-2026-09-26-subprimal-case: two beef cells that may be the wrong product

**The questions.** (1) May a sirloin TIP steak (cut from the round) stand for sirloin steak (cut from the loin)?
(2) May a whole-subprimal CASE, sold only as a multi-piece case priced per pound, price a retail chuck roast?

Raised by queue item 2026-09-26-8deaa4. Source: `grocery/triage-plans/plan-2026-09-26-3.json`.

## What I checked

Read from the main board `grocery/out/comparison-2026-09-23.json` (576 commodities):

**sirloin-steak, 7 store cells, crown Family Fare $6.49/lb "Fresh Petite Beef Sirloin Sizzle Steak" (a loin cut).**
Three of the 7 cells are sirloin tip, matching the triage count of 3:
- Aldi sale $7.99/lb, Fresh Black Angus Sirloin Tip Steak
- Fareway everyday $7.99/lb, USDA Choice Sirloin Tip Steak
- Walmart everyday $8.82/lb, Beef Choice Angus Thin Sliced Sirloin Tip Steak

The other 4 are loin cuts (Family Fare sizzle steak, Sam's top sirloin $9.97, Hy-Vee loin sirloin $10.99, Baker's top
sirloin $13.99). The crown is a loin cut, so it does not move under either answer.

The recipe-side identity mark (`ops/out/ingredient-identity-cell-baseline.json`) also carries 2 sirloin tip keys on
"Beef Flank/Sirloin Steak", at Family Fare (whole sirloin tip) and Sam's (sirloin tip case). Those are recipe-board
cells, a different set from the 3 main-board cells above, and the same ruling covers them.

**chuck-roast, 7 store cells, crown Sam's Club $6.97/lb "Whole Beef Chuck Roll, Case, priced per pound".** Matches
the triage. Next cheapest is Aldi $6.99/lb "Choice Black Angus Chuck Roast Per LB", then Walmart $7.97, Fareway $8.99.
The same Sam's key is in the recipe-side mark, so it prices recipe lines too.

## Options, sirloin tip

- **A. Keep.** The 3 tip cells stay on sirloin-steak. A reader comparing stores sees a round cut priced beside loin cuts.
- **B. Exclude sirloin tip from sirloin-steak.** The 3 cells fall back to each store's loin sirloin (Aldi petite
  sirloin $8.99 per the triage, Fareway and Walmart their cheapest top sirloin) or empty. No recipe price moves,
  because the crown is already a loin cut. A separate sirloin-tip commodity can carry the tip rows if wanted.

## Options, subprimal case

- **A. Keep.** Sam's holds the crown at $6.97/lb, but a shopper can only get that price by buying the whole case.
- **B. Exclude a case or whole-subprimal from retail roast commodities.** The crown moves to Aldi at $6.99/lb (+$0.02
  per lb). Sam's cell falls to its next retail roast or empties.

## Recommended (best long-term): B for both

Both are the "wrong product is a seller shape" pattern in the grocery rules: a different primal is a different food
under your 09-22 ruling, and a case is a pack no reader making one recipe will buy. Both B answers cost almost
nothing on price (the sirloin crown is unchanged, the chuck crown moves 2 cents a pound) and remove two ways a cell
can look cheaper than what a reader can actually buy. Exclude by shape (the words "tip" on sirloin-steak, "case" and
"whole ... roll" on roast commodities), never by brand, so the next seller with the same shape is caught too.

## What executes once ruled

- **B, sirloin tip:** a shape exclude on sirloin-steak (optionally a new sirloin-tip commodity through the
  commodity-registrar), with a must-fire fixture on the 3 names and a clean twin on "top sirloin", then a board
  rebuild; the 2 recipe-side keys drop from the identity mark at the next tighten.
- **B, subprimal case:** a case/whole-subprimal exclude on roast commodities with the Sam's chuck roll as must-fire
  and Aldi's per-lb roast as clean twin; board rebuild; the chuck crown moves to Aldi; the recipe recost chain runs
  for chuck-roast lines.
- **A for either:** the keys are marked reviewed in the identity mark and 8deaa4's residual closes.

## Ruling (2026-09-26, Brad in chat)

Q-2026-09-26-sirloin-tip and Q-2026-09-26-subprimal-case: **"B: exclude both"** - sirloin tip is not sirloin steak;
a whole subprimal case (Sam's chuck roll) is not a chuck roast.
