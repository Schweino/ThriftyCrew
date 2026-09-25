# PLAN: faster pushes, with no loss of accuracy (2026-09-25)

Brad, 2026-09-25: "We need a plan that increases the efficiency of pushes and theres absolutely no impact to accuracy
or introducing bugs/regressions." **Nothing is built by this file.** Read it, edit it, then say which items to build.

## 0. The rule every item obeys

**Only work whose answer is already known may be skipped, and "known" is proved, never assumed.** A check may be
skipped only when every input it reads is byte-identical to a run that already passed. No sampling, no running fewer
checks on "small" changes, no moving checks to after the push, no dropping the rehearsal. Each item that skips
anything first runs in SHADOW mode: it records what it WOULD have skipped, the check still runs, and the two verdicts
are compared. It is switched on only after the shadow period shows zero disagreements. A single disagreement means
the item is wrong and stays off.

## 1. Where push time actually goes (measured, not guessed)

Source: the push ledger (`%LOCALAPPDATA%\ThriftyCrew\push-ledger\pushes-2026-09-22..25.jsonl`, written by
`lib\push-ledger.ps1` blob 99d38754), 613 rows, 123 landings, of which 63 carry leg timings (the field is newer than
the rest). Harness: a scratch read of those files; item M1 commits it. Leg medians over landings that ran the leg:

| push kind | landings | gates (run-gates) | test suite (test-auditors) | chain rehearsal |
|---|---|---|---|---|
| touches the daily chain | 30 | 314 s | 95 s | **898 s** |
| does not touch it | 34 | 271 s | 1 s | not needed |

What that means:
- **A chain push waits on the rehearsal, about 15 minutes.** The gates and test suite run beside it and finish first,
  so making the gates faster saves a chain push NOTHING in wall time.
- **A non-chain push waits on the gates, about 4.5 minutes.** There the gates are the lever.
- **The early rehearsal almost never helps.** It starts at commit time so the push can find its verdict ready. It hit
  on **1 of 16** chain landings that recorded the field (14 more did not record it). The design expected about 43%.
- **8 of 30 chain landings rehearsed two or three times**, because main moved while they waited (about 15 minutes each
  time). Today's push is doing exactly this as this is written.
- **The gates:** 368 self-tests a push; about 161 are skipped because their inputs did not change; **about 203 can
  never be skipped** because nothing records what they read. 1,656 s of CPU per run on the shared 24-slot box, so every
  push's gates also slow everyone else's.
- **A measurement fault to fix first:** a rehearsal that says "not needed" is recorded as taking as long as the gates
  (266 s median), because its clock stops when push-main collects it, not when it finished. So the table's rehearsal
  column is right for chain pushes and the ledger overstates it for the rest.

## 2. The items, biggest saving first

### M1. Measure honestly (prerequisite, no behaviour change)
- Record each leg's OWN finish time, not the time push-main collected it (`New-TcRehearsalJob`'s stopwatch).
- Commit the ledger reader as `ops\report-push-time.ps1`: per push kind, leg medians and p90s, early-hit rate,
  rehearsals per landing, one row per push, denominators printed.
- Bar: none, it changes nothing. Accuracy risk: none, it only records.

### E1. Make the early rehearsal actually hit (chain pushes: up to about 15 minutes each)
- First find out WHY it misses 15 of 16 times. Candidates to test, not assume: the commit-time rebase target moves
  before the push (main moves every few minutes on a busy day), the key includes something that changes between commit
  and push, the early run is still going when the push arrives and is not waited for, or it is superseded by a later
  commit. The early run's own log (`post-commit-*.log`) and `rh_secs_list` answer this.
- Then fix the cause. The push only ever uses an early verdict whose key matches exactly what it would rehearse now,
  which is today's rule, so a hit is the same rehearsal done sooner. It cannot pass anything a push-time rehearsal would
  refuse.
- Bar, written now: early hit on at least 40% of chain landings over the next 20 (today 1 of 16).

### E2. Stop re-rehearsing when main moved but not in a way the rehearsal cares about (chain pushes)
- Measure first: in the 8 landings that rehearsed twice or more, did the commits that landed in between touch any file
  the rehearsal reads? If not, the second rehearsal re-checked identical inputs.
- If so, key the rehearsal on its inputs the way the gates already are, and reuse the verdict when the key is
  unchanged. Shadow period first (section 0): run both, compare, 20 chain pushes with zero disagreement.
- Bar: rehearsals per chain landing from 1.3 (39 over 30) to 1.1 or less.

### G1. Let the 203 always-run gates be skipped when nothing they read changed (non-chain pushes: most of 4.5 min)
- For each always-run self-test, declare what it reads, using the existing key library (`lib\gate-input-key.ps1`), and
  prove the declaration with its `-VerifyDeclared` check against what the test really loads.
- Order by cost: the slowest 20 first (the gate-readings file has each one's time).
- Safety, beyond `-VerifyDeclared`: SHADOW mode. For 2 weeks every converted gate still runs, and the run records
  "would have skipped" next to its real verdict. Any case where it would have skipped and the real run went red is a
  bad declaration: that gate goes back to always-run and the declaration is fixed. Only gates with zero such cases
  switch on.
- Keep a WIDE key from undoing it (the ops rule "A KEYED SELF-TEST CAN STILL RE-RUN ON EVERY PUSH"): a gate whose
  key moves on most commits is listed, never forced.
- Bar: non-chain push gate time from 271 s median to 120 s or less over 20 pushes. Measured on the box's own
  load, so it is compared with pushes from the same hours.

### G2. Fewer wasted gate runs (every push, and every other session's queue)
- The rebase happens before the gates today, but a push whose main moves mid-run still re-runs its gates (catch-up).
  With G1 in place a catch-up re-runs only the gates whose inputs the new commits touched. No new mechanism: this
  falls out of G1.

## 3. Not in this plan, on purpose
- Anything that skips a check without proving its inputs are unchanged (sampling, "small change" fast paths,
  post-push testing). These trade bugs for speed, which Brad ruled out.
- Loosening the rehearsal, the lock, or the gate budget.
- Process start-up per gate (about 95 s of the 1,656 s). Real but small, and merging processes risks tests leaking
  state into each other.

## 4. Order and proof
M1 first, since every bar reads from it. Then E1, then E2 (chain pushes are half of all landings, and the rehearsal
is two-thirds of their wait). Then G1 and G2. Each item ships with a must-fire fixture and a clean twin, and each
claim of a saving is reported as leg medians before and after over at least 20 pushes of the same kind, with the
number of variants tried.

## Knowledge consulted
- `reliability-craft/applies-here.md` section 10: arrival-order service stays; nothing here reorders the queue.
- `.claude/rules/ops-and-gates.md`, "A KEYED SELF-TEST CAN STILL RE-RUN ON EVERY PUSH, when its key is too WIDE", and
  "PUSH-MAIN FITS FIRST, RE-CHECKS WHAT MOVED, AND LOCKS ONLY THE SWAP".
- `.claude/rules/measurement.md`: denominators, bars before the run, one row per case, name the harness and blob.
- `lib/gate-input-key.ps1` (machinery index): the key library G1 extends. Harness blobs at the time of writing:
  `ops/push-main.ps1` fc312015, `ops/run-gates.ps1` 32b06b95, `lib/push-ledger.ps1` 99d38754.
