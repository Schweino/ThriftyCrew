# PLAN — use the cores

**Status: PROPOSED, written 2026-08-23 for a fresh build session. The machine is a Ryzen 9
9950X (16 cores / 32 threads). Every stage in this estate that is not a capture lane runs on
ONE of them. This plan says which stages to fan out, in what order, what must stay serial and
why, and how to prove each phase did not make a watcher go quiet.** Every number below was
measured on 2026-08-23 from the chain's own timestamped log (`grocery\ad-cycle-log.txt`) or
from an instrumented copy of `test-auditors.ps1` that timed every `Ok`/`Bad` call.

**Already in flight, do not redo:** task `task_ba80d0e1` parallelises the five checks that
own 75% of `test-auditors` (`test-match-lib` over ~37k names, and the three
`basis-reconcile` fixture runs). This plan is everything *else*. If that task has not landed
when you start, build phases 1–3 here anyway; they do not touch the same files.

---

## 0. The shape of the problem, measured

The 2026-08-22 daily chain (`check-ad-cycles.ps1`, the downstream of the 08:00 task) ran
**95 minutes wall**. Its time is not smeared. Excluding `test-auditors` (877 s, owned by the
task above) the tail is **~750 s across ten independent advisory audits, run one after
another**:

| stage (child of check-ad-cycles) | wall | reads | writes |
|---|---|---|---|
| match-soundness + aisle-test | 173 s | regular\*, comparison-* | out\audit\* |
| semantic sweep | 136 s | regular\*, commodities | out\semantic-findings.json |
| discover-hyvee | 110 s | hyvee-regular-*, comparison-* | out\discovery\* |
| coverage-gaps | 106 s | ads-*, regular\* | out\coverage-*.json |
| price-alerts | 66 s | comparison-*, price-history | **Send-Alert** |
| basis-reconcile | 47 s | comparison-* | out\basis-reconcile*.json |
| multipack-repair | 39 s | regular\* | **regular\* (MUTATES)** |
| derive-links | 39 s | regular\*, product-urls | product-urls.json |
| commodity-dupes | 26 s | commodities, categories | out\commodity-dupes.json |
| matcher-parity | 22 s | match-lib, compare-deals | — |

Fanned out 8-wide the group is bounded by its longest member: **~750 s → ~200 s**. With the
queued `test-auditors` work, the chain goes from ~31 min of downstream to roughly 10.

Two stages that LOOK slow and are not CPU:
- **Ghost publish** (the `AUTO-PUBLISH: live page updated` step after `share-image`) shows
  gaps of 60–449 s across days. It is network-bound with 7× day-to-day variance, which reads
  as retries/timeouts, not compute. Cores will not help. Out of scope here; noted in §7.
- **The 3,883 s gap** at the top of the 08-22 run is a logged artefact (an interactive run
  interleaving), not a stage.

Already parallel — leave alone: the capture lanes (`Start-Job` in `capture-run.ps1`), the
browser lanes (`pull-browser-stores.py`, one thread per store, shipped 2026-08-23), and the
six Python files that already use pools (`graph/pipeline/resolve.py`,
`graph/learning/local_triage.py`, the three `graph/bench/*` scripts).

---

## 1. The rules every phase obeys

These are not style. Each one is a way a fan-out turns a watcher into a blind watcher, which
is the exact failure class 2026-08-23 was spent killing (a scanner with a backspace in its
regex; a cadence gate whose functions never existed; a capture proven present then dropped
by a relative path — all three reported something reassuring).

1. **Every child's completion is positively accounted for.** A fan-out that collects "no
   error" from N children has not proved N children ran. Each lane returns a record
   (name, rc, marker-seen, elapsed); the collector asserts the count equals the launch count
   and that every expected `*-COMPLETE` marker appeared. A missing record is a **BLIND**
   finding in `$summary`, never silence.
2. **`$summary` and the log are emitted in a deterministic order** — the launch order, not
   the finish order. The daily summary is diffed by eye; if it reshuffles every run nobody
   can read it. Capture each lane's output in memory; `Log` it in sequence after the join.
3. **Nothing that MUTATES shared inputs runs inside a fan-out.** `repair-multipack-sizes`
   rewrites `out\regular\*.json`, which five other lanes read. It runs *before* the fan-out,
   alone, or the fan-out reads a file mid-rewrite and reports on a board that never existed.
4. **`Send-Alert` is not concurrency-safe. Do not call it from inside a lane.** Its
   once-per-type-per-day gate is a read-then-append on `grocery\alert-sent-<day>.txt`
   (`send-alert.ps1:203`) — a check-then-act race. Two lanes alerting in the same second can
   double-send or, worse, one suppresses the other. Lanes return "wants to alert: subject,
   body" in their record; the collector sends, serially, after the join.
