---
description: Traps when working on the grocery board, captures, or the comparison pipeline.
globs: "grocery/**"
alwaysApply: false
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `grocery/`

Loaded only when you touch a file under `grocery/`. These are the traps that have actually cost this
estate a day; each names the memory or file holding the full account rather than restating it, so there
is one copy of every rule and nothing here can drift from it.

- **`known-wrong.json` is the MAIN-board corrector, and `comparison-*.json` is rebuilt daily.** A fresh
  ruling reads as red until the next build. That is on purpose, not a bug to chase.
  [[known-wrong-is-the-main-board-corrector]]
- **`compare-deals.ps1` is not standalone.** A mid-day rebuild needs identity emission AND link repair.
  Never revert-to-isolate. **MANY scripts LIFT its functions**, against a `three` that stood in
  this file for months. **A count here is meaningless without its TEST**, and four counts of this
  same thing disagreed on 2026-09-08 because none of them stated one. Measured that day:
  **53 `.ps1` files name it, 13 of those also call `Invoke-Expression`**, and on the tighter test
  of a `Get-Content` actually pointed AT it, **18 read its source and 12 execute what they lifted**
  (15 of the 18 outside `grocery\out\`). The 12 reproduces on two independent tests. Count it,
  never quote it, and say which test you ran:
  ```
  grep -rl "compare-deals\.ps1" --include=*.ps1 grocery ops meal-prep lib graph | xargs grep -l "Invoke-Expression"
  ```
  A lifted `$script:` constant does not
  travel - the lift needs functions, parens and a column-0 brace.
  [[compare-deals-is-not-standalone]], [[compare-deals-functions-are-lifted-by-many-scripts]]
- **A wrong product is a SELLER SHAPE, not a brand.** Blocking the brand hands the cell to the next
  bulk seller. [[wrong-product-class-is-a-seller-shape]]
- **One bad Walmart pull holds a ship-only cell for 90 days** once Marketplace rows enter the union.
  [[walmart-marketplace-rows-pollute-the-union]]
- **No hard-coded bands** (Brad, 2026-09-04). [[no-hardcoded-bands]]
- **The boards are gitignored**, so a worktree, a CI runner or a clean checkout is BLIND here and the
  engines exit 0 having priced nothing. `ops/seed-worktree.ps1` and `.worktreeinclude` seed them.

Regime: this holds for files under `grocery/`. It says nothing about `meal-prep/`, which has its own
rules file and its own corrector.
