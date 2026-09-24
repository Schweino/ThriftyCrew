# PLAN: a push learns it no longer fits in seconds, and shared files stop manufacturing conflicts (2026-09-23)

Brad asked on 2026-09-23: *"Whats taking so long to push? Is there a system design/architecture problem here?"*, then
chose **"Plan the lasting fix"**. This plan is written before any code. It will be built at lower effort, so every work
item is written to be done without re-deriving it. The bars in section 8 are written now, before any run.

**Status: PLAN, ruled by Brad 2026-09-23, build under way. Revised the same day after three reviews (correctness, safety, measurement) read it
against origin/main `855171a1e`.** The numbers come from three read-only investigators (census, mechanism, cost), from
the planner's checks at `31006efa6`, and from the reviewers' and the reviser's re-derivations at `855171a1e`. Where a
review corrected a figure, the corrected figure is used and its source is named; section 14 records every review issue
that was not applied as written, and why. Scratch scripts live under `%TEMP%\conflict-census\`, `%TEMP%\pushfix\`,
`%TEMP%\gcc-ro\`, and this session's scratchpad (`rv_*.py` from the reviewers, `rvs_*.py` from the reviser). They are
scratch. W0.3 commits a harness that re-derives every baseline read from the PUSH LEDGER. Every figure read from reflog,
git history or transcripts is marked SCRATCH where it is used, unless W0.3's `-History` section re-derives it.

**AMENDED 2026-09-23 evening (section 16, ruled by Brad): design A replaces the chain lease.** Brad chose "Measure
first, then decide"; the early-rehearsal measurement passed its 30% bar (10 of 23 chain landings), so Row 9 (W9.1 to
W9.5) is built in full. W6.1 and W6.2 are replaced, W2.3 is absorbed into W9.3, W2.2R is extended by W9.4, and D8's
exception to the 2026-09-12 ruling is withdrawn. Section 16.4 lists every change to the sections below.

**AMENDED 2026-09-23 (section 15, adopted by Brad): the sibling fix `5841e96b1` is the base of W2.1 and W2.2, and Row 8 closes the causes the first plan left standing.** **RULED 2026-09-23 (Brad, section 12 has each ruling): build all 8 rows. Every recommendation in section 12 is the
ruling, except D8: the chain lease goes LIVE from its first commit with no shadow period.** Brad's words on D8: *"I dont
want to shadow. i want to push live as long as its a thoughtful fix and ready to go"*. W6.1 is rewritten for that: its
"ready" is proved before it lands (a sandbox two-push drill, every fixture and mutant, an `off` switch as the rollback),
and a `lease=timeout` row pages.

**Implementer: before any item, read sections 4, 5 and 9, then your item in section 6, then the section 12 row of any
D-id it names.** Every item is in the ThriftyCrew repo and lands through `ops\push-main.ps1`.

## Knowledge consulted

- `concurrency-craft/concurrency-correctness.md` section 5, "Optimistic concurrency" (pasted in the brief):
  *"Starvation is NOT excluded ... an unlucky thread can lose every race"* and *"The benefit holds only while contention
  on the shared object is low, because at high contention the fraction of compareAndSet calls returning false rises and
  the loop becomes the bottleneck."* Used for W2.2 (the loop is bounded) and W6.1 (the one high-contention object gets
  a lock of its own).
- `concurrency-craft/distributed-coordination.md` 13a, found by `search.py "merge conflict shared append file one
  writer"`: *"Optimistic - assume no conflict, check later. Preferred when conflicts are expected to be rare."* The
  chain manifest set is not rare (section 2.3, A2), so W6.1 treats it pessimistically and leaves every other push
  optimistic.
- `CLAUDE.md`, "THE GATE MUST NOT RUN INSIDE THE LOCK" (Brad, 2026-09-12): *"Serialising the PUSH costs nothing because
  `refs/heads/main` is serialised already; serialising the GATE costs everything."* Nothing here moves a gate leg into
  the push lock. W6.1's lease IS a lock held across gate legs for chain-touching pushes, so it is named as an exception
  to that ruling. Brad accepted it by name on 2026-09-23 (D8), live without a shadow period.
- `.claude/rules/ops-and-gates.md`, "A PUSH IS A COMPARE-AND-SWAP WHOSE CRITICAL SECTION IS THE WHOLE HOOK, so the
  SLOWEST push converges on never landing", and "EVERY LOCK PATH DEGRADES TO THE DAY BEFORE, AND THAT NOW INCLUDES THE
  QUEUE". Every new step in W2 and W6 falls back to today's path when it cannot run, and never refuses for that reason.
- `.claude/rules/ops-and-gates.md`, "ORDER DECIDES WHICH PUSHES ARE REFUSED, NEVER HOW MANY ... State that bound beside
  any fairness fix". W6.1 states its ceiling.
- `.claude/rules/ops-and-gates.md`, "THE LOCK ORDER IS DECLARED, OUTERMOST FIRST": *"Any change that holds two of them
  at once takes them in this order, releases in REVERSE, and SAYS IN ITS COMMIT that it is the first nested acquisition
  of that pair."* W2.1 adds the per-checkout guard and W6.1 adds the chain lease above the push lock, and W6.1 places
  the rehearsal slots, a mechanism the declared order does not yet name.
- `.claude/rules/ops-and-gates.md`: "Never bypass or weaken a gate", "Do not add a gate that is red on day one", "A
  plain run of a ratchet never writes its mark", "To prove work runs concurrently, prove the OVERLAP, not the speed",
  "A timed lock wait is a BRANCH", "A tuning constant records what ELSE was tried", "Write the POINTED-TO object
  before the object that points to it", "A self-test's exit 0 is not its verdict" and "Every threshold here is an UPPER
  bound ... write down what the number does when the producer STOPS".
- `.claude/rules/measurement.md`, "RE-QUALIFY A MOVED HARNESS BY ITS BLOB": the re-read line and what
  `ops/audit-conclusion-currency.ps1` accepts. Also "NAMING A SCRATCH HARNESS IS NOT NAMING A HARNESS" (W0.3 commits
  one), "RECORD THE CASE AT THE MOMENT IT FAILS" (W0.1 writes the conflicted files into the ledger row), "A rate is
  printed with its DENOMINATOR, always", "A matcher that ABSTAINS is scored on what it skipped" (coverage beside every
  leg median) and "a number that moved is not a number that improved".
- `database-craft/transactions-and-recovery.md` section 1 (pasted in the brief): the log is written before the data, so
  an append-only record is the merge-friendly shape. W4.1 is that shape for re-reads.
- `design/backlog-inbox/README.md` on origin/main: *"Brad's fix: every writer gets its own file. No two writers touch
  one file, so there is nothing to lock and nothing depends on anyone remembering."* That ruling (2026-09-08) covers
  NEW findings only. W3.1 extends the same drop box to status changes of EXISTING items rather than building a second
  mechanism.
- `~/.claude/skills/course/inbox/README.md` "Why it exists": the brain met the same shape in its own four shared files
  (*"Four shared files had every lane appending to them with no lock and no allocator"*) and solved it the same way.
- `CLAUDE.md`, "A SIBLING MAY ALREADY HOLD THE FIX": checked with `git log --all --not origin/main` over every file this
  plan changes. The only unpushed commits are the 2026-09-11 gate-slot branches that the 2026-09-12 fold already read.
  Nothing on any branch does what this plan does.
