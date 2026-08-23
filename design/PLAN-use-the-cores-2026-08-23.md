# PLAN — use the cores

**Status: PROPOSED, written 2026-08-23 for a fresh build session. The machine is a Ryzen 9
9950X (16 cores / 32 threads). Every stage in this estate that is not a capture lane runs on
ONE of them. This plan says which stages to fan out, in what order, what must stay serial and
why, and how to prove each phase did not make a watcher go quiet.** Every number below was
measured on 2026-08-23 from the chain's own timestamped log (`grocery\ad-cycle-log.txt`) or
from an instrumented copy of `test-auditors.ps1` that timed every `Ok`/`Bad` call.

**Landed, do not redo (efe803f5, 2026-08-23):** the five checks that owned 75% of
`test-auditors` (`test-match-lib` over ~37k names, and the three `basis-reconcile` fixture
runs) are parallel. `test-auditors` went 429 s → 202 s with byte-identical check lines.
This plan is everything *else*. **That work also overturned one of this plan's rules —
read rule 6 before building anything.**

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
   The other reason lanes must never call `Log` themselves: it is `Add-Content` on one file
   with a retry-then-sidecar fallback (`check-ad-cycles.ps1:52`). Eight lanes contending on
   it would push some lines into `ad-cycle-log.LOCKED-<day>.txt` and scatter one run across
   two files — the shape that made three runs look dead on 08-21/22.
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
6. **PowerShell 5.1 only, and RUNSPACES HOLD CHILD PROCESSES — THEY DO NOT DO THE WORK.**
   No `ForEach-Object -Parallel` (PS 7). For a lane that launches a child and waits on it,
   a `RunspacePool` (`[runspacefactory]::CreateRunspacePool`) beats `Start-Job`: a job is a
   whole new `powershell.exe` (~110 ms and a fresh module load each), a runspace is a thread.
   Every lane in Phase 1 and Phase 2 is that shape, so use the pool there.

   **But a runspace cannot parallelise PowerShell that does regex work on the thread
   itself.** Measured 2026-08-23 while building efe803f5 — `test-match-lib`'s original
   Match-Category pass, 3,000 names, in-process runspace pool:

       1 runspace 8.9 s CPU | 2: 19.3 s | 4: 38.9 s | 8: 79.5 s | 16: 215.5 s — wall flat at ~14 s

   That is negative scaling. `-match`, `-replace` and `-split` call the STATIC Regex
   methods, and in .NET Framework every static Regex call goes through one process-wide
   pattern cache behind one lock; sixteen threads queue on it. Sixteen *processes* each have
   their own, and the same pass went 174 s → 23 s. So: if the hot loop is PowerShell regex
   on the thread, shard into child processes (pass the work list through a temp file, as
   `test-match-lib.ps1` does); precompiled `[regex]` instances are exempt. The collector's
   own parsing of lane output is trivial and is fine on the thread — the trap is moving a
   lane's *work* onto the runspace to "save a process".

   One shared helper for the pattern — `grocery\fanout-lib.ps1` — so the lesson lives in one
   place (the estate's standing rule; see `run-log-lib.ps1` for the precedent).
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
| A′ — deleters | `prune-out`, `prune-intermediates` | serial, **after B has joined** — they delete dated `out\*` files that B lanes read |
| B — read-only audits | the ten in §0 minus the mutators, plus `store-registry`, `commodity-dupes`, `matcher-parity`, `precedence-ladders`, `graph-gates`, `capture-eviction`, `search-terms`, `walmart-fullpull` | **fan-out** |
| C — alerts + summary | collector sends any alerts the lanes asked for, in launch order; appends to `$summary` in launch order | serial |

Do the per-lane `$summary += 'REVIEW ...'` lines and the `Set-CadenceRan` stamps in group C
from the records, not inside the lanes — `$summary = @()` (`check-ad-cycles.ps1:286`) is a
plain array and `$script:` scope does not cross runspaces.

**Two `test-auditors` checks added in efe803f5 will fire on a careless restructure.** They
pin the fix for the 08-23 downstream rc=1 (see §7):
- *every `Test-CadenceDue -Name` line in `check-ad-cycles.ps1` is indented or a `try {`, and
  there are at least two of them.* If rule 8 moves the cadence decision into `Invoke-Fanout`,
  the count in `check-ad-cycles.ps1` drops and the check fails. Keep the `Test-CadenceDue`
  calls in `check-ad-cycles.ps1` (evaluate them while building the lane list, pass the
  verdict into the lane definition) — or extend the check to scan `fanout-lib.ps1` too.
- *`check-ad-cycles.ps1` ends with an explicit `exit N`.* Whatever the restructure appends,
  `exit 0` stays the last statement.

**Watch for:** `discover-hyvee` and `coverage-gaps` both read `comparison-*.json` — fine,
reads are safe. `audit-match-soundness` writes `out\audit\*` — confirm no other B lane reads
that directory during the run. The existing `try/catch` around each stage becomes the lane's
record; **do not drop the non-fatal-by-construction property** — a lane throwing must yield a
record with `rc = -1` and the message, never an exception out of the pool.

**Verify:** (a) run the chain with `-Sequential` and without, same inputs, same day; diff the
two `$summary` blocks and the two sets of `out\*` artefacts — they must be identical
byte-for-byte except timestamps. (b) Kill one lane mid-run (rename its script); the run must
report that lane BLIND by name and still complete every other lane. (c) `test-auditors`
prints **the same check lines** as a same-day serial run (the suite is 475 checks as of
efe803f5, and five fail at HEAD on this machine for reasons unrelated to this plan — a stale
comparison board, prompt-backup drift, known-wrong red, food-category, feed-covers-published
— so "N/0" is not the bar; an identical transcript is), and `test-native-stderr-eap` 6/6. (d) Add a `test-auditors` case: the fan-out
with a lane whose script is missing reports BLIND, not clean.


### Phase 1 — BUILT AND MEASURED, 2026-08-23

**Result: 34 lanes, wall 513 s → 171 s (3.0×, 342 s off the chain), and 0 of 34 lane verdicts
differ between `-Sequential` and the pool.** Measured on this machine, same inputs, same day,
both passes back to back over the real audits, cadence gates forced DUE so both covered the same
34 lanes.

| lane group | serial-equivalent | fan-out x8 |
|---|---|---|
| all 34 advisory audits | 513 s wall (507 s sum-of-lanes) | **171 s wall** (681 s sum-of-lanes) |

The tail is `discover-hyvee` at 165 s — 40 sequential network searches, not compute — with
`semantic` (118 s) behind it. Nothing else exceeds 60 s, so the fan-out is now bounded by a
network lane and further width buys nothing until that lane is split.

**The I/O hypothesis is real but small.** Sum-of-lanes rose 507 s → 681 s (+34%) under
concurrency, so the lanes do contend. It costs a third of each lane's time and buys back two
thirds of the wall clock. `-MaxParallel 8` stays the default on that number; it was not tuned
further because the tail is one network-bound lane.

#### The 2026-08-22 "parallel is worse" verdict was confounded, and is now corrected in place

`check-ad-cycles.ps1:183` carried *"THE PARALLEL EXPERIMENT IS REVERTED, ON THE MEASUREMENT"* —
serial 30.9 min vs parallel 41.7 min, match-soundness 111 s → 904 s, CPU at 14%. Read the clock:

| 2026-08-22 | commit | what |
|---|---|---|
| 07:24 | `31f4835b` | audits go side by side — through `Invoke-Bounded`, then **`Start-Job`-based** |
| 10:09 | `9825bb80` | parallel **reverted** on the 30.9-vs-41.7 numbers |
| 11:14 | `9a23e342` | `Invoke-Bounded` measured at **3.8 minutes per call for a 1-second script**, and rewritten to `Start-Process` |

The verdict was recorded one hour before the machinery it was measured through was proven to
cost minutes per call, and was never re-measured. That comment has been rewritten rather than
obeyed, with the timeline in it, so the next reader does not revert this on a number that was
never valid.

#### Three things the plan got wrong, found while building

1. **The completion markers mostly do not exist.** §2 names `COMMODITY-DUPES-COMPLETE`,
   `STORE-REGISTRY-COMPLETE`, `GRAPH-GATES-COMPLETE` and `CAPTURE-EVICTION-COMPLETE` as markers
   that "already exist". Only the first is real, and `audit-guard-contract` reports even that one
   HALF-COVERED (two unmarked verdict exits, lines 219/235). `audit-store-registry`,
   `audit-graph-gates`, `audit-capture-eviction` and `audit-row-age` emit nothing.
   **So no phase-1 lane declares a marker.** Demanding one a script does not print turns a
   working audit into a BLIND finding every morning — the false-alarm mirror of the failure the
   fan-out exists to prevent. `Marker` is built and tested in `fanout-lib`; lanes get one as
   `audit-guard-contract`'s backlog closes, one at a time, each proven on a real run first.

2. **Rule 4 needed a root-cause fix, not just a convention.** "Do not call `Send-Alert` from
   inside a lane" is right for check-ad-cycles' own alerts (they all live in the consumption
   blocks already, so nothing moved). But three lanes — `match-soundness`, `store-registry`,
   `category-coverage` — page on their **own** behalf via `-Alert`, as grandchildren, and no
   amount of parent-side discipline serialises those. `send-alert.ps1`'s gate is
   read-then-send-then-append across a 30 s network call. It now holds
   `Global\smp-grocery-alert-sent` across that window — the same shape, named the same way, as
   the triage-queue mutex twenty lines above it, which fixed the same race on the same file on
   2026-07-28. If the wait expires it sends **anyway** and says so: a duplicate email is an
   annoyance, a suppressed one is a watcher gone quiet.

