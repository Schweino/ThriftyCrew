# Decision needed: does `cheapest_ps` move too, and change which dinners are free?

Written 2026-08-15, after phase 1 (the recipe card fix) shipped. Phase 1 did not touch this and cannot
change the free set. Nothing below happens without an explicit yes.

## The problem

Phase 1 fixed the recipe CARD: each ingredient is now priced at the store where the package you actually
have to buy costs the least, instead of the store with the lowest price per pound. On
`bangers-and-mash-onion-gravy` that took the receipt from $58.37 to $37.25.

`pipeline\v2-perserving.json`'s `cheapest_ps` carries the same defect in a different flavor, and it is a
DIFFERENT number from the card's. It feeds the top-5 box, the Meal Plan Builder, the hub grid, and the
free-dinner rotation. So the card now says one thing and those surfaces still say another.

Two things are worth separating, because only one of them is a real choice:

- Picking the min-COST store while keeping compute-v2's own recipe package size is **algebraically a
  no-op**. The package size does not vary by store, so minimising cost is exactly minimising per-unit.
  There is no "small fix" version of this.
- The only change that does anything is moving `cheapest_ps` onto the **store's** package size, which is
  what the card computes. That is the real proposal.

## What it costs

Re-ranking `cheapest_ps` re-ranks the top 5 cheapest dinners per protein, and those are the recipes that
go FREE each week. Measured against today's live ranking, using the same 3-key tie-break the rotation
uses, **all four protein classes change**:

| protein | loses free | gains free |
|---|---|---|
| chicken | chicken-pot-pie-biscuit-casserole, claypot-chicken-mushroom-rice | buffalo-chicken-pasta-bake, slow-cooker-crack-chicken-bowls |
| turkey | haluski-and-kielbasa-cabbage-noodles, red-beans-turkey-sausage-and-rice | turkey-alfredo-rotini-bake, turkey-maqluba-upside-down-rice-bake |
| beef | slow-cooker-beef-and-noodles, bistek-tagalog-filipino-beef-onion-rice | john-wayne-casserole, cheesy-beef-and-shells-casserole |
| pork | slow-cooker-filipino-pork-adobo-bowls | no-peek-pork-chop-rice-casserole |

Seven currently-free dinners would go back behind the paywall and seven would open. That is member
visible, so it is your call, not a detail of the fix.

## The options

**A. Do nothing.** The card is right; the top-5 box, planner and hub keep ranking on the old basis. The
cost is that the same recipe can show one per-serving figure on its card and a different one in the
top-5 box. Free set does not move.

**B. Align `cheapest_ps` to the card.** Every surface agrees. Seven dinners lose free status and seven
gain it, once, on the next rotation. Run as a set: `compute-v2-perserving`, `top5-weekly`,
`rotate-free-dinners -DryRun` to see the churn, then live, `gen-planner-data`, hub rebuild.

**C. Align, but freeze the current free set for one week** so nobody loses access the same day, and let
the change ride the next ad flip. More moving parts, and `rotate-free-dinners` only ever reverts slugs it
freed itself, so a hand-held week is a manual step.

Recommendation: **B**, because the disagreement between the card and the box is the thing readers would
actually notice, and the rotation is designed to churn weekly anyway. But the free-set flip is real and
this is the decision to make deliberately.

Measurement behind all of the above: `grocery\measure-cheapest-selection.ps1`, report in
`grocery\out\cheapest-selection-report.json`, summary in `design\MEASURE-cheapest-selection.md`.
