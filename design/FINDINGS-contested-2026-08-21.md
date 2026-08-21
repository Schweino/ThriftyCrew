# Operational / architectural findings — contested-row work, 2026-08-21

Brad asked me to log anything discovered along the way that would make the system
better, faster, or more accurate. Running log. Each entry says what was measured,
not what was assumed.

Status key: **DONE** shipped · **PROPOSED** not built · **WATCH** needs evidence

---

## 1. Guard ordering was convention, not invariant — DONE

`audit-tile-integrity` does not compute its WRONG-PRODUCT verdicts. It reads them
from `out\name-drift.json`. Any `compare-deals` run rewrites `comparison-*.json`
and any link rewrite touches `product-urls.json`, so both routinely become newer
than the flags being used to judge them.

Both pipelines already do the right thing — `weekly-post-capture.ps1:155` and
`check-ad-cycles.ps1:1099` each run `audit-name-drift` immediately before
`guards.ps1`, and `weekly-post-capture.ps1:146` documents why. But nothing
*enforced* it. Anyone running the audits by hand, in any other order, got a
verdict about the past.

Measured: after re-deriving 52 links, the audit failed 7 tiles whose board row
and link were by then character-for-character identical.

That is the harmless direction. The harmful one is the same bug sign-flipped:
point a link at the wrong product while the flags are stale, no flag is found,
the tile passes — a false green on the gate enforcing "price and item name must
match the link 100%".

Now a staleness assertion, HELD not warned, with no `-Force` path.

## 2. The contested list is a standing backlog nobody works — WATCH

`audit-match-contested.ps1` already finds every row whose owner is decided by
array order in `commodities.json`. `audit-match-soundness` reports the count on
every publish. It read **710 contested** the day this log started.

All three wrong-price bugs fixed on 2026-08-20/21 — whole cloves at $11.92/oz,
plain milk swallowing the cheap chocolate gallon, `oranges` claiming OJ — were
already in that pool. The detection existed. The information was never missing.
Nothing turns it into work.

A number that only ever gets printed is not a control.

## 3. Restoring a source file is not restoring the system — DONE

Building `promote_aliases --gated` surfaced this, and it generalises well beyond
that script.

The gate promotes aliases, rebuilds the board, runs guards, and on failure puts
`commodities.json` back. That felt like a clean rollback. It is not: the board
(`comparison-*.json`) and the drift flags are DERIVED from the catalog, and the
last thing a failing round does is rebuild them from the very aliases being
withdrawn. Restoring only the source left a tree where the catalog was clean and
everything computed from it was not.

Observed exactly once, immediately: the next run refused to start, reporting a
red baseline that named two aliases no longer present in any file on disk.

Rollback now means restore-and-rebuild, on one path, in a `finally`, covering
exceptions and Ctrl-C. Anything in this estate that edits a source input and can
bail out has the same obligation — `commodities.json`, `product-urls.json`,
`category-excludes.json` all have derived artefacts downstream of them.

## 4. A rollback that only fires on catastrophe is not a rollback — DONE

Same script, found by reading the code the test made me re-read. The original
`finally` restored only when the catalog had been left *missing or empty*, so
all three ordinary failure exits printed "tree restored" while leaving the
failing round's edits in place. The message was true only in the case that never
happens.

Now a single `promoted_ok` flag: green keeps its edits, every other exit
restores. Worth grepping for elsewhere — "restore only if the file looks
destroyed" is a tempting shape, and it protects against the rarest failure while
ignoring the common one.

## 5. The must-fire fixture earned its keep — WATCH

Both of the above were found by deliberately clearing two known-bad holds and
checking the gate rediscovered them, rather than by running the gate on a batch
where it would pass. A gate tested only on the happy path proves nothing; this
one had two bugs that a passing run would never have exposed, and one of them
silently discarded verdicts it had just spent two guard cycles earning.

`test-guards.ps1` / `run-test-guards-weekly.ps1` already apply this idea to
`guards.ps1`. Nothing applies it to the newer Python gates.
