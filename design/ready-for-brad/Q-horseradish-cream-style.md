# Q-horseradish-cream-style: is cream-style horseradish prepared horseradish or horseradish sauce?

**The question.** "Inglehoffer Horseradish Cream Style 9.5 OZ" holds the Aldi horseradish crown. Is it Prepared
Horseradish, or Horseradish Sauce (creamy)?

Raised by queue item 2026-09-26-f655c7-routes. Source: `grocery/triage-plans/plan-2026-09-26-3.json`.

## What I checked

Read from `grocery/out/comparison-2026-09-23.json`:

- **horseradish, 4 cells, crown Aldi $0.2989/oz** "Inglehoffer Horseradish Cream Style 9.5 OZ". Walmart $0.3032/oz
  "Inglehoffer Creamy Style Prepared Horseradish, 9.5 oz". Baker's $0.3738/oz Silver Spring Coarse Cut. Family Fare
  $0.4988/oz Silver Spring Coarse Cut. So 2 of 4 cells, including the crown, are cream style.
- **horseradish-sauce, 3 cells, crown Walmart $0.16/oz** Great Value Original Horseradish Sauce. Baker's $0.2339,
  Family Fare $0.3773.

All match the triage.

**The panel.** The triage quotes the ingredients as grated horseradish first, then water, soybean oil, vinegar, corn
syrup and eggs. I did not read the jar myself, and nothing in the repo I found holds a label capture for it. Brad, if
you have the jar or a product photo, the ingredient order is the evidence: horseradish first with oil and egg after
reads as a horseradish-forward cream; oil or egg ahead of horseradish would settle it as a sauce outright. Note that
Walmart's own listing calls the same product "Prepared Horseradish".

## Options

- **A. Prepared horseradish (confirm the current route).** Aldi keeps the crown at $0.2989/oz and Walmart stays at
  $0.3032. The horseradish-sauce commodity's two cream-style includes stay dead text for these names.
- **B. Horseradish sauce.** Exclude cream style and creamy from horseradish. The horseradish crown moves to Baker's
  $0.3738/oz (+25%). Aldi's and Walmart's horseradish cells empty, because every in-store candidate at both is an
  Inglehoffer or Beaver creamy jar. Aldi gains a horseradish-sauce cell at $0.2989; that crown stays Walmart $0.16.

## Recommended (best long-term): B

The horseradish-sauce commodity already names cream style twice, so B is what the rule's authors meant, and a recipe
that asks for prepared horseradish wants the plain grated root in vinegar, not an emulsion with oil and egg. It costs
two empty cells and a higher crown, which is the true price of plain horseradish in Omaha. If the panel shows it is
mostly horseradish and you judge it a fair stand-in, A is defensible, but then the sauce commodity's cream-style
includes should be removed so the two rules stop disagreeing.

## What executes once ruled

- **B:** an exclude of cream style and creamy on horseradish with the two Inglehoffer names as must-fire and Silver
  Spring coarse cut as clean twin, then a board rebuild and the recipe recost chain for horseradish lines.
- **A:** `resolve-match-worklist -Decide '<contested key>' -Verdict confirm`, and the dead cream-style includes are
  removed from horseradish-sauce.
