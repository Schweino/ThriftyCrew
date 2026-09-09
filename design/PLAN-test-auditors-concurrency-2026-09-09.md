# Plan: make test-auditors' 271 child spawns overlap, without changing one verdict

**Status: A PLAN, NOT A CHANGE. Nothing in this document has been built.** Brad asked for it to a
file before any code moved, because the target is 6,468 lines with ~148 call sites.

**Harness measured:** `grocery/test-auditors.ps1 -SelfTest`, run at commit `f9badfb1e` against the
live 2026-09-09 board. **Verdict read first: exit 0, `TEST-AUDITORS-COMPLETE pass=702 failed=0`.**

## The measurement

| | |
|---|---:|
| wall clock | **459s** clean, 391s instrumented (see note) |
| checks | **702** |
| child process spawns | **271** |
| total child time | **268.8s, 69% of the run** |
| median child | 357ms |
| longest single child | **34.9s** (`test-matcher-parity.ps1 -Sample 400`) |
| synchronous `RunPS` call sites | **148** |
| batched `RunPSMany` call sites | **3** |

The two wall clocks differ because the instrumented run and the clean run were separate runs minutes
apart on a machine doing other work; **the 268.8s child total is what matters and it came from the
instrumented run.** Do not read 459 minus 391 as an instrumentation cost - it is run-to-run variance,
and neither figure was repeated enough to quote a range.

**How it was measured, and how the file was protected.** `PSChild`'s one-line body is the funnel every
`RunPS` and every direct `PSChild` call passes through, so it was patched to log script, arguments and
elapsed time, run once, then **restored with `git checkout` and verified byte-identical by md5**
against the pre-edit hash (`2e3a6dcf61991be646b8e2aa6d8de176`). Never trust your own restore.

### Where the time is

| | share of child time |
|---|---:|
| top 5 scripts | **47%** |
| top 10 scripts | 64% |
| top 20 scripts | 79% |
| 93 distinct scripts in total | 100% |

**The ten longest single calls are 141.6s, 53% of all child time.** The top five:

| seconds | script | arguments |
|---:|---|---|
| 34.9 | `test-matcher-parity.ps1` | `-Sample 400` |
| 32.3 | `audit-spec-contradictions.ps1` | `-Quiet` |
| 24.9 | `test-match-lib.ps1` | `-Quiet` |
| 13.6 | `audit-script-census.ps1` | *(none)* |
| 10.6 | `fanout-lib.ps1` | `-SelfTest` |

**116.3 seconds in five calls, and not one of them passes an output path.** They are read-only
analysers and self-tests.

### The floor, so nobody expects more than is there

**31% of the run - about 122s - is in-process harness work and is NOT recoverable by batching.**
Overlapping children cannot go below the longest single child, 34.9s. So the best case for a full
refactor is roughly `122 + 35 = 157s`, against 391-459 today. Anything promising better than about
2m40s is promising something this measurement does not support.

## The pattern to copy, and it is already in this repo

`grocery/guards.ps1` solved exactly this in August: `Register-Kid` queues every child up front,
`Wait-Kid` harvests it lazily **at the original call site**. Its header states the property that makes
it safe here, and it is the whole reason to prefer it over inventing something:

> HARVEST ORDER IS THE ORIGINAL CALL ORDER. Results are read back at exactly the site that used to
> make the call, so every ok/warn/HARD FAIL line keeps its text AND its position in the report.

Same process boundary, same exit code, same arguments, same artifacts. **Only the waiting overlaps.**
`guards.ps1` also documents why NOT to dot-source the children's functions instead: every child audit
declares `param()` at file scope, so dot-sourcing executes that in the caller's scope and clobbers its
variables. That reasoning applies here unchanged.

## THE CENTRAL HAZARD: 82 of 101 children share an output path

This is the finding that should shape the whole build, and it is why "just batch them all" is the
wrong first move.

- **101 children pass an explicit `-ReportDir` / `-OutDir` / `-OutFile`, and 82 of those write into a
  path another child also writes.** 24 share one `cov-ledger-*` directory; 7 share a `taudit-rep-*`;
  7 share a `sanity-native-*`.
- **170 children pass no output path at all**, so they write wherever they default. This file's own
  header records what that costs: a fixture run once overwrote `out\pack-basis-audit.json` and
  `out\basis-reconcile.json` with a synthetic board's result, and the live report read clean.

**Run two of those concurrently and they race on the same file.** Serial execution is currently
hiding that, so the collisions are latent today and would become real defects on the day of the
change. Any site that is batched must first be given its own output directory.

## Three tiers, smallest blast radius first

### Tier 1 - the five giants, five call sites

Launch the five scripts above at the very start of the suite and harvest each at its existing
assertion site. **None passes an output path**, which is what makes this tier nearly free: no
collision analysis, no temp-directory rework.

- Expected: their 116.3s overlaps into the ~275s of remaining work and largely disappears.
  **391s becomes roughly 280s.**
- Risk: low. Five sites, no shared writes, verdict text and order unchanged.
- **This tier alone is about a quarter of the runtime for five edits, and it is what I would build
  first if anything is built.**

### Tier 2 - the top 20 scripts, 79% of child time

Extend to the next tranche. **Requires the collision work**: each batched child gets its own output
directory, and every assertion that reads a report file must be checked to read the right one.

- Expected: approaching the 157s floor.
- Risk: moderate, and concentrated entirely in the shared-path set.

### Tier 3 - all ~148 sites

The full `Register-Kid` conversion. Completes the pattern and prevents the next long child from
re-creating the problem.

- Expected: the floor, roughly 157s. **Only about 20s better than Tier 2** for far more surface.
- Risk: highest. 148 sites in a data-dependent suite.

## Verification, which is not negotiable

**Diff the 702 verdicts BY NAME, never by count.** A suite that silently runs a subset still prints a
large number, and this estate has a memory for exactly that. The suite already prints per-check lines,
so: capture before, capture after, sort, diff. Identical name-and-verdict sets or the change does not
ship. Count equality is not evidence.

Also required before shipping:
- exit code read first, then the tally
- a run against a **real board**, since the suite is data-dependent and goes blind (rc=3) without one -
  which is exactly why `run-gates` excludes it
- `run-gates` green afterwards, because `test-auditors.ps1` source shape is pinned by other checks

## What this plan does NOT propose

- **It does not propose putting `test-auditors` into `run-gates`.** The exclusion is deliberate and
  correct: the boards are gitignored, so on a clean checkout it reports could-not-evaluate, and gating
  pushes on that trains people to ignore red.
- **It does not weaken, skip or sample any check.** All 702 continue to run. The only thing that
  changes is when the harness waits.
- It does not touch `check-ad-cycles.ps1`, which carries 81 audit references and has not been profiled.
  **If the daily chain's cost is the real concern rather than the interactive one, profile that first** -
  test-auditors may be one part of a larger number, and this plan would then be optimising the wrong
  seven minutes.

## One stale number found on the way

`ops/run-gates.ps1`'s `$SKIP` entry says test-auditors' *"418 checks"*. It is **702** - up 68% since
that comment was written, which is most of why the suite feels slower than it used to. Worth correcting
whether or not any of this is built.
