# The cross-road census: how many test-auditors cases can go stale the way u108 did (2026-09-11)

Status: MEASURED, and the block shipped with this file.

Harness: `ops/audit-crossroad-reads.ps1`, run over `grocery/test-auditors.ps1`. The numbers below were
first read in worktree `bold-bohr-996bf1` on the tree that became commit `3afbb5049`, rebased onto
`origin/main`. Re-run it rather than quoting these figures; it prints its own denominator.

Re-read at commit `3afbb5049`: every number in this document still holds. The harness is NEW in that
commit, so the base commit this work started from cannot qualify it - a document and the harness it
names cannot cite each other in one commit, and `ops/audit-conclusion-currency.ps1` correctly called
the first attempt UNQUALIFIED for exactly that reason. The re-read is a real run, not a formality: at
that content `-SelfTest` exited 0 over 15 cases and the live run exited 0 at 157 units, 253 resolved
path expressions, 2 tracked derived artifacts, 1 unit on both roads, 0 new against the baseline.

## The question

`design/PLAN-capture-eviction-stamp-2026-09-11.md` repaired ONE case. It did not ask how many others
carry the same shape. This is that count.

The shape: a case decides its verdict by comparing a file that reaches a checkout by COMMIT (tracked)
with one that reaches it by COPY (gitignored, seeded by `ops/seed-worktree.ps1` and `.worktreeinclude`).
The two roads move independently, so the case measures which road ran last rather than the property it
was written to assert, and a push from a worktree is refused for a reason the pusher did not cause.

## Method, and the two versions of it

A first cut read only `Join-Path $root '<literal>'` and found **147** live path expressions. That is the
wrong denominator: it cannot see a path built in two steps, which is how the suite reaches
`out\audit\match-baseline.json`. Following root variables transitively to a fixpoint reads **253**. The
census below is the second number. This is the `count-tracked-writers` shape from `ops-and-gates.md` -
a number that moved because the tool was wrong, not because the tree was.

Classification is git's: TRACKED is `git ls-files`, COPY is `git check-ignore`. A glob is classified by
what is on disk rather than by the pattern, because that is what the case reads.

## The count

Over `grocery/test-auditors.ps1` at the commit above:

