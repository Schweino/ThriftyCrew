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

## Results - appended after the run

**Run:** 2026-09-11, trials started 15:00:59 to 15:15:41. **Harness:** `sidecar/probe_double_load.py` at
`7f8fa73287ce65352af8fd7cd5845d500ee9dc64`, clean (`harness_dirty` false in all 18 rows), run under
`C:\Codex\ThriftyCrew\sidecar\.venv\Scripts\python.exe` (Python 3.12.10). **Arms:** `unlocked` = `sidecar/app.py`
at `38cce56c55911c83405843def6c50d16070ff1cd` (blob `12939f86bf`), `locked` = `sidecar/app.py` at
`7f8fa73287ce65352af8fd7cd5845d500ee9dc64` (blob `d6a5016a51`). Each arm's extracted copy was checked
byte-identical to its blob with `git hash-object --no-filters` before the first trial. **Verdict read:** harness
exit 0; `invalid trials: 0 of 18`.

**The ids above are the ones the rows record, and a rebase onto a moved origin/main rewrote them before the push.**
Checked, not assumed: `sidecar/app.py`, `sidecar/probe_double_load.py` and `sidecar/lib_match.py` carry the same
blob before and after the rewrite, and nothing upstream that the rebase put underneath touched `sidecar/`.

| arm | as the rows record it | on main |
|---|---|---|
| unlocked | `38cce56c5` | `eb32b00b3226ab6be3f1127b3415568429ffa820` |
| locked, and the harness | `7f8fa7328` | `16ca1df7c6a6b7fc3a19eb097e3f7ebc4e49225a` |

The blob ids, which a rebase cannot move:

| file | unlocked arm | locked arm |
|---|---|---|
| `sidecar/app.py` | `12939f86bf` | `d6a5016a51` |
| `sidecar/probe_double_load.py` | `e3a804dadf` | `e3a804dadf` |
| `sidecar/lib_match.py` | `360c93b5ad` | `360c93b5ad` |

The commit each arm ran at, on main: eb32b00b3226ab6be3f1127b3415568429ffa820 (unlocked) and
16ca1df7c6a6b7fc3a19eb097e3f7ebc4e49225a (locked, and the harness).

Re-read at commit 7f3c964f73c56572df610df545989c17fb43a85e: the one change to `sidecar/app.py` after 16ca1df7c
writes this document's measured figures into the comment above `matcher()`. Only comment lines moved, so
`matcher()`, `health()` and the lock are the code the locked arm ran, and every verdict above still holds.

### The verdicts, as `--summarise` derived them from the rows file

- **B1 CONFIRMED.** `load_count` 2 in **6 of 6** unlocked concurrent trials (3 `pair0`, 3 `hook`).
- **B2 CONFIRMED.** Median held **9,032 MiB** over the 6 trials with `load_count` 2, against **4,621 MiB** over
  the 3 unlocked single trials: **1.95x** against a bar of 1.6x. The 2026-09-10 readings were 8,990 and 4,527
  MiB, 1.99x. The unguarded double load is the 2x.
- **B3 ACCEPTED.** `load_count` 1 in **6 of 6** locked concurrent trials, every request 200 in **6 of 6**, median
  held **4,606 MiB** against **4,500 MiB** for the 3 locked single trials: **2.4%** drift against a bar of 15%.

| arm | shape | valid | load_count | held MiB, per trial | median held |
|---|---|---|---|---|---:|
| unlocked | single | 3 of 3 | 1, 1, 1 | 4,555 / 4,621 / 4,621 | 4,621 |
| unlocked | pair0 | 3 of 3 | 2, 2, 2 | 8,943 / 9,116 / 8,977 | 8,977 |
| unlocked | hook | 3 of 3 | 2, 2, 2 | 9,087 / 9,189 / 8,949 | 9,087 |
| locked | single | 3 of 3 | 1, 1, 1 | 4,492 / 4,500 / 4,605 | 4,500 |
| locked | pair0 | 3 of 3 | 1, 1, 1 | 4,735 / 4,589 / 4,623 | 4,623 |
| locked | hook | 3 of 3 | 1, 1, 1 | 4,542 / 4,402 / 4,649 | 4,542 |

Every trial, in run order. MiB of a 16,303 MiB card; "after kill" is the card once the trial's process tree was
gone, which is what the next trial's baseline had to settle from.

