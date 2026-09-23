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

**RULED 2026-09-23 (Brad, section 12 has each ruling): build all 8 rows. Every recommendation in section 12 is the
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
thoughtful fix and ready to go"*. W6.1 steps 4, 9 and 10 carry what that means.

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
