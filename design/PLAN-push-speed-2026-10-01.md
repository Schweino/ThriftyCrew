# Push speed: a landing in minutes, not twenty (2026-10-01)

Brad, 2026-10-01: "20 minutes for a push is not acceptable."

## Knowledge consulted

- `design/PLAN-use-the-cores-2026-08-23.md` and `-2`: test-auditors parallelism was measured then at 202 to 226 s and
  closed as an 8 s win. That verdict is stale: a full run is 631 s today (below).
- `skills/concurrency-craft/applies-here.md`, "Landing a push on the shared ThriftyCrew main": push-main's design A,
  the lock holds only the swap, legs outside it.
- `.claude/rules/ops-and-gates.md` og-21 (ordinal keys), og-27 (lock order), og-36 (no upper wall-clock bar in a
  hermetic self-test), og-45 (a keyed self-test's key).
- `lib/parallel-run.ps1` header: separate processes, not runspaces, because of PS 5.1's regex lock.

## What a landing costs today (measured, not guessed)

Six landings on 2026-10-01 (`%LOCALAPPDATA%\ThriftyCrew\triage-land\land-20261001-*.log`):

| landing | total | run-gates wall | test-auditors |
|---|---|---|---|
| 11:34 refused | 15.0 min | 861 s | not reached |
| 12:14 refused | 24.9 min | 747 s | full, 802 cases |
| 13:32 landed | 18.5 min | 392 s | full, 818 cases, 631 s |
| 14:03 refused | 11.5 min | 668 s | not reached |
| 14:27 landed | 17.8 min | 396 s | full, 818 cases |
| 14:47 landed (one plan JSON) | 8.2 min | 452 s | not run |

One run-gates on an UNCHANGED origin/main in a fresh seeded worktree, every output line timestamped
(`scratchpad\gates-timed.txt`): **357 s total**. 12.5 s discovery; **293 s keying** (14.6 s to 307.4 s, before the pool
starts); then the pool ran the 72 jobs it could not reuse in about 48 s. The run's own timing line said "serial would
have been about 363s, so the pool is saving roughly 19s a run": the 24-wide pool is not the bottleneck, the serial pass
in front of it is.

Keying cost, isolated: `Get-TcGateInputKey` over 120 real gates, alone on the box: **1,367 ms a gate** (164 s). Each
gate re-reads, re-strips, re-resolves and re-hashes the same shared libraries; nothing is reused across gates.

## The steps, in order of size of win and inverse order of risk

1. **Memoize the keying pass** (no ruling needed; shipped first).
   `lib/gate-input-key.ps1`: a TEXT memo (always on, ordinal keys, pure functions of the exact text) and a RUN memo
   (only between `Enable-TcGateKeyMemo` and `Disable-TcGateKeyMemo`, which run-gates calls around its keying loops;
   file SHA-256s and reference/glob resolution, keyed on the gate's folder). Bar written before the run: every key
   byte-identical with the memo on and off, and at most 200 ms a gate. Result: 287 of 287 keys identical; 688 -> 137 ms
   a gate with the run memo (1,367 ms before either memo). Self-test 129 of 129 (3 new: the default-off memo sees a
   rewritten file, the on memo caches, off again drops it).
2. **Run the test-auditors leg BESIDE run-gates, not after it** (`ops/push-main.ps1` Invoke-TcDefaultLegs). This changes
   the D1 sequencing of W9.3, on Brad's ruling above. test-auditors runs in its own detached, seeded worktree of the
   same HEAD (as `grocery/triage-land.ps1 -Rehearse` already does) so neither leg's writes can trip the other's
   gate-leftovers check. A red run-gates still waits for test-auditors, so one refusal names both layers.
   Expected: a push costs max(gates, test-auditors) instead of the sum.
3. **Find where test-auditors' 631 s goes, then fix THAT** (measured before choosing sharding). Each `Use-Unit` call was
   timestamped in a throwaway copy over one full run (704 s attributed over 157 labels): **u001-1-basis-reconciler was
   354 s, half the suite**; the next unit was 36 s. Its four frozen-board cases called `audit-basis-reconcile.ps1`
   without `-RawDir`, so each one scanned the LIVE captures under grocery\out: 139.8 s a run against 0.4 s with an empty
   fixture folder, same verdict (`checked=1 findings=1`). That is also why the suite grew from ~200 s (2026-08-23) to
   631 s with the data, and it made the fixture non-hermetic. Fixed with an empty `-RawDir`: u001 1.9 s, 4 of 4 pass.
   The two calls were the only `audit-basis-reconcile` fixtures without one (5 calls in the suite).
   Sharding the remaining ~350 s across processes stays a follow-up, worth doing only if a full run still sets a
   push's length once step 2 runs it beside run-gates.

## What this does not change

No gate is weakened, skipped or reordered for correctness: every gate still runs or replays a verdict keyed on its
exact inputs. The lock still holds only the swap. The memo is off for anything but run-gates' own keying pass.