- Memory index lines (the files themselves were not opened): `landing-a-push-needs-a-clean-worktree`,
  `new-scheduled-task-needs-two-pushes-from-a-worktree` ("a gate checks its MAIN-checkout path"),
  `scheduled-tasks-run-under-headless-conhost` ("new TC tasks need the wrapper"), `ps-start-process-exitcode-needs-handle`,
  `prepush-test-auditors-judges-against-a-shared-record`, `an-intention-has-no-exit-code` ("a follow-up step needs a
  detector, not a reminder"), `a-wait-must-not-outlive-its-subject`, `powershell-exiting-event-does-not-fire` and
  `recommend-the-best-long-term-solution`.

## 1. The answer to Brad's question

**Yes, it is a design problem, and waiting in line is not it.** Most pushes are not slow. The median landing took
**2.5 minutes** from push-main start to its ledger row (152 run-bearing landings to 10:32Z today; the measurement
reviewer read 153), and 2 of those took over 30 minutes. The slow ones are the pushes that change the daily chain.
Since the chain rehearsal became a push gate (`a66ef0e94`, 2026-09-22 16:26 CDT), such a push spends about half an hour
proving itself (run-gates, then test-auditors, then the rehearsal) before it asks whether it still fits on main. When
main moved in the meantime and the two collide, it throws the half hour away and starts again, with the same odds. The
only chain-touching attempts measured are the housekeeping lane's 3 today: legs of 1,816 to 2,167 s each, and 1 h 52
min from its first gate to its landing. Over the 16 of today's 22 lock-taking attempts that had logs, waiting for the
lock was 2.3% of the time (about 3.1% counting the lock wait the log join missed). Three things make it slow:

1. **The fit check comes last.** The rebase happens only inside the lock, after the verdicts. By ancestry, 10 of 21
   attributed conflicts collided only with commits that were already on main when push-main started (SCRATCH, section
   2.3 A1). A rebase at minute 0 would have refused those in seconds.
2. **The verdicts are tied to exact file contents**, so a landing that touches anything they read voids them. Main
   changed one of the chain rehearsal's files (about 130, by one investigator's reproduction and the correctness
   reviewer's replica; W0.5 prints the set from the rehearsal script itself) on 26.4% of landings over 7 days, nearly
   all of them before the rehearsal gate existed.
3. **A few shared files turn independent work into collisions.** Above all this is the backlog file, which 47.5% of
   landings touch. The others are the re-read lines in two gate write-ups and one index page.

The lasting fix checks fit first, re-checks only what moved, runs the two long legs side by side, and gives each writer
its own file. It weakens no gate. The one pessimistic piece (a lease for chain pushes) holds a lock across gate legs,
which your 2026-09-12 ruling forbids in general. You accepted that exception by name on 2026-09-23 (D8), live from its
first commit.

## 2. The defect as measured

### 2.1 Where the time goes

| Measure | Value | Denominator and source |
|---|---|---|
| run-gates wall, when it ran | median 60 s (7 days), 96 s (today) | n=164 of about 335 push-main rows in the window carry a log, and 16 of 22 today (coverage per the abstention rule); cost, from 206 attempts deduplicated out of 401 logs |
| test-auditors leg, when it ran rather than reused | median 664 s (7 days), 851 s (today) | n=11 and n=4; cost |
| chain rehearsal, when it ran | median 814 s (730 to 948) | n=3, all today, one lane; cost |
| wait for a gate worker slot | median 0 s, max 63 s | 164 runs; cost |
| push lock wait | rows with a run id, from 09-18T20:33:58Z (about 4.6 days): median 0 s, p75 44, mean 138, max 1,165 (n=195). All lock-taken rows 09-16T10:32Z to 09-23T10:32Z: median 0.017 s, p75 0.05 s, mean 105.5 s (n=268). Today max 96 s | n=22 lock-taken rows today (investigators' window); the all-rows figures are the measurement reviewer's |
| share of today's visible leg time | run-gates 25.9%, test-auditors 41.5%, rehearsal 30.3%, lock wait 2.3% | the 16 of 22 attempts with logs, 8,231 s; cost. Counting all 254 s of today's lock wait (the log join missed at least 65 s) gives about 3.1%. The in-lock hold is outside both figures |
| whole-verdict reuse in the in-lock hook after a rebase | 0 of 84 (7 days), 0 of 9 (today); without a rebase 52 of 56 and 5 of 5 | cost, from the in-lock RUN-GATES-COMPLETE line |
| in-lock hold plus overhead | rebased median 128 s (n=52), not rebased 25 s (n=33) | cost; a derived remainder (D - W - logged legs), not a direct timer. W0.1's `lock_held_ms` replaces it |
| full test-auditors run INSIDE the lock after a rebase | 10 runs, 339 to 792 s | of 84 rebased hooks (reused 9, not needed 43, not captured 22); cost |

The worst case today was the housekeeping lane (`agent-a49021947d73d02ed`). Its three attempts took 2,278, 1,830 and
1,956 s (ledger `run` start to row). Their legs were run-gates 348/324/262 s, test-auditors 871/762/831 s and rehearsal
948/730/814 s, with lock waits of 96/0/0 s. The first two were refused-rebase-conflict and the third landed as
`31006efa6` at 10:48:53Z, 1 h 52 min after its first gate started. The planner re-read those three ledger rows:
08:57:01 to 09:34:59, 09:41:15 to 10:11:46, and 10:16:17 to 10:48:53 UTC.

**Generic and chain-touching pushes are two populations.** Today's UTC-day landings to 10:32Z: 17, median 2.9 min from
run start to row, 0 over 30 min (reviser, `rvs_land.py`); the measurement reviewer, on a local-day window that includes
the 10:48Z landing, read 15, median 3.8 min, 1 over 30 min. The half hour is the chain-touching path, and every number in
the section 4 model belongs to that path only.

### 2.2 What the refusals were

Across the push ledger (`%LOCALAPPDATA%\ThriftyCrew\push-ledger\pushes-*.jsonl`, 8 days with push-main rows, 365 rows
to 10:32Z today, 2 temp-checkout fixture rows excluded; census, re-derived exactly by the measurement reviewer) there
were:
- 244 landings of 365 (110 landed, 134 landed-after-rebase);
- 66 refused-gate-red, 24 refused-not-ready, 22 refused-rebase-conflict and 9 push-rejected.

Ledger files are named by LOCAL day while `ts` is UTC, so a row after 19:00 CDT sits in the previous day's file. Every
window below is stated in UTC.

Conflicts cluster on three days: 8 of 143 rows on 09-18, 12 of 133 on 09-19 and 2 of 25 on 09-23. Every other day had 0.

**The 22 rebase conflicts** (census, 22 of 22 attributed: 17 cross-validated against git's own CONFLICT line, 4
computed only, 1 transcript only; SCRATCH):
- 20 of 22 rows conflicted ONLY on shared append-shaped or derived files, and 25 of the 28 file instances were
  mechanical. The rubric: MECHANICAL means both edits are independent and the right result keeps both.
- The files that collided:

  | File | Rows |
  |---|---|
  | `design/BACKLOG-course-findings.md` | 14 (13 computed, 1 from a transcript: `i220-both-stores`, which the census's attribution marks unattributed) |
  | `design/ready-for-brad/README.md` | 5 |
  | re-read lines in 3 MEASURE docs | 2 rows, 3 instances |
  | `grocery/known-wrong.json` plus `grocery/out/audit/match-baseline.json` | 1 (gc-fence) |
  | header metadata in `lib/concurrency-probe.ps1` | 1 |
  | genuine code, 3 files | 2 |

- The 2 genuine code conflicts must never be auto-resolved:
  1. i144-coconut: main moved the allergen gate out of wave-publish, while the branch asserts that wave-publish runs it.
  2. housekeeping: the same leak fix to `grocery/test-flag-verification.ps1`, landed first by a sibling (`38357202c`)
     with the same subject.
- 20 of 22 rows came from one session's parallel lanes (session 97732561, the 09-18/19 backlog run). In 16 of the 19
  rows whose colliders are known, every colliding push was a sibling lane of that same session.

**The 9 push-rejected rows** (census and mechanism): none was a file collision. Every one was refused by the in-lock
hook after push-main's rebase:

| Cause | Rows | When (UTC) |
|---|---|---|
| chain rehearsal found no verdict for the post-rebase key | 4 | 04:26:31Z (in `pushes-2026-09-22.jsonl`), 05:13, 06:32 and 09:57Z on 09-23; 1 confirmed by the lane's own diagnosis, 3 by construction |
| `audit-conclusion-currency` red | 3 | 09-12 |
| the push's own new failing test-auditors case | 1 | |
| `audit-prompt-backup` red from live prompts outside git | 1 | |

A 10th push-rejected row arrived after the cutoff, at 11:36:24Z, 26.4 min from its run start: a fifth in-lock rehearsal
no-verdict refusal (measurement reviewer; `%TEMP%\tc-prepush-rh-66071.log`). So the baselines here are already stale,
which is one reason W0.3 re-derives them before any bar is judged.

On two of today's rehearsal refusals, full test-auditors ran inside the lock for 792 s and then 709 s before the
seconds-long rehearsal check refused (cost; session ffbacbef). The hook order causes this: run-gates at
`ops/hooks/pre-push:251`, test-auditors at :282, the rehearsal check at :302. The planner and the correctness reviewer
verified that order on origin/main.

**The cost of a collision is the whole cycle.** The 19 conflict rows with a run id spent 256 min from push-main start to
refusal (median 13.9 min, max 38.0). The 5 push-rejected rows with a run id spent 72 min (median 14.0). A retry keeps
the same window and the same odds, so the cost compounds (cost; re-derived exactly by the measurement reviewer).

### 2.3 The architecture defects

**A1. The optimistic loop discovers a conflict last and retries without bound.** `ops/push-main.ps1` on origin/main
does these steps in order, with nothing before :346 that fetches or probes:
1. :318 runs the runner (run-gates, then test-auditors);
2. :338 runs the rehearsal;
3. :346 takes the lock;
4. :360 fetches;
5. :388-397 rebases, and aborts and refuses on any conflict.

What the evidence supports is branch age, not window length:
- **Ancestry** (SCRATCH): each attributed collider checked with `git merge-base --is-ancestor` against the row's ledger
  base (the remote-tracking ref at push-main start). 10 of 21 attributed conflicts collided only with commits already on
  main at start, 10 only with commits that landed after start, 1 with both, and 1 row is unattributed. Source: the
  census's `attribution.txt`, checked by the measurement reviewer's `rv_collider.py` and re-run by the reviser with the
  same 10/10/1/1. Nearly all the after-start colliders are backlog or ready-for-brad lines.
- **Conflict rate by the time before the lock** (push-main duration minus lock wait; 106 rebase-needing attempts, 19
  conflicts, 09-18 to 09-23; `%TEMP%\gcc-ro\coll.py`, re-run by the measurement reviewer with its write removed):

  | Time before the lock | Conflicts |
  |---|---|
  | under 120 s | 7 of 23 (30.4%) |
  | 120-300 s | 5 of 48 (10.4%) |
  | 300-600 s | 3 of 19 (15.8%) |
  | 600-1200 s | 2 of 10 (20.0%) |
  | 1200 s or more | 2 of 6 (33.3%) |

  This is not monotone, and the shortest bucket is among the worst, which fits stale branch bases. The first version of
  this plan printed a monotone four-bucket table (87 attempts, 14 conflicts, "branch base to lock grant"). No scratch
  file produces it, so it is withdrawn.
- The cost investigator's maximum-likelihood estimate of the chance that one landing conflicts is q = 0.070 over 71
  attempts (SCRATCH). Separately, 35 of the 106 had no landing during push-main at all, and 4 of those conflicted. That
  count understates what a pre-flight catches, because a conflict with an old collider can still have had unrelated
  landings during push-main; the ancestry split above is the measure of it.

**A2. Every verdict earned outside the lock is keyed on content that the in-lock rebase changes** (mechanism, read
from code). There are five keys:
1. the whole-run fingerprint (`lib/gate-verdict.ps1`);
2. every self-test key, which includes the runner files `ops/run-gates.ps1`, `lib/parallel-run.ps1` and
   `lib/gate-input-key.ps1`;
3. the test-auditors key, which covers its inputs, every `lib/*.ps1`, and board name, length and mtime;
4. the rehearsal key, a SHA over every chain-manifest blob. `ops/rehearse-chain.ps1`'s header says *"any change to a
   manifest file needs a new rehearsal"*;
5. conclusion-currency, which re-qualifies only by the harness's CURRENT blob.

Measured effects:
- Landings touching the chain set: 79 of 299 over 7 days (26.4%), and 6 of 17 today (SCRATCH, over a 130-file set from
  the cost investigator's Python reproduction). Nearly all 299 landed BEFORE `a66ef0e94` made a chain push rehearse,
  so how many chain pushes are OFFERED under that requirement is not yet measured (about 18 hours of rows).
- Chance a rehearsal is voided during a 35-minute window (cost's Poisson model, measured inputs; both arms shown, this
  plan cites the 7-day arm):

  | Landings an hour | 7-day chain share 0.264 (n=299) | today's share 0.353 (n=17) |
  |---|---|---|
  | 4.3 (today) | 48.4% | 58.7% |
  | 16 (the 09-19 peak) | 91.5% | 96.3% |

  The first version of this plan cited 58.7% and 96.3% while saying it used 0.264; `%TEMP%\gcc-ro\prob.py` prints both.
- Self-tests with a key: 147 of 348-349 (42%) today. They were 290 of 347 before `15b02198b`, a stale-pass fix that must
  not be reverted.
- `ops/run-gates.ps1` took 12 origin/main commits since 09-16 (11 at the planner's count; `4db4b2036` landed since). By a
  line-kind classifier over each diff (the reviser's; not a hunk-by-hunk reading): 8 changed only static-list entries
  and the comment lines beside them, 1 changed only header prose (`493339c8f`), and 3 changed code (`31fe44004`,
  `8bf0d72f8`, `2660cd919`). Each flushed every self-test key box-wide. What a flush costs in gate time is NOT measured;
  W0.1 records it.

**A3. Shared append-shaped files turn independent work into textual conflicts** (cost and census, 14-day class census
at `31006efa6`; SCRATCH). For each class, EXPOSED counts touches that landed within 60 minutes after a different pusher
touched the same file:

| Class | Exposed touches |
|---|---|
| backlog, queue and triage files | 165 of 289 (`BACKLOG-course-findings.md` alone 152 of 174) |
| rules and registers | 42 of 121 |
| registration hubs | 43 of 146 |
| re-read lines | 11 of 62 |
| code outside the hubs | 74 of 1,304 |
| bot outputs | 14 of 1,329 |
| graph state | 0 of 271 |

The backlog file was touched by 142 of 299 landings over 7 days (47.5%) and overlapped in 12 of 19 recent conflicts.
Take the median share of other landings that touch one of a landing's files: it falls from 0.232 to 0.023 once that one
file is removed.

**A4. The re-read convention feeds itself** (mechanism). A re-read line contains the word "harness", so the audit enrols
every path on it, and on the next line, as a new harness of that doc (`ops/audit-conclusion-currency.ps1:64, 80-87`).
That is how `ops/run-gates.ps1`, the most-edited gate file, became a harness of both gate-queue documents.
- 5 of the 32 (doc, harness) pairs exist only because a re-read line names the path (confirmed by the correctness
  reviewer).
- `MEASURE-gate-slot-admission-2026-09-11.md` and `MEASURE-gate-queue-window-2026-09-11.md` held 24 and 22 re-read lines
  at `31006efa6`, and hold 25 and 23 at `855171a1e` (reviser, `git show ... | grep -c 'Re-read at'`). The two added
  lines are live evidence for this defect: `30dcc69c7` (05:53:20 CDT) re-read both docs at run-gates' new blob, and
  `51ef26dc0` twenty seconds later edited the same lines again, *"the two gate-cost re-reads cite run-gates' blob after
  the rebase"*, because a rebase had moved the blob they cited.
- The per-content blob rule is also not rebase-stable when the harness changed on both sides. Today's attempt 2 merged
  `grocery/pricing-math-lib.ps1` to a blob that was neither side's, so even a conflict-free merge would have read
  5 UNQUALIFIED against a baseline of 4, and gone red inside the lock.

**A5. A fail-open on the conclusion-currency baseline.** At `ops/audit-conclusion-currency.ps1` on origin/main (:466 and
:480, confirmed by two reviewers), a baseline that fails to parse becomes `$base = $null`. Then `if ($Accept -or $null
-eq $base)` WRITES the current count as the new mark and exits 0 on a plain run. A botched hand resolution of that JSON
would silently accept a rise. The mustfire census fails closed in the same spot (exit 3).

### 2.4 The measurement defects

- A push-main row records no conflicted files, no phase, no leg times, no lock hold time and no hook refusal line. So
  16 of 22 historical conflicts could only be reconstructed through reflog and transcript archaeology.
- A row does not record WHICH push-main wrote it, so rows from checkouts that never rebased onto a change cannot be told
  from rows written by the changed code. About 135 worktrees exist and each runs its own copy.
- A row carries no session id, so "a parallel run" cannot be selected from the ledger, and no flag says whether the push
  touched the chain.
- `ops/test-prepush-hook.ps1` never sets `TC_PUSH_LEDGER_ROOT` (0 hits on origin/main). Its sandboxes therefore wrote
  279 of 615 hook-lock rows in 09-17..23, and 78 of 95 today, into the production ledger (cost); sandbox rows were
  still arriving at 11:21Z (96 of 114 hook-lock rows in today's file, measurement reviewer). push-main rows are
  unaffected.
- `gate-readings.jsonl` carries no durations, and a reused run writes nothing. run-gates does print, on every run,
  `run-gates: <x> of <y> self-test(s) already passed over these exact inputs and were not run again; <z> could not be
  keyed and always run` (`ops/run-gates.ps1:800`), which is the flush cost's raw material and is recorded nowhere.

### 2.5 Where the investigators and reviewers disagreed

| Point | What each said | What this plan uses |
|---|---|---|
| Housekeeping leg times | The orchestrator: about 35 min, "762 s and 831 s" test-auditors. Cost: test-auditors 871/762/831 s plus a rehearsal leg of 948/730/814 s the orchestrator left out. Mechanism could not verify the test-auditors legs and inferred about 835 s for attempt 3. | Cost's per-leg figures, which sum to within 50 s of the ledger durations. |
| What collided today | The orchestrator listed `ops/mustfire-census-baseline.json`. Census and mechanism: it did NOT collide in either window (0 of 2), but the lane regenerated it after each rebase (4,735, then 4,770, then 4,788 must-fires). The orchestrator also missed `lib/concurrency-probe.ps1`, the file git actually stopped on first. | The census list. No merge work on the mustfire baseline (D12). |
| Where union merging is safe | Census: safe for end-of-file re-read paragraphs and for the ready-for-brad index. Mechanism: tested five cases under a real rebase. An edit on one side resurrects the old row, and a delete plus an append undoes the delete. 5 of 35 doc commits since 09-16 edit existing lines, so doc-level union would interleave prose. Union must name only a dedicated append-only ledger. The correctness reviewer confirmed that union keeps both appended rows under a plain rebase and under the bot's autoStash plus `-X theirs` shape, with 0 CR in the blob. | Mechanism. Union on one ledger file only (W4.1); the ready-for-brad index is fixed structurally (W3.3). |
| Row totals | Census 365 rows and 244 landings; mechanism 368 and 245 (gate-red 66 against 68). | Not a disagreement. Census excluded the 2 fixture rows and read to 10:32Z; the 10:48Z landing is the 245th. |
| Chain-set churn | Census 36 of 109 commits since 09-22 16:26 CDT. Mechanism 102 of 538 commits since 09-16 and 29 of 91 today, a lower bound over files and globs. Cost 79 of 299 landings (26.4%) and 6 of 17 today, over a set of 130 files from its own Python reproduction; the correctness reviewer's replica of `Get-RhManifestSet` also read 130. | Different units, not a disagreement. Probabilities use cost's per-landing share. W0.5 prints the set from `rehearse-chain.ps1` itself. |
| Is lock wait a lever? | All three: not today (2.3%). Cost: on 09-19, 33 of 104 lock-taken rows waited over 300 s, and lock wait was 33.8% of the 7-day landed wall, because each rebased landing held the lock about 2 min. | The fix for busy days is a short in-lock hold (bar B3), not more fairness or more slots. |
| How to detect a conflict early | Mechanism: `git merge-tree --write-tree --name-only`. Census: a squashed merge agreed with git 17 of 17 but can differ from a per-commit rebase. | The rebase itself, outside the lock (W2.1). It is exact, and the verdicts then judge the rebased content. `merge-tree` is used only by `-DryRun` and for W0.1's labelled-approximate full conflict list. |
| Rehearsal counterfactual | Mechanism: high on the mechanism, medium-high that a clean rebase would still have been refused. Census: medium that the rebase changed the key in 3 of the 4 rehearsal rows. | Treated as 1 confirmed and 3 by construction. W0.1's `reject_class` settles it going forward. |
| Conflict odds and the window | The plan's first table said the odds rise with the window. The measurement reviewer could not reproduce it; the only script over those 106 attempts gives a non-monotone table, and the ancestry split puts half the conflicts at branch age. | The reproducible table and the ancestry split (A1). |
| How long a push takes | The plan's first answer said "about half an hour" for a push. The measurement reviewer: a typical push takes a median of a few minutes; the half hour is the chain-touching path, n=3 attempts from one lane. | Two populations (section 1, 2.1); the model is attached to chain-touching pushes only. |

## 3. Goals, as properties that can be checked

- **G1.** A rebase conflict against what main held at the pre-flight fetch is refused before any gate leg runs. The
  refusal names the conflicted files and any main commit whose subject equals one of the branch's. (W2.1; bar B1)
- **G2.** A push that is going to be refused for a missing rehearsal verdict is refused before the hook starts
  run-gates or test-auditors. (W1.1; fixture; bar B2b)
- **G3.** When main moves during the legs, push-main rebases again outside the lock and re-runs each leg, for at most 3
  rounds. test-auditors and the rehearsal each reuse a whole recorded verdict when their key did not move. run-gates
  reuses only its per-self-test keys (147 of 348 are keyed) and never a whole run after a rebase (0 of 84 today), so a
  catch-up round always costs at least run-gates' unkeyed part. The in-lock rebase then brings in only what landed after
  the last round. (W2.2; bars B2, B3, B8)
- **G4.** For a chain-touching push, the time before the lock is run-gates plus the LONGER of test-auditors and the
  rehearsal, not all three added together. (W2.3; bar B7)
- **G5.** Two sessions that each record progress on the backlog, a re-read or a ready-for-brad item never change the
  same tracked lines. (W3.1, W3.3, W4.1; bars B4, B5)
- **G6.** If W5.1 is built: an edit of the static gate list moves no self-test cache key, and an edit of run-gates' own
  code still moves every one. (W5.1; fixture)
- **G7.** A chain-touching push through an UPDATED push-main in LIVE lease mode, that holds the chain lease and did not
  time out waiting for it, cannot have its final rehearsal voided by another updated push-main push. It CAN still be
  voided by: a plain `git push` of a chain change; a push from a checkout whose push-main predates W6.1; a push-main in
  shadow mode; a waiter that timed out behind a wedged holder. B6 counts every chain landing in those four classes, and
  gives no verdict when they are more than 20% of chain landings. (W6.0, W6.1; fixture, bar B6)
- **G8.** Nothing here lets content reach main that no gate and no person verified: no automatic resolution of any
  conflict, no regenerated baseline, no re-read written for someone, and no two conflicting status updates settled by
  file order. (Section 9; fixtures)
- **G9.** Every push-main refusal records its phase, its files, the gate that refused and the push-main that wrote it,
  and test fixtures never write the production ledger. (W0.1, W0.2)
- **G10.** A conclusion-currency baseline that is missing or cannot be read makes the audit exit 3 and is never
  rewritten by a plain run or by `-Tighten`; run-gates scores that 3 as a FAIL and the push is refused. (W1.2)

## 4. The design, and why it is this shape

```
push-main start
  per-checkout guard (W2.1)     a second push-main in this checkout is refused at once (never waits)
  record branch base, change id and the running push-main's blob (W0.1)
  PRE-FLIGHT, unlocked (W2.1)   fetch into FETCH_HEAD only; if the remote moved, rebase NOW
                                conflict -> abort, name files and same-subject siblings, refuse (seconds)
  seed the checkout (as today, now after pre-flight)
  LEGS, unlocked                run-gates, then  [ test-auditors  ||  chain rehearsal ]   (W2.3, D1)
                                any red -> refuse before the queue (as today)
  CHAIN LEASE (W6.1, D8)        a chain-touching push takes it here and holds it to after the push lock
  CATCH-UP, unlocked (W2.2)     fetch; if moved: rebase, re-run each leg (each reuses what its keys allow);
                                at most 3 rounds (D11)
  LOCK (as today)               fetch; rebase if moved (now usually nothing); git push
    pre-push hook               rehearsal record check FIRST (W1.1), then run-gates, then test-auditors, all warm
```

1. **Check fit first.** The rebase moves to the start, outside the lock. That is exact where a squashed merge-tree is
   an approximation, and it means every verdict afterwards judges near-final content. A branch-age conflict (10 of 21
   attributed conflicts, A1) is then refused in seconds instead of at minute 14 or minute 35.
2. **Re-check only what moved, and bound the loop.** The catch-up round reuses each leg's own key: run-gates' per-gate
   keys, test-auditors' keyed pass, and the rehearsal's verdict key. So one definition of "still holds" exists per leg,
   and nothing new is invented. The loop stops after 3 rounds and falls back to today's in-lock path, because an
   unbounded optimistic loop can starve.
3. **Put the cheap refusal first in the hook.** The same three checks run in the same hook. The seconds-long record
   check simply comes before the 13-minute leg it would have made pointless.
4. **Run the two long legs side by side.** test-auditors and the rehearsal read the same content and write different
   records. The rehearsal takes one of its own 6 rehearsal slots (`Global\tc-rehearsal-slot-`, a pool separate from the
   24 gate slots, `ops/rehearse-chain.ps1:119`); test-auditors takes no slot at all and is metered by nothing but its
   1200 s kill. So overlapping them adds unmetered load, and W2.3 measures that before D1 is decided. The rehearsal
   starts only after run-gates passes, so a push that run-gates refuses never starts one. (The 66 of 365
   `refused-gate-red` rows mix run-gates reds with test-auditors reds, and the ledger cannot split them until W0.1's
   leg fields exist.)
5. **Give each writer its own file, and never merge a file whose content needs judgement.**
   - Backlog status changes go through the existing inbox, with one writer (Brad's 2026-09-08 ruling, extended).
   - Re-reads go into one append-only ledger with union merge and an append-only check.
   - The ready-for-brad index stops holding per-item text.
   - JSON rulings, baselines and code are never merged by a driver.
6. **A pessimistic lock for the one high-contention object, with its limits stated.** A lease taken only by
   chain-touching push-main pushes serialises their final rehearsal. Its limits:
   - It protects a holder only against other updated push-main pushes that respect it (G7 lists the exceptions).
   - It is a lock held across gate legs (the catch-up's run-gates, test-auditors and at most one re-rehearsal), so it
     is an exception to Brad's 2026-09-12 ruling, named in D8.
   - Its ceiling is 60 divided by the hold in minutes, per hour: about 12 an hour when a holder need not re-rehearse
     (hold about 5 min), and about 2.4 to 3.5 an hour when it must (hold 17 to 25 min). The 09-19 peak offered about 4.2
     chain landings an hour (16 landings an hour times 26.4%, a share measured before the rehearsal gate), and at that
     rate most holders would re-rehearse, so at that peak the lease queues. It does not livelock, which today's loop does.
   - It can never move into the pre-push hook: the hook runs under the push lock, and taking an outer lock there makes
     one process hold the lease while waiting for the push lock and another hold the push lock while waiting for the
     lease.
   Every other push stays optimistic and is never held by it.

**Expected effect, a model and not a measurement** (cost's Poisson model, q = 0.070 at today's 4.3 landings an hour,
1 - (1 - q)^(landings in the window)). For a CHAIN-TOUCHING push, shrinking the post-rebase window from about 35 to about
18 minutes takes its conflict odds from about 16.6% to about 9%, and a conflict is then found at minute 0 or minute 18,
not minute 35. A GENERIC push's window is already about 4 minutes, which the same model puts near 2%, so for generic
pushes the lever is the pre-flight (the 10 of 21 branch-age conflicts), not the window. Taking the backlog file out of
the common path cuts the median overlap share tenfold (0.232 to 0.023). Section 8's bars say what the real ledger must
show.

## 5. How to work this plan (read before any item)

- **Repo and landing.** ThriftyCrew only. Land every item through `ops\push-main.ps1` from a clean, seeded linked
  worktree (memory `landing-a-push-needs-a-clean-worktree`), and never with `--no-verify`, `-NoRehearsal` or
  `TC_NO_REHEARSAL`. W2.1 changes push-main itself, so run it with `-DryRun` from the worktree first and read the
  pre-flight lines before the real landing. W0.5, W6.0 and any item that changes a chain-manifest file is itself a
  chain-touching push: budget its rehearsal (about 14 minutes and one of 6 rehearsal slots).
- **Commits.** Stage explicit paths. Commit with a pathspec, `git commit -F <msgfile> -- <paths>`, and write the message
  file with `[IO.File]::WriteAllText($p, $body, (New-Object Text.UTF8Encoding($false)))`. Check `git show --stat HEAD`
  after every commit. Every message carries `Plan: design/PLAN-push-derived-conflicts-2026-09-23.md W<id>` on its own
  line and a `Store:` line naming the sections the item's knowledge came from.
- **Cite blobs, never your own unlanded commit hash** (`git rev-parse HEAD:<path>`): push-main rebases before it pushes.
- **Re-reads this item owes.** Before committing, run `powershell -File ops\audit-conclusion-currency.ps1 -ReportOnly`
  (after W4.2, `-ListHarnessSources`) on the post-change tree and list every doc that enrols a file you changed as a
  harness. Re-read each doc's conclusion against your change and add the re-read in the SAME commit (a ledger row via
  `ops\add-reread.ps1` once W4.1 has landed, a doc line before that). If you skip this, your push moves UNQUALIFIED above
  the baseline of 4 and run-gates refuses it with RATCHET BROKEN. Each item below names the docs that NAME its files at
  `855171a1e` (a `git grep` over `design/MEASURE-*.md` and `design/EVAL-*.md`); the audit decides which of them enrol.
  The pairs the correctness reviewer read as CURRENT at `31006efa6`, which therefore go UNQUALIFIED the moment the harness
  moves, are:
  - `lib/push-ledger.ps1` and `ops/probe-push-convergence.ps1` in `MEASURE-push-convergence-2026-09-12.md`;
  - `ops/audit-conclusion-currency.ps1` in `MEASURE-gate-slot-admission-2026-09-11.md` and
    `MEASURE-ratchet-plain-run-writes-2026-09-12.md`;
  - `ops/run-gates.ps1` in `MEASURE-gate-queue-window-2026-09-11.md` and `MEASURE-gate-slot-admission-2026-09-11.md`.
- **Self-test input declarations.** A `# gate-inputs:` line outranks inference in `lib/gate-input-key.ps1`, and a stale
  one replays a pass over changed code (the `15b02198b` class). Every item that changes a self-test, or adds a file a
  self-test dot-sources or copies, updates that file's `# gate-inputs:` line and runs
  `powershell -File lib\gate-input-key.ps1 -VerifyDeclared <file>`, reading exit 0. `ops/push-main.ps1:43` declares
  push-main, push-lock, git-repo-env, push-ledger, seed-hint and seed-worktree today; W2.3 adds
  `lib\concurrency-probe.ps1`, W6.1 adds `lib\chain-lease.ps1`, `lib\gate-slots.ps1` and `lib\mutex-hold.ps1`.
  `ops/test-prepush-hook.ps1:81` already omits `ops\rehearse-chain.ps1`, which its suite copies at :752; W1.1 fixes it.
- **Readers of a file you restructure.** Before moving content out of a file, `git grep` for every tracked reader of
  that file's text (a regex over its source, a path in a list, a reachability census) and change each one in the same
  commit. `grocery/audit-script-census.ps1` counts a script reachable only when an EXECUTABLE file names it (its
  extension list, `.ps1 .psm1 .js .yml .yaml .vbs .bat .cmd`, at :236); a new by-hand script goes on its `KNOWN` list with
  a reason, or the census ratchet goes red.
- **Self-tests.**
  - Read the exit code first. The last line is the suite's verdict and names the self-test.
  - A literal-case suite asserts how many cases ran.
  - Needles that must not match their own source are built by concatenation.
  - At-the-bar cases use binary-exact numbers: integer seconds, integer counts.
  - Every temp path is per run, allocated through one function and removed in `finally`.
  - A temp git repo calls `Clear-TcGitRepoEnv` (`lib/git-repo-env.ps1`) before `git init`.
  - Concurrency is proved by overlap (`lib/concurrency-probe.ps1`) or by a holder in another process
    (`lib/mutex-hold.ps1`), never by a wall-clock upper bar. A clock survives only as a generous hang guard.
  - No case opens a PRODUCTION lock name (the push lock, the chain lease, the per-checkout guard). Pass the private
    prefix and queue root seams the existing cases already use (`-LockPrefix`, `-LockQueueRoot`).
- **New detectors** carry a `SCOPE OF A CLEAN REPORT:` line and end with a `<NAME>-COMPLETE` marker. A `switch` on data
  carries a `default` that throws.
- **Heavy local load** goes through `ops/cpu-load.ps1`. Never run `run-gates` in a loop to measure anything.
- **The pre-push hook is a COPY** in the common `.git\hooks`, installed by `ops/install-hooks.ps1`. After W1.1 lands,
  install it from a clean worktree checked out at the landed origin/main, never from a feature branch, and then run
  `ops/audit-hook-installed.ps1` and read exit 0.
- **Rollout is per checkout.** Each checkout runs its own push-main and its own hook suite, so for days most ledger rows
  come from copies that predate an item. Every bar is judged only over rows whose `pm_blob` (W0.1) maps to a push-main
  commit at or after the item's landing, and prints how many older-copy rows it excluded.
- **Docs say what the code does.** Each item updates the header comment of every file it changes and any rules or
  CLAUDE.md sentence that describes the old behaviour, in the same commit.
- **No em dashes** in anything a reader sees, the plan and commit messages included.

## 6. Work items

### Row 0: instruments first

**W0.1 The push ledger records what a refusal needs, and which code wrote it.**
Files: `lib/push-ledger.ps1`, `ops/push-main.ps1`. Re-reads owed (section 5): `MEASURE-push-convergence-2026-09-12.md`
names `lib/push-ledger.ps1`; `MEASURE-aldi-pack-basis-2026-09-19.md`, `MEASURE-push-convergence-2026-09-12.md`,
`MEASURE-push-lock-2026-09-11.md` and `MEASURE-sams-cents-unit-price-2026-09-20.md` name `ops/push-main.ps1`.
1. `Write-TcPushRow` gains ONE optional parameter, `-Fields` (a hashtable merged into the row after the existing
   fields). A key that collides with an existing field throws. Readers ignore unknown fields, so rows stay backward
   compatible. The schema, with the item that fills each field (W0.1 writes every field it can; later items fill theirs):

   | Field | Meaning | Filled by |
   |---|---|---|
   | `schema` | `2` | W0.1 |
   | `pm_blob` | `git hash-object` of the running `ops/push-main.ps1` (`$PSCommandPath`) | W0.1 |
   | `session` | the first of these set in the environment: an orchestrator run id, the Claude Code session id; `null` otherwise. Read which variables a spawned session actually carries with `Get-ChildItem env:` before choosing, and name them in the header. A worktree name is not a session: one session makes many | W0.1 |
   | `change_id` | `git diff <branch_base> HEAD \| git patch-id --stable`, first field, taken at start | W0.1 |
   | `branch_base`, `branch_base_ts` | `git merge-base HEAD refs/remotes/<remote>/<branch>` and its `%cI`, taken at push-main START before any fetch | W0.1 |
   | `phase` | for a refusal: `preflight`, `catchup` or `inlock` | W0.1 (`inlock`), W2.1, W2.2 |
   | `rebase_phases` | every phase in which a rebase ran, in order | W0.1 (`inlock`), W2.1, W2.2 |
   | `preflight_sha` | `FETCH_HEAD` at the pre-flight fetch | W2.1 |
   | `conflict_files`, `conflict_scope` | `git diff --name-only --diff-filter=U` BEFORE `git rebase --abort`; scope `first-stop`, because it names only the commit the rebase stopped on | W0.1 |
   | `conflict_files_all` | `git merge-tree --write-tree --name-only --no-messages HEAD <target>` over the whole range, labelled approximate (a squashed merge) | W0.1 |
   | `sibling_same_subject` | short shas of main commits whose subject is Ordinal-equal to one of the branch's | W0.1 (in lock), W2.1 |
   | `leg_sec` | `rg`, `ta`, `rh`: integer seconds of the FIRST set of legs, 0 for a reused leg, `null` for one that did not run | W0.1 |
   | `catchup_sec`, `rounds` | total seconds of catch-up legs, and the round count | W2.2 |
   | `rg_reused`, `rg_selftests`, `rg_unkeyable` | parsed from run-gates' `<x> of <y> self-test(s) already passed ...; <z> could not be keyed` line (`ops/run-gates.ps1:800`) in the runner's output | W0.1 |
   | `ta_rc` | test-auditors' exit code outside the lock (124 is its own 1200 s kill) | W0.1 |
   | `ta_moved` | the `TA-KEY-MOVED` line | W0.4 |
   | `hook_ta` | `reused`, `ran`, `not-needed` or `unknown`, from the in-lock hook's test-auditors lines. Read `ops/prepush-test-auditors.ps1`'s reuse and run lines to choose the literal patterns | W0.1 |
   | `chain_touching` | from the `outcome=` field of the `CHAIN-REHEARSAL-CHECK-COMPLETE code=<n> outcome=<o>` line the `-ForPush` child prints (`ops/rehearse-chain.ps1:820`, :842); read its outcome vocabulary and map it; `null` when the line is absent | W0.1 |
   | `lock_held_ms` | from the lock grant to `Exit-TcPushLock`, a `[Diagnostics.Stopwatch]` | W0.1 |
   | `reject_class`, `reject_lines` | see step 2; up to 3 lines of at most 300 chars each | W0.1 |
   | `backlog_direct`, `inbox_invalid` | W3.2's counts | W3.2 |
   | `reread_doc_lines` | W4.1's count | W4.1 |
   | `lease`, `lease_wait_ms`, `lease_hold_ms`, `lease_holder` | W6.1 | W6.1 |

2. push-main fills them. On `push-rejected`, classify `$p.Text` by the first rule that matches, and keep the matching
   lines:
   - `^PRE-PUSH-REFUSED cause=(\S+)` (the fixed line W1.1 adds): class = that cause, plus `gate=` when present;
   - `^pre-push: BLOCKED - (the chain rehearsal|this push changes the daily chain)` or `^chain-rehearsal: (REFUSED|COULD
     NOT)`: `rehearsal`;
   - `^pre-push: BLOCKED - the test-auditors check`: `test-auditors`;
   - `^pre-push: BLOCKED - run-gates`: `run-gates`, and every `^\s+FAIL\s+(\S+)` line is kept, so the class becomes
     `run-gates:<gate>` for the first failing gate (for example `run-gates:ops\audit-conclusion-currency.ps1`);
   - `^pre-push: REFUSING`: `structure`;
   - `! \[remote rejected\]` or `cannot lock ref`: `remote`;
   - nothing matched: `unknown`, with the first 3 non-empty lines kept.
   The old regex (`^(pre-push: REFUS|chain-rehearsal: REFUSED)` or `RATCHET BROKEN`) matched only the three structural
   REFUSING lines: every gate refusal in the hook says `pre-push: BLOCKED` (`ops/hooks/pre-push:323-325, 346-350, 376,
   418`), and `RATCHET BROKEN` never reaches git's stderr, because the hook echoes only `^  FAIL|^run-gates: (FAILED|COULD
   NOT)` lines from run-gates' log.
3. The row is still written after the lock is released, as today.
Fixtures (push-main `-SelfTest`, a temp bare remote plus a clone):
- MUST FIRE: a rebase that conflicts on one path writes a row with outcome `refused-rebase-conflict`, `conflict_files`
  equal to exactly that path, and `conflict_scope` `first-stop`.
- MUST FIRE: a stub hook text of an in-lock rehearsal refusal records `reject_class` `rehearsal` and that line.
- MUST FIRE: a stub hook text of an in-lock run-gates red naming `ops\audit-conclusion-currency.ps1` in a `FAIL` line
  records `run-gates:ops\audit-conclusion-currency.ps1`.
- MUST FIRE: a `PRE-PUSH-REFUSED cause=rehearsal` line wins over the legacy wording in the same text.
- CLEAN TWIN: a clean rebase writes `landed-after-rebase` with no `conflict_files`, a numeric `lock_held_ms`, a
  40-hex `pm_blob` equal to `git hash-object` of the script under test, and `schema` 2.
- MUST NOT FIRE: a row in the old shape (no new fields) still parses in `ops/probe-push-convergence.ps1`.
- MUST NOT FIRE: an unknown hook text records `unknown` and never throws.
Done when: `ops/push-main.ps1 -SelfTest` and `ops/probe-push-convergence.ps1 -SelfTest` exit 0 with their verdict
lines, and the first real landing after W0.1 carries every W0.1 field. Read the ledger to check.

**W0.2 The hook suite stops writing the production ledger.**
File: `ops/test-prepush-hook.ps1`. Re-reads owed: `MEASURE-push-lock-2026-09-11.md` names it.
1. At the top of the self-test, set `$env:TC_PUSH_LEDGER_ROOT` to a per-run temp directory, and restore the old value
   in `finally`.
2. Name each sandbox `tc-prepush-selftest-<blob8>-<pid>-<guid8>`, where `<blob8>` is the first 8 hex of the suite's own
   blob. The prefix stays, so every existing exclusion glob still matches. A sandbox name WITH a blob segment can only
   come from a suite at or after W0.2.
Fixtures:
- MUST FIRE: after the suite, its own temp ledger holds at least one row that a sandbox wrote.
- CLEAN TWIN: no row in the real ledger names one of THIS run's sandbox names (its pid and guid). Record the names and
  read the real file. Do not compare its line count, because a real push may append during the run.
Done when: the suite exits 0 with its verdict line, and 7 days after landing the production ledger holds 0 rows naming a
sandbox with a blob segment. Rows naming an old-style sandbox come from checkouts that have not rebased; W0.3 counts and
reports them and they are not a failure of W0.2.

**W0.3 One committed harness for every bar here, with its read-out dates.**
File: `ops/probe-push-convergence.ps1`, extended rather than duplicated. Re-reads owed:
`MEASURE-push-convergence-2026-09-12.md`.
1. Add a `-Cost` section that prints, each figure with its N and the window in UTC:
   - push-main outcomes by UTC day;
   - seconds from the `run` start to the row, by outcome, phase, and generic versus chain-touching (median, p90, max, N);
   - first-attempt-to-landing seconds per change, grouping rows by (checkout, `change_id`), generic versus
     chain-touching (median, p90, N changes). Rows without a `change_id` group by checkout and consecutive attempts
     within 6 hours, and are labelled so;
   - leg seconds by leg (median, p75, N rows carrying the field, N eligible rows);
   - lock hold (median, p90, N), split by whether a catch-up or in-lock rebase ran;
   - conflict files by class, using the literal class table below, and for every conflict row the ANCESTRY of each
     colliding main commit (the newest main commit touching a conflict file in `branch_base..<the row's target>`)
     against `preflight_sha`: `before-preflight`, `after-preflight` or `unknown`;
   - `reject_class` counts, and how many push-rejected rows are `unknown`;
   - `backlog_direct`, `inbox_invalid`, `reread_doc_lines` totals;
   - `rg_reused` and `rg_selftests` for rows whose run-gates leg was the first in its checkout after a
     `ops/run-gates.ps1` landing, against all other rows: the flush cost, as extra leg seconds per day (the D7 input);
   - lease counts and hold spans (W6.1);
   - landings per active hour (a UTC clock hour with at least one push-main row), and which hours are BUSY (at least 6
     push-main rows).
2. Row selection:
   - Exclude rows whose checkout is under `%TEMP%\tc-prepush-selftest-*`, and print `excluded N rows`.
   - Map each row's `pm_blob` to the first origin/main commit carrying that blob of `ops/push-main.ps1` (from `git log
     --format=%H origin/main -- ops/push-main.ps1` and `git rev-parse <c>:ops/push-main.ps1`). A blob not on that history
     is `unknown-copy`. A bar's treated rows are those whose mapped commit is at or after the item's landing commit;
     print `older-copy rows excluded N` and `unknown-copy rows excluded N`. Rows with no `pm_blob` are pre-W0.1.
   - A PARALLEL RUN is at least 4 distinct checkouts sharing one `session` that each wrote a push-main row within one
     2-hour window.
3. The class table is literal regexes in the script, first match wins:
   - `backlog-index`: `^design/BACKLOG-`, `^design/ready-for-brad/README\.md$`, `^design/backlog-inbox/`;
   - `reread`: `^design/(MEASURE|EVAL)-`, `^design/reread-ledger\.tsv$`;
   - `ruling`: `^grocery/known-wrong\.json$`, `^grocery/commodities\.json$`;
   - `baseline`: `baseline\.json$`;
   - `rules`: `^\.claude/rules/`, `^CLAUDE\.md$`;
   - `hub`: `^ops/run-gates\.ps1$`, `^grocery/test-auditors\.ps1$`, `^grocery/check-ad-cycles\.ps1$`,
     `^ops/run-gates-static\.tsv$`;
   - `code`: `\.(ps1|py|js|sh)$`;
   - `other`: anything else.
4. The bars table of section 8 is a literal table in the script: bar id, metric, stratum, minimum N, bar value, the
   landing commit of the item it judges (filled by that item's own landing commit), and the read-out date.
   `-Due` prints every bar whose read-out date has passed and exits 2 if any has no result line (`B<n>: result`) in
   section 13 of this plan's committed copy; exit 0 otherwise. Until W3.4's task runs `-Due`, each item's landing commit
   also files one backlog-inbox finding naming its bars and read-out dates, so the read-out is tracked work and not a
   memory.
5. `-History` (report only) re-derives what it can from reflog and git: the chain share of landings (through W0.5's
   `-ListSet`, printed BLIND before W0.5 lands), the 14-day class census, the backlog touch share (142 of 299) and the
   median overlap share. The conflict attribution before W0.1 needed transcripts and cannot be re-derived; it stays
   SCRATCH and is labelled so wherever it is used.
6. Run `-Cost` and `-History` once after Row 0 lands and paste both outputs into section 13 as the committed baseline,
   citing the script's blob. Where it disagrees with an investigator's or reviewer's scratch number, print both and use
   the committed one.
7. **Soak before Row 2.** Row 2 does not start until at least 30 lock-taken push-main rows carry W0.1's fields from
   updated copies. B3's, B7's and B9's baselines come from those rows (a direct timer), not from the derived remainder
   in section 2.1.
Fixtures (frozen literal JSON lines):
- MUST FIRE: `design/BACKLOG-course-findings.md` is classed `backlog-index`.
- MUST NOT FIRE: a sandbox checkout row is excluded and counted in `excluded`.
- MUST FIRE: a row whose `pm_blob` maps to a commit before the item's landing is excluded from that bar and counted.
- MUST FIRE: four checkouts with one session inside 2 hours form a parallel run; three do not (the at-the-bar pair).
- At the bar: a refusal 60 s after its run start counts as within B1, and one at 61 s does not.
- MUST FIRE: `-Due` with a past read-out date and no result line exits 2; CLEAN TWIN: with the result line, exit 0.
- CLEAN TWIN: the existing convergence sections print unchanged for the frozen rows.
Done when: `-SelfTest` exits 0 with its verdict line, and a plain `-Cost` run prints every section with denominators.

**W0.4 test-auditors says which input moved its key.**
File: `ops/prepush-test-auditors.ps1`.
1. The pass record changes shape, on purpose: today `Write-TaPassRecord` stores schema 1 (the 16-hex key over the
   sorted rows, `recorded_at`, `rc`, `mode`, `selected`, `cases`, `fail_lines`), and `Read-TaPassRecord` throws on any
   other schema. Schema 2 adds the sorted input rows themselves, plus a content hash beside each board row.
   - The KEY does not change: it is still computed from name, length and mtime, so nothing about what it decides moves.
   - First find where the record lives and who reads it. If any other checkout's older copy can read the same record
     (memory `prepush-test-auditors-judges-against-a-shared-record`), keep that reader working: write schema 2 to a
     sibling file, or make the reader accept both. State which in the commit.
   - Measure the added board-hashing time per key computation on the main checkout's boards, and put it in the commit.
   - Cost, stated here and in D13: every checkout pays ONE full test-auditors run on its first push after W0.4, because
     no schema 2 record exists yet.
2. When the keyed pass is not reused and a schema 2 record exists, diff the rows and print one line before running:
   `TA-KEY-MOVED kind=<content|mtime|lib|board> input=<repo path>`, naming the first input that differs. `kind=mtime` is
   a board whose content hash is equal and whose `LastWriteTimeUtc` differs. With no schema 2 record, print
   `TA-KEY-MOVED kind=no-record`.
3. push-main copies that line into the row's `ta_moved` field.
Fixtures:
- MUST FIRE: a board rewritten with identical bytes prints `kind=mtime`.
- MUST FIRE: an edit of `grocery/test-auditors.ps1` prints `kind=content`.
- MUST FIRE: a schema 1 record prints `kind=no-record` and runs.
- MUST NOT FIRE: an unchanged key prints nothing and reuses.
- CLEAN TWIN: the key computed over a frozen input set is byte-identical before and after the change.
Done when: the self-test exits 0. After 7 days, W0.3 splits the in-lock and pre-lock full runs into content moves and
mtime moves for D13.

**W0.5 The rehearsal script can print its set without rehearsing.**
File: `ops/rehearse-chain.ps1`. A chain-touching push: budget its rehearsal.
1. There is no read-only mode today (the modes are default, `-CheckPush`, `-ForPush` and `-SelfTest`), and
   `Get-RhManifestSet` cannot be dot-sourced because the script body runs on load. A default run clones, seeds, takes
   one of 6 rehearsal slots and runs the ship path for about 14 minutes.
2. Add `-ListSet [-Commit <sha>] [-Range <a>..<b>]`: print the manifest set at the commit (one repo path per line, sorted
   Ordinal), then, with `-Range`, the trigger decision `-ForPush` would make for that range. It clones nothing, takes no
   slot and writes nothing. It ends with `CHAIN-REHEARSAL-LISTSET-COMPLETE files=<n>`.
Fixtures:
- MUST FIRE: over a fixture manifest, the printed set equals the expected list exactly, and `files=` equals its count.
- MUST NOT FIRE: nothing is written: the verdict directory and the temp root are unchanged afterwards (compare their
  listings), and no rehearsal slot was taken (a probe from another process).
- CLEAN TWIN: `-ForPush` over the same fixture decides exactly as before.
Done when: the self-test exits 0, and `-ListSet` at origin/main prints the set (confirm or correct the 130 in section 2).

### Row 1: two small corrections, no rulings needed

**W1.1 The pre-push hook asks for the rehearsal record first, and names its refusals.**
Files: `ops/hooks/pre-push`, `ops/test-prepush-hook.ps1`. Re-reads owed: `MEASURE-gate-queue-live-sampling-2026-09-11.md`,
`MEASURE-push-convergence-2026-09-12.md` and `MEASURE-push-lock-2026-09-11.md` name the hook;
`MEASURE-push-lock-2026-09-11.md` names the suite.
1. Today the check sits inside the `if [ "$rc" -eq 0 ]` branch, after test-auditors, and its BLOCKED lines print only
   when test-auditors passed. Move the check (the `rh=`, `rhrc=`, `rhlog=` lines and the `-CheckPush` call with its
   marker test, on origin/main from :302) to just before the run-gates announcement at :251. `$refs` is written at
   :52, so its input already exists there.
2. Move the BLOCKED branch with it, so that a non-zero `rhrc` prints the same lines (the three `case` arms, the
   Rehearse and Bypass lines, the log path) and exits 1 at that point. On that new exit path, `rm -f "$refs"` first, as
   every other early exit does (:63, :74, :85, :93), and keep `$rhlog` as today. Delete the later `[ "$rhrc" -ne 0 ]`
   branch. The success path still echoes the check's output lines, and the normal `rm -f "$refs"` stays after
   test-auditors, which reads it too.
3. Every BLOCKED and REFUSING exit also prints one fixed line to stderr: `PRE-PUSH-REFUSED cause=<run-gates|
   test-auditors|rehearsal|structure> [gate=<first failing gate>]`. W0.1's parser already prefers it.
4. Keep the check's exit codes and its `TC_NO_REHEARSAL` handling byte for byte. Update the header's description of
   the order.
5. The precedence change, stated in full in the commit: a push that would fail run-gates or test-auditors AND has no
   rehearsal verdict now reports the rehearsal only, and the first refusal the pusher sees is the one that prints the
   `-NoRehearsal` bypass line. This weakens nothing: the same three checks must all pass, and the cheapest decides first.
6. Add `ops\rehearse-chain.ps1` to `ops/test-prepush-hook.ps1`'s `# gate-inputs:` line (:81); the suite copies it at
   :752. Run `-VerifyDeclared`.
Fixtures (sandbox linked worktree, as the suite does today):
- MUST FIRE: a chain-touching push with no recorded verdict is refused, and the run-gates stub never ran. The stub
  writes a marker file; assert that it is absent.
- MUST FIRE: that refusal prints `PRE-PUSH-REFUSED cause=rehearsal`.
- MUST FIRE: after that refusal, no `tc-prepush-refs-*` file from this hook run is left in the temp directory.
- CLEAN TWIN: a chain-touching push with a recorded verdict still runs run-gates and test-auditors. Both markers are
  present.
- MUST NOT FIRE: a push that touches no chain file runs run-gates and test-auditors as before.
Done when:
1. the suite exits 0 with its verdict line;
2. after landing, `ops/install-hooks.ps1` runs from a clean worktree at the landed origin/main;
3. `ops/audit-hook-installed.ps1` exits 0.

**W1.2 conclusion-currency fails closed on its baseline.**
File: `ops/audit-conclusion-currency.ps1`, the baseline read and the `if ($Accept -or $null -eq $base)` branch. Re-reads
owed: `MEASURE-gate-slot-admission-2026-09-11.md`, `MEASURE-gate-slot-starvation-2026-09-11.md`,
`MEASURE-push-convergence-2026-09-12.md` and `MEASURE-ratchet-plain-run-writes-2026-09-12.md` name it.
1. Tell apart ABSENT (no file), UNREADABLE (a parse error, or no integer `unqualified`) and READ.
2. On ABSENT or UNREADABLE:
   - a plain run ends through `Exit-Guard -Code 3`, with `blind=baseline-missing` or `blind=baseline-unreadable` and the
     path, and writes nothing;
   - `-Tighten` also exits 3 and writes nothing;
   - only `-Accept` writes a baseline.
   The refusal line starts with `!` so that run-gates' excerpt filter (`'!|FAIL'`, `ops/run-gates.ps1:969`) prints it
   under the FAIL line in the pusher's outside-the-lock output.
3. On a READ baseline, `-Tighten` and `-Accept` behave exactly as today.
4. How run-gates scores it, read at `ops/run-gates.ps1:963-969`: any non-zero static exit, 3 included, is `$fail += $g.f`,
   so the whole run exits 1 and pre-push refuses; the row reads `refused-gate-red`. State that in the commit. (The first
   version of this plan expected a whole-run 3. That was wrong, and fail-closed holds either way.)
5. Census, not a sweep: grep `ops/*.ps1` and `grocery/*.ps1` for a `$null -eq $base` (or equivalent) branch that writes
   a baseline, and list the files in the commit message. Fix only this one, and file the others as one backlog inbox
   finding.
Fixtures (per-run temp baseline through `-BaselineFile`):
- MUST FIRE: a baseline holding conflict markers gives exit 3, and its bytes hash-identical afterwards.
- MUST FIRE: an absent baseline on a plain run gives exit 3, and no file is created.
- MUST FIRE: `-Tighten` over an absent baseline gives exit 3, and no file is created.
- CLEAN TWIN: `-Accept` with an absent baseline writes it and exits 0.
- CLEAN TWIN: `-Tighten` over a READ baseline with a lower count still records the fall, as today.
- At the bar: a count equal to the baseline exits 0, and one above it exits 2.
Done when: the self-test exits 0 with its verdict line, and run-gates over the real tree is green, because the
committed baseline (4 of 13 at its recording) parses.

### Row 2: fit first, re-check what moved, legs side by side

**W2.1 Pre-flight: fetch and rebase before any leg.**
File: `ops/push-main.ps1`. Re-reads owed: the four push-main docs listed in W0.1. Needs the soak in W0.3 step 7.
1. **Per-checkout guard.** At push-main start, take a mutex named from SHA-256 of the lower-cased full worktree path
   (`git rev-parse --show-toplevel`), built the way `Get-TcLedgerLockName` builds a ledger name, with ZERO wait. If
   another push-main holds it, refuse `refused-not-ready` with the holder's pid and `Why` "another push-main is running
   in this checkout". If the mutex cannot be created, proceed as today and say so. An abandoned mutex (killed holder)
   reads free. It never waits, so it forms no wait-for edge with any other lock; W6.1's lock-order text still lists it,
   outermost, with that reason. This exists because pre-flight and catch-up now rewrite HEAD outside the push lock, and
   two push-main runs in one checkout (a retry started while the first is gating) would otherwise rewrite HEAD under
   each other's legs, and gate-verdict could record a pass for content no run wholly judged.
2. Add `Invoke-TcPreflightRebase -Dir -Remote -Branch -DryRun`. It returns `Code`, `Rebased`, `FromSha`, `ToSha`,
   `Files`, `Siblings` and `Why`. Call it BEFORE `Invoke-TcSeedIfUnseeded` (the rebase needs no seeded input, since the
   seeded paths are gitignored, and a fresh worktree's 47 MB seed should not delay a seconds-long refusal) and before
   `& $runner`, outside the lock. Seed only when it returns 0.
3. Inside it:
   1. `git fetch --quiet --refmap= <remote> <branch>`, then read `FETCH_HEAD`. The empty `--refmap=` makes git write
      only `FETCH_HEAD`, which is per-worktree, and leave the shared `refs/remotes/<remote>/<branch>` alone. Until now
      every push-main fetch ran under the push lock; unlocked fetches from many worktrees updating that shared ref would
      contend on its `.lock` and could fail the in-lock fetch (`blind-fetch-failed`, exit 3). A fetch failure returns
      Code 0 with the reason and push-main carries on: the in-lock fetch decides, exactly as today.
   2. Every warm leg that reads `refs/remotes/<remote>/<branch>` is handed the `FETCH_HEAD` sha instead.
      `Get-TcWarmRefLine` (:261-266) does, and builds test-auditors' ref line from it; give it a `-RemoteSha` parameter.
      Otherwise the warm verdict names a remote sha the hook will not see, and the hook runs test-auditors in full
      inside the lock. Read `Invoke-TcWarmGate` for the same pattern.
   3. Build the plan with the existing `Get-TcPushPlan`. A dirty tree is `refused-not-ready`, as today.
   4. When `NeedsRebase`: under `-DryRun`, do not rebase; print whether a rebase is needed and, from `git merge-tree
      --write-tree --name-only --no-messages HEAD <sha>`, whether it would conflict and on which files, labelled
      approximate. Otherwise run `git rebase <sha>`.
   5. On a non-zero rebase: if `git diff --name-only --diff-filter=U` names files, it is a CONFLICT. Collect them, then
      `git rebase --abort`. Collect the siblings: main commits in `<merge-base>..<sha>` whose subject is Ordinal-equal
      to a subject in `<merge-base>..HEAD`. Print both lists and return Code 1. If no file is unmerged and no
      `rebase-merge` or `rebase-apply` directory exists (for example `index.lock` stopped it from starting), it is
      COULD-NOT-REBASE: return Code 0 with that reason, and the in-lock path decides as today.
4. push-main records `refused-rebase-conflict` with `phase=preflight` and returns 1. The branch is exactly where it was.
5. On success, print `push-main: rebased onto <sha9> before gating; the branch was at <FromSha9>`, and record
   `preflight_sha` and `preflight` in `rebase_phases`.
6. A later red leaves the branch rebased. Say that in the header: the session then fixes the change on current main.
7. The in-lock fetch and rebase stay as today, except that the in-lock fetch retries ONCE on a `cannot lock ref` error
   before recording `blind-fetch-failed`.
8. **The outcome vocabulary.** `landed-after-rebase` now means a rebase ran in ANY phase (pre-flight, catch-up or in
   lock), and `rebase_phases` says which. So the historical 134 `landed-after-rebase` rows stay comparable as "this push
   had to move", and a phase split is read only from rows that carry `rebase_phases`. `base` keeps its meaning (the
   remote-tracking ref at start); `preflight_sha` is the new second base. W0.3 prints which rows predate the change.
9. **Existing cases that move with it, in the same commit:**
   - ~:649, labelled "a branch whose base the remote moved past is rebased under the lock": after W2.1 the pre-flight
     rebases it. Relabel it, and assert `rebase_phases` equals `preflight`.
   - ~:756, which asserts `outcome -eq 'landed-after-rebase'`: still true under step 8; add an assertion on
     `rebase_phases`.
   - W0.1's CLEAN TWIN: assert `rebase_phases` too.
   - Cases e (~:663-676) and n1 (~:762-775) set up their conflict before push-main starts, so the pre-flight now catches
     them and the in-lock abort would be reached by no case. Add a seam, `-BeforeLock` (a scriptblock run after the last
     catch-up fetch and before `Enter-TcPushLock`), and through it keep ONE in-lock conflict-and-abort case and ONE
     in-lock clean-rebase case: the scriptblock lands a commit on the fake remote at exactly that point.
Fixtures (temp bare remote plus clone; the runner is a stub that records whether it ran and the HEAD it saw):
- MUST FIRE: a conflicting branch is refused and the stub never ran. The row carries `phase=preflight` and exact files.
- MUST FIRE: a main commit with the branch's subject is named as a sibling.
- MUST FIRE: through `-BeforeLock`, a conflicting commit landed after pre-flight is refused in the lock with
  `phase=inlock`, the rebase is aborted and HEAD is the pre-lock sha.
- MUST FIRE: a second push-main started in the same checkout while the first holds the guard is refused at once with
  the holder's pid (the holder is another process, through `lib/mutex-hold.ps1` on a private name).
- CLEAN TWIN: a remote that moved without a conflict is rebased first, and the stub saw the rebased HEAD.
- CLEAN TWIN: through `-BeforeLock`, a clean commit landed after pre-flight is rebased in the lock and lands, with
  `rebase_phases` `preflight,inlock` or `inlock`.
- CLEAN TWIN: after a refused pre-flight, HEAD is the original sha and `git status --porcelain` is empty.
- CLEAN TWIN: the pre-flight fetch leaves `refs/remotes/<remote>/<branch>` unchanged and `FETCH_HEAD` at the remote tip.
- MUST NOT FIRE: a remote that has not moved causes no rebase, and the stub saw the original HEAD.
- MUST NOT FIRE: a failed fetch does not refuse, and the stub ran.
- MUST NOT FIRE: with `refs/remotes/<remote>/<branch>.lock` held by another process, the pre-flight fetch still
  succeeds.
- MUST NOT FIRE: a rebase that cannot start (a planted `index.lock`) is `could-not-rebase`, not a conflict, and push-main
  proceeds.
- MUST NOT FIRE: `-DryRun` never moves HEAD.
Done when: `-SelfTest` exits 0 with its verdict line, `-VerifyDeclared` passes, and a `-DryRun` from the landing
worktree prints the pre-flight lines. The mutation bars are in section 8.

**W2.2 Catch-up: re-check what moved, at most 3 rounds.**
File: `ops/push-main.ps1`. Needs W2.1.
1. After the legs pass, run up to `$CatchUpRounds = 3` rounds. The value is the first plausible one and was not swept;
   the comment says so. It also says what happens when the producer stops: if main stops moving, one round.
2. Each round:
   1. Fetch as in W2.1 (`--refmap=`, `FETCH_HEAD`). If the fetch FAILS, end the catch-up and go to the lock, as today,
      recording `degraded=fetch`. If `FETCH_HEAD` equals the base the legs last judged, stop.
   2. Otherwise rebase. A conflict refuses with `phase=catchup`, as in W2.1; a could-not-rebase ends the catch-up and
      goes to the lock.
   3. Re-run the runner (`Invoke-TcWarmGate`, then `Invoke-TcWarmTestAuditors`) and `Invoke-TcRehearsalForPush`. Each
      reuses what its own keys allow: test-auditors its keyed pass, the rehearsal its verdict key, run-gates only its
      per-self-test keys (its unkeyed self-tests and statics always run). Nothing new decides "still holds".
   4. A leg that exits 1 refuses, as a red does today. A leg that exits 3 (or anything but 0 and 1) ends the loop and
      goes to the lock, recorded as `rounds=<n>` and `degraded=<leg>`: the hook then gates that leg inside the lock, as
      before.
3. After round 3, whatever it found, go to the lock and print `push-main: catch-up did not settle in 3 rounds; the hook
   gates the rest inside the lock, as before`. Degrade, never refuse (D11).
4. Record `rounds`, `catchup_sec` and any `degraded` in the row.
Fixtures (temp remote; the rehearsal stub pushes one commit to the fake remote on its first call, which makes a landing
during the legs deterministic. W2.3 moves these stubs from `-RehearsalRunner` to its `-RehearsalStarter` seam and
rewrites these cases in its own commit):
- CLEAN TWIN: the loop settles in round 2, each stub is called twice, and the in-lock rebase is a no-op.
- MUST FIRE: a remote that moves every round stops after exactly 3 rounds, the 4th never starts, and the push still
  reaches the lock. This is the at-the-bar case.
- MUST FIRE: a conflict in catch-up refuses with `phase=catchup` before the lock. A probe from another process shows the
  lock was never taken.
- MUST FIRE: a leg exiting 1 in round 2 refuses `refused-gate-red`.
- MUST NOT FIRE: a leg exiting 3 in round 2 does not refuse; the push reaches the lock with `degraded` naming the leg.
- MUST NOT FIRE: a failed catch-up fetch does not refuse; the push reaches the lock with `degraded=fetch`.
- MUST NOT FIRE: a remote that never moves gives exactly one fetch after the legs and no second leg run.
Done when: `-SelfTest` exits 0 with its verdict line. B2, B3 and B8 are read on their dates (section 8).

**W2.3 test-auditors and the rehearsal run side by side** (D1).
**[ABSORBED 2026-09-23 evening into W9.3, section 16. Not built on its own; W9.3 uses this text with its changes.]**
File: `ops/push-main.ps1`.
1. **Step 0, before any code: three readings and one measurement.**
   - How `ops/rehearse-chain.ps1` cleans its clone, and what a killed run leaves behind (memory
     `powershell-exiting-event-does-not-fire`: a killed process runs no `finally`). The design below never kills the
     child. Do not change that without this reading.
   - That neither leg writes inside the checkout. Run each alone on a clean seeded worktree and compare, before and
     after, `git status --porcelain --ignored` plus the SHA-256 of every board file and every file under
     `grocery/out/` and `meal-prep/db/built/` (the gitignored paths both legs might read). A plain `git status
     --porcelain` cannot see gitignored writes. If either leg writes there, stop and report, because two legs sharing a
     checkout must not race on a file.
   - What the default `Wait()` must guard: moving from `& powershell` plus `$LASTEXITCODE` to `Start-Process` brings back
     the PS 5.1 empty-`ExitCode` trap (memory `ps-start-process-exitcode-needs-handle`).
   - THE MEASUREMENT (D1 is decided on it). Bar, written now: over 3 overlapped runs, **0 test-auditors timeouts** (rc 124
     or 3) and overlapped test-auditors wall at most 1.25 times its median alone wall. Method: on one clean seeded
     worktree, alternate arm by arm, 3 runs of test-auditors alone and 3 runs with a rehearsal started beside it; record
     each run's wall, rc, the rehearsal's wall and peak memory, and the box's other load (how many gate slots and
     rehearsal slots were held at start). If a busy box is to be simulated, the extra load comes from `ops/cpu-load.ps1`,
     never from hand-rolled burners or looped run-gates. This costs about 1.5 hours of box time and 3 rehearsal slot
     uses; commit the harness if the question can recur. Why it is needed: test-auditors takes no gate slot and runs
     under a hard 1200 s kill, today's legs already reach 871 s (73% of that bound) with no rehearsal beside them, and
     a timeout comes back as 3, which push-main passes to the hook, which then runs the full suite INSIDE the push lock.
2. The runner seam changes shape. Replace `-RehearsalRunner` with `-RehearsalStarter`, a scriptblock that returns an
   object whose `Wait()` returns `Code` and `Why`. The default starter runs `Start-Process powershell -ArgumentList
   '-NoProfile','-ExecutionPolicy','Bypass','-File',<rh>,'-ForPush','-Remote',<r>,'-Branch',<b> -PassThru
   -NoNewWindow -RedirectStandardOutput <per-run file> -RedirectStandardError <per-run file>` and touches
   `$proc.Handle` at once. W2.2's stub cases move to this seam in this commit.
3. After run-gates passes, call the starter, then run test-auditors in process, then call `Wait()`. The default
   `Wait()` runs `WaitForExit()`, reads `ExitCode`, echoes the output, and decides:
   - an empty or unreadable `ExitCode` is 3;
   - the last line must be `CHAIN-REHEARSAL-CHECK-COMPLETE code=<n> ...`, and `<n>` must equal the exit code; a
     missing marker, or a marker whose code disagrees with the exit code, is 3.
4. A test-auditors red is reported at once. push-main then waits for the child to finish, printing that it is waiting
   and why (a wait must not outlive its subject, and a kill would leak the clone), and refuses `refused-gate-red`.
   **Cost, stated in D1:** such a push now waits for its rehearsal (up to about 14 minutes plus a rehearsal slot wait)
   before refusing, where today it refuses before the rehearsal starts. A cooperative cancel (a stop file the rehearsal
   polls) would remove that cost; it is a chain change of its own and is not built here (section 10).
5. A push that needs no rehearsal still starts the child. `-ForPush` answers "not needed" in seconds, exactly as today.
6. The rehearsal child takes a rehearsal slot in its own process; push-main takes no gate or rehearsal slot itself while
   the child runs, and test-auditors takes none at all. Say in the commit that no process here holds one pool while
   waiting on the other, so this is not a nested acquisition.
7. Record `ta_rc` for every run, overlapped or not.
Fixtures:
- MUST FIRE, overlap: the test-auditors stub and the rehearsal stub each wait, through `lib/concurrency-probe.ps1`,
  until both have started. A serial pipeline cannot satisfy that, and a 120 s hang guard fails the case.
- MUST FIRE: a red rehearsal refuses `refused-rehearsal` when both gate legs passed.
- MUST FIRE: a red test-auditors refuses `refused-gate-red`, and the child has exited before push-main returns.
- MUST FIRE: a stub whose `ExitCode` reads empty, with a `code=0` marker, is scored 3 and not a pass.
- MUST FIRE: a stub that exits 0 with a `code=1` marker is scored 3.
- CLEAN TWIN: both pass and the lock is taken.
- CLEAN TWIN: W2.2's catch-up round uses the same start, run and wait sequence, so both legs also overlap there. Drive a
  one-landing catch-up and assert the overlap probe fires in round 2 as well.
- MUST NOT FIRE: a push that needs no rehearsal gets the child's "not needed" answer, and test-auditors' result alone
  decides.
The fixture starters launch a per-run stub `.ps1` as a real child process, so the overlap is between processes, as in
production. Add `lib\concurrency-probe.ps1` to push-main's `# gate-inputs:` line and run `-VerifyDeclared`.
Done when: step 0's measurement met its bar and D1 is decided, `-SelfTest` exits 0 with its verdict line, and B7 is read
on its date.

### Row 3: the backlog and the index stop being shared lines

**W3.1 Backlog status changes go through the inbox** (D2).
Files: `ops/merge-backlog-inbox.ps1`, `design/backlog-inbox/README.md`, `ops/audit-backlog-status.ps1`.
1. A new block form, in its own file under a NEW subdirectory, `design/backlog-inbox/updates/<lane>-<YYYY-MM-DD>.md`:
   ```
   ## UPDATE I165
   `DONE` `queue-7`
   <body paragraphs, appended to that item>
   ```
   The id pattern is `^## UPDATE ([A-Z]+[0-9]+)\s*$`, which covers the backlog's I and E ids. The next non-empty line is
   the item's new tag spans. The subdirectory matters: the current merge enumerates `Get-ChildItem -LiteralPath
   $InboxDir -Filter *.md` without `-Recurse` (`ops/merge-backlog-inbox.ps1:624`), so an older copy of the merge never
   sees an UPDATE file, and cannot misread `## UPDATE I165` as a NEW finding and allocate a bogus id for it.
2. **What an UPDATE replaces.** A heading is `### <id> - <title> <state span> [<tag spans>] [<prose>]`. The title can
   carry backticked code of its own (E7 `.worktreeinclude`, I1 `~/.claude`, E29 `run-log-lib.ps1`), and some headings
   carry prose after the tags (I5). So an UPDATE replaces exactly: the ONE backticked span that is a state in
   `audit-backlog-status.ps1`'s closed vocabulary (longest match first, as that file does), plus the contiguous
   backticked spans immediately after it. The title before it and any prose after the last replaced span stay
   byte-identical.
3. The merge, still the one writer:
   - It holds a ledger lock (`lib/ledger-lock.ps1`, `Enter-TcLedgerLock` on the backlog file's path) across its read, id
     allocation and write, so a scheduled run and a hand run cannot allocate at once.
   - It appends a blank line, the body and `**Merged from design\backlog-inbox\updates\<file> on <date>.**` at the end of
     that item's section, just before the next `### ` or `## ` heading.
   - It applies updates in file-name order, then in-file order.
   - **Conflicting updates are never settled by order.** When one batch updates one id from two files with DIFFERENT
     tag sets, it quarantines BOTH files, each with a `.reason.txt` naming the other, merges nothing for that id, and
     exits 2. File names start with the lane, so "later" would mean alphabetical by lane, not by time. When the tag sets
     are identical, both bodies merge and the output says `I165 updated by 2 files: <a>, <b>`.
   - It prints the commit trailer line for whoever commits the merge: `Backlog-Merged-From: <file>[, <file>...]`.
4. **Validation by the gate's own rules.** After applying UPDATEs to a temp copy, run `audit-backlog-status.ps1`'s gate
   mode over that copy. A file whose update makes the temp backlog fail (a missing REVERSIBILITY or FIRST-RUNG tag on a
   heading that is not closed, two state spans, an unknown state) is quarantined whole, as today, with the gate's
   finding in its `.reason.txt`. So is an UPDATE for an id that does not exist. `-ValidateFile` covers UPDATE files the
   same way. Quarantine for updates is `design/backlog-inbox/updates/quarantine/`.
5. `audit-backlog-status.ps1 -Summary` overlays pending UPDATE blocks and prints each such item under its new state
   with `(pending inbox: <file>)`. The gate mode (no `-Summary`) is unchanged and judges only the backlog file.
6. List what each file that names `BACKLOG-course-findings` does with it, and put the list in the commit message. The
   files are `graph/bench/probe_statistics.py`, `graph/pipeline/probe_basis_modes.py`,
   `grocery/audit-script-census.ps1`, `ops/audit-backlog-status.ps1`, `ops/count-unchecked-child-parse.ps1`,
   `ops/count_unchecked_child_parse.py` and three triage plans. Confirm that none needs a state which would now lag
   until the merge.
7. The README gains a "Recording progress on an existing item" section with the form above, the `updates/` directory,
   and the rule that a lane never edits the backlog file directly.
Fixtures (temp backlog and temp inbox):
- MUST FIRE: an UPDATE for I2 changes exactly I2's state and tag spans and appends the body at the end of I2's section,
  and every other byte is identical.
- MUST FIRE, E7 shape: an UPDATE for a heading whose TITLE carries backticked code leaves the title's span untouched.
- MUST FIRE, I5 shape: an UPDATE for a heading with prose after its tags leaves the prose byte-identical.
- MUST FIRE: an UPDATE naming a missing id quarantines the file, the run exits non-zero and the backlog is unchanged.
- MUST FIRE: an UPDATE with an unknown state is quarantined.
- MUST FIRE: an UPDATE that drops a required REVERSIBILITY tag on an open item is quarantined with the gate's finding.
- MUST FIRE: two files giving one id DIFFERENT tag sets quarantine both, exit 2, and the backlog is unchanged for it.
- CLEAN TWIN: two files giving one id the SAME tag set both merge.
- CLEAN TWIN: a plain new-finding file in the same batch still gets the next id and merges.
- MUST NOT FIRE: UPDATE files for two different items give byte-identical backlogs in either merge order.
- MUST NOT FIRE: the current merge's enumeration, run over an inbox holding only `updates/` files, finds no new finding.
- CLEAN TWIN: `audit-backlog-status.ps1` over the merged temp backlog exits 0.
- CLEAN TWIN: `-Summary` shows a pending UPDATE's item under its new state, marked pending.
Done when: the self-test exits 0 with its verdict line, and the first real lane files an UPDATE that merges.

**W3.2 push-main counts direct backlog edits and invalid inbox files** (warn only; D3 decides any refusal). Needs W3.1.
File: `ops/push-main.ps1`, inside the pre-flight.
1. List the commits in `<merge-base>..HEAD` with `git log --no-renames --name-status`. Count those that change
   `design/BACKLOG-course-findings.md` and neither delete nor rename out any file under `design/backlog-inbox/`
   (including `updates/`). The merge moves a quarantined file to `quarantine/`, which default rename detection would show
   as `R`, so `D` and `R` out of the inbox both count as a merge.
2. When the count is over 0, print `push-main: WARN - <n> commit(s) here edit design/BACKLOG-course-findings.md
   directly. That file overlapped in 12 of 19 recent rebase conflicts. Record progress as '## UPDATE <id>' in
   design/backlog-inbox/updates/ (see its README).`
3. Run `merge-backlog-inbox.ps1 -ValidateFile` over every inbox file the push ADDS; warn on each that would be
   quarantined, naming its reason. The scheduled merge would otherwise find it hours later, unattended.
4. Write the counts into `backlog_direct` and `inbox_invalid`. Never refuse.
Fixtures:
- MUST FIRE: a commit that edits the backlog and touches no inbox file warns, with a count of 1.
- MUST NOT FIRE: a commit that edits the backlog and deletes an inbox file does not warn.
- MUST NOT FIRE: a commit that edits the backlog and moves an inbox file into `quarantine/` does not warn.
- MUST NOT FIRE: a branch that does not touch the backlog does not warn.
- MUST FIRE: an added UPDATE file naming a missing id warns, with `inbox_invalid` 1.
Done when: the self-test exits 0. After 7 days, W0.3's `backlog_direct` total goes to Brad as D3's evidence.

**W3.3 The ready-for-brad index stops holding per-item text** (D10).
Files: `design/ready-for-brad/README.md` and the destinations below.
1. The README at `855171a1e` has 5 sections after its opening explainer. Move each one VERBATIM to the destination named
   here, under a `## What Brad does` heading, directly after the destination's first heading:

   | README section | Destination |
   |---|---|
   | `grocery-browser-stores-refresh.SKILL.i124.md (backlog I124)` | a NEW file, `I124-grocery-browser-stores-refresh.md`. The SKILL file opens with YAML frontmatter and is a staged skill, so a block inside it would either break the frontmatter or ship into the skill |
   | `produce-condiment-exclusion.md` | that file |
   | `I60-lesson-republish.md (backlog I60)` | that file |
   | `lessons/ (backlog I108, I109, I111)` | `lessons/README.md` (it exists; read `git log` on it first, and if a script generates it, use a new `lessons/WHAT-BRAD-DOES.md` instead) |
   | `One VACUUM of graph.db (backlog I211)` | a NEW file, `I211-graph-vacuum.md` |

   `I143-claim-words.md` is generated whole by `meal-prep/pipeline/audit-nutrient-claims.ps1`, and neither it nor
   `I143-sweep.md` has a README section. Leave both untouched.
2. The README keeps its opening explainer and one line: `The list is this directory: Get-ChildItem
   design\ready-for-brad -Exclude README.md`.
3. Read the four scripts that name `ready-for-brad`: `grocery/record-sample-verdict.ps1`,
   `meal-prep/pipeline/audit-nutrient-claims.ps1`, `meal-prep/pipeline/build-v2-spec.ps1` and
   `meal-prep/pipeline/nutrient-claim-lib.ps1`. If any writes a README section, change it to write its own file instead,
   and run its self-test.
Done when: the README holds no per-item section, each of the 5 moved blocks is byte-identical in the destination the
table names (a diff per row, in the commit message), and the two generated or sectionless files are byte-identical to
their parent blobs.

**W3.4 The backlog merge runs on a schedule, and the bars' read-outs have an exit code** (D2).
Files: a new task script under `ops/` (name it for what it does, for example `ops/run-backlog-merge.ps1`), the task
registration the estate already uses for TC tasks (read how `audit-task-registration` and the existing install script
register one; do not hand-register), `grocery/health-heartbeat.ps1`'s task list.
1. The task runs at 11:00 and 17:00. Each run:
   - refreshes its own dedicated clean linked worktree to origin/main (never the main checkout, and never around the
     ~07:00 bot's window);
   - runs `merge-backlog-inbox.ps1`, which holds the ledger lock (W3.1), so a hand run and the task never allocate at
     once;
   - on a merge that changed the backlog, commits with a pathspec and the `Backlog-Merged-From:` trailer, and lands
     through `ops\push-main.ps1`;
   - runs `probe-push-convergence.ps1 -Due` (W0.3).
2. It pages through the estate's alert path on: merge exit 2 (a quarantine, including conflicting updates); a refused
   push; `-Due` exit 2; any push ledger row with `lease=timeout` or `lease=error` since its last run (W6.1 step 10, once
   W6.1 has landed; before that there are none to read); and a STALE INBOX, the absence floor: the oldest pending UPDATE
   file older than 24 hours. The
   task runs twice a day, so a working task leaves no UPDATE older than about 18 hours; 24 hours means the producer
   stopped. First plausible value, not swept.
3. It runs under the headless conhost wrapper (memory `scheduled-tasks-run-under-headless-conhost`), and
   `grocery/health-heartbeat.ps1` watches it like every other TC task.
4. Expect two pushes from a worktree (memory `new-scheduled-task-needs-two-pushes-from-a-worktree`: a gate checks the
   main-checkout path).
Fixtures: MUST FIRE: a stale UPDATE file (mtime 25 hours old, set through the seam that supplies "now") pages; MUST NOT
FIRE: one 23 hours old does not; MUST FIRE: a merge exit 2 pages; CLEAN TWIN: an empty inbox exits 0 and pages nothing.
Done when: the self-test exits 0, the task is registered and `Get-ScheduledTask` shows it (a definition is not a
registration), and its first scheduled run's log shows a merge and a `-Due` result.

### Row 4: re-reads stop colliding and stop multiplying

**W4.1 One append-only re-read ledger with union merge** (D4).
Files: new `design/reread-ledger.tsv`, `.gitattributes`, `ops/audit-conclusion-currency.ps1`, new
`ops/audit-reread-ledger.ps1`, new `ops/add-reread.ps1`, `.claude/rules/measurement.md`, `ops/push-main.ps1` (step 7),
`grocery/audit-script-census.ps1`'s `KNOWN` list. Re-reads owed: the four conclusion-currency docs in W1.2.
1. The ledger is LF, UTF-8 without a BOM, with one header line,
   `doc<TAB>harness<TAB>blob<TAB>prior_blob<TAB>date<TAB>action<TAB>note`, and exactly seven tab-separated fields per row,
   each row ending in LF. `action` is `reread` or `withdrawn`. `prior_blob` is the blob the pair was last qualified at
   (the previous qualifying row's or doc line's blob, or `-` when none): it records which harness change the note says
   was read. `note` holds no tab and no CR.
2. Add one `.gitattributes` line: `design/reread-ledger.tsv merge=union`. It names only that path. `union` is built
   into git and needs no `.git/config` entry.
3. conclusion-currency reads the ledger as a SET beside the doc lines:
   - a `reread` row qualifies only its own (doc, harness) pair, and only when its blob equals the harness's current
     blob in full (40 hex, Ordinal);
   - a `withdrawn` row for the same doc, harness and blob cancels it, wherever it sits in the file;
   - a row never enrols a harness;
   - doc lines keep working exactly as today.
   Its UNQUALIFIED report prints, for each pair, the doc, the harness and the harness commits it moved past since the
   pair's last qualifying blob. It does NOT print a runnable command: deciding that the change altered nothing IS the
   re-read (measurement.md), and a copy-paste line would turn it into a formality.
4. `ops/audit-reread-ledger.ps1`, registered in run-gates' static list:
   - every row at `git merge-base HEAD origin/main` must still be present, byte for byte, in HEAD's ledger; a missing or
     edited row exits 2 and is named;
   - every row at HEAD must end in LF, have seven fields, a 40-hex `blob`, a 40-hex or `-` `prior_blob`, and an
     `action` of `reread` or `withdrawn`; otherwise exit 2 naming the line (a missing trailing LF glues two rows together
     under union merge, and conclusion-currency would silently ignore the result);
   - a base that cannot be resolved (a shallow checkout, a sandbox with no `origin/main`) is BLIND:
     `blind=no-merge-base`, exit 3, scored as run-gates scores any other non-zero static;
   - a ledger absent at the base is counted and skipped. It is green on day one because the file starts as its header.
5. `ops/add-reread.ps1 -Doc <path> -Harness <path> -Note "<what still holds>"`:
   - refuses an empty note, and a note identical to the pair's previous note;
   - takes the blob from `git rev-parse HEAD:<harness>`, or `git hash-object <harness>` when the working copy differs
     from HEAD, as measurement.md already allows, and `prior_blob` from the pair's last qualifying row or doc line;
   - writes through `lib/lf-write.ps1` (`Write-TcLfFile -NoBom`): read the current bytes, append the one LF-terminated
     row, write the whole file. NOT through `lib/append-line.ps1`: `Add-TcLine` always appends CRLF (`GetBytes($Text +
     "`r`n")`, `lib/append-line.ps1:75`). One person runs this writer, so append atomicity is not needed;
   - verifies a CR count of 0 on the bytes written, and tells the caller to check the committed blob the same way
     (`git cat-file -p HEAD:design/reread-ledger.tsv`) after committing.
   It writes only when a person runs it with their own note. It is a by-hand tool that no executable names, so add it to
   `audit-script-census.ps1`'s `KNOWN` list with the reason "by hand, re-qualifies a moved harness".
6. measurement.md's "RE-QUALIFY A MOVED HARNESS BY ITS BLOB" bullet names the ledger row as the preferred form and
   `add-reread.ps1` as its writer.
7. push-main's pre-flight counts commits in `<merge-base>..HEAD` that ADD a `Re-read at` line to a `design/*.md` file,
   prints `push-main: WARN - <n> commit(s) here add a re-read as a doc line; record it with ops\add-reread.ps1 instead`,
   and records `reread_doc_lines`. Never refuses; D3 decides.
Fixtures:
- MUST FIRE: a `reread` row with the current blob makes that (doc, harness) CURRENT.
- MUST NOT FIRE: a row carrying only a 12-character prefix of the blob does not qualify.
- MUST NOT FIRE: a row for (doc A, harness P) does not qualify (doc A, harness Q).
- MUST NOT FIRE: a row naming a path the doc does not name leaves the doc's harness set unchanged.
- MUST FIRE: `withdrawn` after `reread` reads UNQUALIFIED, and so does `withdrawn` before `reread`.
- MUST FIRE (ledger audit): a HEAD ledger missing a base row exits 2 naming it, and an edited row exits 2.
- MUST FIRE (ledger audit): a row with six fields, a short blob, a CR, or no trailing LF exits 2 naming the line.
- MUST FIRE (ledger audit): an unresolvable base exits 3 with `blind=no-merge-base`.
- CLEAN TWIN (ledger audit): appended rows only exit 0.
- MUST FIRE (writer): an empty note and a repeated note are refused; CLEAN TWIN: a new note writes one row with 0 CR.
- CLEAN TWIN, real tree: with the ledger at its header, the PER-DOC verdict list from `-ReportOnly` is identical
  before and after the change, both taken at the same origin/main. (Not fixed counts: the next landing that adds a doc
  or moves a harness would turn a count red for reasons unrelated to this change. At `31006efa6` it read 4 of 26
  UNQUALIFIED, 8 current and 14 not qualifiable, which the correctness reviewer reproduced.)
- Union, in a temp repo carrying this repo's `* text=auto eol=lf` line plus the union line: two branches append
  different rows and a rebase gives both rows and no conflict. Then the bot's shape, `git -c rebase.autoStash=true
  rebase -X theirs`, still keeps both rows, and the blob has 0 CR. **If this case fails, stop and report: do not land a
  union line whose behaviour under the bot is unknown.** (The correctness reviewer ran it on git 2.54 and it passed.)
Done when: every suite exits 0 with its verdict line, and the real-tree twin holds.

**W4.2 Re-read lines stop enrolling harnesses, after freezing today's pairs** (D5).
File: `ops/audit-conclusion-currency.ps1`, plus the docs that gain frozen lines. Re-reads owed: as W4.1.
1. Add a report-only `-ListHarnessSources` switch that prints each (doc, harness) pair with the line that enrolled it.
2. For each pair enrolled only by a re-read line (5 of 32 by the mechanism's count, confirmed by the correctness
   reviewer), add one explicit line to that doc, ABOVE its block of re-read lines:
   `Harness (frozen 2026-09-2x from a re-read line): <path>`.
3. The enrolment rule, exactly:
   - A RE-READ PARAGRAPH starts at a line matching `Re-read at (harness blob|commit)` and runs to the next blank line, or
     to the next line that BEGINS with a harness label (`Harness:` or `Harness (frozen`), whichever comes first.
   - No line inside a re-read paragraph enrols a harness, and the re-read line is never joined with the line after it
     (today `Get-HarnessPaths`, :71-91, joins each line with the next).
   - Every other line that matches as a harness line enrols, exactly as today. A line that begins with a harness label
     always enrols, even directly after a re-read line.
4. Verify that the sorted pair list is identical before and after (32 of 32 on the investigators' count; use the tree's
   count), and that the per-doc verdict list is unchanged.
Fixtures:
- MUST NOT FIRE: a re-read line naming a new path does not enrol it.
- MUST NOT FIRE: a wrapped continuation of a re-read line that contains the word "harness" does not enrol its path.
- MUST FIRE: a `Harness:` line on the very next line after a re-read line still enrols.
- CLEAN TWIN: an explicit harness line elsewhere still enrols.
- CLEAN TWIN: the real tree's pair set is identical before and after the change.
Done when: the self-test exits 0 and both before-and-after lists are in the commit message.

### Row 5: the runner file stops flushing every cache (built only if D7 says so)

**W5.1 The static gate lists move to a sorted data file** (D7: DEFERRED until W0.3 measures the flush cost).
Files: `ops/run-gates.ps1` (`$static` from :207 and `$pyStatic` at :572 on origin/main), new `ops/run-gates-static.tsv`,
new `ops/run-gates-static-notes.md`, and EVERY reader found in step 0. Re-reads owed: `MEASURE-daily-chain-cost-2026-09-09`,
`MEASURE-daily-chain-stages-2026-09-09`, `MEASURE-event-bus-concurrent-append-2026-09-11`, `MEASURE-gate-cost-2026-09-09`,
`MEASURE-gate-queue-live-sampling-2026-09-11`, `MEASURE-gate-queue-window-2026-09-11`,
`MEASURE-gate-slot-admission-2026-09-11` and `MEASURE-ratchet-plain-run-writes-2026-09-12` name `ops/run-gates.ps1`.
0. **Readers first.** `git grep` for every tracked file that reads run-gates.ps1's source text (its path, a regex over
   `f = '`, over `daily =`, over `n = '`), and put the count and the list in the commit. At `855171a1e` these are known,
   and each changes in THIS commit or the push is red:
   - `grocery/audit-script-census.ps1`: it counts a script reachable only when an executable file names it. After the
     move, `grocery/audit-instore-shutout.ps1` would be named by no executable file (a new ORPHAN in its strict grocery
     tier), and eight ops audits whose only executable caller is run-gates would raise the outside-grocery ratchet
     (`capture-ingest-reporting`, `lesson-rate-claims`, `literal-newline-escape`, `phantom-paths`, `rule-currency`,
     `ruling-drift`, `threshold-register`, `unread-wait`; the correctness reviewer's `git grep`). Add `.tsv` to its
     reachability extensions (:236) for that one file, or have run-gates keep a generated name list; choose one and say
     why.
   - `grocery/audit-guard-contract.ps1` (:172, the same executable-extension reachability): the audits run only by
     run-gates would read DEAD. Same fix, same commit.
   - `ops/run-daily-ratchets.ps1`: it regex-reads the `daily = $true` entries out of run-gates.ps1 (:40), and its
     `-SelfTest` MUST FIRE "run-gates really does mark audits daily" (:99) is a live join. Point it at the TSV.
   - `grocery/test-auditors.ps1:3200`: requires run-gates.ps1 to contain `f = 'grocery\audit-json-readers.ps1'`. Point it
     at the TSV. A leftover copy of the text in run-gates would make two lists, so do not keep one.
1. The file has one entry per line, `kind<TAB>script<TAB>args<TAB>cadence<TAB>zero_ok<TAB>name`, sorted by `script`
   then `args`, Ordinal. `kind` is `ps` or `py`; `cadence` is `push` or `daily`; `zero_ok` is `0` or `1` (no entry
   carries it today, `ops/run-gates.ps1:445`, but W6.9 declared it and the scoring reads it at :959); `name` is the `n`
   text printed on every ok, BLIND and FAIL line (:960-969). The rationale comments beside each entry (171 lines, some
   recording Brad's rulings on push versus daily) move VERBATIM to `ops/run-gates-static-notes.md`, one `## <script>`
   section each, so a change to a registration's reason edits the notes file, not run-gates.
2. run-gates reads it and dispatches exactly as the arrays did. First check that the pool does not depend on array
   order, and state the finding in the commit.
3. A missing file, a wrong field count, an unknown value in a closed column, a duplicate (script, args), a missing
   script or an unsorted line exits 3 with `blind=static-list-unreadable` and the line to fix. That fails closed. The
   column set is closed; a new field is added by a commit that changes the parser and this plan's text.
4. run-gates prints `static list: <n> entries (<p> push, <d> daily), <y> python`. The investigators counted 58
   PowerShell entries (6 daily) and 2 Python; the reviewers counted 59 `$static` entries. Use the tree's count.
5. The data file is NOT added to `$runnerFiles`. Statics are never keyed, so no key needs it, and the whole-run
   fingerprint already covers every tracked file.
6. Sorting puts two different registrations on different lines, so git merges them cleanly unless the names are
   neighbours.
Fixtures:
- MUST NOT FIRE: an edit of the list file leaves one sandbox self-test's `Get-TcGateInputKey` unchanged.
- CLEAN TWIN: an edit of run-gates' own code moves that key, which is today's behaviour.
- MUST FIRE: a malformed list exits 3, and so does an unsorted one, and so does a seven-field line.
- CLEAN TWIN: `run-daily-ratchets.ps1 -SelfTest`'s live join finds the same daily set from the TSV.
- Landing check, once: parse the parent blob's `$static` and `$pyStatic` arrays by AST and compare EVERY field of every
  entry (`f`, `a`, `daily`, `zero_ok`, `n`) with the file, Ordinal; then run run-gates over the pre-change and the
  post-change tree and compare the dispatched gate NAMES, not a pass count. Put both results in the commit.
Done when: run-gates', gate-input-key's and run-daily-ratchets' self-tests exit 0; `audit-script-census`,
`audit-guard-contract` and test-auditors are green over the post-change tree; and the dispatched name lists match.

### Row 6: the one contended object gets a lock of its own

**W6.0 The rehearsal triggers on a deleted set member too.**
File: `ops/rehearse-chain.ps1`. A chain-touching push: budget its rehearsal. Needs W0.5.
1. `Get-RhPushDecision` triggers on `diff(rsha..lsha)` intersected with the set AT `lsha`. A push that deletes a set
   member, and drops it from the manifest, is never rehearsed, yet it moves every rehearsal key. Trigger on the diff
   intersected with the UNION of the sets at `rsha` and `lsha`.
2. This strengthens the gate (more pushes are rehearsed) and needs no ruling. Say so in the commit.
Fixtures: MUST FIRE: a push that deletes a manifest member and removes it from `files[]` needs a rehearsal; CLEAN TWIN:
a push that edits a member still needs one; MUST NOT FIRE: a push touching no member at either end does not.
Done when: the self-test exits 0 with its verdict line.

**W6.1 The chain lease: chain-touching pushes serialise their final rehearsal** (D8). Needs W2.2 and W6.0.
**[REPLACED 2026-09-23 evening by W9.2, section 16. Not built; read 16.4 for what carries over.]**
Files: new `lib/chain-lease.ps1`, `ops/push-main.ps1`, `.claude/rules/ops-and-gates.md` (the lock order), and, only
when the default flips to live, `CLAUDE.md`'s "THE GATE MUST NOT RUN INSIDE THE LOCK" paragraph.
1. **Which pushes take it.** Every push-main push whose `-ForPush` child reports it chain-touching (its `outcome=`,
   W0.1), with the union trigger of W6.0, INCLUDING a `-NoRehearsal` or `TC_NO_REHEARSAL` push that would have been
   chain-touching: skipping the rehearsal does not stop the push from voiding someone else's.
2. `lib/chain-lease.ps1` wraps `lib/gate-slots.ps1` at `Total 1` with its own prefix and queue, as `lib/push-lock.ps1`
   does, so it is not a second copy of the arrival-order rules. It takes `-Prefix` and `-QueueRoot` seams, and it
   REFUSES the production prefix whenever `$env:TC_CHAIN_LEASE_SELFTEST` is set; push-main's `-SelfTest` sets it.
3. push-main takes the lease after the legs pass and before the catch-up round, holds it through the catch-up, the push
   lock and the push, and releases it after the push lock. Under the lease no other respecting push lands a chain
   change, so a holder re-rehearses at most once (when a chain landing voided its legs' rehearsal before it took the
   lease). Its hold is therefore about 5 minutes without a re-rehearsal, 17 to 25 with one, and at most about 45 (three
   catch-up rounds that each re-run test-auditors).
4. **Mode** is a push-main parameter, `-ChainLease`, defaulting to `live` from its first commit (D8, ruled
   2026-09-23: no shadow period). `[CHANGED 2026-09-23]` This step first specified a shadow default.
   - Live: wait, and record `lease=held`, `lease_wait_ms`, `lease_hold_ms`, and `lease_holder` whenever it waited
     behind one (the holder's pid and checkout, from its ticket). An error is `lease=error` and the push proceeds.
   - Off: never open the lease, record `lease=off`, and push exactly as before W6.1. This is the ROLLBACK: flipping the
     default to `off` is a one-line commit, and a pusher can pass `-ChainLease off` on one push. It exists so going
     live without a shadow period never leaves a broken lease with no way round it but a revert.
5. **The wait bound, and it is not a total.** `Enter-TcGateSlots`' `WaitSec` bounds time WITHOUT QUEUE MOVEMENT
   (`lib/gate-slots.ps1:296`, :372), not total time. That is deliberate here: a waiter behind a moving queue keeps its
   place, because leaving it would land unleased and void the holder, which is the failure the lease exists to prevent.
   `$ChainLeaseWaitSec = 3600`: the first plausible value above the longest hold step 3 allows (about 45 min), not
   swept. So only a wedged or frozen holder times a waiter out. While waiting, push-main prints its position and the
   queue depth every 5 minutes. A timed-out waiter proceeds without the lease, as today, and records `lease=timeout`,
   `lease_wait_ms` and `lease_holder`. A dead holder's mutex is abandoned and reads free. It never refuses.
6. **The ceiling, stated beside the fix as the rules require.** 60 divided by the hold in minutes, per hour: about 12
   chain pushes an hour when no holder re-rehearses, about 2.4 to 3.5 an hour when every holder does. At the 09-19 peak
   (about 4.2 chain landings an hour offered, from a share measured before the rehearsal gate) most holders would
   re-rehearse, so the lease queues at that peak, and the total wait of a deep waiter is the queue ahead of it. It
   removes a livelock; it does not add capacity.
7. **Lock order**, added to `.claude/rules/ops-and-gates.md` in this commit, outermost first:
   - `0a.` the per-checkout guard (W2.1, `ops/push-main.ps1`): taken with zero wait, so it never waits on anything and
     nothing waits on it; listed so a reader knows it exists;
   - `0b.` the chain lease (`lib\chain-lease.ps1`, `Enter-TcChainLease`);
   - `1.` the push lock, `2.` the gate worker slots, and so on, as today;
   - the REHEARSAL SLOTS (`Global\tc-rehearsal-slot-`, a `gate-slots` instance with a budget of 6), which the declared
     order does not yet name. Read `ops/rehearse-chain.ps1` for any gate-slot or push-lock acquisition made while a
     rehearsal slot is held. If there is none, place them at `2b`, a peer of the gate slots never nested with them in
     either order, and say so. If a rehearsal takes gate slots inside its slot, place them above the gate slots.
   The commit names these as first nested acquisitions: lease over push lock; lease over gate slots (the catch-up's
   run-gates); lease over a rehearsal slot (the catch-up's rehearsal child, another process, which is still a
   wait-for edge). No holder of the push lock, a gate slot or a rehearsal slot ever waits on the lease: only push-main
   takes it, and only before its catch-up. The lease can never move into the pre-push hook (section 4, point 6).
8. The exception to Brad's 2026-09-12 ruling is named in W6.1's own landing commit, and in the CLAUDE.md paragraph in
   the same commit: "The one lock held across gate legs is the chain lease, taken only by chain-touching push-main
   pushes, accepted by Brad on 2026-09-23 (D8), live without a shadow period. `-ChainLease off` is the rollback."
9. **READY TO GO, proved before the landing commit** (Brad's condition for going live directly). All of these, in the
   commit message with their outputs:
   - every fixture below passes, and push-main `-SelfTest` exits 0 with its verdict line;
   - `-VerifyDeclared` passes for push-main's `# gate-inputs:` line, which now names `lib\chain-lease.ps1`,
     `lib\gate-slots.ps1` and `lib\mutex-hold.ps1`;
   - mutants M12 and M14 (section 8) each turn their named case red, run from a temp mirror with the originals
     md5-identical afterwards;
   - **the two-push drill**, in a sandbox (a temp bare remote and two clones, private lease prefix and queue root,
     stubbed legs that write a marker and a rehearsal stub that records the remote sha it judged): two chain-touching
     push-main runs start together. Assert that the second WAITED (its `lease_wait_ms` is at least the first's hold
     minus a hang guard, read from the rows), that each run's rehearsal judged the sha it then landed on (the stub's
     recorded sha equals the parent of its landed commit), and that both land with `rounds` at most 2. Run it 3 times;
     all 3 must pass. A drill that passes by timing alone is not a pass: the wait is proved by the second run's ticket
     having been behind the first's (the queue probe), not by a wall clock;
   - `.claude/rules/ops-and-gates.md`'s lock order and CLAUDE.md's paragraph land in the same commit.
10. **The watch that replaces the shadow week.** W0.3's `-Cost` prints every `lease=timeout` and `lease=error` row, and
   W3.4's twice-daily task pages on any since its last run: a timeout means a wedged or frozen holder, which is the one
   way a live lease hurts. B6 is read 14 days after the landing.
Fixtures (every lease in them is a private-prefix instance):
- MUST FIRE: with the lease held from another process (`lib/mutex-hold.ps1`), a live chain push waits, then proceeds
  once it is released.
- MUST FIRE: a `-NoRehearsal` chain-touching push opens the lease.
- MUST NOT FIRE: a non-chain push never opens the lease.
- MUST FIRE, the mechanism: a probe from another process sees the lease held at the moment the push holds the push
  lock.
- MUST FIRE: the timed-out branch, driven by a holder that never releases and a lowered bound, proceeds with
  `lease=timeout` and `lease_holder` naming the holder.
- MUST FIRE: with `TC_CHAIN_LEASE_SELFTEST` set, a call with the production prefix throws.
- CLEAN TWIN: a lease that cannot be created degrades to no lease, records `lease=error`, and the push proceeds.
- CLEAN TWIN: an uncontended live push holds the lease until after the push lock (a probe from another process sees it
  held then), and records `lease=held`, a numeric `lease_hold_ms` and a `lease_wait_ms` of 0.
- CLEAN TWIN, the rollback: `-ChainLease off` never opens the lease (a probe from another process sees it free
  throughout), records `lease=off`, and the push lands exactly as before W6.1.
Done when: step 9's READY list is in the landing commit, the landing's own ledger row carries `lease=held` (or `off`
with the reason), and B6 is read 14 days after the landing.

### Row 7: the process text

**W7.1 The rules say how a lane lands.**
Files: `CLAUDE.md` ("ONE PUSH AT A TIME" paragraph), `.claude/rules/ops-and-gates.md`.
1. CLAUDE.md gains two sentences: push-main rebases before it gates and re-checks what moved before it takes the lock,
   and a conflict is refused in seconds with the files named.
2. ops-and-gates.md gains one bullet, "A LANE WRITES ONLY WHAT IT OWNS": backlog progress as an inbox UPDATE, a re-read
   as a ledger row, and a ready-for-brad item as its own file, with the measured reason (20 of 22 conflict rows were
   shared append-shaped or derived files, and 14 of them were the backlog).
3. Memory index lines about landing a push are updated by the main session, never by a worktree agent.
Done when: both files land. There is no fixture: prose.

## 7. Order

Take one row at a time, and land and verify each item before the next.

| Row | Items, in order | Why here |
|---|---|---|
| 0 | W0.1, W0.2, W0.3, W0.4, W0.5; then the soak (W0.3 step 7) | every later bar needs rows carrying these fields, and W0.3's first run is the baseline |
| 1 | W1.1, W1.2 | no ruling needed; W1.1 removes up to 792 s of in-lock work per rehearsal refusal; W1.2 closes a fail-open before any merge change touches baselines |
| 2 | W2.1, then W2.2, then W2.3 (D1 after its step 0 measurement; D11) | the largest lever (section 2.3, A1); W2.2 needs W2.1's rebase; W2.3 changes W2.1's runner seam |
| 3 | W3.1 (D2), then W3.2, then W3.3 (D10), then W3.4 (D2) | the hottest file; W3.2's warning must name a command that already exists; W3.4 needs W3.1's lock and W0.3's `-Due` |
| 4 | W4.1 (D4), then W4.2 (D5) | re-read collisions and fan-out |
| 5 | W5.1 only if D7 says build | the cache flush, once its cost is measured |
| 6 | W6.0, then W6.1 live (D8, ruled 2026-09-23: no shadow period; W6.1 step 9's READY list first) | its design depends on W2.2's catch-up, on W0.5's set and on W0.3's chain-push numbers |
| 7 | W7.1 | the process text, once the behaviour it describes has landed |

Rows 3 and 4 land inside Row 2's measurement windows. The bars keep them apart by class (section 8), so a Row 2 bar is
never met by removing backlog or re-read conflicts.

**How the build runs (2026-09-23).** Nothing in Rows 3 and 4 depends on Row 2, so they are built beside Rows 0 and 1
rather than after the soak. **Wave 1**: W0.1, W0.2 then W1.1, W0.3, W0.4, W0.5, W1.2 then W4.1 (without its push-main
step 7) then W4.2, W3.1, and W3.3. **Wave 2**, after W0.3 step 7's soak: W2.1, W2.2, W2.3, W3.2, W4.1 step 7, W3.4, W6.0,
W6.1, then W7.1. Each wave's lanes BUILD in parallel, each in its own linked worktree and files no other lane touches,
and LAND ONE AT A TIME: no lane pushes while another of this build is landing, so the build's own lanes cannot collide
with each other, which is the pattern that produced 20 of the 22 conflict rows (section 2.2). A lane that owes a re-read
records it after rebasing onto the main it will land on, as a ledger row once W4.1 has landed.

## 8. Bars, written now

Every bar is measured by `ops/probe-push-convergence.ps1 -Cost` (W0.3), cited by its blob, over push ledger rows after
the named item lands, from UPDATED copies only (`pm_blob`), with `excluded N rows`, `older-copy rows excluded N` and the
landings per active hour printed. Each value is the first plausible one, not the survivor of a sweep. **A number that
moved is not a number that improved.** 20 of 22 conflict rows came from one parallel run on two busy days, so a quiet
fortnight would show improvement for free. So every bar below carries a minimum N and a stratum, and every zero-count bar
prints the probability of seeing zero under the OLD rate, and gives a verdict only when that probability is 5% or less.
Under its minimum N a bar is reported with its N and gives no verdict. Rows 3 and 4 remove backlog and re-read conflicts,
so a Row 2 bar that counts conflicts counts only conflict rows whose files are outside the `backlog-index` and `reread`
classes.

| # | Metric | Stratum, minimum N | Baseline (source) | Bar | Item |
|---|---|---|---|---|---|
| B1 | (a) seconds from push-main start to a `phase=preflight` conflict refusal; (b) catch-up or in-lock conflict rows whose colliding commit was on main BEFORE the pre-flight fetch (W0.3's ancestry, rows without `degraded=fetch`) | (a) at least 5 preflight refusals; (b) at least 10 conflict rows of any phase | 13.9 min median, max 38.0, 19 rows with a run id (census, cost); 10 of 21 attributed conflicts collided only with commits on main at start (SCRATCH) | (a) median at most 60 s; (b) 0 such rows. (b) tests the mechanism directly: W2.1 is deterministic, so any such row is a defect. Reported beside it, not judged: the share refused at each phase by class, expected near 50% preflight with W2.1 alone and higher once Row 3 removes the backlog's after-start collisions | W2.1 |
| B2 | in-lock refusals with `reject_class` `rehearsal`, per push-main row that took the lock | at least 50 qualifying rows; judged in the stratum of hours with fewer than 8 landings; hours with 8 or more are reported and belong to B6 | 4 in 28 lock-taken rows, UTC 2026-09-23T00:00Z to 10:32Z (reviser, `rvs_b2.py`; one row sits in `pushes-2026-09-22.jsonl`); a 5th at 11:36:24Z | at most 1 per 50. Expected (model): about 1 per 300 at today's 4.3 landings an hour, and about 3 per 50 at the 09-19 rate of 16 before W6.1 is live, which is why the busy stratum is not judged here. No verdict while any push-rejected row in the window has `reject_class` `unknown` | W2.2 |
| B2b | `lock_held_ms` on rehearsal-refused rows | at least 3 rows | full test-auditors ran 792 s and 709 s inside the lock before two such refusals (cost) | median at most 60 s | W1.1 |
| B3 | `lock_held_ms` | stratum A: rows where main moved during the legs (a catch-up or in-lock rebase ran); stratum B: rows where it did not; at least 30 rows in A | the soak's direct timer (W0.3 step 7); for orientation the derived remainder read rebased 128 s (n=52), not rebased 25 s (n=33) | A: median at most 45 s and p90 at most 180 s. B: median no more than 10 s above its soak baseline | W2.2 |
| B4 | (a) landings with `backlog_direct` over 0; (b) conflict rows whose `conflict_files` include `design/BACKLOG-course-findings.md` | (a) at least 50 landings; (b) at least 60 push-main rows from parallel runs | (a) 142 of 299 landings TOUCHED the file (cost; a touch, not only a direct edit); (b) 14 of 22 conflict rows (13 computed, 1 from a transcript); about 5% of rows on 09-18 and 09-19 (14 in 276 to 278) | (a) at most 10% of landings; (b) 0, where P(0 in 60 rows at 5%) = 0.95^60 = 4.6% | W3.1, W3.2 |
| B5 | (a) re-reads written as ledger rows, of all re-reads added (ledger rows plus new `Re-read at` doc lines, `reread_doc_lines`); (b) conflict rows in class `reread` | (a) at least 10 re-reads | (a) 0 today (no ledger); (b) 2 of 365 rows (0.55%, census) | (a) at least 90% ledger rows. (b) is reported with P(0 under the old rate) and gives no verdict: at 0.55% a zero in 200 rows has a 33% chance with no fix at all, and 5% needs about 545 rows | W4.1 |
| B6 | push-main rows per landed chain-touching CHANGE (grouped by `change_id`), excluding gate-red and not-ready | at least 10 chain-touching changes from updated copies in live lease mode | W0.3's first run over rows since `a66ef0e94`; the housekeeping lane took 3 attempts for 1 landing | at most 1.2. Printed beside it: chain landings that did not hold the lease (plain push, older copy, shadow, timeout); no verdict when they exceed 20% of chain landings | W6.1 live |
| B7 | pre-lock wall on chain-touching rows where test-auditors RAN (not reused) and the rehearsal ran over 60 s | at least 5 such rows after, and at least 3 before (the soak) | housekeeping serial legs summed to 2,167, 1,816 and 1,907 s (cost) | post-change median at most the pre-change medians' rg + max(ta, rh) + 60 s, taken from the pre-change rows, not from the same run's legs; and 0 test-auditors timeouts (`ta_rc` 124 or 3) in overlapped runs | W2.3 |
| B8 | wasted gate minutes per landing: (row time minus run start) over `refused-rebase-conflict` rows outside the `backlog-index` and `reread` classes and over `push-rejected` rows, PLUS `catchup_sec` over every push-main row, divided by ledger landings in the same window | judged over BUSY hours (at least 6 push-main rows); at least 50 landings in them | 328 min over 24 rows with a run id, against 154 ledger landings after the first run-bearing row (09-18T20:33:58Z): about 2.1 min per landing (measurement reviewer); W0.3's first run recomputes it with the class filter and the busy stratum | at most one third of W0.3's recomputed baseline | Row 2 |
| B9 | seconds from push-main start to a landed row, generic and chain-touching separately | at least 30 generic and 5 chain-touching landings | generic median 2.5 min over 152 run-bearing landings (reviser; 153 by the measurement reviewer); the soak recomputes both | generic: median at most baseline + 60 s (the pre-flight's fetch and rebase) and p90 at most baseline p90. Chain-touching: median at most 45 min | Row 2 |
| B10 | first-attempt-to-landing per change, grouped by (checkout, `change_id`), generic and chain-touching separately | at least 30 generic and 5 chain-touching changes | W0.3's first run; the housekeeping change took 1 h 52 min over 3 attempts | chain-touching: median at most 45 min (one set of legs, about 36 min serial, plus the lock); generic: median at most baseline + 60 s | Row 2, W6.1 |
| B11 | full test-auditors runs INSIDE the lock (`hook_ta` `ran`), per lock-taken row | at least 50 lock-taken rows | 10 of 84 rebased hooks over 7 days (cost) | not above the pre-W2.3 rate measured from the soak and Row 2 rows | W2.3 |

**Read-outs have an exit code.** Each item's landing commit fills its bars' landing commit and read-out date into W0.3's
table; `-Due` exits 2 for a bar past its date with no result line in section 13, and W3.4's task runs it twice a day and
pages. Until W3.4 lands, each item's landing commit also files a backlog-inbox finding naming its bars and dates.

**Fixture and mutation bars.** Every case listed in section 6 passes, each suite prints its verdict line with exit 0,
and every literal-case suite's count equals the number of cases in its file. Mutants run from a temp mirror, with the
originals md5-identical afterwards, one at a time:

| Mutant | Must turn red |
|---|---|
| M1: remove the `Invoke-TcPreflightRebase` call | the W2.1 conflict MUST FIRE |
| M2: move the rehearsal block back after run-gates | the W1.1 MUST FIRE |
| M3: `$CatchUpRounds` from 3 to 4 | the W2.2 at-the-bar case |
| M4: the ledger match changed from full equality to a prefix | the W4.1 prefix MUST NOT FIRE |
| M5: restore `$null -eq $base` writing a baseline | the W1.2 MUST FIRE |
| M6: run the rehearsal after test-auditors instead of beside it | the W2.3 overlap MUST FIRE |
| M7 (if W5.1 is built): add the static list file to `$runnerFiles` | the W5.1 MUST NOT FIRE |
| M8: remove the in-lock `git rebase --abort` | the W2.1 in-lock conflict-and-abort case through `-BeforeLock` |
| M9: settle two different UPDATE tag sets by file order instead of quarantining | the W3.1 conflicting-updates MUST FIRE |
| M10: end a re-read paragraph only at a blank line | the W4.2 "Harness: directly after a re-read line" MUST FIRE |
| M11: trigger on the set at `lsha` only | the W6.0 deletion MUST FIRE |
| M12: release the lease before the push lock instead of after it | the W6.1 MUST FIRE "a probe from another process sees the lease held at the moment the push holds the push lock" |
| M14: `-ChainLease off` still opens the lease | the W6.1 rollback CLEAN TWIN |
| M13: the RejectLine classifier back to the old regex | the W0.1 in-lock run-gates red MUST FIRE |

A mutant that survives means the fixture is insensitive, and the item is not done.

## 9. What this plan must not do

- **Never weaken or bypass a gate.** None of the following is allowed:
  - `--no-verify`, or `-NoRehearsal` as a habit;
  - skipping the in-lock hook because the outside gate passed;
  - a docs-only fast path that skips static gates or the unkeyed self-tests;
  - dropping boards or `lib/*.ps1` from the test-auditors key;
  - dropping manifest files from the rehearsal key;
  - dropping `ops/run-gates.ps1` from `$runnerFiles`;
  - accepting either parent's blob for a harness that was merged.
- **Never auto-resolve a genuine code conflict.** push-main refuses and names the files and any same-subject sibling. It
  never passes `-X ours`, `-X theirs` or a merge driver for code, and no driver is added for any `.ps1`, `.py`, `.js`
  or `.json` file.
- **Never settle a conflicting status by order.** Two updates that give one backlog item different states are
  quarantined for a person, never resolved by file name, lane name or time.
- **Never let a regenerated file carry content nobody verified.**
  - push-main never regenerates a baseline after a rebase: not the mustfire census, `match-baseline.json`, the golden
    `MANIFEST.json`, `hunt_daemon_selftest.names.txt`, nor any `*-baseline.json`.
  - A ratchet mark moves only through its own `-Tighten` or `-Accept`, run by a person; over a missing or unreadable
    baseline only `-Accept` writes.
  - Nothing writes a re-read row or line on anyone's behalf. `add-reread.ps1` writes only the note its caller typed,
    and the audit prints no ready-made command.
  - No JSON ruling registry (`known-wrong.json`, `commodities.json`) is merged by anything but a person.
- **No `merge=union` on any document as a whole.** It interleaves prose edits, resurrects an edited line and undoes a
  deletion. Union goes on `design/reread-ledger.tsv` only, and only with its append-only check in run-gates.
- **No gate leg inside the push lock** beyond what the hook already runs there. **No lock held across a gate run, with
  two named exceptions:** the per-checkout guard (W2.1), which never waits and so serialises nothing across checkouts,
  and the chain lease (W6.1), which serialises chain-touching push-main pushes across their catch-up legs, accepted by
  Brad by name on 2026-09-23 (D8). Holding one lock across every push's whole gate would cap the box at about
  1.7 landings an hour at T = 35 min.
- **No test opens a production lock name**: the push lock, the chain lease or the per-checkout guard.
- **No unbounded retry loop.** The catch-up stops at 3 rounds and falls back to today's path.
- **No new gate that is red on day one.** The ledger check starts on an empty ledger, the list-file validator starts on
  a sorted file, and W3.2 and W4.1's counts only warn.
- **Do not install hooks from a feature worktree** (section 5).
- **Do not "fix" throughput with more gate slots, lock fairness or a faster ref update.** None is a lever today (slot
  wait median 0 s over 164 runs, lock wait 2.3% to 3.1%, ref update about 2 s).
- **Do not count test-prepush sandbox rows, or rows from checkouts older than the item,** in any figure here.

## 10. Deliberately not done

| Proposal | Disposition |
|---|---|
| Per-change (patch-id) re-qualification of a moved harness | NOT BUILT; D6 says why |
| Narrowing the rehearsal key to the push's own chain scripts | NOT BUILT; D9. W6.1 fixes the same symptom without accepting an unrehearsed combination |
| An arithmetic merge driver for `ops/mustfire-census-baseline.json` | NOT BUILT; D12. It conflicted 0 of 2 times today, and it needs a `.git/config` entry |
| A pre-check of `audit-conclusion-currency -ReportOnly` before the legs | NOT BUILT. After W2.1, run-gates judges the rebased tree first and reports it within its own median 60 to 96 s, before test-auditors or the rehearsal start |
| A cap on parallel lanes per orchestrator | NOT BUILT. The collisions were on shared files that Row 3 removes; a cap would cut throughput for a defect that is structural |
| The prompt-backup ambient-drift refusal (1 of 9 push-rejected) | NOT IN SCOPE. Live prompts outside git drift on their own clock; procedure P3 of the brain-consults plan covers edits |
| Keying test-auditors' boards by content instead of mtime | DEFERRED to D13, on W0.4's split |
| Hub registration by header discovery instead of a list | DEFERRED. Revisit only if W0.3 shows the sorted list, or run-gates itself, still conflicting |
| Retro-filling the 16 unreconstructable conflicts | NOT DONE. W0.1 records the next ones at the moment they fail |
| A cooperative cancel of the rehearsal child when test-auditors goes red | NOT BUILT. It needs a stop file the rehearsal polls, which is a chain change with its own rehearsal; revisit if W0.3 shows test-auditors-red chain pushes waiting often |
| Taking the chain lease inside the pre-push hook, so plain `git push` respects it | NEVER. The hook runs under the push lock, and an outer lock taken there inverts the declared order (section 4, point 6) |
| A probe process holding the PRODUCTION lease name during push-main's self-test, to prove no case opens it | NOT DONE. While it held the name, every real chain push on the box would wait on a test. The self-test's refusal of the production prefix (W6.1 step 2) proves the same thing in process |
| A total-time bound on the lease wait | NOT BUILT. A waiter that leaves a moving queue lands unleased and voids the holder; the no-movement bound (W6.1 step 5) ends only a wedged queue |

## 11. Blast radius and rollback

- **push-main (W0.1, W2.1-W2.3, W3.2, W4.1 step 7, W6.1)** changes how every push-main push on the box runs. Each
  checkout runs its OWN copy, so a change reaches a checkout only when it rebases, and a plain `git push` is always
  available and fully gated by the hook. Every new step degrades to today's path when it cannot run: a fetch failure, a
  could-not-rebase, the loop running out of rounds, a leg that could not evaluate, a guard or lease that is errored or
  timed out. Only a real conflict, a real red, or a second push-main in the same checkout refuses. Rollback is a
  revert, landed by a plain `git push` if push-main itself is broken.
- **The pre-push hook (W1.1)** is a box-wide copy. A wrong reorder affects every push on the box until it is
  re-installed. Rollback: revert, then re-install from a clean worktree at origin/main. The old text is in git.
- **The rehearsal script (W0.5, W6.0)** is itself in the chain manifest: each change needs its own rehearsal and voids
  every in-flight chain push's rehearsal once. W6.0 rehearses more pushes than today. Rollback is a revert, which is
  itself a chain-touching push.
- **conclusion-currency (W1.2)** gets stricter. A damaged baseline now stops every push with a named FAIL, which is the
  intent. Rollback is a revert.
- **The backlog merge (W3.1, W3.4)** writes only when a person or the scheduled task runs it, under a ledger lock, and
  quarantine keeps the file green for its gate. An UPDATE that lands on the wrong item is a readable diff in one commit;
  revert that commit. The task can be disabled with `Disable-ScheduledTask` while a fix lands.
- **The re-read ledger (W4.1)** puts a union attribute on one path. The ledger adds qualification only for full-blob,
  path-bound rows, so at worst a CURRENT is missed, and a false CURRENT would need a row with the exact current blob.
  Rollback: revert, and the doc lines still work.
- **Enrolment (W4.2)** is proved identical on the real tree before landing. Rollback is a revert.
- **The static list (W5.1), if built,** is the riskiest single edit, because a bug could stop a static gate running or
  orphan the audits it registers. It is guarded by the reader census, the every-field landing check, the dispatched-name
  comparison, the fail-closed validator and the printed count. Rollback is a revert.
- **The chain lease (W6.1)** is a new lock, live from its first commit (D8). It can only add wait to chain-touching
  pushes, never a refusal, and at peak that wait is a queue. Rollback: `-ChainLease off` on one push, or a one-line
  commit flipping the default to `off`, then a revert.
- **Nothing here** publishes a page, changes a price, writes a board or graph.db, or touches the ~07:00 bot.

## 12. Decisions only Brad can make

**RULED 2026-09-23.** Brad chose "Build all 8 rows (Recommended)", which makes every recommendation in the table the
ruling: D1 on W2.3's step 0 measurement, D2 yes (he answered "Yes to both" to the inbox route and the schedule), D3 yes
(the refusal, from a literal cutoff one week after W3.1 and W4.1 land), D4 yes, D5 yes, D6 no, D7 deferred to W0.3's
measurement, D9 no, D10 yes, D11 yes, D12 no, D13 on W0.4's split. **D8 departs from its recommendation**: live from the
first commit with no shadow period, in his words *"I dont want to shadow. i want to push live as long as its a
thoughtful fix and ready to go"*. W6.1 steps 4, 9 and 10 carry what that means. The amendment of the same day (section 15, adopted by Brad) adds D11a and D14 to D18, all ruled yes as recommended (15.7).

| # | Decision | Recommendation | Blocks |
|---|---|---|---|
| D1 | Run the chain rehearsal at the same time as test-auditors. Load: the rehearsal takes one of its own 6 rehearsal slots (a pool separate from the 24 gate slots) and about 3.52 GB at peak (`f072577f8`); test-auditors takes NO slot, so its concurrent load is metered by nothing but its 1200 s kill, and a timeout sends the full suite into the push lock. Cost: a chain push whose test-auditors goes red waits for its rehearsal (up to about 14 minutes plus a slot wait) before refusing | yes, only if W2.3's step 0 measurement meets its bar (0 timeouts over 3 overlapped runs; overlapped test-auditors at most 1.25 times its alone wall). Gain: about 700 to 950 s per chain-touching push that runs BOTH legs (3 attempts of one lane; test-auditors ran rather than reused in 11 rows over 7 days) | W2.3 |
| D2 | Backlog progress on an EXISTING item goes through the inbox (your 2026-09-08 ruling extended from new findings to updates), and the merge also runs on a schedule: a new scheduled task at 11:00 and 17:00, in its own clean worktree through push-main, that pages on a quarantine, on a refused push and on an UPDATE older than 24 hours (W3.4) | yes to both. The schedule matters because "the orchestrator will merge it" is an intention with no exit code. Two conflicting updates are quarantined for you, never settled by order. Pending updates show in `-Summary` meanwhile | W3.1, W3.4 |
| D3 | After 7 days of W3.2 and W4.1 counts, refuse (from a literal cutoff date) a push whose commits edit the backlog directly or add a re-read as a doc line. The refusal keys on the `Backlog-Merged-From:` trailer the merge prints, not on a file deletion a lane could fake, and a person can pass it with a logged `-AllowDirectEdit "<reason>"` | yes, from a cutoff one week after W3.1 and W4.1 land: a warning alone has not held any rule here | a follow-on to W3.2 and W4.1 |
| D4 | A dedicated re-read ledger file with `merge=union` in `.gitattributes`, naming only that file | yes, only if W4.1's `-X theirs` fixture passes (the correctness reviewer's scratch run passed) | W4.1 |
| D5 | Re-read lines stop adding harnesses, after today's 5 prose-only pairs are frozen as explicit lines | yes: nothing currently watched is dropped, and the self-feeding growth stops (`51ef26dc0` edited two re-read lines only because a rebase moved the blob they cited) | W4.2 |
| D6 | Re-qualify a moved harness per CHANGE (patch-id rows, rebase-stable) instead of per CONTENT (blob) | no: the merged harness would never be read whole, and two harmless changes are not proven harmless together. W2.1 moves the second lander's re-read to minute 2 instead | none |
| D7 | Move run-gates' static gate lists, their names and their rationale into a sorted data file and a notes file, so a registration edit stops flushing every self-test cache | DEFER, then decide on 7 days of W0.1's run-gates reuse fields: build only if W0.3 shows flushes after a run-gates.ps1 landing costing more than 30 gate-minutes a day on busy days (first plausible bar, not swept). For it: 8 of 12 run-gates commits since 09-16 changed only entries and their comments. Against it: four tracked readers of its source text must change in one commit, and the cost of a flush has never been measured | W5.1 |
| D8 | A chain lease, a new outermost lock taken only by chain-touching push-main pushes, 3 days in shadow and then live. It is a lock held across gate legs (the catch-up's run-gates, test-auditors and at most one re-rehearsal), an exception to your 2026-09-12 ruling. Its ceiling is about 12 chain pushes an hour when no holder re-rehearses and 2.4 to 3.5 when every one does; at the 09-19 peak (about 4.2 an hour offered) it queues. It protects only against updated push-main pushes (G7) | shadow: yes. Live: only if the 3 shadow days show (a) at least 2 contended pushes (otherwise it buys nothing yet and stays in shadow) and (b) the busiest shadow hour's chain pushes at or below 60 divided by the median shadow hold in minutes; if (b) fails you decide with that number in hand. It is the only change here that removes the chain push's livelock at busy hours (a rehearsal voided in 48.4% of 35-minute windows at 4.3 landings an hour, 91.5% at 16) | W6.1 live |
| D9 | Narrow the rehearsal key to the push's own chain scripts | no: it would land combinations nobody rehearsed; D8 fixes the symptom instead | none |
| D10 | The ready-for-brad README becomes an explainer, and each item carries its own "What Brad does" block (in its own file, or a new sibling file where the item file is a skill or generated) | yes: 5 of 22 conflict rows, and it is a move of existing text | W3.3 |
| D11 | Catch-up stops at 3 rounds, and then pushes as today (the hook gates the rest inside the lock) rather than refusing | yes: degrade to the day before, never a new refusal | W2.2 |
| D12 | A custom arithmetic merge driver for the mustfire baseline | no: 0 conflicts today, and it would need a shared `.git/config` entry | none |
| D13 | Key test-auditors' boards by content hash instead of length and mtime | decide on W0.4's 7-day split; yes only if mtime moves are a real share of the full runs. Known cost already paid by W0.4: one full test-auditors run per checkout for the schema 2 record, plus the board-hashing time its commit measures | none |

## 13. Results against the bars

Empty until the items run. W0.3's first `-Cost` and `-History` runs go here first, as the committed baseline, with the
script's blob. Each bar's result is one line, `B<n>: result <verdict> over <N> (<window>, W0.3 blob <id>)`, which is
what `-Due` looks for.

## 14. Review dispositions

Every blocker and major issue from the three reviews was applied, and every minor one below was applied unless this
section says otherwise. These are the issues NOT applied exactly as the review wrote them, and why.

- **Correctness, W5.1 blocker: "Or weigh dropping W5.1".** Not dropped and not built yet: W5.1 now carries the reader
  census and every fix the review named, and D7 changes from "yes" to DEFER on a measured flush cost. The reviser's
  recount (8 of 12 run-gates commits since 09-16 changed only entries and their comments) is the case for keeping it;
  the unmeasured cost is the case for waiting.
- **Correctness, W6.1: "Say whether the lease wait is total-bounded; if so, implement it as a total".** It is NOT
  total-bounded, on purpose (W6.1 step 5): a waiter that leaves a moving queue lands unleased and voids the holder, which
  is the failure the lease exists to stop. The bound is raised from 1800 s to 3600 s of no movement, above the longest
  hold the design allows, and the waiter prints its position every 5 minutes.
- **Safety, W6.1: "Assert, with a probe from another process, that no test case opens the production lease name".**
  Replaced by an in-process refusal of the production prefix under `TC_CHAIN_LEASE_SELFTEST`, with a MUST FIRE. A probe
  holding the production name would make every real chain push on the box wait on a test (section 10).
- **Safety, W2.1/W2.2 minor: "Take a per-checkout push-main mutex before pre-flight".** Applied as a ZERO-wait guard
  that refuses a second push-main in the same checkout, rather than a waiting mutex. A second run in one checkout is a
  retry or a mistake, and waiting would only make it find nothing to push after the first lands; a zero-wait guard also
  adds no wait-for edge to the lock order.
- **Measurement, B1: "state the value expected with W2.1 alone (about 50%) and with Rows 3 and 4 (near 0)".** The share
  is now REPORTED with that expectation, and B1's judged half is a mechanism bar instead: 0 catch-up or in-lock conflicts
  whose collider predates the pre-flight fetch. The share depends on the lane mix and on Rows 3 and 4; the mechanism bar
  does not, and W2.1 is deterministic, so it has power at small N.
- **Measurement, order attribution: "Either hold Row 3 until Row 2's windows close, or split B1 and B8 by class".**
  Split by class; Row 3 is not held, so the backlog relief is not delayed by two weeks.
- **Measurement, B5 and B8 activity windows.** Applied to B8 (busy hours). B5 is restated as an adoption bar, because its
  zero-count half has no power in 14 days at a 0.55% base rate (5% needs about 545 rows), which the table now says.
- **Correctness, W0.1 RejectLine: "Or have the hook print one fixed PRE-PUSH-REFUSED line".** Both: W0.1 matches the
  hook's real wording, so rows from older hook copies classify, and W1.1 adds the fixed line, which the parser prefers.
- **Safety, W4.2: "unless it is part of the same re-read paragraph (up to the next blank line)" together with "a
  Harness: line directly after a re-read line still enrols".** As written these contradict when there is no blank line
  between the two. Resolved by letting a line that BEGINS with a harness label end a re-read paragraph (W4.2 step 3), so
  both cases hold.
- **Safety, W3.1/D2 minor: "Run -ValidateFile over every inbox file a push adds ... in push-main's pre-flight or in a
  static gate".** Applied in the pre-flight as a WARNING (W3.2 step 3), not a refusal and not a new static gate: a
  refusal there is D3's to decide, and a new static gate edits run-gates.ps1, which flushes every key.
- **Safety, W4.1 minor: "records the harness commit range it says was read".** Applied as a `prior_blob` field, so the
  row has seven fields rather than six; the audit's format check and the fixtures use seven.
- **Measurement, MM10: "Extend W0.3 with a reflog-plus-git section, or mark those bars' baselines as scratch".** Both:
  `-History` re-derives what reflog and git allow, and the pre-W0.1 conflict attribution, which needed transcripts, stays
  marked SCRATCH wherever it is used.
- **Figures that differ between a reviewer and the reviser**, both printed where used: landings to 10:32Z, 152 (reviser)
  against 153 (measurement reviewer); today's landings, 17 on the UTC day with median 2.9 min (reviser) against 15 on a
  local-day window with median 3.8 min (measurement reviewer). The difference is the window, and both are named.

## 15. Amendment 2026-09-23: the landed sibling fix, and the gaps a skeptic found

**Status: PROPOSED 2026-09-23 about 15:00Z by the synthesis stage, not yet ruled.** Brad asked the same day: *"Pushes
are taking way too long. I see multiple attempts for one push. I hope this plan we are doing resolves this for
good."* This section answers that against the plan as ruled plus `5841e96b1`, a push-main change a sibling session
landed at 13:41:38Z without citing this plan. It was written from three read-only investigators (causes, sibling,
residual) and two skeptics (correctness, measurement), read against origin/main `2c7a9fe50` to `ea3ec081f`. **Every
figure here that is not from a committed harness is SCRATCH**, with its source named. The scratch lives under
`%TEMP%\pushgood-causes\` (`attempts.jsonl`, one row per push-main row, 60 rows, 2026-09-21T00:00Z to 14:17:54Z),
`%TEMP%\pushgood-sibling\`, `%TEMP%\pushgood-residual\`, `%TEMP%\pushgood-skeptic\`, `%TEMP%\pushgood-skmeas\` and
`%TEMP%\pushgood-synth\`. W0.3's probe was on origin/main by 14:56Z (blob `571be839`), but its chain and phase
figures need W0.1's fields, so none of the numbers below could come from it yet. An item marked **NEEDS A RULING** waits for Brad.
Every other item here strengthens a check or adds an instrument and needs none.

**The short answer.** As ruled, plus `5841e96b1`: **no, not for good.** Of today's 22 refused or rejected push-main
attempts (349.2 min, 13 changes; section 15.3), the two together remove 7 outright (137.5 min), turn 2 into automatic
re-rounds, and leave 13 standing. 3 of those 13 are correct refusals of a change's own red, which no plan should
remove. The other 10 are causes this plan never targeted (dirty trees, reds over state outside git, one header-line
conflict). Two more routes to a second attempt sit outside the push-main ledger altogether (main-checkout plain
pushes, and plain-push chain landings that ignore the lease), and B6 as landed counts rows, so it cannot see most of
this. Row 8 and the re-scoped items below target each of those. With them built, the answer becomes YES WITH
NAMED GAPS, and 15.8 names the gaps.

### 15.0 Knowledge consulted (for this amendment)

Store search, `search.py --multi` with four probes ("dirty working tree during push refused not ready", "plain push
from main checkout cannot lock ref rejected", "gate red from state outside git ambient", "single writer id allocation
lock per repository"), exit 0, 8 hits, 3 used:
- `reliability-craft/applies-here.md`, "The 07:00 bot, the shared index ...": the bot's push path *"runs `git -c
  rebase.autoStash=true rebase -X theirs origin/main`, up to four times, and autoStash restores CONTENT and not the
  index"*. Used for W8.2: a main-checkout landing must not leave pre-rebase copies on local main for that `-X theirs`
  replay to find.
- `claude-code-craft/applies-here.md`, "A worktree is not the main tree, and main moves while you work": the gate
  family works from a seeded linked worktree (`git worktree add --detach ...` then `seed-worktree.ps1 -Target`). Used
  for W8.2's throwaway worktree.
- `course/inbox/README.md`, "Why it exists": *"Four shared files had every lane appending to them with no lock and no
  allocator"*. Used for W3.4a: one allocator, not one lock per checkout.

From the brief and the loaded rules:
- `CLAUDE.md`, "A SIBLING MAY ALREADY HOLD THE FIX": *"the tie is broken by running both over one case list, not by
  whichever session pushes first."* `attempts.jsonl` is that case list (15.3), and 15.2 builds on the sibling's code
  instead of beside it.
- `.claude/rules/ops-and-gates.md`, "EVERY LOCK PATH DEGRADES TO THE DAY BEFORE": the sibling's unlocked fetch refuses
  on failure, which W2.1R turns back into a degrade.
- `.claude/rules/ops-and-gates.md`, "A PUSH IS A COMPARE-AND-SWAP WHOSE CRITICAL SECTION IS THE WHOLE HOOK, so the
  SLOWEST push converges on never landing": still true of every plain push, which is why W8.2 exists.
- `.claude/rules/ops-and-gates.md`, "THE LOCK ORDER IS DECLARED" and "The order covers every BLOCKING WAIT": W8.3's
  lease probe takes zero wait, so it adds no edge.
- `.claude/rules/ops-and-gates.md`, "Do not add a gate that is red on day one" and "A rule in a file is not a block":
  W7.2 warns first, with a dated refusal left to Brad.
- `.claude/rules/measurement.md`, "A matcher that ABSTAINS is scored on what it skipped" and "a number that moved is
  not a number that improved": B6 as landed excludes the classes that are still failing, so it is amended (15.6).
- `concurrency-craft/concurrency-correctness.md` section 5: *"Starvation is NOT excluded ... an unlucky thread can lose
  every race."* Plain pushes still race the whole hook (W8.2), and lease-ignoring chain landings still void a holder
  (W8.3).
- Memory `prepush-test-auditors-judges-against-a-shared-record`: *"judged against a SHARED record other checkouts
  rewrite"*. Used for W8.5.

### 15.1 What landed after the ruling, and what is still on a branch

| Item | On origin/main | Note |
|---|---|---|
| sibling push-main change | `5841e96b1`, landed 13:41:38Z | push-main blob `c63e2a7c`. Its Store line reads *searched "rebase verdict key", nothing applicable*, and it has no Plan line |
| W3.3 | `cd5ae5d85` | |
| W0.5 | `2c3f491de` | |
| W3.1 | `258410c55`, `cc2d28e50` | |
| W0.2 | `ccd64fdc6` | |
| W1.1 | `2a081824b`, `2c7a9fe50` | the common `.git\hooks\pre-push` hashes to origin/main's blob `1edfa22b` (read 14:56Z, file time 14:50Z), so the rehearsal record check now runs first on every push on the box |
| W0.3 | `c1c418fdc`, `ea3ec081f` | probe blob `571be839` |

Built on branches and not landed at 14:56Z: W0.1 on `feat/pd-ledger` (1 commit, 36 behind origin/main), W0.4 on
`feat/pd-ta` (2 commits), and W1.2, W4.1 and W4.2 on `feat/pd-currency` (3 commits). Their hashes are not cited,
because push-main rebases before it pushes.

**Production exposure of `5841e96b1` is too small to judge.** 3 of the 60 case-list rows ran its order, and all 3
landed (82 s, 1,036 s and 262 s; causes). 4 more push-main rows landed between 14:17:55Z and 14:56Z, and 0 were
refused. They carry no `pm_blob`, so which code wrote them is unknown (synth, `since.py`, `lost.py`). **So at most 7
rows, 0 refusals: its effect is UNMEASURED, not zero.** Every counterfactual below is read from its code, not observed.

**Process cause of the double build.** The plan landed at 12:31:35Z (`f33d11829`) and names `ops/push-main.ps1`. The
sibling committed its change to that file 54 minutes later. `git grep -l -F 'ops/push-main.ps1' origin/main --
'design/PLAN-*2026-09-2*.md'` returns exactly this plan (SCRATCH, sibling), and nothing in the process runs that
search. W7.2 closes it.

### 15.2 `5841e96b1` is the base of W2.1 and W2.2, step by step

Line numbers are from origin/main `ops/push-main.ps1` at blob `c63e2a7c`. DONE means the plan's step is met as
written. DONE DIFFERENTLY means the behaviour exists in another shape, and the last column says which shape stands.
The sibling investigator ran the sibling's own `-SelfTest` from a `git archive` export with `TEMP` redirected: exit 0,
38 of 38 ok, 0 FAIL, verdict line `push-main self-test PASS: 38 cases`. Three single mutants each turned exactly their
named case red, and the original was md5-identical afterwards (SCRATCH): in-lock check ignored, 3 reds; cap 3 to 4,
q5 red; pre-flight sync removed, q1 red.

**W2.1 (pre-flight)**

| Step | Status | Where in `5841e96b1` | What stands after this amendment |
|---|---|---|---|
| 1 per-checkout guard | NOT DONE | nothing | W2.1R step 1, as written. It is now more urgent: every round starts by rebasing HEAD outside the lock (round-1 call after :403), so a retry started while the first run is gating rebases under its legs |
| 2 `Invoke-TcPreflightRebase`, called before the seed | DONE DIFFERENTLY | `Invoke-TcSyncToRemote` :292-331, called at the top of every round (:403 onward). The seed runs BEFORE it (:399) | Extend `Invoke-TcSyncToRemote`. The new function is NOT built. The seed moves after the round-1 sync (W2.1R step 6) |
| 3.1 fetch with `--refmap=`, a failure degrades | DONE DIFFERENTLY | a plain `git fetch --quiet <remote> <branch>` (:298) that updates the shared `refs/remotes/origin/main`. A failure REFUSES, exit 3 `blind-fetch-failed` (:299-301), in every phase | Keep the plain fetch and drop `--refmap=` (reason in W2.1R step 2). Retry once on `cannot lock ref`; outside the lock a fetch that still fails degrades |
| 3.2 hand `FETCH_HEAD` to `Get-TcWarmRefLine` | NOT DONE, MOOT | a plain fetch leaves the shared ref current, which `Get-TcWarmRefLine` reads | Dropped |
| 3.3 build the plan, a dirty tree is refused-not-ready | DONE | :312-316 | W8.1 adds the paths and when they appeared |
| 3.4 `-DryRun` never rebases | DONE DIFFERENTLY | `-DryRun` rebases in the round-1 sync and can run up to 3 real rehearsals | W2.1R step 7 |
| 3.5 conflict against could-not-rebase, files, siblings | PARTLY DONE | on any non-zero rebase it aborts and prints git's own text (:320-325). The `rebase --abort` result is discarded (:324). A rebase that could not start is called a conflict | W2.1R steps 3 to 5 |
| 4 refuse with `phase=preflight` | DONE DIFFERENTLY | refused-rebase-conflict with no phase field | W0.1R fills `phase` |
| 5 print and record `preflight_sha` | PARTLY DONE | prints the rebase (:329). Records nothing | W0.1R records it |
| 6 a later red leaves the branch rebased | DONE in behaviour | the header states it for the churn path (:286-288) only | W2.1R step 10, header text |
| 7 in-lock fetch retries once | NOT DONE | | W2.1R step 2 |
| 8 outcome vocabulary | DONE | `$rebasedAny` for a rebase in any phase | none |
| 9 existing cases move; `-BeforeLock` seam | DONE DIFFERENTLY | cases q1 to q5 drive a commit landing during the legs through the existing `-RehearsalRunner` seam. There is no in-lock CONFLICT case, and the suite does not assert its own case count | W2.1R step 9. The `-BeforeLock` seam is NOT built |

**W2.2 (catch-up)**

| Step | Status | Where in `5841e96b1` | What stands |
|---|---|---|---|
| 1 up to `$CatchUpRounds = 3` | DONE DIFFERENTLY | `$script:PmMaxRehearsalRounds = 3` (:290) counts leg sets | Two counters (W2.2R steps 1 and 2) |
| 2.1 fetch after the legs, outside the lock | NOT DONE | origin's move is learnt only by the in-lock sync | W2.2R step 1 |
| 2.2 rebase; a conflict refuses `phase=catchup` | PARTLY DONE | a round-2 or round-3 sync rebases before its legs; no phase | W0.1R and W2.2R |
| 2.3 re-run each leg, reusing its own keys | DONE | every round re-runs the runner and the rehearsal leg | none |
| 2.4 a leg exit 3 degrades | DONE for run-gates and test-auditors (:427-431, left to the hook). A rehearsal 3 refuses as `refused-rehearsal-blind` (:446), as it did before `5841e96b1` | Keep. D11a |
| 3 after round 3, go to the lock | DONE DIFFERENTLY | refuses `refused-rehearsal-churn`, exit 1 (:517-520) | D11a: keep the refusal for the rehearsal leg only |
| 4 record `rounds`, `catchup_sec`, `degraded` | NOT DONE | a round that hands the lock back writes no row (:509-514). `$ledgerWaitMs` holds the last round's wait only (:453). A round-2 or round-3 refusal before the lock writes `state=not-taken` although the lock was taken earlier | W0.1R |
| (not in the plan) in-lock verdict check | ADDED by the sibling | after an in-lock rebase, `-CheckPush` over the ref line git will hand the hook (:482). If the verdict no longer covers the content, the lock is handed back and the push gates and rehearses again outside it (:484-485). It uses the same key, script copy, verdict directory and remote sha as the hook, and reproduced production verdict `90fa60e24508` in 0.8 to 0.9 s, 6 of 6 runs (SCRATCH, sibling) | Keep as the backstop |

### 15.3 The case list: today's 22 refused attempts, and what removes each

UTC 2026-09-23, 00:00Z to 14:17:54Z: 50 push-main rows over 24 checkouts, 28 landed, 22 refused or rejected. The
refused rows cost **349.2 min** of push-main wall time (row time minus run start), across 13 changes. This was derived
three times and agreed each time: causes 349.2, measurement skeptic 349.3, synth `lost.py` 349.2 (exit 0 each; SCRATCH).
Classes are the causes investigator's, each cited per row in `attempts.jsonl`. The measurement skeptic's split
(push-rejected 9, not-ready 7, gate-red 4, conflict 2) reconciles, because row 46 is a push-rejected row whose cause
was a gate.

| Class | Rows / changes / min | Removed by | After the plan as ruled plus `5841e96b1` |
|---|---|---|---|
| rehearsal voided by branch age: every commit that moved the key was on main before the run started | 6 / 6 / 107.0 | `5841e96b1`'s pre-flight rebase (from code) | REMOVED |
| rehearsal voided during the run (rows 42 and 57) | 2 / 2 / 41.8 | `5841e96b1`'s in-lock check turns each into an automatic re-round, about 14 min of rehearsal and never a relaunch. W6.1's lease protects row 57's shape (its voider was a push-main landing). Row 42's voider `855171a1e` was a plain `git push`, which the lease cannot see | AUTOMATED; the time stays |
| not-ready, dirty tree | 7 / 6 / 83.9 | nothing in the plan. `5841e96b1` finds dirt present at the start in seconds, which is still an attempt | STANDING (W8.1, W8.2, W7.1a) |
| rebase conflict, row 40: re-read lines in one MEASURE doc | 1 / 1 / 30.5 | W4.1's ledger | REMOVED once W4.1 lands |
| rebase conflict, row 36: comment-only header lines in `lib/concurrency-probe.ps1` against `15b02198b`, then re-read lines | 1 / 1 / 38.0 | W4.1 takes the re-read part. Nothing takes the header lines | STANDING (left, 15.8) |
| gate red, the change's own | 3 / 3 / 24.7 | nothing should | CORRECT REFUSAL |
| gate red, not the change's own: row 29 gate-leftovers (a self-test rewrote a tracked `grocery/product-urls.json`, fixed at source by `38357202c`); row 46 `audit-prompt-backup` red in the lock over live prompts outside git, 12 s before the mirror commit `091e6520d` landed | 2 / 2 / 23.3 | nothing in the plan (section 10 put prompt-backup NOT IN SCOPE) | STANDING (W8.4; gate-leftovers left, 15.8) |

Both conflicts collided only with commits that landed during the run (0 of 4 colliders were on main at the run's
start), so no pre-flight could have caught either (SCRATCH, causes).

**Tally.** Removed 7 of 22 (137.5 min). Automated 2 (41.8 min, still paid as time). Standing 13 (169.9 min): 3
correct, 10 caused by the system. Over the whole window (60 rows, 2026-09-21 to 14:17:54Z) the dirty-tree class is 10
rows and 101.8 min. By when the dirt appeared: at the start 6 (40.4 min), during the run 1 (16.5 min), unknown 3 (45.0
min). 3 of the 10 (17.9 min) were push-main run from the main checkout, which is always dirty (SCRATCH, causes;
medium confidence on the split).

**Outside the case list, and not visible in any push-main row:**
- **Main-checkout plain pushes lose the compare-and-swap.** 16 push-main rows from the main checkout since 09-16 and
  0 landed: 10 refused-not-ready, 6 refused-gate-red (SCRATCH, correctness skeptic; the measurement skeptic read 18 of
  18 refused over all time). So the main checkout lands only by plain push: 72 of 310 landings in 7 days, 23.2%
  (SCRATCH, residual). Of 82 main-checkout hook-lock rows since 09-16 in which every hook check passed, 11 were
  followed by no origin/main update within 15 s, and 7 of those 11 match git's own `cannot lock ref ... is at <base>`
  line in a transcript (SCRATCH, skeptic `mainland.py`). Example: agent-aaecadb7dfb010d3e at 2026-09-21T11:48:21Z
  printed `pass=453 fail=0`, was rejected, rebased cleanly, and landed on its second push.
- **Chain landings that ignore the lease.** 6 of 17 chain landings since the rehearsal gate (09-22T21:26Z) were plain
  `git push` from linked worktrees, all from lanes of one orchestrator (session ffbacbef, whose briefs said `git push
  origin HEAD:main` until 13:14Z) (SCRATCH, residual; the measurement skeptic read 6 of 18 with the production
  `-ListSet`). Over 7 days it was 31 of 85, 25 of those from the main checkout (a counterfactual over today's manifest
  set). B6 gives no verdict above 20%.
- **Hook refusals of plain pushes leave no row.** Only 32 of 72 origin/main updates in the window came through a
  push-main row (SCRATCH, causes). The hook writes a row only when it takes the lock, after its checks pass.

**Corrections to section 2.2.** (1) The 2 genuine code conflicts are 1. The housekeeping lane's
`grocery/test-flag-verification.ps1` commit and `38357202c` have the same patch-id (`677b6cd8ae38`), so the rebase
skipped it. git actually stopped on the header lines and re-read lines above (SCRATCH, causes, confirmed by the
measurement skeptic). (2) The rehearsal push-rejected rows are 8 of 8 confirmed, not "1 confirmed, 3 by construction".
A read-only replica of `Get-RhManifestSet` reproduced the key of 37 of 37 recorded verdicts, and it reproduced the
hook-log key of all 8 refusals on the post-rebase commit (SCRATCH, causes `rhkey.py`). 6 of the 8 were branch age and
2 were voided during the run. (3) B2's baseline becomes 8 in-lock rehearsal refusals in 46 lock-taking push-main rows
(UTC 09-23 to 14:17:54Z), not 4 in 28.

### 15.4 Re-scoped items: nothing is built twice

**The push-main lane is ONE lane.** `ops/push-main.ps1` is touched by W0.1R, W2.1R (with W8.1), W2.2R, W2.3, W3.2,
W4.1 step 7, W6.1 and W8.2. They land in that order, one lane, each landed and verified before the next starts. Two
sessions editing that file at once is how `5841e96b1` and `feat/pd-ledger` came to conflict in 6 hunks.

**W0.1R W0.1, rebased onto `5841e96b1`.** Files as W0.1. The trial rebase in a scratch clone stopped on
`ops/push-main.ps1` alone, with 6 hunks: 1 in the function block, 3 in the `Invoke-TcPushMain` body and 2 in the
self-test. `lib/push-ledger.ps1` merged cleanly (SCRATCH, sibling; aborted afterwards).
1. Keep both function sets: the sibling's `$script:PmMaxRehearsalRounds`, `Invoke-TcSyncToRemote` and
   `Invoke-TcRehearsalCheck`, and W0.1's helpers.
2. Take `pm_blob` at START, before the round-1 `Invoke-TcSyncToRemote`. That sync can rewrite `ops/push-main.ps1` on
   disk, so a hash taken later names code that is not running.
3. Fill `conflict_files`, `conflict_scope`, `conflict_files_all` and `sibling_same_subject` INSIDE
   `Invoke-TcSyncToRemote`'s rebase-failure branch, before its `rebase --abort`, and return them on its result.
4. `phase`: `preflight` is the round-1 sync. `catchup` is anything before the lock in rounds 2 and 3 (their sync,
   legs and rehearsal). `inlock` is the in-lock sync, `push-rejected` and `refused-rehearsal-churn`. Fill
   `rebase_phases` in order.
5. New fields, added to section 6's schema table as W0.1 fields because the loop they describe has landed:

   | Field | Meaning |
   |---|---|
   | `rounds` | leg sets run |
   | `rehearsals` | the sibling's counter |
   | `rehearsed` | rounds whose rehearsal leg made a NEW verdict (not reused, not "not needed") |
   | `lock_takes` | times the push lock was entered |
   | `lock_wait_ms_total`, `lock_held_ms` | sums over every take (`waitMs` keeps its old meaning, the last take, for old readers) |
   | `inlock_check` | `covered`, `not-covered`, `could-not-decide` or `not-run` |
   | `preflight_sha` | `FETCH_HEAD` at the round-1 sync (moved here from W2.1) |
   | `subjects_sha` | SHA-256 of the Ordinal-sorted, LF-joined commit subjects of `branch_base..HEAD` at start (W0.3b groups on it) |
   | `dirty_paths`, `dirty_since` | W8.1 |
   | `via_worktree` | W8.2 |

6. In the `finally`, skip W0.1's `phase=inlock` fill and the row when `$again`. Take `reject_class` and `hook_ta`
   inside `if (-not $again)`. `leg_sec` is round 1's legs; `catchup_sec` is the legs of rounds 2 and 3.
7. Apply W0.1's `$cloneA`, `$cloneB`, `$cloneC` rename to the sibling's untouched `$a`, `$b`, `$c` lines, and keep the
   sibling's label "rebased before the lock".
8. Every fixture stub of `ops\rehearse-chain.ps1` accepts `-CheckPush -Branch -RefsFile` and ends with
   `CHAIN-REHEARSAL-CHECK-COMPLETE`.
9. The merged suite asserts its literal case count. Expect about 70 (33 shared, 32 from W0.1, 5 from the sibling;
   SCRATCH arithmetic): use the file's count. Recompute every blob the commit message cites.
10. W0.3's outcome vocabulary gains `refused-rehearsal-churn`, `refused-rehearsal-blind`, `blind-fetch-failed` and
    W2.1R's `refused-already-on-main`.
Fixtures (added to W0.1's):
- MUST FIRE: a push that hands the lock back once and then lands records `rounds=2`, `lock_takes=2`,
  `inlock_check=covered` on its one row, and `lock_wait_ms_total` equals the sum of both waits.
- MUST FIRE: when the fake remote carries a changed `ops/push-main.ps1` that the round-1 rebase brings in, `pm_blob`
  equals the hash of the script as it was at start.
- MUST FIRE: a round-2 refusal before the lock records `lock_takes=1`.
- CLEAN TWIN: a one-round landing records `rounds=1`, `lock_takes=1`, `inlock_check=not-run`.
Done when: as W0.1, and the first real landing after W0.1R carries every field above.

**W2.1R Pre-flight residual (replaces W2.1).** File: `ops/push-main.ps1`, extending `Invoke-TcSyncToRemote`. Needs
W0.1R and W0.3 step 7's soak. Re-reads owed: as W0.1.
1. **The per-checkout guard**, exactly as W2.1 step 1. Its refusal names the holder's pid and start time, and says
   *"another push-main is already landing this checkout: wait for it, do not relaunch"* (agents poll push-main with
   9.5-minute deadlines, SCRATCH, correctness skeptic).
2. **The fetch.** Keep the plain fetch, which updates the shared `refs/remotes/origin/main`. Drop `--refmap=`, because
   1,223 of 1,225 updates of that ref from 08-23 to 09-23 were `update by push` (SCRATCH, sibling), so a stale shared
   ref is rare. `rehearse-chain -ForPush` and `prepush-test-auditors`' `--not --remotes` both read it, so an isolated
   `FETCH_HEAD` would make them read a stale base after an off-box push. When the fetch text matches `cannot lock ref`,
   retry once. Outside the lock (round-1 and later-round syncs), a fetch that still fails returns Code 0 with its `Why`
   and `degraded=fetch`, and push-main carries on: the in-lock fetch decides, which is the day before. Inside the lock,
   after the retry, it stays `blind-fetch-failed`, exit 3. The one production race seen: a transcript at
   2026-09-23T09:19:12Z read `cannot lock ref 'refs/remotes/origin/main': is at 38357202c but expected 4fa9f1a7b`, 1 s
   after `38357202c` landed by push (SCRATCH, correctness skeptic). In a sandbox, 0 of 120 fetches beside a push failed
   (SCRATCH, sibling), so it is rare and real.
3. **Conflict against could-not-rebase.** On a non-zero rebase, unmerged files (`git diff --name-only
   --diff-filter=U`) mean a CONFLICT: collect them, then abort. No unmerged file and no `rebase-merge` or
   `rebase-apply` directory under `git rev-parse --git-dir` means COULD-NOT-REBASE. Outside the lock that returns Code 0
   with the reason, and the in-lock path decides. Inside the lock it returns 3.
4. **The abort is checked.** A non-zero `git rebase --abort`, or a rebase directory still present afterwards, returns
   Code 3 with `blind=rebase-abort-failed`. Its message says the branch may be mid-rebase, and never says "exactly where
   it was". Siblings, as W2.1 step 3.5.
5. **Already on main.** After any successful rebase, if `git rev-list --count <rem>..HEAD` is 0, return Code 1 with
   outcome `refused-already-on-main`. Name the dropped commits and the main commits carrying their subjects, and never
   run a leg, push or record a landing. In sandbox `fx2` the rebase exited 0 with *skipped previously applied commit*,
   `git push` exited 0 *Everything up-to-date*, and today's code prints LANDED and records `landed-after-rebase`
   (SCRATCH, sibling). Duplicate lane work is real: `8bc691501` and `38357202c` carried one patch today.
6. Seed after the round-1 sync, and only when it returned 0.
7. `-DryRun`: the round-1 sync never rebases. It prints whether a rebase is needed and the approximate conflict list
   from `git merge-tree --write-tree --name-only --no-messages HEAD <rem>`, and at most one round runs.
8. **Re-exec on self-change.** When the round-1 sync rebased and `git hash-object ops/push-main.ps1` differs from
   `pm_blob`, release the guard, run the new copy once as a child process with the same arguments and
   `TC_PUSH_MAIN_REEXEC=1`, and return its exit code. The child writes the row; the parent writes none. A run with that
   variable set never re-execs, and `-NoReexec` skips it on purpose. Why: 3 of 5 knowable rows after `5841e96b1`
   landed ran an older copy (SCRATCH, measurement skeptic), and 31.7% of push-main rows came from checkouts older than
   2 hours (126 of 327 rows with a HEAD log, SCRATCH, residual). Without it, a stale checkout's first push after W6.1
   takes no lease and can void the holder. It takes effect only from the first copy that carries it.
9. **Fixture moves.** Add the in-lock CONFLICT case through the existing `-RehearsalRunner` seam: the stub lands a
   conflicting commit on the fake remote while it runs. This replaces the plan's `-BeforeLock` seam. The suite asserts
   its literal case count.
10. The header says: every round starts by rebasing outside the lock, and a later red leaves the branch rebased.
Fixtures (temp bare remote plus clone; the runner stub records whether it ran and the HEAD it saw):
- MUST FIRE: a conflicting branch is refused before the runner stub runs, `phase=preflight`, and `conflict_files` is
  exactly the conflicted path.
- MUST FIRE: a main commit with the branch's subject is named as a sibling.
- MUST FIRE: through the `-RehearsalRunner` stub, a conflicting commit landed during the legs is refused in the lock
  with `phase=inlock`, the rebase is aborted, and HEAD is the pre-lock sha.
- MUST FIRE: a second push-main in the same checkout, while a holder in another process (`lib/mutex-hold.ps1`,
  private name) holds the guard, is refused at once and names the holder's pid.
- MUST FIRE: a branch whose only commit is already on the fake remote as an identical patch is refused
  `refused-already-on-main`. The runner stub never ran, and no row says landed.
- MUST FIRE: an abort that exits 1 (a seam) gives exit 3, and the message does not say "exactly where it was".
- MUST FIRE: a round-1 rebase that brings in a changed `ops/push-main.ps1` re-executes once, the child's row carries the
  new blob, and the parent writes none. CLEAN TWIN: with `TC_PUSH_MAIN_REEXEC` set, it does not re-exec again.
- MUST NOT FIRE: a fetch that fails once with `cannot lock ref` succeeds on the retry. The ref's `.lock` is held from
  another process until the first try has failed.
- MUST NOT FIRE: a fetch that keeps failing outside the lock does not refuse: the stub ran and the row says
  `degraded=fetch`.
- MUST NOT FIRE: a planted `index.lock` is could-not-rebase, not a conflict, and push-main proceeds.
- MUST NOT FIRE: `-DryRun` never moves HEAD, and runs one round.
- CLEAN TWIN: a remote that moved without a conflict is rebased first, and the stub saw the rebased HEAD (the sibling's
  q1, kept).
- CLEAN TWIN: after a refused pre-flight, HEAD is the original sha and `git status --porcelain` is empty.
Mutants: M1 retargets to removing the round-1 `Invoke-TcSyncToRemote` call, which must turn q1 and the first MUST FIRE
red. M8 retargets to removing the in-lock abort, which must turn the in-lock CONFLICT case red. M15 removes the fetch
retry, which must turn the retry MUST NOT FIRE red. M16 removes the already-on-main check, which must turn its MUST
FIRE red. M18 removes the re-exec, which must turn its MUST FIRE red.
Done when: `-SelfTest` exits 0 with its verdict line and its count assertion, `-VerifyDeclared` passes, and a `-DryRun`
from the landing worktree prints the pre-flight lines and moves nothing. Bars: B1 (its (b) half judges the pre-flight
directly) and B13a.

**W2.2R Catch-up on top of the sibling's loop (replaces W2.2).** File: `ops/push-main.ps1`. Needs W2.1R.
**[Stands; EXTENDED 2026-09-23 evening by W9.4, section 16, which changes only the lock phase.]**
1. `$script:PmMaxCatchUpRounds = 3`, the first plausible value and not swept. When main stops moving, no catch-up
   round runs. After a round's legs pass and before `Enter-TcPushLock`, run one unlocked fetch (W2.1R step 2). If the
   remote has not moved, take the lock. If it moved, rebase outside the lock (a conflict refuses with `phase=catchup`),
   then start the next round without taking the lock. Each leg reuses what its keys allow. A could-not-rebase, a fetch
   failure, or reaching the catch-up cap goes to the lock, where the in-lock sync and the sibling's check decide
   exactly as `5841e96b1` does today (D11's degrade).
2. `$script:PmMaxRehearsalRounds = 3` keeps the sibling's cap, but counts only rounds whose rehearsal leg REHEARSED
   (W0.1R's `rehearsed`). Why two counters: with one counter, cheap catch-up rounds over non-chain moves would spend the
   rehearsal budget, and a chain push at a busy hour would reach the cap on rounds that needed no rehearsal.
3. At the rehearsal cap, with no covering verdict, refuse `refused-rehearsal-churn` (D11a). A run-gates or test-auditors
   exit 3 in any round degrades to the hook, as today.
4. **An in-lock check that cannot decide** (Code 3, :347) is retried once (0.8 to 0.9 s a run, SCRATCH, sibling). If
   it still cannot decide, it no longer hands the lock back: the push goes ahead and the hook decides, which is the day
   before. Since W1.1 the hook's rehearsal record check runs first and takes seconds, so a wrong guess costs seconds and
   one recorded refusal, where the sibling's path pays a whole round of about 14 minutes on every crash. Record
   `inlock_check=could-not-decide`, so B2(b) does not count a hook refusal that follows it. The churn message names
   which cause it saw: a manifest move, a stale verdict or a crashed check.
5. Record `rounds`, `catchup_sec` and `degraded` (W0.1R).
Fixtures: the sibling's q2, q4 and q5 stay. Added:
- CLEAN TWIN: a remote that moves once during round 1's legs, on a non-chain file, settles in round 2 outside the lock.
  Each stub is called twice, the rehearsal stub reports a reused verdict, and the in-lock rebase is a no-op.
- MUST FIRE, at the bar: a remote that moves after every round's legs stops after exactly 3 catch-up rounds. The 4th
  never starts, and the push reaches the lock.
- MUST FIRE: a conflict found by the catch-up fetch refuses with `phase=catchup`, and a probe from another process shows
  the lock was never taken.
- MUST FIRE: a runner stub exiting 1 in round 2 refuses `refused-gate-red`.
- MUST FIRE: three non-chain catch-up rounds do not spend the rehearsal budget. A chain move found in the lock after
  them still gets its hand-back round.
- MUST NOT FIRE: a stub exiting 3 in round 2 does not refuse. The push reaches the lock with `degraded` naming the leg.
- MUST NOT FIRE: a failed catch-up fetch does not refuse, and the row says `degraded=fetch`.
- MUST NOT FIRE: a remote that never moves gives exactly one catch-up fetch and no second leg run.
- MUST NOT FIRE: an in-lock check stub that exits 3 twice does not hand the lock back. It was called exactly twice,
  and the push is attempted with `inlock_check=could-not-decide`.
- CLEAN TWIN: a check stub that exits 3 once and then 0 lands with `inlock_check=covered`.
Mutants: M3 retargets `$script:PmMaxCatchUpRounds` from 3 to 4, which must turn the at-the-bar case red. M17 counts
catch-up rounds against the rehearsal budget, which must turn the "does not spend" MUST FIRE red. The sibling's cap
mutant, 3 to 4 on `$script:PmMaxRehearsalRounds`, must still turn q5 red.
Done when: `-SelfTest` exits 0 with its verdict line and its count. B2, B3 and B8 are read on their dates.

**W2.3, amended.** The `-RehearsalStarter` seam carries the sibling's q1 to q5 model (the stub records the HEAD it saw
and moves the fake origin while it runs), moved in W2.3's commit. The default `Wait()` keeps the sibling's marker rule.
`-RehearsalCheck` stays as the in-lock seam.

**W6.1, amended.**
- Step 3: the lease is taken after round 1's legs pass, before the first catch-up fetch. It is held across every lock
  hand-back and every later round, and released after the push's final `Exit-TcPushLock`, whether it lands or refuses.
  The MUST FIRE "a probe from another process sees the lease held at the moment the push holds the push lock" also runs
  in a round-2 hand-back drill.
- New step: while push-main holds the lease it exports `TC_CHAIN_LEASE_HOLDER`, a token naming the lease instance, so
  its own hook child can tell it descends from the holder (W8.3). The token names its lock, following the rule that
  TC_PUSH_LOCK_HOLDER learnt the hard way.
- With W2.1R step 8, a stale checkout's first push after W6.1 runs the new copy and takes the lease.

**W3.4a, amended (D17, NEEDS A RULING): one allocator for backlog ids.** W3.1 landed a merge whose ledger lock is named
from the full path of the backlog file in the checkout that runs it (`lib/ledger-lock.ps1` `Get-TcLedgerLockName`;
`ops/merge-backlog-inbox.ps1:173` defaults `$Backlog` to its own checkout, and :1541 locks it). So W3.4's task, in its
own worktree, and a hand merge in any other checkout take DIFFERENT mutexes. Each can allocate the same next id from
its own copy, and the second to land hits a rebase conflict on the backlog file, which is the collision Row 3 exists to
remove. A shared lock cannot fix this, because two copies at one base still allocate the same id. Only one writer can.
Evidence: code reading (correctness skeptic), and 13 backlog commits since 09-16 name a merge, all by hand (SCRATCH).
No collision has been observed since W3.1 landed about an hour before this was written, which is no evidence either way.
1. The scheduled task (W3.4) is the only writer that allocates ids or applies UPDATEs. A merge anywhere else refuses
   unless `-AllowHandMerge "<reason>"` is passed, and prints that reason in its `Backlog-Merged-From:` trailer.
2. A session that needs an id now runs the task on demand (`Start-ScheduledTask`), which uses the same worktree and the
   same push-main route. It does not hand-merge.
3. W3.2's pre-flight warning also counts commits that MODIFY an existing file under `design/backlog-inbox/updates/`.
   Such a lane is appending to a day file that the merge may already have consumed and deleted, which rebases into a
   modify/delete conflict. The README tells a lane to write a new file per batch, `<lane>-<YYYY-MM-DD>-<HHmmss>.md`.
   Speculative: 0 inbox files have been edited twice since 09-08 (SCRATCH, correctness skeptic).
Fixtures: MUST FIRE: a merge outside the task's worktree without `-AllowHandMerge` exits non-zero and writes nothing.
CLEAN TWIN: with `-AllowHandMerge "<reason>"` it merges and prints the reason in the trailer. CLEAN TWIN: the task's own
worktree merges with no switch. MUST FIRE (W3.2): a commit that modifies an existing `updates/` file warns with a count
of 1. MUST NOT FIRE (W3.2): a commit that adds a new `updates/` file does not warn.
Bar: B19.

### 15.5 Row 8: the causes the first plan left standing

**W8.1 push-main names the dirt, and says when it appeared.** File: `ops/push-main.ps1`, in `Invoke-TcSyncToRemote`'s
not-ready branch. It is built with W2.1R, in the push-main lane.
1. The round-1 sync keeps the dirty refusal, which `5841e96b1` already makes in seconds, before any leg. It records
   `dirty_paths` (at most 20 `git status --porcelain` lines, sorted Ordinal) and `dirty_since=start`.
2. A later sync (catch-up or in the lock) that finds the tree dirty records `dirty_since=during-legs` and the list. Its
   message says the tree was clean at the pre-flight and names what became dirty while the legs ran, and that something
   in this checkout wrote it.
3. When the checkout is the main checkout (`git rev-parse --git-dir` equals `--git-common-dir`), the refusal names W8.2's
   route instead.
Fixtures:
- MUST FIRE: a tree dirty at start refuses before the runner stub runs, with `dirty_since=start` and the path.
- MUST FIRE: a runner stub that writes a tracked file refuses in the lock, with `dirty_since=during-legs` naming that
  file.
- MUST NOT FIRE: an ignored file written by the stub does not refuse.
- CLEAN TWIN: a clean tree lands, and the row has no dirty fields.
Bar: B13.

**W8.2 The main checkout lands through push-main, from a throwaway worktree.** Files: `ops/push-main.ps1`
(`-ViaWorktree`, automatic when run from the main checkout), `CLAUDE.md` (the "ONE PUSH AT A TIME" paragraph: the
route), `.claude/rules/ops-and-gates.md`. It lands after W6.1 in the push-main lane, so a main-checkout chain push
takes the lease like any other. It adds no lock. Each run pays one seed of a fresh worktree (about 47 MB, the figure
W2.1 gives), and only from the main checkout.
0. **Step 0, before code.** In a scratch repo carrying this repo's `.gitattributes`, with a dirty tree (modified tracked
   data files the landed commits do not touch, plus untracked files) and one staged file belonging to "another
   session", prove what `git reset --keep <landed>` does. The dirty files must stay byte-identical. The staged entry
   must be unstaged with its content kept, as git's `--keep` table says. It must refuse when a file the landing changes
   has local changes. If any of that differs, stop and report.
1. From the main checkout, or with `-ViaWorktree`: refuse when HEAD has no commit ahead of origin/main. Print every
   commit that will land: like a plain push, it lands the whole branch (UNPUSHED IS NOT PRIVATE). Run `git worktree add
   --detach <per-run dir under %TEMP%, named tc-pm-via-<pid>-<guid8>> HEAD`, seed it with `ops/seed-worktree.ps1
   -Target`, and run the whole push-main sequence with `-Dir` pointed at it: guard, pre-flight, legs, lease, lock.
2. On a landing, if the main checkout's HEAD is still the sha the run started from, run `git reset --keep <landed tip>`
   there. Local main then carries the landed commits, and nothing is left for the bot's `-X theirs` replay. If HEAD
   moved, or `--keep` refuses, change nothing, print the landed tip and the one command to run, and exit 0 with
   `main_sync=manual`.
3. `finally`: `git worktree remove --force` and `git worktree prune`. A refusal leaves the main checkout exactly as it
   was.
4. `CLAUDE.md` and `ops-and-gates.md`: a session in the main checkout lands with `ops\push-main.ps1`, which does all of
   this itself. A plain push is the fallback, and it is still fully gated.
Fixtures (a temp bare remote, plus a clone standing in for the main checkout, private lock names):
- MUST FIRE: from a dirty clone with a staged file, a push lands through a throwaway worktree. The dirty files are
  byte-identical afterwards, and local main equals the landed tip.
- MUST FIRE: a remote that moves during the legs is rebased in the throwaway worktree, never in the clone.
- MUST FIRE: after every outcome, `git worktree list` shows no throwaway worktree.
- MUST NOT FIRE: a clone whose HEAD moved during the run is left unchanged, with `main_sync=manual`.
- CLEAN TWIN: a refused run leaves the clone's `git status --porcelain` and `git ls-files -s` byte-identical.
Bar: B12.

**W8.3 A chain push not descended from the lease holder is refused in seconds while the lease is held (D14, NEEDS A
RULING).** Files: `ops/hooks/pre-push`, `lib/chain-lease.ps1` (a zero-wait probe), `ops/test-prepush-hook.ps1`. Needs
W6.1. **[AMENDED 2026-09-23 evening, section 16.4: read "the lease" as the chain queue of W9.2 throughout; the probe is in
`lib/chain-queue.ps1`, the token is `TC_CHAIN_QUEUE_HOLDER`, the cause is `chain-queue`, and it needs W9.2.]** Evidence: 15.3. 6 of 17 chain landings since the gate ignored the lease, and 1 of today's 2 during-run voids was
one of them (row 42, `855171a1e`).
1. Directly after the rehearsal record check that W1.1 moved to the front of the hook, and before run-gates and any
   lock: when that check's `CHAIN-REHEARSAL-CHECK-COMPLETE` outcome says the push is chain-touching (anything but its
   not-needed outcome; read its vocabulary first), probe the lease with ZERO wait. If a process holds it and this push's inherited `TC_CHAIN_LEASE_HOLDER` does not name that instance,
   print `pre-push: BLOCKED - a chain-touching push is landing under the chain lease (holder pid <n>, <checkout>). Land
   chain changes with ops\push-main.ps1, which queues for the lease.` and `PRE-PUSH-REFUSED cause=chain-lease`, then
   exit 1.
2. If the lease is free, or the probe errors, proceed exactly as today, with one WARN line naming push-main as the route
   for chain changes.
3. **Why this is not section 10's NEVER.** That row forbids WAITING on the lease in the hook, which would invert the
   lock order. A zero-wait probe acquires nothing and adds no wait-for edge. Nothing that holds the push lock waits on
   this.
4. **Blast radius, for D14.** A bot push carrying an unpushed session chain commit is refused while a lease is held,
   which delays the bot by up to one lease hold (about 5 to 45 minutes, W6.1 step 3). That carry is itself the
   UNPUSHED IS NOT PRIVATE defect, and the bot's refusal pages as it does today.
Fixtures (the suite's sandbox, private lease prefix):
- MUST FIRE: a chain-touching plain push with a recorded verdict, while the lease is held from another process
  (`lib/mutex-hold.ps1`), is refused within the hang guard with `cause=chain-lease`, and the run-gates stub never ran.
- MUST NOT FIRE: the same push with the lease free proceeds and prints the WARN line.
- MUST NOT FIRE: a push-main child whose `TC_CHAIN_LEASE_HOLDER` names the held instance proceeds.
- MUST NOT FIRE: a non-chain push proceeds while the lease is held.
- CLEAN TWIN: a probe that throws proceeds as today.
Re-install the hook from a clean worktree at the landed origin/main (section 5). Bar: B14.

**W8.4 audit-prompt-backup refuses a push only over what the push changed (D15, NEEDS A RULING; reverses section 10's
NOT IN SCOPE).** Files: `ops/audit-prompt-backup.ps1`, plus the daily chain step or W3.4's task that runs its full
mode. Evidence: 5 of 19 kept in-hook run-gates red logs dated 09-20 to 09-23 name it (SCRATCH, correctness skeptic).
8 of 44 cause-naming gate refusals over 7 days name it (SCRATCH, residual; coverage 44 of 78). Today's row 46 was one.
The audit compares the SHARED live `C:\Users\Owner\.claude\scheduled-tasks` with each checkout's mirror, so one
session's live edit reddens every other push on the box until its mirror lands, and none of those pushes can fix it.
1. At push time, it fails only when a file under `ops/prompt-backup/` that this push changes (`git diff --name-only
   <merge-base with origin/main>..HEAD`) does not match its live copy, or when the audit itself changed. A
   live-to-mirror mismatch the push did not touch prints `REVIEW` with the paths, and passes.
2. Its full live-to-mirror check runs daily, and pages on a mismatch older than 24 hours. That is the floor: a mirror
   nobody committed.
3. Its `SCOPE OF A CLEAN REPORT:` line says what the push mode no longer covers, and where that moved.
Fixtures:
- MUST FIRE: a push that edits a mirror so it no longer matches its live copy fails.
- MUST NOT FIRE: a push touching no mirror, over a drifted live copy, passes and prints REVIEW naming it.
- MUST FIRE: the daily mode fails on that same drift.
- CLEAN TWIN: a push whose changed mirror matches its live copy passes.
Bar: B15.

**W8.5 test-auditors tells a red the push caused from one already on main (D16, NEEDS A RULING).** File:
`ops/prepush-test-auditors.ps1`. Evidence: 13 of 44 cause-naming gate refusals over 7 days were test-auditors reds
over board data (capture-evictions stamp 6, live-board twins 5, golden 1, derived-size-density 1; SCRATCH, residual,
coverage 44 of 78). The memory records the same push ALLOWED at 19:25 and REFUSED at 20:09 on 09-11, "on nothing you
did". The known-failures record lives in the common git dir (`ops/prepush-test-auditors.ps1:65-66`), and other
checkouts rewrite it.
0. **Step 0.** Read how the suite selects cases (the `selected` field of its pass record), and whether it can run named
   cases only. If it cannot, stop and report: running the whole suite twice would double an 851 s leg (today's median,
   SCRATCH).
1. When a push adds a failing case, run ONLY the newly failing cases again, in a throwaway checkout at `git merge-base
   HEAD origin/main`, over the SAME board files hardlinked in, as the EXPECTED-LIVE-RED paired run already does.
2. A case that also fails at the base is PREEXISTING. Print `PREEXISTING <case>` with both exit lines, count it, and do
   not refuse. A case that passes at the base and fails at the tip refuses exactly as today. Any exit 3 in the base run
   refuses as today, because a could-not-look is never a pass.
3. The shared record is written as today. The paired run is judged first.
Fixtures:
- MUST FIRE: a case red at the tip and green at the base refuses.
- MUST NOT FIRE: a case red at both, over one board, does not refuse, and prints PREEXISTING.
- MUST FIRE: a base run that exits 3 refuses.
- CLEAN TWIN: the EXPECTED-LIVE-RED path decides exactly as before, over its frozen fixture.
Bar: B16.

**W0.3b The probe counts attempts, not rows.** File: `ops/probe-push-convergence.ps1` (landed as `c1c418fdc`). Needs
W0.1R and W0.6. It changes no bar's value, only what the bar counts.
1. An ATTEMPT is a run a session launched: a push-main row, or a W0.6 `hook-refused` row of a plain push. A LEG SET is
   one round (`rounds`, summed). B6 and B10 print both.
2. A change is (checkout, `subjects_sha`), and `change_id` only breaks ties. A lane that amends a baseline between
   attempts keeps its subjects, so it stays one change. The housekeeping lane's three attempts carried three
   `change_id`s (`67c869cf9e76`, `2f849964be2f`, `81a788cbef31`), so as landed B6 would read 1.0 where the truth is 3
   (SCRATCH, measurement skeptic). A subject set that lands from another checkout links the two groups, and the change
   is counted as crossing checkouts.
3. A change landed on its first attempt only when that attempt's own row landed. Changes finished by another checkout
   stay out of B6's denominator and are counted on their own line.
4. B6 prints not-ready rows and ambient reds as columns instead of excluding them: own red, ambient red, not-ready at
   start, not-ready during the legs, mechanical conflict, genuine conflict.
5. B6 and B10 are stratified by PARALLEL RUN and by landings in the clock hour (fewer than 8, or 8 or more). The quiet
   stratum prints P(result | old rate).
6. `-History` gains two counts, committed rather than described: main-checkout plain pushes that passed every hook check
   and were then rejected (a held hook-lock row with no origin/main update within 15 s, the method of
   `%TEMP%\pushgood-skeptic\mainland.py`), and chain landings by route (push-main, plain push from a worktree, plain push
   from the main checkout, no ledger row; the method of `%TEMP%\pushgood-residual\landings.py`).
7. The older-copy count beside every bar is also printed as a share.
Fixtures (frozen literal rows):
- MUST FIRE: three attempts of one lane with three different `change_id`s and one `subjects_sha` are one change with 3
  attempts.
- MUST NOT FIRE: two changes in one checkout with different subjects stay two changes. This is the checkout that landed
  7 changes in turn.
- At the bar: a held hook-lock row followed by an update after 15 s counts as followed, and one after 16 s does not.
- MUST FIRE: a change whose only push-main row was refused, and which landed from another checkout, is counted as
  crossing checkouts and not as a first-attempt landing.
- CLEAN TWIN: rows without `rounds` still print B6's old line, labelled pre-W0.1.
Done when: `-SelfTest` exits 0 with its verdict line, and a plain `-Cost` prints both attempt and leg-set lines.

**W0.6 The hook records its refusals.** Files: `ops/hooks/pre-push`, and a small writer that calls `Write-TcPushRow`.
Read first how `audit-script-census` reaches `ops/hold-push-lock.ps1`, which only the hook names, and register the
writer the same way.
1. Every exit that prints `PRE-PUSH-REFUSED cause=...` (W1.1) also writes one ledger row: `event=hook-refused`, with
   `cause`, `gate`, `checkout`, `pid`, the ref line's shas, and `under_push_main` (whether a push-main token was
   inherited).
2. The write is best effort. If it fails, the hook prints one line and keeps its exit code. It costs one PowerShell
   start on a refusal (an estimate, not measured) and nothing on a pass.
Fixtures (the suite's sandbox, `TC_PUSH_LEDGER_ROOT` per run as W0.2 set it):
- MUST FIRE: a chain push with no verdict writes one `hook-refused` row with `cause=rehearsal`.
- MUST FIRE: a run-gates red writes `cause=run-gates` and the first failing gate.
- MUST NOT FIRE: a passing push writes no `hook-refused` row.
- CLEAN TWIN: with an unwritable ledger directory, the hook still exits 1 with its PRE-PUSH-REFUSED line.
Re-install the hook from a clean worktree at the landed origin/main. Done when: the suite exits 0, and the first real
refusal afterwards is in the ledger.

**W6.2 The manifest set follows dot-sources. This is a soundness gap, and it ADDS attempts.**
**[REPLACED 2026-09-23 evening by W9.5, section 16, which lands before W9.1.]** File:
`ops/rehearse-chain.ps1` (`Get-RhManifestSet`) or `ops/chain-manifest.json`'s derive rule. This is a chain-touching
push, so budget its rehearsal. Evidence: the 130 members at origin/main reach 44 non-member `.ps1` files through
dot-sources (for example `meal-prep/engine/publish.ps1:40` sources `meal-prep/lib/render-tokens.ps1`). 15 of 577
first-parent commits in 7 days changed one of those 44 and no member (SCRATCH, correctness skeptic `closure.py` over
the causes replica). Such a landing keeps every verdict valid, so a chain push can land a combination no rehearsal
ran. That is the RCA F2 failure the rehearsal exists for.
1. Derive the set transitively over literal dot-sources, the way `lib/gate-input-key.ps1` already derives self-test
   keys.
2. Stated cost: about 15 more chain-touching commits a week at the 7-day rate (SCRATCH), which raises lease contention.
   So it lands AFTER W6.1 is live and after B6's first read-out, so that B6 is judged on the set it was designed for.
   It strengthens a gate and needs no ruling. It is listed for Brad because it adds attempts.
Fixtures:
- MUST FIRE: a fixture member that dot-sources `lib/x.ps1` puts `lib/x.ps1` in `-ListSet`'s output, and a push that
  changes only `lib/x.ps1` needs a rehearsal.
- MUST NOT FIRE: a file no member reaches stays out.
- CLEAN TWIN: a dot-source cycle terminates.
- CLEAN TWIN: `-ListSet` over the real tree prints every current member plus the closure, and `files=` equals the
  count.
Bar: B17.

**W7.1a, added to W7.1's text.** Three sentences, with the reason for each. (1) Run board steps, guards and reconcilers
in a scratch clone, never in the checkout you land from: W8.1's during-legs class, where row 50 of the case list was the
lane's own `reconcile-ghost-drift` writing `grocery/ghost-tool-published.json` mid-run. (2) Land a chain change only
through `ops\push-main.ps1`, never `git push origin HEAD:main`, and orchestrator briefs say so: 15.3's lease-ignoring
class. (3) From the main checkout, `ops\push-main.ps1` lands through a throwaway worktree (W8.2).

**W7.2 A commit that changes a file an under-way plan names cites the plan.** Files: `ops/hooks/commit-msg`, and a new
`ops/plan_citation.py` beside `ops/store_citation.py`, in its shape: judged only under `CLAUDE_CODE_SESSION_ID`, and a
missing script or interpreter is BLIND, never a refusal. Evidence: 15.1's process cause.
1. For each staged path, list the `design/PLAN-*.md` files on origin/main whose Status line says ruled or build under
   way, and that name the path. When one exists and the message has neither `Plan: <that plan>` nor `Plan-not-applicable:
   <reason>`, print `plan-citation: WARN - <path> is named by <plan> (build under way); read it, and add a Plan: line or
   Plan-not-applicable: <reason>`.
2. Warn only. A refusal from a literal cutoff date, as the Store line has, is D18 (NEEDS A RULING).
Fixtures:
- MUST FIRE: a staged path named by a fixture plan whose status says build under way, with no Plan line, warns.
- MUST NOT FIRE: the same commit with a Plan line does not warn.
- MUST NOT FIRE: a plan whose status says DONE or SUPERSEDED does not warn.
- CLEAN TWIN: `Plan-not-applicable: <reason>` passes.
- CLEAN TWIN: with no `CLAUDE_CODE_SESSION_ID`, the commit is not judged.
Bar: B18.

### 15.6 Bars, written now

Each is measured by `ops/probe-push-convergence.ps1` (W0.3, with W0.3b), cited by its blob, over rows from UPDATED
copies only. Each value is the first plausible one, not swept. Each item's landing adds its bar to the probe's literal
bars table, with the 14-day read-out every bar already takes. A **mechanism** bar tests a deterministic step, so any
counted row is a defect, and it needs no P(zero | old rate).

| # | Metric | Stratum, minimum N | Baseline (source) | Bar | Item |
|---|---|---|---|---|---|
| B2 (amended) | as written, plus (b): in-lock refusals with `reject_class` `rehearsal` on rows whose `inlock_check` is `covered` | as written | (a) 8 in 46 lock-taking rows, UTC 09-23 to 14:17:54Z (SCRATCH, causes) | (a) as written; (b) 0, mechanism: the check and the hook read one key | W2.2R |
| B6 (amended) | (a) ATTEMPTS per landed chain-touching change (W0.3b), counting not-ready and ambient reds and excluding only the change's own reds and genuine conflicts; (b) LEG SETS per landed chain-touching change | quiet (not a PARALLEL RUN, and fewer than 8 landings in the hour): at least 10 changes; contended: at least 5 | 12 chain changes landed through push-main 09-21 to 09-23, 2 of 12 on the first attempt, 30 rows, 2.50 per change; 1.92 under the old exclusions (SCRATCH, measurement skeptic) | (a) at most 1.2 quiet and at most 1.5 contended; (b) at most 1.8 quiet, reported when contended. The model for (b): at least one round-1 void at 31% to 62% of start times this morning (SCRATCH, residual replay, one day), so 1.3 to 1.6 is expected with the lease | W6.1, W8.x |
| B12 | (a) share of landings of main-checkout commits made through `-ViaWorktree`; (b) remote rejections after the lock on `-ViaWorktree` rows | (a) at least 30 such landings | (b) plain pushes: 11 of 82 held main-checkout hook-lock rows since 09-16 were not followed by a landing (SCRATCH, correctness skeptic) | (a) at least 80%; (b) 0, mechanism: the lock is held from the in-lock fetch to the ref update | W8.2 |
| B13 | (a) seconds from push-main start to a `dirty_since=start` refusal; (b) `dirty_since=during-legs` rows per push-main row that ran legs | (a) at least 5 rows; (b) at least 150 rows after W7.1a lands | (b) at least 2 of today's 48 rows, 4.2%, from direct transcript evidence, with 3 of the 7 dirty refusals undetermined (SCRATCH, residual) | (a) median at most 60 s, mechanism; (b) at most 1 in 150. P(at most 1 in 150 at 4.2%) = 1.3% | W8.1, W7.1a |
| B14 | chain landings that did not hold the lease, by route; and plain-push chain landings made while a lease was held | at least 20 chain landings | 6 of 17 since the gate, 35.3% (SCRATCH, residual) | at most 10%; and 0 during a held lease, mechanism | W8.3 |
| B15 | push refusals classed `run-gates:ops\audit-prompt-backup.ps1` on a push that changes nothing under `ops/prompt-backup/` and not the audit | 14 days | 5 of 19 kept in-hook red logs 09-20 to 09-23 (SCRATCH, correctness skeptic) | 0, mechanism; and the daily check's COMPLETE marker on at least 13 of 14 days (the floor) | W8.4 |
| B16 | test-auditors refusals whose only newly failing cases are PREEXISTING | at least 10 test-auditors refusals | 13 of 44 named gate refusals over 7 days were board-data reds (SCRATCH, residual, coverage 44 of 78) | 0, mechanism. Reported, no verdict: PREEXISTING prints per day, and test-auditors refusals per 100 push-main rows against W0.3's recomputed baseline | W8.5 |
| B17 | chain landings whose diff touches only a closure member without a covering rehearsal | 14 days | 15 of 577 first-parent commits in 7 days (SCRATCH, correctness skeptic) | 0, mechanism. Printed beside it: the chain share of landings before and after | W6.2 |
| B18 | session commits that change a file named by an under-way plan and carry neither Plan line | at least 10 such commits | 1 known (`5841e96b1`) | reported while warn-only; 0 after D18's cutoff | W7.2 |
| B19 | backlog conflict rows where both colliding commits carry a `Backlog-Merged-From:` trailer | 14 days | none observed since W3.1 (about 1 hour of rows) | 0, mechanism, once D17 lands | W3.4a |

**Read B6 honestly.** B6 is read no earlier than 14 days after W6.1 and W2.1R's re-exec have both landed, and it
prints the plain-push share of chain landings beside it. The build lands its own lanes one at a time, which removes one
of the two sources of contention while the bars are read. So a quiet window can pass (a) for free, which is why the
contended stratum is judged separately.

### 15.7 Decisions for Brad, added to section 12

**RULED 2026-09-23 (Brad).** He adopted this amendment ("Adopt and build (Recommended)") and accepted every ruling below as recommended: D11a, D14, D15, D16, D17 and D18.

| # | Decision | Recommendation | Blocks |
|---|---|---|---|
| D11a | At the rehearsal cap, refuse (`refused-rehearsal-churn`, as `5841e96b1` does) rather than push into the lock | yes, for the rehearsal leg only. The hook never rehearses, so pushing in with no covering verdict is a certain refusal inside the lock. D11's degrade stays for run-gates and test-auditors, which the hook can run again | W2.2R |
| D14 | The pre-push hook refuses, in seconds, a chain-touching push not descended from the lease holder while the lease is held | yes. 6 of 17 chain landings since the gate ignored the lease (SCRATCH). A zero-wait probe inverts no lock order. Cost: a bot push carrying an unpushed session chain commit waits out one lease hold | W8.3 |
| D15 | audit-prompt-backup judges at push time only what the push changed; the full live-to-mirror check moves to a daily run that pages | yes. A push cannot fix another session's live prompt edit, so the refusal teaches retry and not repair. 8 of 44 named gate refusals over 7 days (SCRATCH) | W8.4 |
| D16 | A test-auditors case that also fails at the push's base, over the same board, is PREEXISTING and does not refuse | yes. It is the paired-run rule Brad already ruled for EXPECTED-LIVE-RED, applied to "adds a failing case". 13 of 44 named refusals (SCRATCH) | W8.5 |
| D17 | The scheduled merge is the only allocator of backlog ids; a hand merge needs `-AllowHandMerge "<reason>"` | yes. A lock per checkout cannot serialise two copies, and one writer is the 2026-09-08 ruling taken to its end | W3.4a |
| D18 | W7.2's warning becomes a refusal from a literal cutoff, with a `Plan-not-applicable:` escape | yes, 7 days after it lands, as the Store line did | none |

### 15.8 Gaps this amendment deliberately leaves, and why

- **A change's own red, and a genuine code conflict.** These are the gates working: 3 own-red rows today, and 1 genuine
  code conflict in 22 rebase conflicts over 8 days. They will always, correctly, cost a second attempt.
- **Header-line conflicts** (row 36: `# gate-inputs:` lines against header-seed lines in one library). 1 row in 8 days,
  and section 9 forbids a merge driver for any `.ps1`. W0.1R's `conflict_files` makes recurrences visible. Revisit at 3
  or more in 14 days.
- **gate-leftovers reds from a self-test that writes a tracked file in a linked worktree** (row 29). The gate is right
  to refuse, it names the writer, and that instance was fixed at source (`38357202c`). Running every leg in a snapshot
  worktree would copy every seeded board on every push. Revisit if W0.1R's `reject_class` shows more than 2 a week.
- **The round-1 rehearsal void.** The lease is taken after round 1's legs, so a chain landing during those legs still
  costs one automatic re-round of about 14 minutes (at least one void at 31% to 62% of start times this morning,
  SCRATCH, one day). That is time and not an attempt. Taking the lease before round 1 would hold a lock across a
  30-minute leg set and cap chain pushes at about 2 an hour.
- **The lease queue at peak.** W6.1 step 6's ceiling stands: 2.4 to 3.5 chain pushes an hour when every holder
  re-rehearses. It removes a livelock and adds no capacity. At the 09-19 rate of about 6 chain landings an hour (a
  counterfactual over today's set), expect waits, not attempts. With the lease and 35% of chain landings ignoring it,
  the chance that all 3 rounds are voided is 13% to 39% at that rate (SCRATCH, residual Poisson model); W8.3 is what
  drives that share toward 0.
- **Blind or stale rehearsal verdicts** (1 of 40 verdicts was blind, SCRATCH). This is infrastructure. W0.1R records
  `refused-rehearsal-blind` on its own line.
- **test-auditors' 1200 s kill under overlap.** W2.3's step 0 already measures it. 0 kills were seen in about 80
  printed runs over 7 days, with a maximum of 949 s (SCRATCH, residual).
- **Retro-filling the false LANDED rows** that an identical patch may already have produced. W2.1R step 5 stops new
  ones, and old ones are not reconstructed.

### 15.9 Order, and what changes elsewhere

| Step | Items | Why here |
|---|---|---|
| now | W0.1R (the `feat/pd-ledger` rebase), then the rest of Wave 1 as planned (W0.4, W1.2, W4.1, W4.2) | every later bar needs W0.1R's fields |
| with the soak | W0.3b, W0.6, W7.2 | instruments, and nothing refuses. The soak's rows should count attempts correctly from the start |
| after the soak, push-main lane | W2.1R with W8.1, then W2.2R, W2.3, W3.2 (with W3.4a step 3) and W4.1 step 7, then W6.0 and W6.1, then W8.2 | one file, one lane |
| beside that lane, other files | W8.4 (D15), W8.5 (D16), W3.4 with W3.4a (D17) | independent files |
| after W6.1 is live | W8.3 (D14) | it reads W6.1's token |
| after B6's first read-out | W6.2 | it raises chain contention, so B6 is read first |
| last | W7.1 with W7.1a | the text follows the behaviour |

- **Section 3** gains G11: a change that is green and conflicts with nothing on main lands on its first push-main run,
  from any checkout including the main one (W2.1R, W8.1, W8.2, W8.3; B6, B12, B13). And G12: a push is refused only
  for a red it caused (W8.4, W8.5; B15, B16).
- **Section 8**: M1, M3 and M8 are retargeted as in 15.4. M15 to M18 are added.
- **Section 10**: the prompt-backup row becomes D15. The "taking the lease inside the hook: NEVER" row stands, and
  W8.3's zero-wait probe is not a take.
- **Section 11**, added: W2.1R's re-exec makes a push-main change, including a broken one, reach a stale checkout one
  run sooner. Rollback is a revert landed by plain `git push`, or `-NoReexec` on one push. W8.2 moves the main
  checkout's HEAD with `git reset --keep`, and only when HEAD is where the run found it. W8.3 adds a hook refusal that
  lasts at most one lease hold, and its rollback is a hook revert plus a re-install. W8.4 moves a check from the push
  to the daily chain. W8.5 adds a partial second test-auditors run on a red only.

## 16. Amendment 2026-09-23 (evening): design A replaces the chain lease

**Status: RULED 2026-09-23 (Brad).** An architecture review read the push path end to end the same afternoon and
recommended its design A, "rehearse at commit, stack at push, lock only the swap", over the plan's chain lease (W6.1).
Before anything was built, its section 7 step 1 wrote a bar in the metric's own units: *"if at least 30% of chain
landings would have hit, build parts A1 and A3. If under 30%, build A2 and A4 only."* Brad chose **"Measure first, then
decide"**. The measurement read 43%, over the bar, so **design A is built in full**, all five parts, as Row 9 below. The
lease is not built. Everything in sections 1 to 15 that this section does not name stands as written.

The review is scratch: `%TEMP%\push-arch-review\REVIEW-push-architecture-2026-09-23.md` (`git hash-object` blob
`43938012`), code read at origin/main `a4f64d867`. **Every figure from it is marked (review)** and is its own SCRATCH
derivation. Figures taken from earlier sections of this plan are marked (plan). The early-rehearsal measurement is
SCRATCH too and is cited by its harness blobs below.

### 16.0 Knowledge consulted (for this amendment)

- `CLAUDE.md`, "THE GATE MUST NOT RUN INSIDE THE LOCK" (Brad, 2026-09-12): *"Serialising the PUSH costs nothing ...
  serialising the GATE costs everything."* This is the test W9.2 and W9.4 are held to. The chain queue serialises the
  swap, which `refs/heads/main` serialises already, and holds nothing that a leg waits for. The lease held a lock across
  gate legs and needed D8's named exception; design A needs none, so that exception is withdrawn (16.8).
- `.claude/rules/ops-and-gates.md`, "ORDER DECIDES WHICH PUSHES ARE REFUSED, NEVER HOW MANY ... State that bound beside
  any fairness fix". W9.2 states its ceiling (6 rehearsal slots divided by the rehearsal's length) and its head-of-line
  cost.
- `.claude/rules/ops-and-gates.md`, "EVERY LOCK PATH DEGRADES TO THE DAY BEFORE". A queue that cannot be read or
  written, an early rehearsal that cannot start, a stop that cannot be delivered and a hand-back cap that is reached all
  fall back to the path before this section, and none of them refuses.
- `.claude/rules/ops-and-gates.md`, "THE LOCK ORDER IS DECLARED, OUTERMOST FIRST", and "The order covers every BLOCKING
  WAIT". 16.6 places the queue ticket and the early-rehearsal cap, and says why the ticket is not a lock held across a
  leg.
- `.claude/rules/measurement.md`, "Write the ACCEPTANCE BAR before the run": the 30% bar was written in the review
  before the run, and 16.5's bars are written here before any W9 item runs. "NAME THE HARNESS AND THE COMMIT IT RAN AT"
  and "Never cite your own unlanded commit hash, anywhere: cite a blob": 16.1 names every harness by its blob and the
  origin/main commit it ran at, and no item below cites a hash of its own.
- Store search: `"merge queue dependent pipeline rehearsal"`, nothing applicable beyond the review.
- Memory index lines (the files were not opened): `an-intention-has-no-exit-code` (D19: an explicit "remember to
  prepare" step is not a trigger), `powershell-exiting-event-does-not-fire` (a stopped rehearsal is stopped by its own
  process, never killed, or its scratch clone leaks) and `ps-start-process-exitcode-needs-handle` (W9.3's starter).

### 16.1 The ruling and the measurement

**What was measured.** For every chain-touching landing after the rehearsal gate `a66ef0e94` (2026-09-22T21:26:14Z):
would a rehearsal started when the session committed that content have finished, and still been valid, before the
push started? One row per landing, written before any total, in `rows.jsonl`.

- A **landing** is one `update by push` entry in the shared reflog of `refs/remotes/origin/main` whose tip changed the
  manifest key (a replica of `Get-RhManifestSet`, `rhkey.py`). 23 landings, 2026-09-22T23:42:45Z to
  2026-09-23T18:05:46Z: 18 through push-main, 5 plain pushes.
- The **commit time** is the earliest committer date among every copy of the first landed commit carrying that key's
  content (same author, author date, subject and patch-id): a pre-rebase copy for 19 of 23 rows, the landed commit for 4.
- The **push start** is the matching push-main row's `run` start (within 30 s); for a plain push it is the landing time,
  which is optimistic.
- **Valid** means the manifest set of main as it stood at the commit time equals the set of the main the push landed
  on: nothing changed the set in between. **HIT** means valid, and a gap from commit to push start at least the key's
  recorded rehearsal seconds (804 s when no verdict records it).

| Stratum | HIT | Note |
|---|---|---|
| all chain landings | **10 of 23 (43%)** | the ruled figure; bar 30% |
| push-main landings | 6 of 18 (33%) | one landing above the bar: 5 of 18 would be 28% |
| plain-push landings | 4 of 5 (80%) | plain start times are optimistic |
| early rehearsal on HEAD as committed, NOT rebased onto origin | 6 of 23 (26%) | under the bar |
| voided only by a change before push start (the review's variant) | 11 of 23 (48%) | reported, not the verdict |

- **The misses:** 13. 12 were voided by 1 or 2 other chain landings between the commit and the landing. 1 was valid
  with a 6 s gap against a 1,242 s rehearsal.
- **Sensitivity**, each reading 10 of 23: a flat 804 s bar for every row; the author date as the commit time.
- **Gaps:** median commit-to-push gap 2,597 s, median rehearsal 833 s. 21 of 23 gaps were long enough; validity is
  what fails.
- **Coverage:** 80 reflog push entries after the gate, all `update by push`; 67 of 67 landed push-main ledger rows in
  that window matched a reflog entry within 30 s.
- **Harness** (scratch, `git hash-object` blobs, never commits): `%TEMP%\early-rehearsal\measure.py` `a6a2b8ed`,
  `derive.py` `e9d921b2`, `checks.py` `050c4a4e`, `%TEMP%\pushgood-causes\rhkey.py` `4f2f4789`, rows
  `rows.jsonl` `5e9017ff`, run at origin/main `85238faf6`. `derive.py` and `checks.py` were re-run for this amendment,
  exit 0 each, with the totals above.

**Three things the pass does not say**, written down so the bar is not over-read:
1. **The rebase condition is load-bearing.** The bar passes ONLY when the early rehearsal runs on HEAD rebased onto
   origin/main as it stood at commit time (43%). On HEAD as committed it reads 26%, under the bar. So W9.1's rebase is
   the design, not an optimisation, and a W9.1 that rehearses the unrebased commit has not built what was measured.
2. **The push-main margin is thin.** 6 of 18 is one landing above 30%. Push-main is the route W8.3 makes the only one for
   chain changes, so B22 re-measures the hit rate live, on push-main landings, and a live reading under the bar sends
   W9.1's trigger back to Brad (16.5).
3. **One day, 23 landings, one bar, five variants read.** A number that passed is not a number that will hold. The
   misses are the queue's case, not the early rehearsal's: 12 of 13 were voids by another chain landing, which W9.2
   stacks on instead of voiding.

### 16.2 The design, in this plan's terms

```
session commit that changes the manifest set
  EARLY REHEARSAL (W9.1)     fetch; rehearse HEAD rebased onto origin as it is now, in a scratch clone, in the
                             background; a later commit in this checkout that changes the key supersedes it
push-main start
  guard, round-1 sync, seed  (W2.1R, W8.1, as ruled)
  CHAIN QUEUE (W9.2)         a chain-touching push takes a ticket; its rehearsal is of HEAD stacked on the tickets
                             ahead of it (or on origin when none is ahead), usually found recorded by W9.1 in seconds
  LEGS, unlocked (W9.3)      [ run-gates, then test-auditors ]  ||  [ rehearsal of the stacked tip ]
                             any red -> the rehearsal is stopped, the push refuses
  CATCH-UP (W2.2R)           fetch; if main moved, rebase outside the lock and re-run each leg on its own keys
  HEAD OF QUEUE (W9.2)       a queue member waits until every ticket ahead has landed or left
  LOCK, the swap only (W9.4) fetch; unmoved -> git push (the hook replays); moved -> hand the lock back, rebase and
                             re-run outside, come back; after 3 hand-backs, rebase inside as today
    pre-push hook            rehearsal record check (W1.1), queue probe (W8.3, amended), run-gates, test-auditors
KEY (W9.5)                   the manifest set includes the dot-source closure of its scripts
```

**Guarantees kept:** all three legs judge the exact tip that lands, and the hook inside the lock is unchanged and
still the last word. **Removed:** the only lock this plan held across gate legs. **Gained:** a queue member is not
voided by the members ahead of it, and dot-sourced code the chain runs is rehearsed.

**The bound, stated beside the fix as the rules require.** The queue orders chain landings and adds no rehearsal
capacity. The ceiling is the rehearsal slots divided by the rehearsal's length: 6 slots over 800 to 1,240 s is about 17
to 27 chain landings an hour (review), against about 4.2 an hour offered at the 09-19 peak (plan, 16 landings an hour
times 26.4%) and the lease's 2.4 to 12 (plan). Its cost is head-of-line: a member ready before the one ahead waits for
it, up to that member's remaining rehearsal (up to about 21 minutes, review). It never livelocks, because the only
re-rehearsal is a restack after a ticket ahead failed or left.

**Still exposed, as under W6.1:** a plain `git push` of a chain change, or a checkout whose push-main predates W9.2, can
land ahead of the queue and void a stacked verdict. The in-lock verdict check and the hook's `-CheckPush` still refuse
content without a covering verdict, so the exposure costs time, never correctness. W8.3 (amended) and W2.1R's re-exec
shrink it.

### 16.3 Row 9: design A

Every item is in the push-main lane of 15.4 (one lane, one item landed and verified before the next), because W9.1,
W9.2, W9.3 and W9.5 also change `ops/rehearse-chain.ps1`, which is itself a chain-manifest file: each of those is a
chain-touching push, so budget its rehearsal (about 14 minutes and one of 6 slots, plan). Section 5's rules apply to
every item: pathspec commits, blobs never own hashes, the re-reads each item owes, `# gate-inputs:` lines verified with
`-VerifyDeclared`, private lock names in every fixture, overlap never a wall clock, the suite's last line its verdict,
literal-case suites asserting their count. New row fields land as W0.1R fields in `lib/push-ledger.ps1` in the item that
first writes them.

**W9.1 Rehearse at commit: HEAD rebased onto origin at commit time, with supersede.** Files: `ops/rehearse-chain.ps1`
(`-Early`, `-Onto`, `-StackFile`, `-StopFile`, the verdict record), `ops/push-main.ps1` (`-Prepare`),
`ops/hooks/post-commit` (new, D19), `ops/install-hooks.ps1`, `ops/audit-hook-installed.ps1`. Needs W9.5 (16.10).
0. **Step 0, before any code: what a stopped rehearsal leaves behind.** Read `Invoke-RhProcess` and `Invoke-RhArm`
   (`ops/rehearse-chain.ps1`, :414 and :470 at origin/main) and list everything the ship path writes OUTSIDE the scratch
   root (`%LOCALAPPDATA%`, `%TEMP%`, any named mutex, any ledger lock). Then stop one rehearsal of a fixture chain by
   stopping its child tree while the parent keeps running, and compare those places before and after. If the child
   leaves shared state behind (an abandoned ledger lock, a half-written journal outside the root), the stop in step 4 is
   NOT built: a superseded rehearsal runs to the end and records its verdict, which is harmless because a verdict covers
   only its own key, and costs one slot. Report which it was in the landing commit.
1. **`-Onto <sha>` and `-StackFile <path>`.** The rehearsal's arm, after `git clone --shared --no-checkout` and before
   the seed, checks out the base (`-Onto`, or the first line of the stack file) and cherry-picks, in order, every commit
   the stack file lists after it (W9.2 writes it), then the commits of `<merge-base>..<Commit>`. Cherry-picks, not a
   rebase of any worktree: every commit is already in the shared object store, and the rehearsal's own clone is the only
   tree that moves. The verdict is keyed on `Get-RhManifestSet` at the resulting tip, by the unchanged key function, and
   written to the same store. A cherry-pick conflict records NO verdict, prints `chain-rehearsal: STACK CONFLICT` with
   the files and the commit it stopped on, and exits 3 with `blind=stack-conflict`.
2. **`-Early -Onto <sha>`.** Rehearse `HEAD` onto `<sha>` in the background, with every rule of a push-time rehearsal
   (the slot cap, the verdict store, the interlock self-test), and:
   - start nothing when the content touches no manifest member (`Get-RhTrigger` against `<sha>`, with W6.0's union),
     when a verdict exists for the rebased key, or when an in-flight early rehearsal in any checkout already holds that
     key;
   - record the in-flight run at `%LOCALAPPDATA%\ThriftyCrew\chain-rehearsal\early\<SHA-256 of the lower-cased
     checkout path>.json` (pid, key, onto, head, start, stop file), written with `Write-TcAtomicFile`;
   - take an **early cap** before the rehearsal slot: a `gate-slots` instance, prefix `Global\tc-rehearsal-early-`,
     `$script:RhEarlyMaxSlots = 4` of the 6. The first plausible value, not swept: an early rehearsal is speculative and a
     push-time one is a push waiting, so 2 slots are always left to pushes. Push-time rehearsals never take it.
3. **The trigger.** `ops\push-main.ps1 -Prepare` fetches (W2.1R step 2's fetch), starts `rehearse-chain.ps1 -Early -Onto
   <origin/main sha>` as a detached process, prints the key and the in-flight file, and returns 0 without moving HEAD or
   running a leg. **`ops/hooks/post-commit`** (D19) runs the same start detached and returns 0 at once. It never blocks
   and never fails a commit, whatever the starter does. It fires only under `CLAUDE_CODE_SESSION_ID`, as W7.2's
   commit-msg check is judged, and NEVER inside a rehearsal: `rehearse-chain.ps1` exports `TC_REHEARSAL_RUN=1` to its
   arm, and the hook exits 0 when it is set. Read first how `Invoke-RhCommitStage` points the clone at hooks: a clone
   that runs `ops/hooks` from the rehearsed tree would otherwise start a rehearsal from inside a rehearsal. Until D19 is
   ruled yes, `-Prepare` is the only trigger, and B22 is not read.
4. **Supersede.** A new early start in a checkout whose in-flight file names a DIFFERENT key writes that run's stop
   file first. A commit that leaves the key unchanged starts nothing and stops nothing, which is the measured condition
   (the first commit carrying the landed key's content). `Invoke-RhProcess`'s wait polls `-StopFile` every 5 s (first
   plausible, not swept); on seeing it, it stops its OWN child tree, writes no verdict, lets its own `finally` remove the
   scratch root, and ends with `CHAIN-REHEARSAL-CHECK-COMPLETE code=3 blind=stopped`. The rehearsal process itself is
   never killed by anyone else. A stop that cannot be written is ignored and the older run finishes (step 0's fallback).
5. **Deliberately not re-triggered on a main move.** An early verdict voided by a later landing is not re-rehearsed in
   the background: that would multiply rehearsals by the landing rate. W9.2 rehearses the stacked tip at push time instead.
6. **The verdict record** gains `early` (bool), `onto`, `head`, `checkout` (hashed as the in-flight file is) and
   `stage_secs` (seconds for clone, checkout, seed, interlock self-test, ship path and commit stage), the one instrument
   the review found the rehearsal lacks (review 7.2). `-CheckPush` and `-ForPush` ignore the new fields.
7. **push-main records** `early_hit` on every chain-touching row: `yes` when the first `-ForPush` of the run found a
   covering verdict whose record says `early`, `no` otherwise, `not-chain` when the push touched no member.
Fixtures (temp bare remote and clones, private slot and early-cap prefixes, a stub chain):
- MUST FIRE: a commit that changes a member starts one early rehearsal onto the fetched origin sha, and its verdict key
  equals the key `-ForPush` computes when that same content is pushed onto that origin.
- MUST FIRE, the measured condition: with origin moved past the commit's base by a commit touching no member, the
  early verdict still covers the push. With origin moved by one that DOES touch a member, it does not.
- MUST NOT FIRE: a commit touching no member starts nothing.
- MUST NOT FIRE: a commit whose rebased key already has a verdict, or an in-flight early run in another checkout,
  starts nothing.
- MUST FIRE, supersede: a second commit that changes the key writes the first run's stop file; the first ends
  `blind=stopped`, its scratch root is gone, and the second runs. CLEAN TWIN: a second commit that leaves the key
  unchanged stops nothing.
- MUST NOT FIRE: a stopped run changes nothing in the verdict store (every file's hash identical before and after).
- MUST NOT FIRE: with `TC_REHEARSAL_RUN=1` the post-commit hook starts nothing.
- MUST NOT FIRE: without `CLAUDE_CODE_SESSION_ID` the post-commit hook starts nothing.
- MUST FIRE: a stack whose cherry-pick conflicts records no verdict and exits 3 with `blind=stack-conflict`.
- CLEAN TWIN: a post-commit hook whose starter throws still returns 0, and the commit exists.
- CLEAN TWIN: `-ForPush` after an early pass of the same content prints PASSED from the recorded verdict and runs no
  rehearsal; the row carries `early_hit=yes`.
- MUST FIRE, the early cap: with 4 early caps held from another process (`lib/mutex-hold.ps1`, private prefix), a 5th
  early run waits, while a push-time rehearsal is still granted a slot.
- CLEAN TWIN: the verdict record carries `early`, `onto`, `head`, `checkout` and a numeric `stage_secs` for every stage.
Mutants: M19 rehearses `HEAD` without `-Onto` (the unrebased variant), which must turn the measured-condition MUST FIRE
red. M20 removes the `TC_REHEARSAL_RUN` guard, which must turn its MUST NOT FIRE red.
Done when: step 0 is reported, both suites exit 0 with their verdict lines and counts, `-VerifyDeclared` passes, the
hook is re-installed from a clean worktree at the landed origin/main (section 5) with `audit-hook-installed` exit 0, and
the first real chain commit afterwards writes an in-flight file. Bars: B22, B21.

**W9.2 The chain queue: each ticket stacked on the one ahead (replaces W6.1's lease).** Files: new `lib/chain-queue.ps1`,
`ops/push-main.ps1`, `ops/rehearse-chain.ps1` (reads the stack file of W9.1 step 1), `.claude/rules/ops-and-gates.md`
(the lock order, 16.6). Needs W6.0, W9.1 and W9.3.
1. **Who joins.** Exactly W6.1 step 1's set: every push-main push whose `-ForPush` child reports it chain-touching, with
   W6.0's union trigger, INCLUDING a `-NoRehearsal` or `TC_NO_REHEARSAL` push, because skipping the rehearsal does not
   stop it voiding the tickets behind it.
2. **`lib/chain-queue.ps1`** reuses `lib/gate-slots.ps1`'s ticket functions (`New-TcGateTicket`,
   `Test-TcGateTicketLive`, `Get-TcGateQueueAhead`, `Remove-TcGateTicket`: arrival order, liveness by the ticket's mutex,
   dead tickets swept) and NEVER `Enter-TcGateSlots`: the queue grants no slot and excludes nobody from running a leg.
   Read `lib/gate-slots.ps1` first; if the ticket functions cannot be called without a slot grant, factor them out in
   this commit with gate-slots' own self-test green. It takes `-Prefix` and `-QueueRoot` seams and REFUSES the
   production prefix whenever `$env:TC_CHAIN_QUEUE_SELFTEST` is set; push-main's `-SelfTest` sets it.
3. **The ticket record**, beside each ticket, written with `Write-TcAtomicFile`: `ticket`, `pid`, `checkout`, `base`
   (the origin sha it stacked on), `range` (the shas of `<merge-base>..HEAD`, oldest first), `state` (`rehearsing`,
   `ready`, `swapping`, `landed`, `left`), `rh_key` (the manifest key of its stacked tip) and `updated_utc`. A ticket
   rewrites its record whenever its HEAD moves (a catch-up or hand-back rebase).
4. **Stacking.** At join, push-main reads every live ticket ahead, oldest first, and writes a per-run stack file: the
   current origin sha, then the `range` of every ahead ticket whose `state` is not `landed` or `left`. Its push-time
   rehearsal (W9.3's starter) runs `-ForPush -StackFile <file>`, which finds a recorded verdict for the stacked key in
   seconds or rehearses it. **The worktree is NEVER rebased onto an ahead ticket's commits**: only the rehearsal's clone
   applies them, because a ticket that leaves would otherwise land its commits with this push. The legs (run-gates,
   test-auditors) judge the worktree HEAD, which is rebased onto origin only, and judge it again, warm, after the final
   rebase (W9.4), so they always judge the exact tip that lands.
5. **Waiting for the head.** After its legs pass and its catch-up settles, a member waits until every ticket ahead is
   `landed`, `left` or dead, printing its position and the depth every 5 minutes. It holds nothing but its ticket while
   it waits: no gate slot, no rehearsal slot, no push lock. When the ones ahead have landed, it runs W9.4's swap. Because
   only members change the manifest set once W8.3 is live, its final tip's set equals the set it was rehearsed on, and
   the in-lock verdict check passes with no second rehearsal.
6. **Restack, the only re-rehearsal.** When a ticket ahead turns `left` or dies, or rewrites its `range` so that the
   stacked key moves, the member rebuilds its stack file and rehearses once more (`restacks` counts it). A ticket that
   is refused writes `left` before it releases.
7. **A stack conflict is a warning, not a refusal.** When the rehearsal reports `blind=stack-conflict`, push-main prints
   which ticket ahead (checkout and pid) and which files, records `stack=conflict`, and keeps its place. If that ticket
   lands, the member's catch-up rebase refuses it with `phase=catchup`, which is the correct refusal. If that ticket
   leaves, the member restacks.
8. **The wait bound, and it is not a total** (W6.1 step 5's reasoning, carried over). `Get-TcGateQueueAhead` progress
   bounds time WITHOUT QUEUE MOVEMENT: `$ChainQueueStallSec = 3600`, the first plausible value above the longest single
   state a head ticket holds (one rehearsal plus its legs and 3 hand-backs, about 45 minutes), not swept. A waiter that
   leaves a moving queue lands unstacked and voids the tickets behind it, so only a wedged or frozen head times a waiter
   out. A timed-out waiter writes `left`, proceeds exactly as the W2.2R path does, and records `queue=timeout` and
   `queue_ahead` (the head's pid and checkout). It never refuses.
9. **Mode**, a push-main parameter `-ChainQueue`, default `live` from its first commit (D8's ruling that Brad wants a
   thoughtful fix live, not shadowed, carried over to its replacement). `off` never opens the queue and records
   `queue=off`: that is the ROLLBACK, a one-line default flip or `-ChainQueue off` on one push. A queue that cannot be
   created, read or written records `queue=error` and the push proceeds as the W2.2R path does.
10. **The holder token.** While a member holds a ticket it exports `TC_CHAIN_QUEUE_HOLDER`, a token naming the queue
   instance and its ticket, so its own hook child can tell it descends from a member (W8.3, amended). The token names its
   instance, as `TC_PUSH_LOCK_HOLDER` learnt to.
11. **Row fields:** `queue` (`joined`, `off`, `error`, `timeout`, `not-chain`), `queue_pos`, `queue_wait_ms`,
   `queue_ahead`, `stacked_on` (the stack's base sha9 and the count of ahead ranges), `restacks`, `stack`.
12. **READY, proved before the landing commit** (W6.1 step 9's condition, carried over). In the commit message, with their
   outputs: every fixture below passes and push-main `-SelfTest` exits 0 with its verdict line and count;
   `-VerifyDeclared` passes for a `# gate-inputs:` line that names `lib\chain-queue.ps1`, `lib\gate-slots.ps1` and
   `lib\mutex-hold.ps1`; mutants M12, M14, M21 and M22 each turn their named case red from a temp mirror, originals
   md5-identical afterwards; and **the three-push drill**, 3 times, all 3 passing: in a sandbox (a temp bare remote,
   three clones, private queue prefix and root, stub legs, a rehearsal stub that records the tree it judged), three
   chain-touching push-main runs start together. Assert that each stub judged origin plus exactly the ranges ahead of it,
   that all three land in ticket order, and that each has `restacks=0` and a stub rehearsal count of 1. The order is read
   from the queue records and the ledger rows, never from a wall clock.
13. **The watch.** W0.3's `-Cost` prints every `queue=timeout` and `queue=error` row, and W3.4's twice-daily task pages
   on any since its last run (W6.1 step 10, carried over).
Fixtures (every queue a private-prefix instance):
- MUST FIRE, stacking: with a ticket ahead, the member's rehearsal stub judged origin plus the ahead ticket's range plus
  its own, not origin plus its own.
- MUST FIRE, ordering: a member whose legs finish first does not take the push lock until the ticket ahead has landed.
  A probe from another process reads the ahead ticket `landed` before the member's first lock take.
- MUST FIRE, restack: a ticket ahead that is refused (its runner stub exits 1) turns `left`, and the member rehearses
  once more onto origin alone, with `restacks=1`.
- MUST NOT FIRE, the safety case: after a ticket ahead leaves, the member's landed commit has none of that ticket's
  commits among its ancestors, and at no point did the member's worktree HEAD contain them.
- CLEAN TWIN: a member lands after the one ahead with no second rehearsal: the in-lock check reads `covered` and the
  stub rehearsed once.
- MUST NOT FIRE: a non-chain push never takes a ticket, and lands while two members are queued.
- MUST FIRE: a `-NoRehearsal` chain-touching push takes a ticket.
- MUST FIRE, the stack conflict: a member that conflicts with the ticket ahead records `stack=conflict`, names that
  ticket, keeps its place, and is refused `phase=catchup` once that ticket lands.
- MUST FIRE, the timed-out branch: an ahead ticket held by a holder that never changes state (another process) and a
  lowered bound gives `queue=timeout`, `queue_ahead` naming the holder, and a push that proceeds.
- MUST FIRE: with `TC_CHAIN_QUEUE_SELFTEST` set, a call with the production prefix throws.
- CLEAN TWIN: an unwritable queue root records `queue=error`, and the push lands as the W2.2R path does.
- CLEAN TWIN, the rollback: `-ChainQueue off` takes no ticket (a probe from another process sees none throughout),
  records `queue=off`, and the push lands as the W2.2R path does.
- MUST NOT FIRE, the lock order: while a member waits for the head, a probe from another process can take the push lock
  and a gate slot: the ticket holds neither.
Mutants: M12 retargets to "a member takes the push lock before the ticket ahead has landed or left", which must turn the
ordering MUST FIRE red. M14 retargets to "`-ChainQueue off` still takes a ticket", which must turn the rollback CLEAN TWIN
red. M21 stacks on origin alone and ignores the tickets ahead, which must turn the stacking MUST FIRE red. M22 rebases the
worktree, not the rehearsal clone, onto the stack, which must turn the safety MUST NOT FIRE red.
Done when: step 12's READY list is in the landing commit, the landing's own ledger row carries `queue=joined` (or `off`
with the reason) and the first real chain landing afterwards carries every field in step 11. Bars: B6, B10, B20, B21.

**W9.3 The legs run beside the rehearsal (absorbs W2.3).** File: `ops/push-main.ps1`. Needs W2.2R and W9.1 (the stop
file). W2.3 is not built separately: its step 0 readings and measurement, its `-RehearsalStarter` seam, its `Wait()`
rules and its fixtures are W9.3's, with the changes below.
1. **Step 0 is W2.3's step 0**, every reading and the measurement, with one more arm: the rehearsal now starts beside
   run-gates too. Bar, written now: over 3 overlapped runs, **0 test-auditors timeouts** (rc 124 or 3), overlapped
   test-auditors wall at most 1.25 times its median alone wall, AND overlapped run-gates wall at most 1.25 times its
   median alone wall. Same method, alternating arm by arm, extra load only through `ops/cpu-load.ps1`. D1 is decided on
   it, as ruled. If it fails, Brad decides with the numbers (16.8), and until then W2.3's shape (run-gates first, then
   test-auditors beside the rehearsal) is what gets built.
2. **The seam** is W2.3 step 2's `-RehearsalStarter`, whose `Wait()` returns `Code` and `Why` and keeps the sibling's
   marker rule (15.4, W2.3 amended). The starter passes `-StackFile` (W9.2) and a per-run `-StopFile`.
3. **The order.** After the round-1 sync and the seed: call the starter, then run run-gates, then test-auditors, in
   process, then call `Wait()`. So the rehearsal starts at the same moment as run-gates, where W2.3 started it after
   run-gates passed. The default `Wait()` decides exactly as W2.3 step 3 says: an empty `ExitCode` is 3, and a missing
   or disagreeing `CHAIN-REHEARSAL-CHECK-COMPLETE` marker is 3.
4. **A red leg stops the rehearsal.** A run-gates or test-auditors red writes the stop file at once. push-main then
   waits for the child to exit (it never kills it), prints that it is waiting and why, and refuses `refused-gate-red`.
   The child ends `blind=stopped` and records nothing. This removes W2.3's stated cost (a red push waiting up to about 14
   minutes for its rehearsal before refusing) and reverses section 10's "cooperative cancel: NOT BUILT" row. If W9.1's
   step 0 found the stop unsafe, the child is not stopped and W2.3's cost stands, stated in the commit.
5. **Slots.** The child takes a rehearsal slot in its own process, run-gates takes gate slots in its own pool,
   test-auditors takes none, and push-main holds none of them itself while the child runs. Say in the commit that no
   process here holds one pool while waiting on the other, so this is not a nested acquisition.
6. **Every catch-up and hand-back round** uses the same start, run, wait sequence, so the legs also overlap there.
7. **Row fields:** `ta_rc` for every run (W2.3 step 7), `rh_stopped` (bool), and `rh_secs_list` (each round's rehearsal
   seconds, 0 for a reused or found verdict), which B21 reads.
Fixtures: every W2.3 fixture, with its overlap case widened:
- MUST FIRE, overlap: the run-gates stub and the rehearsal stub each wait, through `lib/concurrency-probe.ps1`, until
  both have started. A pipeline that starts the rehearsal after run-gates cannot satisfy it; a 120 s hang guard fails the
  case. (W2.3's test-auditors-and-rehearsal overlap case stays.)
- MUST FIRE, the stop: a red run-gates stub writes the stop file; the rehearsal stub, which polls it, exits
  `blind=stopped` before push-main returns, and push-main refuses `refused-gate-red`.
- MUST NOT FIRE: a stopped rehearsal's refusal is `refused-gate-red`, never `refused-rehearsal` or `refused-rehearsal-blind`.
- CLEAN TWIN: all three legs pass and the lock is taken, with `rh_stopped=false`.
- CLEAN TWIN: a catch-up round overlaps its legs too (W2.3's round-2 case).
Mutants: M6 retargets to "start the rehearsal after run-gates", which must turn the widened overlap MUST FIRE red. M23
removes the stop-file write on a red, which must turn the stop MUST FIRE red.
Done when: step 0's measurement met its bar and D1 is decided, `-SelfTest` exits 0 with its verdict line and count, and
B7, B11 and B20 are read on their dates.

**W9.4 Lock only the swap: the hand-back rule and the 3-round fallback (extends W2.2R).** File: `ops/push-main.ps1`,
the lock phase of `Invoke-TcPushMain` and `Invoke-TcSyncToRemote`'s in-lock call. Needs W2.2R.
1. **Inside the lock**, fetch (W2.1R step 2, with its retry). If origin is the sha the last outside round judged, push:
   the hook then replays the recorded run-gates verdict and the test-auditors pass, which is the not-rebased hold of
   about 25 s (plan).
2. **The hand-back rule.** If origin moved and fewer than `$script:PmMaxHandBacks = 3` hand-backs have run, do NOT rebase
   inside the lock. Release it (`Exit-TcPushLock`), rebase outside it (a conflict refuses with `phase=catchup`), re-run
   the legs on their own keys (W9.3's sequence; run-gates and test-auditors warm, the rehearsal leg found by key when the
   manifest set did not move), and take the lock again. A queue member keeps its ticket and its place throughout. 3 is
   the first plausible value, not swept; when main stops moving, no hand-back runs.
3. **The fallback.** At the cap, rebase inside the lock as `5841e96b1` does today and run the sibling's in-lock verdict
   check as the backstop. The cap is never a refusal: it degrades to the day before, which is what makes the rule unable
   to livelock.
4. **The counters stay apart** (W2.2R step 2's reason). A hand-back counts in `hand_backs`, never in the rehearsal
   budget, unless its rehearsal leg REHEARSED (W0.1R's `rehearsed`).
5. **Row fields:** `hand_backs`, `handback_sec` (outside time spent in hand-back rounds), and `rebase_phases` gains
   `handback`. `inlock` now appears only at the cap.
6. **Cost, stated.** A push is handed back when origin moved in the window from its last outside fetch to its in-lock
   fetch. At 18 landings an hour and a 30 s window that is about 14% of pushes, at one warm keyed round each (about 60 to
   130 s), about 15 s a push on average (review). In exchange the rebased in-lock hold of about 128 s (plan) becomes the
   25 s replay, and the modelled lock utilisation at 18 landings an hour falls from 0.64 to 0.125 (review, from the plan's
   holds). B23 measures it.
Fixtures (the self-test's existing `Enter-TcPushLock` wrapper pattern, `ops/push-main.ps1` :1811 to :1822 at origin/main,
lands a commit on the fake remote immediately before the real take):
- MUST FIRE: a remote that moves just before the in-lock fetch hands the lock back once. No rebase ran while the lock was
  held (HEAD at each release equals HEAD at that take), the row reads `hand_backs=1`, `lock_takes=2`, and it lands.
- MUST FIRE, at the bar: a remote that moves before every in-lock fetch hands back exactly 3 times. The 4th take rebases
  inside the lock, `rebase_phases` ends `inlock`, and the push lands. Never refused.
- MUST FIRE: a hand-back rebase that conflicts refuses with `phase=catchup`, and a probe from another process shows the
  lock free at that moment.
- MUST NOT FIRE: an unmoved origin at the in-lock fetch gives `hand_backs=0` and one take.
- CLEAN TWIN: after the cap's in-lock rebase, the sibling's in-lock verdict check still runs (`inlock_check` is not
  `not-run`).
- CLEAN TWIN: a queue member that is handed back keeps its ticket (a probe from another process reads it live and still
  at the head).
Mutants: M24 rebases inside the lock on the first move (cap 0), which must turn the first MUST FIRE red. M25 sets
`$script:PmMaxHandBacks` from 3 to 4, which must turn the at-the-bar case red.
Done when: `-SelfTest` exits 0 with its verdict line and count, and B3 and B23 are read on their dates.

**W9.5 The dot-source closure in the rehearsal key (replaces W6.2).** File: `ops/rehearse-chain.ps1`
(`Get-RhManifestSet`, `-ListSet`), or `ops/chain-manifest.json`'s derive rule. A chain-touching push. Needs W0.5.
1. **As W6.2 step 1:** derive the set transitively over literal dot-sources, the way `lib/gate-input-key.ps1` derives
   self-test keys. The gap is 45 non-member scripts reached from the 129 member scripts by the review's method (review
   3.8; UNSOUND by leaf name) and 44 by the correctness skeptic's (15.5); 16 of 633 first-parent commits in 7 days touched
   only the gap (review), 15 of 577 by the other count (15.5).
2. **`-ListSet` prints the closure.** Each closure member on its own line, tagged `closure <path> <- <member that
   sources it>`, and the complete line reads `CHAIN-REHEARSAL-LISTSET-COMPLETE files=<n> members=<m> closure=<c>`, with
   n = m + c. So the change in trigger rate is visible (review 7.3).
3. **Why it moves ahead of W9.1, when W6.2 waited for B6.** W6.2 was held back because every extra chain-touching commit
   raised lease contention. The queue's ceiling (16.2) makes that cost small, and design A leans on the key harder:
   an early verdict is trusted for as long as the set does not move, so a set that misses code the chain runs is trusted
   for longer. The review's rule: fix the key's known gap first.
4. **Landing it voids every recorded verdict once**, because every key changes. Land it at a quiet hour and say so in
   the commit.
5. **Named, not fixed:** tracked rule data the chain reads (`commodities.json`, `known-wrong.json`, `stores.json`) is
   outside the key by the design of plan-2026-09-22-7 (review 3.8). A rehearsal of a script change is not re-judged when
   main later changes a ruling. W9.5 does not change that, and the commit says so.
Fixtures: W6.2's four (a dot-sourced `lib/x.ps1` enters the set and a push changing only it needs a rehearsal; a file no
member reaches stays out; a dot-source cycle terminates; `-ListSet` over the real tree prints every member plus the
closure), plus:
- CLEAN TWIN: the complete line's `files=` equals `members=` plus `closure=`, and equals the number of path lines printed.
- MUST FIRE: a closure member is printed with the member that sources it.
Mutants: M11 stands (W6.0). M26 drops the transitive step (one level of dot-source only), which must turn a fixture whose
library is reached through a second library red.
Done when: the self-test exits 0 with its verdict line and count, and `-ListSet` over origin/main is pasted in the
commit with its `closure=` count. Bar: B17 (amended).

### 16.4 What is replaced, and what is amended

| Earlier item | Now | What changes |
|---|---|---|
| W6.1 (the chain lease) | **REPLACED by W9.2** | Not built. `lib/chain-lease.ps1`, `-ChainLease`, `Enter-TcChainLease` and `TC_CHAIN_LEASE_HOLDER` are never written. Its steps 1, 5, 9, 10 and its `off` rollback carry into W9.2 steps 1, 8, 12, 13 and 9. Its CLAUDE.md sentence naming the exception (step 8) is not written |
| W6.1, amended (15.4) | withdrawn with W6.1 | the hand-back drill and the holder token move to W9.2 steps 10 and 12 and W9.4 |
| W2.3 | **ABSORBED by W9.3** | not built on its own; its step 0, seam, `Wait()` rules and fixtures are W9.3's, with the rehearsal also beside run-gates and a stop on a red |
| W2.3, amended (15.4) | stands inside W9.3 | the sibling's q1 to q5 model moves to the `-RehearsalStarter` seam in W9.3's commit |
| W2.2R | **stands, EXTENDED by W9.4** | W9.4 changes only what the lock phase does when origin moved: hand back instead of rebase, up to 3 times |
| W6.2 | **REPLACED by W9.5** | the same derive, plus `-ListSet`'s closure lines, and it moves ahead of W9.1 instead of after B6's read-out |
| W6.0 | stands | W9.2 step 1 needs its union trigger |
| W8.3 | **amended: the lease is the queue** | the zero-wait probe reads the chain queue (`lib/chain-queue.ps1`): while any live ticket exists, a chain-touching push whose inherited `TC_CHAIN_QUEUE_HOLDER` does not name a live ticket is refused in seconds with `PRE-PUSH-REFUSED cause=chain-queue` and a message naming push-main as the route, which joins the queue. The probe acquires nothing. D14's ruling covers it unchanged; its blast radius becomes "up to one queue drain" instead of "one lease hold" |
| W8.2 | amended | a main-checkout chain push through `-ViaWorktree` joins the queue like any other, where 15.5 said it takes the lease |
| W2.1R step 8 | amended reason | a stale checkout's first push after W9.2 would join no queue and could void the tickets behind it; the re-exec is what makes it join |
| W7.1a sentence (2) | stands | "land a chain change only through push-main" now means "join the queue" |
| B6, B10, B14 | amended text | "W6.1" and "the lease" read as W9.2 and the queue; B14 counts chain landings that joined no queue, and plain-push chain landings while a ticket was live |
| section 9, "No lock held across a gate run, with two named exceptions" | **one exception now** | the per-checkout guard only. The chain lease exception is withdrawn, and so is D8's acceptance of it (16.8) |
| section 10, "cooperative cancel of the rehearsal child: NOT BUILT" | **BUILT** in W9.1 step 4 and W9.3 step 4 | unless W9.1's step 0 finds the stop unsafe |
| section 10, "taking the chain lease inside the pre-push hook: NEVER" | reads as the queue | a hook never WAITS on the queue. W8.3's zero-wait probe is not a take |
| section 10, "a total-time bound on the lease wait: NOT BUILT" | reads as the queue | W9.2 step 8, same reason |
| section 8 mutants | M6, M12, M14 retargeted; M19 to M26 added | as each item above says |

### 16.5 Bars, written now

Measured by `ops/probe-push-convergence.ps1` (W0.3 with W0.3b), cited by its blob, over rows from UPDATED copies only
(`pm_blob`), printing the rows it excluded and why. Each value is the first plausible one, not the survivor of a sweep.
Each item's landing commit adds its bars to the probe's literal bars table with the standard 14-day read-out. Under its
minimum N a bar prints its N and gives no verdict. A **mechanism** bar tests a deterministic step, so any counted row is a
defect.

| # | Metric | Stratum, minimum N | Baseline (source) | Bar | Item |
|---|---|---|---|---|---|
| B20 | chain-push wall time: seconds from push-main start to a landed row, for chain-touching landings; (a) rows with `early_hit=yes`; (b) all | (a) at least 5 rows; (b) at least 10 rows | median 1,726 s, p25 1,036, p75 2,964, max 3,968, over 9 landed chain rows on 09-22 and 09-23 (review, time join, 26 of 50 verdicts attributed); B9's chain-touching figure from the soak, recomputed | (a) median at most 300 s; (b) median at most 1,260 s (one rehearsal, review's worst case) and p90 at most 2,400 s | W9.2, W9.3 |
| B21 | repeat-rehearsal share: rehearsal seconds beyond each landed chain change's first rehearsal, over all rehearsal seconds of landed chain changes (`rh_secs_list`, grouped by change as W0.3b groups) | at least 10 landed chain changes | 5,457 of 14,122 s, 30%, over 9 landings (review; an upper estimate, two rows' rehearsals overlapped) | at most 10%; printed beside it, rehearsals per landed chain change, with `restacks` split out | W9.2, W9.1 |
| B22 | the early-verdict hit rate, re-measured live: chain-touching push-main landings with `early_hit=yes`, over all chain-touching push-main landings | at least 20 landings, from copies with W9.1 and D19's hook both live | 6 of 18 push-main (33%), 10 of 23 all (43%), unrebased 6 of 23 (26%) (16.1, SCRATCH) | **at least 30%**, the bar Brad ruled on. Under it at N, W9.1's trigger goes back to Brad with the number (W9.2 to W9.5 stand on their own). Printed beside it: early runs started, superseded, stopped, stack-conflicted and blind, per chain commit. When the trigger stops, the rate falls toward 0 and this bar reads a failure, so it cannot go quiet | W9.1 |
| B23 | lock busy fraction: sum of `lock_held_ms` in a clock hour over 3,600,000; and `lock_held_ms` on rows with `hand_backs` of 1 or more | busy hours (at least 8 push-main landings): at least 5 hours and 50 lock-taking rows | modelled 0.64 at 18 landings an hour and a 128 s rebased hold (review, from the plan's holds); the soak's direct timer recomputes it before W9.4 lands | busy-hour median at most 0.25; median `lock_held_ms` on handed-back rows at most 45 s. Printed beside it: the share of rows that reached the 3 hand-back cap, expected well under 1% (0.14 cubed, review model) | W9.4 |
| B17 (amended) | as 15.6, plus: the share of first-parent commits that are chain-touching, before and after W9.5 | 14 days either side | 16 gap-only of 633 commits in 7 days, 2.5% (review) | as 15.6, 0 mechanism. The share should move by about 2.5 points; a move of more than 7.5 points means the closure over-reaches and the derive is read again before any other W9 item lands | W9.5 |

B6, B7, B9, B10 and B11 are read as written; their items now resolve through the Plan-line rule (16.9).

**The soak is WAIVED (Brad, 2026-09-24 01:00: "Land now, use what we have").** W0.3 step 7's 30 rows are not collected
before Row 2 and Row 9 land. The before-picture is the 2026-09-23 reconstructed analysis (15.3 and the review) plus the 11
schema-2 rows already on the ledger. B3, B7 and B9, whose baselines the soak was to supply, are judged against that
before-picture and are therefore WEAKER bars: any verdict on them says so beside the number.

### 16.6 The lock order

The declared order in `.claude/rules/ops-and-gates.md` gains, in W9.2's landing commit, outermost first:
- `0.` the capture-run mutex, as landed;
- `0a.` the per-checkout guard (W2.1R): zero wait, so it waits on nothing and nothing waits on it;
- `0b.` **the chain queue ticket** (`lib\chain-queue.ps1`). **It is not a lock held across a leg.** It excludes nobody
  from running a leg: while a member holds it, every other push, member or not, runs run-gates, test-auditors and its
  rehearsal freely. The only thing it defers is the next member's SWAP, which `refs/heads/main` serialises already. So
  it serialises the push, never the gate, which is what the 2026-09-12 ruling asks. It sits at `0b` because a holder
  then waits on the push lock, gate slots (its run-gates) and a rehearsal slot (its rehearsal child, another process,
  which is still a wait-for edge). Its own blocking wait, for the tickets ahead, is safe under the blocking-wait rule:
  the ticket ahead never waits on anything behind it, and no holder of the push lock, a gate slot or a rehearsal slot
  ever waits on a ticket. The hook's W8.3 probe takes zero wait;
- `1.` the push lock, `2.` the gate worker slots, as today;
- `2a.` **the early-rehearsal cap** (`Global\tc-rehearsal-early-`, W9.1 step 2), taken only by an early rehearsal and
  always before its rehearsal slot;
- `2b.` the rehearsal slots (`Global\tc-rehearsal-slot-`), placed by W6.1 step 7's reading, which W9.2's commit does:
  read `ops/rehearse-chain.ps1` for any gate-slot or push-lock take made while a rehearsal slot is held; if none, `2b`
  is a peer of the gate slots, never nested with them;
- `3.` and `4.` as today.

The commit names these as first nested acquisitions: ticket over push lock; ticket over gate slots; ticket over a
rehearsal slot; early cap over rehearsal slot. The lease's pairs are never created.

### 16.7 Deliberately not built

| Proposal | Disposition |
|---|---|
| A warm, persistent rehearsal environment (review design C) | NOT BUILT. Setup is under 5% of a rehearsal: a clone, checkout and seed copy took about 10 s against 800 to 1,240 s (review, one probe). It would save at most about 10 to 40 s and add the risk that one rehearsal inherits the previous one's gitignored outputs. W9.1's `stage_secs` turns the 5% into a measurement; revisit only if it reads setup over 15% |
| A stage-memoised rehearsal that re-runs only the chain stages whose inputs changed (review design D) | NOT BUILT. It is sound only with a complete input list per stage, and the stages build paths at run time; the manifest key already missed 44 to 45 dot-sourced scripts before W9.5. It would land combinations nobody rehearsed in exactly the cases nobody can enumerate. Revisit only if stage reads are traced from a real run rather than declared |
| A batched merge train with bisection (review design B, the runner-up) | NOT BUILT. It needs a long-lived runner or a leader election among push-mains, and its latency is worse than A's at today's load (14 to 22 min idle, 21 to 31 mean busy, review). Revisit if chain pushes pass about 20 an hour, where 6 slots stop being enough |
| Re-rehearsing an early verdict in the background whenever main moves | NOT BUILT (W9.1 step 5). It multiplies rehearsals by the landing rate; W9.2 rehearses the stacked tip once, at push time |
| Rebasing a member's worktree onto the tickets ahead | NEVER (W9.2 step 4). A ticket that leaves would land its commits with the member's push |
| Letting a ready member overtake the ticket ahead | NOT BUILT. The member was rehearsed on top of it, and the one ahead was rehearsed without the member, so an overtake lands a combination nobody rehearsed |
| The ordinary-push components the review lists as F (a per-blob cache for whole-tree static audits, splitting the `test-commodity-rules-lib` long pole, re-keying the unkeyed self-tests) | NOT IN THIS AMENDMENT. They are not part of design A and were not ruled; each is its own proposal |

### 16.8 Decisions

- **D8 is superseded.** It accepted a lock held across gate legs as a named exception to the 2026-09-12 ruling. Design A
  holds none, so the exception is withdrawn and never used. Brad's condition on D8, live from the first commit and
  proved ready first, carries over to W9.2 (steps 9 and 12).
- **D1 is carried into W9.3**, decided on W9.3's step 0 measurement, with its bar widened to run-gates (W9.3 step 1).
  If the bar fails, Brad decides with the numbers.
- **D19 (NEEDS A RULING): the early rehearsal's trigger is a `post-commit` hook** in `ops/hooks`, installed box-wide by
  `ops/install-hooks.ps1` and asserted by `ops/audit-hook-installed.ps1`. It is a standing configuration change, which
  is why the review left the choice to Brad. **Recommendation: yes.** The measured hit rate assumed a rehearsal started
  at commit time, and the alternative, a session remembering to run `push-main -Prepare`, is an intention with no exit
  code. The hook starts a detached process and returns at once, fires only under `CLAUDE_CODE_SESSION_ID`, never inside
  a rehearsal, and never fails a commit. Rollback: remove the hook file and re-install. Blocks: B22's read, and W9.1's
  done line for the hook half only.

### 16.9 The Plan-line rule

**Every landing commit carries BOTH ids where one item replaces or re-scopes another**, on the one Plan line, the new
id first: `Plan: design/PLAN-push-derived-conflicts-2026-09-23.md W2.1R W2.1`. The probe resolves a bar's landing as
the first main commit whose Plan line carries the bar's item id as a whole token, and its bars table names the ORIGINAL
ids (B1 names W2.1, B2 and B3 name W2.2, B6 names W6.1, B7 and B11 name W2.3), so a commit that carries only the new id
leaves its bars unresolved forever. For this plan:

| Item | Its Plan line carries |
|---|---|
| W0.1R | `W0.1R W0.1` |
| W2.1R | `W2.1R W2.1` |
| W2.2R | `W2.2R W2.2` |
| W9.2 | `W9.2 W6.1` |
| W9.3 | `W9.3 W2.3` |
| W9.5 | `W9.5 W6.2` |
| W9.1, W9.4 | their own id only: they replace nothing, and their bars (B21 to B23) are added under their own ids |

An item already landed with one id only is not rewritten; its bar gets a result line naming the landing by hand in
section 13.

### 16.10 The new order for the push-main lane

This replaces 15.9's "after the soak, push-main lane" row and its "after W6.1 is live" and "after B6's first read-out"
rows. Everything else in 15.9 stands. One lane, one item landed and verified before the next, because `ops/push-main.ps1`
and `ops/rehearse-chain.ps1` are each touched by several items.

| Step | Item | Why here |
|---|---|---|
| 1 | W2.1R with W8.1 | the pre-flight every later round starts from |
| 2 | W2.2R | the catch-up W9.4 extends |
| 3 | W9.4 | lock only the swap; it helps every push and needs only W2.2R |
| 4 | W3.2 (with W3.4a step 3), then W4.1 step 7 | as 15.9 |
| 5 | W6.0 | W9.2 needs its union trigger (chain-touching push) |
| 6 | W9.5 | the key's gap closes before anything trusts the key for longer (chain-touching push; voids every verdict once) |
| 7 | W9.1 (`-Onto`, `-StackFile`, `-Early`, `-Prepare`, the stop) | the stacking primitive and the stop file W9.3 and W9.2 need; the hook half waits for D19 |
| 8 | W9.3 | legs beside the rehearsal, after its step 0 measurement and D1 |
| 9 | W9.2 | the queue, live, after its READY list |
| 10 | W8.2 | the main checkout joins the queue like any other push |
| 11 | W8.3 (amended) | it reads W9.2's token and queue |
| last | W7.1 with W7.1a | the text follows the behaviour |
