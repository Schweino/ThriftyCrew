---
description: Traps when working on recipes, the food DB, costing, or the Recipe Hunter pipeline.
globs: "meal-prep/**"
alwaysApply: false
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `meal-prep/`

Loaded only when you touch a file under `meal-prep/`. Pointers, not copies - the full account lives in
the named memory or file.

- **`set-board-cell.ps1` is the RECIPE-board corrector**, one cell at a time on
  `recipe-board-everyday.json`. It is not `known-wrong`, which corrects the main board.
  [[set-board-cell-is-the-recipe-board-corrector]]
- **Recost aftercare:** `sync-recipesdb-cost` BEFORE `propagate`, and `-Slugs` has two different shapes.
  `propagate` itself has no `-Slugs` at all - it publishes the whole dirty set, and dirty is
  spec-hash-versus-stamps. [[recost-needs-sync-recipesdb-cost-and-the-slugs-trap]], [[propagate-has-no-slugs]]
- **A spec's bid is not a pricing input.** An unbid scaler line blacks out the card's live scaler.
  [[spec-bid-is-not-a-pricing-input]]
- **A publish crash loses the journal** unless the journal is written per slug, and `-All` iterates
  `db/built` rather than the specs. [[publish-wave-crash-loses-the-journal]]
- **`retire-recipe` only retires LIVE recipes.** The built-but-unpublished have no gated disposal.
  [[retire-recipe-only-retires-live-recipes]]
- **The paywall split is `html|paywall|html` at `<!--TC-PAYWALL-->`**, before "What This Batch Costs".
  [[recipe-paywall-split]]
- **A spec's mtime is not evidence of a recost** - reanchor rewrites every spec daily.
  [[spec-mtime-is-not-evidence-of-a-recost]]

- **THE PANEL IS READ IN FULL AND THE FOOD DB KEEPS FOUR FIELDS OF IT** (2026-09-12, backlog I145).
  `db/food-label-captures.json` carries `sodium_mg` and populates it - the Great Value chicken broth
  capture records 830 mg, the beef broth 810. `food-macros-db.json` has **no sodium field on any of
  its 441 rows**, and no sugar field; fibre survives on 98 of 441. So the expensive half was done -
  sodium was transcribed by hand off a photograph, at the five-to-eight round trips per label that
  `[[reading-a-nutrition-label-off-a-product-photo]]` records as the cost - and then it was dropped
  on the way in. A US panel must declare thirteen things; we keep four of them.
  **THIS IS AN OPEN QUESTION FOR BRAD AND IS RECORDED HERE ONLY SO IT STOPS BEING INVISIBLE.** If we
  want sodium, the captures already hold it for the rows they cover and the field costs nothing; if
  we do not, the CAPTURE schema should stop collecting it so the next label sweep stops paying for a
  number nobody stores. What is wrong today is neither answer - it is paying for it and discarding
  it. Worth knowing while deciding: a meal-prep audience is a plausible sodium-watching audience, and
  broth, canned tomatoes and soy sauce are exactly where it concentrates.
- **A DUAL-COLUMN PANEL DECLARES TWO DIFFERENT FOODS, AND NOTHING WE CAPTURE RECORDS WHICH COLUMN A
  NUMBER CAME FROM** (2026-09-12, backlog I146). A cereal box legally carries both "per 1.5 cup
  serving" and "per serving with three quarters of a cup of skim milk", side by side. The capture
  fields are `item`, `status`, `product`, `url`, `label`, `stored_brand` and `note`, and **there is
  no field naming the column**; `food-macros-db.json`'s only nearby field is a free-text `notes`
  carrying things like `"raw"`. That `"raw"` is the tell that this estate already knows the shape:
  `[[food-db-naming-rulings]]` ruling 2 exists because bone-in skin-on chicken thigh is 221 cal per
  100 g edible and 177 as-purchased, with nothing in either name saying so, and Brad's ruling was to
  put the basis IN THE NAME. **A dual-column panel is that same defect one step earlier**, and it is
  worse in one respect: raw-versus-cooked at least leaves a trace, and an as-prepared column leaves
  none at all once transcribed. Fourteen captures exist today and none is obviously a dual-column
  product, so **the cost of fixing this BEFORE the next sweep is one field and the cost after it is a
  re-read of every affected label.**

Regime: this holds for files under `meal-prep/`. The grocery board has a different corrector and a
different rebuild cadence.