3. **Groups A and A′ needed no work.** The mutators already run above the ship boundary
   (`repair-multipack-sizes` at :526, `derive-links-from-prices` at :764, `fix-links-ff` at :788)
   and the deleters already run below the last reader (`prune-out` / `prune-intermediates` at
   :2185). Both were already correct; the plan's table describes a move that did not need making.

#### What shipped

- `grocery\fanout-lib.ps1` — `New-FanoutLane` / `Invoke-Fanout` / `Get-FanoutRecord` /
  `Test-FanoutComplete`, plus a 14-case `-SelfTest` run from `test-auditors`. `RunspacePool`
  over `Start-Process` children (rule 6: **runspaces hold children, they do not do the work**).
  No `param()` block, deliberately — a dot-sourced `param([switch]$SelfTest)` resets the
  caller's own switches, which is the bug `lib\guard-contract.ps1` already paid for.
- `check-ad-cycles.ps1` — 34 lanes; **only the launch moved.** Every stage's reading, signature
  de-dup, summary line, alert and cadence stamp is byte-identical and now reads its child's
  output out of a record instead of off a pipeline. That is what makes the `-Sequential` diff
  meaningful at all.
- `-MaxParallel 8` (default) and `-Sequential`, wired through and pinned by a test.

#### Verification actually performed

