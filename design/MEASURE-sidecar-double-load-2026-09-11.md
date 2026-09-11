# Does the sidecar load its models twice on a cold start?

**Status:** the design and the acceptance bar below were written and committed on 2026-09-11 BEFORE any
trial ran. The results section is appended after the run and does not edit anything above it.
**Harness:** `sidecar/probe_double_load.py`, run under `sidecar\.venv\Scripts\python.exe`.
**Commits:** stated in the results section - the harness commit and the commit each arm's `app.py` came from.
**Rows:** `design/MEASURE-sidecar-double-load-2026-09-11.jsonl`, one row per trial per arm. Every total in
this document is derived from that file by `probe_double_load.py --summarise`, never typed.
**Machine:** RTX 5070 Ti, 16,303 MiB; 32 logical cores; Windows 11.

## The question

Measured 2026-09-10 on the same card, idle about 1,650 to 1,700 MiB:

| restart | how the first load happened | card after | held |
|---|---|---:|---:|
| 06:30, 06:33 | inside the recall hook's two back-to-back requests (`/recall-search`, then `/embed` 1.5 s later, both timing out client-side while the server kept loading) | 10,629 to 10,685 MiB | about 8,990 MiB |
| 06:58 | `start-sidecar.ps1` sent ONE `/embed` and waited for it | 6,227 MiB | about 4,527 MiB |

About 2x. `app.py`'s `matcher()` did `if _M is None: _M = Matcher.load(with_reranker=True)` with no lock,
and FastAPI runs sync endpoints on a threadpool, so two first requests arriving together can both see
`None` and both load. That was an INFERENCE from two card readings. This document tests it.

## Design

**Two arms**, each a copy of `sidecar/app.py` taken from a named commit:

- `unlocked` - the original `matcher()` plus ONE change: every entry into `Matcher.load` appends to a list
  before the load starts, and `/health` reports its length as `load_count`. `list.append` is atomic under the
  GIL, so the count stays exact while two threads race into the load.
- `locked` - the same counter, with `matcher()` guarded by a double-checked `threading.Lock`.

**Three request shapes**, fired at a server whose `/health` has answered and whose models are NOT loaded:

- `single` - one `/embed`. The control: what one load holds.
- `pair0` - two `/embed` released together by a barrier.
- `hook` - `/recall-search` at 0 s and `/embed` at 1.5 s: the recall hook's shape at 06:30 on 2026-09-10.

**18 trials**: 3 rounds x 2 arms x 3 shapes, 3 trials per cell. Within a round every shape runs on both
arms back to back, and the order of arms and shapes rotates round by round, so neither arm always runs
first or on a warmer disk cache.

**One trial** is a fresh server process on probe port 8079 serving one arm, launched directly and not
through `start-sidecar.ps1` - the front door warms the service with ONE request before it returns, which is
exactly the thing that would prevent the race. The live service on 8077 is stopped through
`sidecar\stop-sidecar.ps1` before every trial, so the card holds nothing else of ours. No trial starts
within 180 s of a quarter-hour mark: `TC Sidecar Watchdog` fires every 15 minutes and restarts a service it
finds down, so the harness waits for that run to finish and stops what it restarted, through the front
door again. No trial starts within 180 s of the 21:30 GPU window (ruling R1).

**Primary metric:** `load_count` from `/health`, read after every request in the trial has returned.
**Secondary:** held MiB = `nvidia-smi` memory.used once it is stable after the requests, minus the same
trial's own settled baseline; and the peak during the trial.

**A trial is INVALID** - kept in the rows file, excluded from the verdicts, and counted by name - when
`/health` never answered, when it reported the models already loaded before the requests, when a listener
was on 8077 at the start or end, when the baseline did not settle within 300 MiB of the idle reference, or
when a request thread hung past its guard. A cell with more than one invalid trial makes every bar that
reads it BLIND.

## Acceptance bar - written before the run

- **B1, the double load exists.** Arm `unlocked`, shapes `pair0` and `hook`: CONFIRMED if `load_count` is 2
  or more in at least 1 of the 6 trials, because the claim under test is that two first requests CAN both
  load. REFUTED if `load_count` is 1 in 6 of 6. The rate, k of 6, is reported either way.
- **B2, the double load is the 2x.** CONFIRMED if the median held MiB of the `unlocked` trials that read
  `load_count` 2 is at least **1.6x** the median held MiB of the 3 `unlocked` / `single` trials. Below that,
  the double load is real but does not explain the card reading, and the 2x needs another cause.
- **B3, the fix.** ACCEPTED only if arm `locked`, shapes `pair0` and `hook`, reads `load_count` = 1 in
  **6 of 6** trials, every request in those trials returns 200 (a caller that queued at the lock must not
  fail), and their median held MiB is within **15%** of the `locked` / `single` median. One `load_count` of
  2 fails it.

**Where the numbers came from, and what else was tried.** 1.6x: two loads sharing nothing would read 2.0x,
and one process pays its CUDA context once however many loads it does, which pulls the ratio below 2; the
2026-09-10 readings gave 1.99x. 1.6 is the first plausible number, not the survivor of a sweep. 15%: also
first plausible, not swept; the only earlier reading of a warmed single load is one reading (4,527 MiB),
which is no basis for a tighter band. Neither threshold was moved after the rows existed.
