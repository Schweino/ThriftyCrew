# PLAN: efficiency budgets, so bloat is refused when small instead of cleaned up in a day

Status: RULED 2026-09-27 (Brad: "Yes, all of it"). Build after gate-diet round 4 lands, so the push-cost
baseline is taken from the new numbers.

## Why
On 2026-09-27 a full day went to cleanup: 208 worktrees, 83 dead scripts, 116 KB of always-loaded rules,
four files of 3,700 to 8,000 lines, and push checks that re-ran on every data commit. Each grew one reasonable
change at a time, and nothing measured the total. The always-loaded-bytes ratchet was the one budget that
existed, and it was also the one that held: it refused this very day's first rule for adding bytes.

**Principle: budgets, not more gates.** Each kind of bloat becomes ONE number with a mark that may only fall
(`lib/ratchet.ps1`); a rise is refused unless the commit accepts it with a reason. Everything is built on
machinery that already exists (CLAUDE.md, 2026-09-27: new machinery must pay for itself).

## Knowledge consulted
- rules:ops-and-gates.md og-11: "Do not add a gate that is red on day one... use a ratchet whose mark may only go
  DOWN. A plain run of a ratchet never writes its mark: a fall is SPOKEN and the committed mark kept; -Tighten
  records it."
- rules:ops-and-gates.md og-19: a one-way control constant needs a rate limit and a plausibility bar.
- `ops/audit-always-loaded-bytes.ps1`: the exemplar budget (mark, -Accept with a reason in the commit).
- design/W0-gate-catches-2026-09-27.md and design/PLAN-push-gate-diet-2026-09-27.md: the push-cost numbers.

## Work items
**B1. Push-cost budget.** Extend `ops/run-gates.ps1`'s existing timing rows: after a full run, compare the
executed gate CPU against a committed mark for two classes, data-only push and code push. The number is a
median over the last N recorded runs of that class, never one run (a single run moved by load is noise).
A rise past the mark is refused as a ratchet break; `-Accept` records a higher mark with the reason in the
commit. The practical effect: a new check that declares no inputs raises the data-only number and is refused
until it is keyed or accepted. Fixtures: MUST FIRE (a new unkeyed gate on a data-only fixture raises the
median past the mark), MUST NOT FIRE (a keyed new gate), CLEAN TWIN (a fall is spoken and the mark kept).
Cost: reads rows run-gates already writes; target under 1 s.

**B2. File-size budget.** A ratchet over tracked `.ps1`/`.py` line counts: no NEW file over 1,000 lines, and
every file already over it has its own mark that may only fall. Files split into a folder (the 2026-09-27
host-plus-pieces shape) count each piece. Built as a mode of an existing static audit if one fits
(`audit-script-census` walks the same set), else one small audit keyed on the code scan set (D1 keying), so it
costs nothing on data-only pushes.

**B3. Automatic worktree cleanup.** Add a step to an existing nightly task (daily ratchets) that removes
worktrees exactly as done by hand on 2026-09-27: clean (`git worktree remove` without `--force`), whose HEAD
is an ancestor of origin/main, not locked, untouched for 3+ days; then deletes the merged branch and prunes.
Never `--force`, never an unmerged worktree. It reports counts (removed, refused-dirty, unmerged, locked).

**B4. Weekly efficiency report.** One section in the existing Monday brain digest: each budget's current
number, its mark, the 4-week trend, and anything within 10% of its mark. Budgets: push cost (both classes),
largest files, always-loaded bytes, script-census orphans, worktree count, plans marked under way.

## Bars (written before the build)
- B1 and B2 red on a fixture that breaks them and green on the tree as landed.
- B3 removes nothing a person could lose: fixtures for dirty, unmerged and locked worktrees, each left alone.
- Total added push cost for B1+B2 on a data-only push: under 2 s.

## Decisions (ruled)
- D1 Budgets over new gates: YES.
- D2 Build after round 4 so the baseline is current: YES.
