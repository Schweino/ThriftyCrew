# Giving `compare-deals.ps1` a provided interface

**Status: PLAN, not ratified. Nothing here has been built.** Written 2026-09-09 for backlog I82.
The detector half (`ops/audit-lift-completeness.ps1`) shipped; this is the refactor that would retire
the need for it.

## The problem in one line

`compare-deals.ps1` is a component with a required interface and no provided one, so twelve scripts
have jammed the socket onto its source file: they `Get-Content` the engine, regex out function bodies,
and `Invoke-Expression` them.

## Why nobody just dot-sourced it

`grocery/build-walmart-deals.ps1:82` says it plainly: **"it runs a pipeline on load, so we can't
dot-source it."** That is the root cause and every other symptom follows from it. The file is 3,566
lines and mixes three things that want to be separate:

1. pure pricing math (`Get-UnitPrice`, `Get-PackCount`, `Get-SizeAmount`, `Convert-ToUnit`, ...)
2. a data constant, `$GLOBAL_EXCLUDE`
3. the board build itself, which executes on load

## What is actually coupled, measured 2026-09-09

`ops/count-source-lifters.ps1 -Script compare-deals.ps1` prints its own tests and their numbers:
**55 name it, 18 read its source, 12 execute what they lifted.** Say which test you mean or the number
means nothing.

There are **two** lifted interfaces, not one, and they need different fixes:

| interface | how it is lifted | consumers |
|---|---|---|
| the pricing functions | regex `^function <name> ... ^}` then `Invoke-Expression`, driven by a hand-maintained name list | 3 builders lift the 9-function list; `test-unitprice.ps1` lifts a different 8 |
| `$GLOBAL_EXCLUDE` | regex the array literal text, then `Invoke-Expression '@(' + body + ')'` | 16 files mention it, including `compare-deals.ps1`'s OWN self-test |

**The engine lifts from itself.** `compare-deals.ps1:1653` and `:2076` extract `$GLOBAL_EXCLUDE` and
`Match-Category` out of `$PSCommandPath`, because its self-test block runs before those definitions
exist. Any fix has to handle that or the engine's own tests break.

## The proposed shape

The estate already has this pattern working three times: `grocery/match-lib.ps1`,
`grocery/known-wrong-lib.ps1`, `grocery/identity-lib.ps1`. This is not a pattern to invent.

1. **`grocery/pricing-math-lib.ps1`** - the pure functions, no load-time side effects, dot-sourced by
   `compare-deals.ps1` and by every current lifter. Deletes the hand-maintained name lists and with
   them the whole class of bug `audit-lift-completeness.ps1` now watches for.
2. **`grocery/global-exclude.json`** (or a `.ps1` returning the array) - the data constant, read rather
   than parsed out of source. Retires the `Invoke-Expression` on regex-extracted array text in 5+ files.
3. `compare-deals.ps1` keeps the board build and nothing else that anyone needs to reach into.

## Why it was not done in the same session as the detector

**Blast radius on a live paid pricing path.** It is one atomic change across 13+ files, on the code
that decides what a shopper is told a thing costs, where understating is exactly as wrong as
overstating. It cannot be staged: the moment the functions leave `compare-deals.ps1`, every lifter's
regex finds nothing. The failure would at least be LOUD ("not recognized as the name of a cmdlet")
rather than a silently wrong price, which is the one comfort here.

**Two things must be true before it ships**, and neither is free:

- the three lifting builders, `test-unitprice.ps1`, `test-matcher-parity.ps1` and `test-auditors.ps1`
  all pass unchanged in behaviour;
- a board rebuilt after the change is **byte-identical** to one rebuilt before it. That is the only
  evidence that carries here. A passing test suite is not it.

## The forward rule, which holds regardless

Before adding a consumer to an existing script, ask what its **provided** interface is. If the answer
is "read its source", that is the finding. And any claim about how many things depend on X is measured
with a command and a date, never carried in prose or a filename.
