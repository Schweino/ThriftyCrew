# Does the gate design scale, and what would a better one be

**Status: A DESIGN NOTE. Nothing here is built, and nothing here is recommended for building today.**
Brad asked whether there is a better design, even a major redesign, because the estate keeps growing
and this does not look like it scales. It does not, and this says precisely where it breaks, why the
obvious fixes do not, and what the actual alternatives cost.

**Measured at commit** `9d987f823`, 2026-09-09, on a 32-logical-core machine.

## 1. The growth is real, and fast

| date | source `.ps1`+`.py`, excluding `platform/`, `.claude/skills/`, `archive/` |
|---|---:|
| 2026-08-01 | 266 |
| **2026-09-09** | **654** |

**+146% in five and a half weeks.** Checked for the obvious confound: this is not a bulk import. The
largest contributor is `meal-prep/pipeline` at +112 files, which is product work. Tracked files went
3,944 to 8,266 over the same window.

At that pace the estate doubles about every six weeks.

## 2. Where it breaks, precisely

`run-gates`: **306 gates, 51s wall, 572s of gate work at width 16.**

- throughput bound: 572 / 16 = **35.8s**
- longest single gate: **31.1s** (`map-preresolve.ps1`)

**It has just crossed from longest-job-bound to throughput-bound**, and that crossover is the whole
answer to "why does this suddenly feel bad". Below it, a new gate was nearly free: it hid behind the
31s job. Above it, **every new gate adds about one sixteenth of its cost directly to the wall.** The
architecture did not change; the regime did.

And width is spent. Measured on 2026-09-09 at the four-pool shape: widths 16, 24 and 32 gave 78s, 76s
and 75s while the work inside inflated 516s to 657s. The pool saturates at 16 on this machine.

**So the current design is O(N) wall clock in estate size, with a fixed divisor of 16.** Doubling the
estate doubles the gate. That is the scaling defect, stated exactly.

Projected at one doubling (about six weeks at the measured pace):

| | today | after one doubling |
|---|---:|---:|
| `run-gates` wall | 51s | **~95-100s** |
| `test-auditors` | 291s | **~580s (~10 min)** |

## 3. Three obvious fixes, and why each fails

**More width.** Measured, saturated at 16. Dead.

**One process for many checks** (drop process-per-gate). Process startup is 57s of the 572s, 11%. So
the ceiling on this is 11% - and it costs the isolation the estate deliberately bought: `guards.ps1`
documents that every child audit declares `param()` at file scope, so hosting them in one process
clobbers the caller's variables, and a crashing check would take the suite with it. **A 11% ceiling is
not worth the isolation.** Dead.

**Run only the gates a change can affect.** Two independent reasons this is not the answer. It buys
about **20 seconds**: the longest single gate is 31s inside a 51s wall, and the expensive detectors -
`audit-guard-contract`, `audit-write-only-reports`, `audit-source-control-bytes`, `audit-script-census`
- all scan the WHOLE TREE, so no file-based selection can skip them. And it costs the property that
`ops-and-gates.md` protects: "no gate matched your change" and "the gates found nothing" become the
same bytes. **Small win, real loss.** Dead.

The common thread: **the floor is set by the whole-tree detectors, not by the dispatch.** Every fix
aimed at dispatch hits the same ~26-31s wall.

## 4. The three real options, cheapest first

### Option A - CADENCE. Move the whole-tree RATCHETS off the push path.

No new machinery at all. The observation is that several of the most expensive detectors are
**ratchets** - they carry a high-water mark and answer *"is the estate drifting?"*, which is a TREND
question, and a trend does not need per-push resolution.

Measured, which of the expensive whole-tree detectors carry a baseline or high-water mark:

| detector | ratchet language | whole-tree scan |
|---|---:|---:|
| `audit-script-census` | 40 mentions | yes |
| `audit-cross-module-reach` | 32 | yes |
| `audit-guard-contract` | 18 | yes |
| `audit-write-only-reports` | 18 | yes |
| `audit-measurement-provenance` | 18 | no |
| `audit-fixture-vocabulary` | 0 | yes |
| `audit-source-control-bytes` | 0 | yes |