- **(a) same verdicts:** 34/34 lanes identical rc and BLIND state between the two modes. ✅
- **(b) a killed lane reports BLIND by name:** proven in `fanout-lib -SelfTest`, not on the live
  chain. `powershell -File missing.ps1` does **not** fail to launch — it starts, prints its
  banner and exits −196608 — so the first version of this returned `Blind=$false` with no
  finding at all. That is a deleted check reporting a clean board, and it was the harness that
  caught it, not review. Now rc 3 + BLIND, with a frozen fixture. ✅
- **(c)** `test-auditors` PASS and `test-native-stderr-eap` 6/6. ✅
- **(d)** the fan-out BLIND case is a `test-auditors` case, plus four structural ones: every
  lane names a script that exists, every lane is read back by a consumer, no mutator or deleter
  has been added to the pool, and `-Sequential` still exists. ✅

**Not done:** an end-to-end `-Sequential` vs fan-out run of the *whole* chain with byte-compared
`out\*` artefacts. The A/B above covers group B — which is the only part that changed — over the
real audits; the rest of the chain is untouched code. A full-chain diff is still the stronger
test and is worth one run on a quiet morning.

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
- **The 08:00 chain's `downstream` rc=1** (2026-08-23) — **diagnosed and fixed in
  efe803f5.** Of ten `Test-CadenceDue` call sites, nine sat inside a `try`; the tenth was
  the `test-auditors` gate's own top-level `if`. When the helpers turned out never to exist,
  the nine logged "threw" and that one terminated the chain under EAP=Stop two thirds of the
  way in (the 08-23 LOCKED log ends on `prune-intermediates`, then nothing). The file had no
  `exit` statement, so a throw was the only way it could return 1. The capture-eviction block
  was NOT the casualty — it is ~250 lines earlier, in the inspect branch that run never
  entered; that re-run had a different cause. The lesson for Phase 1: one unguarded gate can
  end the chain, which is why a lane's throw must become a record and never an exception.
- **Nested width.** `test-match-lib` now spawns 16 shard processes of its own. It runs from
  `test-auditors`, which is cadence-gated and sits OUTSIDE the Phase 1 fan-out, so the two
  do not stack; if that ever changes, the inner `-Workers` must come down or a quiet
  morning becomes 8×16 powershell.exe.
- **`test-auditors` in the chain at all.** It is cadence-gated at 7 days-or-inputs-moved and
  the gate works as of 08-23. On a quiet day it should now skip entirely. If it is still
  running daily after this plan lands, the cadence inputs are too broad, not the suite too
  slow.