| | |
|---|---|
| units (`Use-Unit` declarations) resolved | 157 |
| live path expressions resolved | 253 |
| of those, TRACKED | 245 |
| of those, gitignored (arrive by COPY) | 5 |
| **TRACKED DERIVED artifacts read live** (under `out\` or `public\`) | **2** |
| **units reading BOTH roads** | **1 of 157** |

The two tracked derived artifacts:

- `grocery/out/capture-evictions.json`, unit `u108`. The incident. Repaired earlier the same day: the
  case now reads the gitignored `capture-evictions-stamp.json` wherever the checkout has one and falls
  back to the tracked report only where it does not.
- `grocery/out/verification-history.json`, unit `u085`. **Not in the class.** Its case asks a property of
  that file ALONE - does every banked verification run declare the population it estimates - so there is
  no second road for it to disagree with. A scope-less run appended in the main checkout fails there
  immediately and is invisible in a worktree until committed, which is the lenient direction: the
  known-failures record is made in main, so the worktree cannot refuse a push over it.

Everything else tracked that the suite reads live is SOURCE (`.ps1`) or a RULE file (`commodities.json`,
`categories.json`, `stores.json`). Those travel by the same road as the code under test, so they cannot
lag behind it, and they are deliberately outside the class - 139 of the first cut's 147 reads are these,
and counting them would make the report a list nobody lowers.

## One thing the census found that nobody was looking for

`grocery/out/comparison-2026-08-08.json` is **TRACKED**. One stray board committed before the ignore
pattern existed; `.gitignore` does not untrack a file already in the index. It is inert for the boards
themselves, and it is a live trap for any tool that classifies `out\comparison-*.json` by asking whether
any tracked path matches the glob - that answers TRACKED, when the board the suite actually picks is the
newest, which on every live machine is ignored. The first version of this detector's glob rule did
exactly that and quietly measured a different question. It is why `Get-TcPathRoad` classifies a glob by
its matches on disk, ignored first, and why both orderings carry a case. Not repaired here: untracking
it is the `capture-evictions.json` argument again and wants its own measurement.

## The ruling, and the rubric it was judged by

The class has population 1 and that one is already repaired, so there is no second instance to fix. What
is missing is a BLOCK on the next one. `.claude/rules/ops-and-gates.md` states in its own words, twice,
that a rule in a file is not a block, and both times the estate's answer was a push-time ratchet.

Rubric, written before choosing: (1) weakens no guard; (2) catches a real new instance in the checkout
where it would bite; (3) green on day one, because a gate that is red on day one teaches people to
ignore red; (4) cannot be satisfied by prose, which is what already failed here; (5) hermetic and cheap
enough to sit in `run-gates`.

`ops/audit-crossroad-reads.ps1` is a ratchet BY NAME against `ops/crossroad-reads-baseline.json`, wired
into `ops/run-gates.ps1`. Day one: 1 known unit, exit 0. By name rather than by count because a baseline
of 1 that becomes a DIFFERENT 1 is a regression a count cannot see.

**What it would still catch, stated plainly.** A new or edited test-auditors case that reads a tracked
artifact under `out\` or `public\` beside a gitignored one fails the push with the unit named and both
roads printed. A case that stops reading the tracked artifact is reported as a tightening. It does NOT
weaken u108: that case still fails, loudly, when the rostered eviction pass has genuinely not run on the
board in this checkout, which is the true positive it exists for.

**What it would not catch**, and this is the whole of it. The scope line in the header says UNSOUND, and
means it: a path built from a computed leaf, a path a CHILD script opens, a path held in a here-string,
and a read reached through a helper the resolver does not follow are all invisible. It also cannot tell a
unit that COMPARES its two roads from one that merely reads both, so an entry is a site to look at rather
than a proven defect. A reported unit is real; silence is not proof.

## Fixtures

15 cases. The MUST FIRE is the pre-repair u108 text, frozen. The MUST NOT FIREs are the repaired shape
(both inputs on the copy road), tracked source and rule files beside a board, a path under a TEMP fixture
root, and a tracked artifact read with no copied path beside it. The CLEAN TWINs are positive assertions
on the mechanism the population rests on: transitive root resolution, the fixpoint, `Split-Path -Parent`,
and a literal tracked path still reading as TRACKED.

**Mutation probe: 10 single compiling mutants, 10 killed, each in its own named case.** Control 15 pass
exit 0; originals md5-identical afterwards; temp mirror removed. Three of the cases exist BECAUSE of that
probe rather than because they were thought of first, and two of those are the reason this document trusts
the fixture at all:

- `$pass -le 1` survived twice. The first two-level fixture sat in dependency order, so one pass resolved
  it. The second put the dependency the other way round and still survived, because reads are collected
  AFTER the loop and a read off a variable that one pass did resolve comes out whatever the loop did. The
  case had to be deep enough that the READ ITSELF needs the second pass.
- Widening the by-copy arm to accept TRACKED survived until a case covered a tracked artifact read with
  NO copied path beside it - the live `u085` shape.

## What it cost to add a detector in `ops/` about `grocery/`

`ops/audit-cross-module-reach.ps1` went red: 118 -> 132, all 14 new sites in this file. Every one was a
frozen fixture literal in the self-test, not this script opening a grocery file - its live path names
`grocery/test-auditors.ps1` and reads every other path out of that file's AST at run time.

The baseline was NOT raised. Two repairs, both the sanctioned ones:

- The fixture paths are hoisted to named variables carrying that audit's own per-line opt-out,
  `# reach-fixture-ok: <reason>`, which it requires a reason for. One spelling of each path is also
  easier to keep true than seven.
- One site was the literal sitting in an assertion's MESSAGE, on a line-continued line where a trailing
  comment is not legal. Interpolating the variable into the message removed it.

Final: **118 code sites in 42 files, exit 0** - the number it held before this change, with this file
contributing none. Measured by moving the three new files aside and re-running: 118 without them, 119
with, which is how the last single site was found rather than guessed.

One thing worth knowing for the next person who does this: a blind find-and-replace over the fixture
literals also corrupted the fixture TEXT, because `''public\board.json''` inside a single-quoted fixture
line contains `'public\board.json'` as a substring. It produced a parse error, and a file that does not
parse is classified by that audit's OLD line rule, which leans CODE - so the count it reported while
broken was neither the old number nor the new one.

## Left standing, deliberately

`ops/seed-worktree.ps1` exits **2** in every checkout on this box today, with one `MISSING` line: the
`.worktreeinclude` entry for `grocery/out/capture-evictions-stamp.json`, which no producer has written
yet. That is a true statement, not a false red - the target really is blind on it - and it clears itself
at the next chain run that calls the eviction pass. Nothing gates on it: the pre-push hook treats seeding
as best effort and does not refuse on a non-zero seed. Recorded here so the next person to read a red
seed does not hunt for a copy failure that never happened.