**This is a per-detector judgement, NOT a blanket move, and the distinction is real.**
`audit-write-only-reports` and `audit-cross-module-reach` ask trend questions and can run daily.
`audit-guard-contract` asks *"did this change kill a guard?"*, which is a CHANGE-TIME question even
though it is implemented as a ratchet, and moving it to daily trades a real detection latency: a dead
guard would ship and be caught the next morning. **That trade must be made deliberately per detector,
in writing, or this option quietly becomes the selection idea rejected above wearing better clothes.**

Buys: the floor drops by whatever is moved. Costs: detection latency on what moves, and nothing else.

### Option B - REUSE A VERDICT, do not skip a check.

Content-address each gate: key = hash(gate source + its libs + its declared inputs). If that key
already has a recorded PASS, reuse it; otherwise run. **The report prints `N reused, M ran`, so every
gate has a verdict on every run.**

That last sentence is the entire difference from selection, and it is not a quibble: selection leaves a
gate with NO verdict and no way to tell that from a clean one. Reuse leaves every gate with a verdict
and says which were recomputed.

Buys: O(changed) for the ~222 self-tests, whose inputs are genuinely local - the script, its libs, its
fixtures. Costs: a cache, and cache invalidation is where this class of system goes wrong. The key must
include the gate's own source and every library it dot-sources, or a fix to a shared lib silently
reuses stale passes. **That failure mode is exactly the one this estate keeps writing guards about, so
the cache itself would need a must-fire fixture proving a lib change invalidates.**

Does NOT help the whole-tree detectors, which read everything, so it does not move the floor.

### Option C - MAKE THE WHOLE-TREE DETECTORS INCREMENTAL.

The only option that changes the asymptote. Restructure a detector as `findings(file)` memoised on file
content hash, then aggregate. A one-file change re-scans one file, and `audit-source-control-bytes`
goes from 8,100 files to 1.

**But it does not work for all of them, and the distinction is structural.** A detector whose question
is per-file - "does this file carry a raw control byte", "is this fixture labelled correctly" - is
memoisable. A detector whose question is REACHABILITY - `audit-script-census` asking "does anything
call this?", `audit-guard-contract` asking "is this detector DEAD?" - is inherently whole-tree, because
adding one file can change the answer for a file that did not change. Those need an incrementally
maintained call-graph index, which is a substantially bigger build and a new thing to keep correct.

Buys: turns the floor from O(N) to O(changed) for the per-file half. Costs: the largest build here, and
the reachability detectors are exactly the expensive ones it cannot help.

## 5. What I would actually do, and when

**Nothing today.** 51 seconds is not hurting anyone, and every option above costs more than it returns
at the current size. Building any of them now would be optimising against a projection rather than a
problem - which is the mistake this document exists to avoid making twice in one day.

**The order when it does hurt: A, then B, then C.** A is a judgement written down and costs no
machinery. B is a cache with one hard failure mode that a fixture can pin. C is a rebuild of the
detectors and should only follow evidence that A and B were not enough.

**The trigger, so this is not a vibe.** Re-read this document when EITHER:

- `run-gates` wall exceeds **90 seconds** (it is 51s; that is roughly one doubling away), or
- `test-auditors` exceeds **10 minutes** (it is 291s; also roughly one doubling), or
- the pool's throughput bound exceeds the longest gate by more than 3x, meaning `work / 16 > 93s`,
  at which point dispatch tuning is definitively finished and only A/B/C remain.

Each is one line to check and each is printed by the tools already.

## 6. What this note does not claim

- It measures ONE machine on ONE day. The 16-wide saturation is a property of this hardware, and a
  bigger machine moves the divisor, not the asymptote.
- The growth rate is five and a half weeks of history extrapolated. Five weeks is not a trend, and a
  doubling every six weeks will not continue indefinitely; treat the projections as an order of
  magnitude, not a schedule.
- **It does not propose changing what any gate asserts.** Every option above keeps all 306 verdicts.
  The estate's rule that a gate is never weakened to buy something else is not in tension with any of
  this, and if any option ever appears to require it, that option is wrong.