5. **The EAP=Stop rule holds inside every runspace.** A native child's stderr under
   `$ErrorActionPreference='Stop'` is a terminating error, and `2>$null` CAUSES it. Every
   child launch goes through `Invoke-Native` / `Invoke-NativeScript` (`grocery\native-lib.ps1`).
   `test-native-stderr-eap.ps1` scans every EAP=Stop script and will fail you otherwise.
   Runspaces do not inherit the caller's dot-sourced functions — dot-source `native-lib.ps1`
   inside the runspace script block.
6. **PowerShell 5.1 only.** No `ForEach-Object -Parallel` (PS 7). Use a `RunspacePool`
   (`[runspacefactory]::CreateRunspacePool`), not `Start-Job`: a job is a whole new
   `powershell.exe` (~110 ms and a fresh module load each), a runspace is a thread. One shared
   helper for the pattern — `grocery\fanout-lib.ps1` — so the lesson lives in one place
   (the estate's standing rule; see `run-log-lib.ps1` for the precedent).
7. **A cap, and a flag to turn it off.** Default `-MaxParallel 8`. `-Sequential` restores
   the old order exactly, so a flaky lane is one flag away from diagnosis rather than one
   revert away. Seeding, attended lanes, and anything that opens a visible window stay
   sequential regardless.
8. **Cadence still applies per lane.** `Test-CadenceDue` (implemented 2026-08-23 —
   it had never existed) decides whether each lane runs at all; the fan-out only runs the
   lanes that are due. A skipped lane is logged as SKIPPED with its last-run date, same as
   today. A SKIP IS NOT A PASS.

---

## 2. Phase 1 — `fanout-lib.ps1` and the advisory-audit fan-out

**Goal:** the ten stages in §0 run concurrently; the chain's downstream drops ~550 s.

**Build `grocery\fanout-lib.ps1`** exposing one function, `Invoke-Fanout`, taking a list of
lane definitions (name, script path, args, cadence name + days + input globs, whether it may
alert) and returning one record per lane in launch order. Inside: a `RunspacePool` of
`-MaxParallel`, each lane dot-sources `native-lib.ps1`, calls `Invoke-NativeScript`,
captures `.Output`/`.Error`/`.ExitCode` and the wall time, and returns them. The collector
asserts `records.Count -eq lanes.Count` and that each lane's output contains its completion
marker (these already exist: `COMMODITY-DUPES-COMPLETE`, `STORE-REGISTRY-COMPLETE`,
`GRAPH-GATES-COMPLETE`, `CAPTURE-EVICTION-COMPLETE`, …). Anything else → BLIND.

**Restructure `check-ad-cycles.ps1`'s INSPECT path** into three ordered groups:

| group | contents | mode |
|---|---|---|
| A — mutators | `repair-multipack-sizes`, `derive-links-from-prices`, `fix-links-ff` | serial, in current order |
| B — read-only audits | the ten in §0 minus the mutators, plus `store-registry`, `commodity-dupes`, `matcher-parity`, `precedence-ladders`, `graph-gates`, `capture-eviction`, `search-terms`, `walmart-fullpull` | **fan-out** |
| C — alerts + summary | collector sends any alerts the lanes asked for, in launch order; appends to `$summary` in launch order | serial |

Do the per-lane `$summary += 'REVIEW ...'` lines and the `Set-CadenceRan` stamps in group C
from the records, not inside the lanes — `$summary = @()` (`check-ad-cycles.ps1:286`) is a
plain array and `$script:` scope does not cross runspaces.

**Watch for:** `discover-hyvee` and `coverage-gaps` both read `comparison-*.json` — fine,
reads are safe. `audit-match-soundness` writes `out\audit\*` — confirm no other B lane reads
that directory during the run. The existing `try/catch` around each stage becomes the lane's
record; **do not drop the non-fatal-by-construction property** — a lane throwing must yield a
record with `rc = -1` and the message, never an exception out of the pool.

**Verify:** (a) run the chain with `-Sequential` and without, same inputs, same day; diff the
two `$summary` blocks and the two sets of `out\*` artefacts — they must be identical
byte-for-byte except timestamps. (b) Kill one lane mid-run (rename its script); the run must
report that lane BLIND by name and still complete every other lane. (c) `test-auditors`
473/0 and `test-native-stderr-eap` 6/6 after. (d) Add a `test-auditors` case: the fan-out
with a lane whose script is missing reports BLIND, not clean.

---

## 3. Phase 2 — `test-auditors.ps1`: the other 433 checks

**Only after `task_ba80d0e1` lands.** Once the five heavy checks are fixed, the remaining 433
total **49 s** — there is little left to win, and the file is a single 3,900-line linear
script where each check builds its fixture inline then asserts. Do NOT shard the whole file;
that was considered on 08-23 and rejected as a large risky edit to the estate's most
load-bearing harness for a ~40 s gain.

What IS worth doing, cheaply: the ~19 independent `-SelfTest` children (lines ~3638–3877:
`$ffs`, `$fcp`, `$sps`, `$asc`, `$rsc`, `$rbb`, `$rcm`, `$rrb`, `$srb`) each spawn a
`powershell.exe` and none depends on another. Launch them through the same `Invoke-Fanout`,
collect the `$r` strings, then run the existing assertions unchanged against the collected
output. The assertions stay exactly where they are; only the launches move.

**Verify:** pass/fail counts identical to the serial run; every assertion still reads the
same `$r` text it read before (the `SELFTEST: N/N pass` pins are load-bearing — see the
19/19 note at `test-auditors.ps1` `$fcp`).

---

## 4. Phase 3 — Python: profile first, then only `resolve`-shaped work

Six Python files already use pools. Of the rest, the candidates by size are
`graph/import/importers.py` (1,150 lines), `review_escalations.py` (830), `state.py` (482),
`import_all.py` (173). **None of these has been timed.** Phase 3 starts with
`python -X importtime` / `cProfile` on `import_all.py` against the live graph and writes the
numbers into this plan before any change.

**Hard constraint found on 08-23:** every importer writes the same `GraphDB`, and `GraphDB`
is SQLite (`graph/learning/local_triage.py:45,67` opens it read-only over `sqlite3`). SQLite
is single-writer. Fanning the importers out across processes **serialises on the write lock
at best and fails with `database is locked` at worst** — it would look faster in a unit test
and be slower or broken on the real file. Do not parallelise the importers as written.

What is legitimately parallel in Python here is the *read-and-compute* half of a stage whose
writes are batched: parse the source JSON for all stores in a `ProcessPoolExecutor`
(CPU-bound, 16 real cores), then write the rows in one transaction on the main process. Only
do this for a stage the profile shows is >20 s and compute-dominated. If the profile says
the time is in SQLite writes, the fix is a bigger transaction, not more cores.

**Verify:** row counts and `build_cell_state` output identical to the serial import on the
same snapshot; `audit-graph-gates.ps1` reports the same seven gates.

---

## 5. Phase 4 — the capture lanes' own tails (small, optional)

`capture-run.ps1` already runs the three API stores as jobs. After they land, each store's
builder (`build-sams-deals.ps1`, `select-fareway-shop.ps1` → `build-fareway-regular.ps1`,
`build-walmart-deals.ps1`) runs serially. They write distinct files and read only their own
capture, so they can run through `Invoke-Fanout` once every capture has landed. Savings are
tens of seconds; do it only because the helper already exists by then. Keep the absolute
`-In` path fixed in 189472c1 — the builders are handed `Join-Path $root $capRel`, never
`$capRel`.

---

## 6. Order, and what to do if a phase fails its verification

Phase 1 → (wait for `task_ba80d0e1`) → Phase 2 → Phase 3 (profile, then maybe) → Phase 4.
Each phase is its own commit with its before/after wall time in the message. If a phase's
`-Sequential` vs fan-out diff is not byte-identical, **stop and find out why before going
on** — a difference is either a real race or a watcher that depends on ordering it never
declared, and either one is a finding, not a nuisance.

Budget note for Brad: check the weekly Claude % before Phase 1 and again before Phase 3.
Phase 1 is the largest edit and the largest win; Phases 2–4 are each a fraction of it.

---

## 7. Out of scope, recorded so it is not lost

- **Ghost publish variance** (60–449 s, §0). Network-bound. Worth its own look for
  retry/timeout behaviour, not for cores.
- **The 08:00 chain's `downstream` rc=1** (2026-08-23). Undiagnosed; the chain stopped before
  its capture-eviction block. Listed in `task_ba80d0e1` as well. Unrelated to parallelism
  but the fan-out restructure in Phase 1 will pass through the same code — read that run's
  log first so the restructure does not paper over it.
- **`test-auditors` in the chain at all.** It is cadence-gated at 7 days-or-inputs-moved and
  the gate works as of 08-23. On a quiet day it should now skip entirely. If it is still
  running daily after this plan lands, the cadence inputs are too broad, not the suite too
  slow.
