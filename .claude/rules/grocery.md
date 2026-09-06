---
description: Traps when working on the grocery board, captures, or the comparison pipeline.
globs: "grocery/**"
alwaysApply: false
---

# Working in `grocery/`

Loaded only when you touch a file under `grocery/`. These are the traps that have actually cost this
estate a day; each names the memory or file holding the full account rather than restating it, so there
is one copy of every rule and nothing here can drift from it.

- **`known-wrong.json` is the MAIN-board corrector, and `comparison-*.json` is rebuilt daily.** A fresh
  ruling reads as red until the next build. That is on purpose, not a bug to chase.
  [[known-wrong-is-the-main-board-corrector]]
- **`compare-deals.ps1` is not standalone.** A mid-day rebuild needs identity emission AND link repair.
  Never revert-to-isolate. Three scripts LIFT its functions, and a lifted `$script:` constant does not
  travel - the lift needs functions, parens and a column-0 brace.
  [[compare-deals-is-not-standalone]], [[compare-deals-functions-are-lifted-by-three-scripts]]
- **A wrong product is a SELLER SHAPE, not a brand.** Blocking the brand hands the cell to the next
  bulk seller. [[wrong-product-class-is-a-seller-shape]]
- **One bad Walmart pull holds a ship-only cell for 90 days** once Marketplace rows enter the union.
  [[walmart-marketplace-rows-pollute-the-union]]
- **No hard-coded bands** (Brad, 2026-09-04). [[no-hardcoded-bands]]
- **The boards are gitignored**, so a worktree, a CI runner or a clean checkout is BLIND here and the
  engines exit 0 having priced nothing. `ops/seed-worktree.ps1` and `.worktreeinclude` seed them.

Regime: this holds for files under `grocery/`. It says nothing about `meal-prep/`, which has its own
rules file and its own corrector.