| trial | round | arm | shape | baseline | after | held | peak held | load_count | load_seconds | after kill |
|---:|---:|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 | unlocked | single | 2,284 | 6,839 | 4,555 | 4,555 | 1 | 19.1 | 2,013 |
| 2 | 1 | locked | single | 1,964 | 6,456 | 4,492 | 4,533 | 1 | 14.5 | 1,878 |
| 3 | 1 | unlocked | pair0 | 1,910 | 10,853 | 8,943 | 8,943 | 2 | 23.5 | 2,048 |
| 4 | 1 | locked | pair0 | 1,942 | 6,677 | 4,735 | 4,718 | 1 | 13.9 | 2,017 |
| 5 | 1 | unlocked | hook | 1,875 | 10,962 | 9,087 | 9,088 | 2 | 21.6 | 1,947 |
| 6 | 1 | locked | hook | 1,834 | 6,376 | 4,542 | 4,530 | 1 | 24.3 | 1,690 |
| 7 | 2 | locked | pair0 | 1,709 | 6,298 | 4,589 | 4,589 | 1 | 16.9 | 1,639 |
| 8 | 2 | unlocked | pair0 | 1,661 | 10,777 | 9,116 | 9,116 | 2 | 61.5 | 1,803 |
| 9 | 2 | locked | hook | 2,034 | 6,436 | 4,402 | 4,627 | 1 | 18.8 | 1,819 |
| 10 | 2 | unlocked | hook | 1,787 | 10,976 | 9,189 | 9,189 | 2 | 31.1 | 1,871 |
| 11 | 2 | locked | single | 1,876 | 6,376 | 4,500 | 4,505 | 1 | 23.4 | 1,771 |
| 12 | 2 | unlocked | single | 1,765 | 6,386 | 4,621 | 4,637 | 1 | 21.6 | 1,781 |
| 13 | 3 | unlocked | hook | 1,781 | 10,730 | 8,949 | 8,949 | 2 | 22.6 | 1,765 |
| 14 | 3 | locked | hook | 1,765 | 6,414 | 4,649 | 4,649 | 1 | 13.3 | 1,797 |
| 15 | 3 | unlocked | single | 1,797 | 6,418 | 4,621 | 4,621 | 1 | 12.7 | 1,813 |
| 16 | 3 | locked | single | 1,781 | 6,386 | 4,605 | 4,609 | 1 | 12.7 | 1,785 |
| 17 | 3 | unlocked | pair0 | 1,765 | 10,742 | 8,977 | 8,993 | 2 | 21.8 | 1,797 |
| 18 | 3 | locked | pair0 | 1,645 | 6,268 | 4,623 | 4,623 | 1 | 12.4 | 1,635 |

### What the bar did not cover, stated so nobody has to find it

- **The idle reference was taken high, so the baseline check was looser than designed.** It read 2,598 MiB,
  sampled just after `stop-sidecar.ps1` returned; the card read 1,660 MiB with nothing of ours on it at 15:16:40,
  and trial baselines ran 1,645 to 2,284. So "settled within 300 MiB of idle" admitted baselines up to 2,898
  where about 1,960 was meant. Two baselines stand out, trial 1 (2,284) and trial 9 (2,034). Neither is a
  previous trial's residue - the card read 1,635 to 2,048 after every kill, and one trial's models are 4,400
  MiB or more. Trial 9's peak held (4,627) is above its held (4,402), which fits about 200 MiB of some other
  process's memory in its baseline. Scoring trial 9 at its peak instead moves the locked concurrent median to
  4,625 MiB and the B3 drift to 2.8%; trial 1 is not the median of its cell. **No verdict moves.** Not fixed in
  the harness: a change that has never been run is not a fix, and the next run should take the idle reference
  as the lowest settled reading rather than the first.
- **Peak held is a SAMPLED lower bound.** The sampler polls every 0.5 s, and in trials 4 and 6 it reads below
  the settle wait's own reading. No bar reads it.
- **The `hook` shape reached the matcher both times.** `/recall-search` answered `ok: true` in 6 of 6 `hook`
  trials; a missing index would have returned before `matcher()` and made that shape a single request.
- **Load time is an observation, not a measurement, and no bar reads it.** `load_seconds` ran 21.6 to 61.5 s in
  the 6 double-load trials against 12.4 to 24.3 s in the 12 single-load trials, on a box shared with other
  sessions' gates. It says, unqualified, that a double load also stretches the cold start that the recall
  hook's 1.5 s timeout is waiting on.
- **The watchdog came round once.** Trial 18 waited out the 15:15 run, which restarted the service (stamp
  `restarted` at 15:15:28, task result 0); the harness stopped it through `stop-sidecar.ps1` before the trial.
  The restart succeeded, so the watchdog's alert path was never taken.

### The live service after the run

Restarted through `C:\Codex\ThriftyCrew\sidecar\start-sidecar.ps1` at 15:16:40: exit 0, `load_seconds` 12.3, card
**1,660 -> 6,370 of 16,303 MiB, about 4,710 MiB held**. That instance serves the MAIN checkout's `app.py`, which at
that moment did not carry these commits (blob `460d827d31`, no `load_count` on `/health`), and `start-sidecar.ps1`
warms with one request, so it is a single load either way. The guard is live from the first restart after the
main checkout carries the locked arm's change, and `/health` says so itself: it reports `load_count` only then.
