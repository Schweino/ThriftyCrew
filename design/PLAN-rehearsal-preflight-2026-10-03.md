# PLAN: rehearse main before the morning run, not every push (2026-10-03)

Status: **DRAFT for Brad to read before anything is built.** Nothing in this file has been implemented.

## Brad's ruling (2026-10-03, in chat)

Asked "How should rehearsal change?" with four options (pre-flight before 07:00; keep per-push but make it cheap;
both; turn it off), Brad chose **"Pre-flight before 07:00"**: stop rehearsing every push, rehearse main once before the
morning run (and on demand), hold the run and name the commit if it fails. Earlier the same session he ordered the
audit below ("Audit whether it earns its cost") after a 57-minute chain push. This **supersedes D19** (commit-time
rehearsal) and the **W9.2 chain queue** of `design/PLAN-push-derived-conflicts-2026-09-23.md` for the push path; the
per-push rehearsal itself came from RCA F2 of `design/RCA-holistic-2026-09-22.md`.

## In plain words

Every push that touches the daily grocery chain is rehearsed: the whole chain is run over yesterday's real data in a
scratch copy before the push may land. That takes about 18 minutes a push (median of 42), and chain pushes queue
behind each other's rehearsals, so one push this morning took 57 minutes, 26 of them waiting. In ten days rehearsal
has passed 229 times and failed **zero** times. The morning run fails exactly as often as it did before rehearsal
existed, and for different reasons (mostly the bot sharing a checkout with sessions), which rehearsal cannot see.

The fix keeps the protection and moves it to where the damage happens: rehearse `main` once, shortly before the 07:00
run. If it fails, the run is held, nothing publishes, Brad is paged with the commit that broke it, and the board stays
on yesterday's good prices. Pushes go back to landing in about 5 minutes.

## What the audit found

All read-only, 2026-10-03 between 08:20 and 09:00 local. One-off commands, described here because none of them is a
reusable harness; the inputs are the files named, as they stood that morning.

| Finding | Number | Source |
|---|---|---|
| Rehearsal verdicts since it began (2026-09-23) | 229 pass, 29 blind, **0 fail** | `%LOCALAPPDATA%\ThriftyCrew\chain-rehearsal\*.json`, `result` field, 258 records |
| push-main rows with a rehearsal outcome | 239: 135 not-needed, 99 rehearsed-pass, 3 could-not-rehearse, 2 bypassed; **0 refused for a failed rehearsal** | `%LOCALAPPDATA%\ThriftyCrew\push-ledger\pushes-*.jsonl`, `rh_outcome` |
| Time in rehearsal | `ship` stage median **1,089 s**, min 775, max 1,626 (42 records over 2 days); was 645 s in `design/MEASURE-daily-chain-stages-2026-09-09.md` | `stage_secs.ship` in the verdict records |
| Where a rehearsal's time goes (one run, 08:03 to 08:19 local) | history banking **444 s of 913 s logged**; recipe overlay 160 s; feed export 100 s; Family Fare link fill 59 s | the live rehearsal's `grocery\out\logs\chain-stages-2026-10-03.jsonl` in its scratch root |
| History banking in production | 250 s (10-01) and 352 s (10-02), **reconciled=0** both days over 30 and 29 weeks | `grocery/ad-cycle-log.txt`, the `update-history:` marker; the log holds only those two days |
| Landing time, last 24 h | non-chain median **5 min** (n=19); chain (rehearsed) median **19 min**, max 58 (n=16) | push-ledger, `run` start to `ts` |
| The 57-minute push (sleepy-sutherland-cc4748, 08:17Z) | checks 7.5 min, rehearsal 24.5 min, queue wait 26 min, catch-up 5.5 min, lock 21 s | its push-ledger row |
| Morning runs with a FAILED LANE | before rehearsal **14 of 18** (09-03 to 09-22); with it **7 of 9** (09-24 to 10-02) | `grocery/out/logs/capture-run-daily-*.log`, last `FAILED LANES` line |
| What the 09-24 to 10-02 failures were | shared main checkout (sync blocked, pre-push refused on another session's leftovers), deploy timing, watchdog wording; **none found** of the F2 shape (a pushed chain change breaking on real data) | 184 distinct items in `grocery/triage-plans/plan-2026-09-24*` to `plan-2026-10-02*`, read by `root_cause` |
| Can rehearsal fail at all? | yes: its self-test carries the founding defect (an emptied `cost-flags.txt`) as a MUST FIRE | `ops/rehearse-chain.ps1` lines 1306-1311 |

**What this does and does not show.** It shows the cost is large and steady, and that no push has been stopped. It
does not show rehearsal is worthless: the F2 class went quiet in the same week other fixes landed, so the zero cannot
be credited to rehearsal or to its absence. That is why the plan keeps a rehearsal and moves it, rather than removing it.

Files read, at origin/main fad7c40c1 (blobs, so a rebase cannot move them): `ops/rehearse-chain.ps1` 7f0827da9,
`ops/push-main.ps1` 065ac60d7, `ops/hooks/pre-push` 3cc6bd839, `ops/hooks/post-commit` 80cce6aaf,
`lib/chain-queue.ps1` 9bc219f26, `grocery/check-ad-cycles.ps1` 9ea9773b6, `grocery/update-history.ps1` 502b5e144.

## Design

**One rule: no chain run starts on code that has not passed a rehearsal over fresh data.** Today that rule is enforced
at push time for every chain push. After this plan it is enforced at RUN time, once, for the commit the run is about to
execute. The verdict store, the key (the manifest set of the commit) and the freshness bar are reused unchanged.

1. **Pre-flight task, ~06:10 local.** A new scheduled task runs `ops/rehearse-chain.ps1 -Preflight` against
   `origin/main` in a scratch clone (rehearse-chain already clones; never the main checkout). It records the verdict
   under the commit's key exactly as a push-time rehearsal does today. About 18 minutes, so it is done before 07:00.
2. **Run-time check.** `capture-run.ps1` (07:00 and 08:00, and any hand run) asks `rehearse-chain.ps1 -CheckRun` for
   the commit it is about to execute, in seconds, before the chain starts. Three answers:
   - **pass** recorded for this key over fresh data: run.
   - **no verdict** (something landed after 06:10 that touches the chain): rehearse now, then decide. The run starts
     late by about 18 minutes on such a day, and only on such a day.
   - **fail**: hold. Nothing publishes, the board stays at its last good state, one page names the failing stage.
3. **Naming the commit.** On a fail, rehearse the chain-touching commits since the last pass, up to 6 at once in the
   existing rehearsal slots, and put the first failing one in the page. When there is one candidate (the usual case)
   this costs nothing extra.
4. **The push path sheds rehearsal.** `push-main`'s rehearsal leg, the pre-push `-CheckPush` refusal, the chain queue
   and the post-commit early rehearsal are switched off by default. Each keeps its code and a switch for one release so
   the rollback is a flag, then is deleted in a later change.

## Work items, in order

| Id | What | Done when |
|---|---|---|
| W1 | `rehearse-chain.ps1 -Preflight` and `-CheckRun` modes over the existing verdict store and key; `-CheckRun` never rehearses unless asked with `-RehearseIfMissing` | self-test: MUST FIRE a recorded fail holds; MUST FIRE no verdict with `-RehearseIfMissing` rehearses; CLEAN TWIN a fresh pass runs in seconds; at-bar and one-past-bar cases on the 2-day freshness bar |
| W2 | `capture-run.ps1` calls `-CheckRun -RehearseIfMissing` before the chain; a fail holds the run with one page | self-test with a stub verdict store; the hold path pages once and publishes nothing |
| W3 | Scheduled task `TC Chain Preflight 0610` through the headless wrapper, registered in `ops/` task registry | `Get-ScheduledTask` shows it Ready; one real run records a verdict for origin/main's key |
| W4 | Fail bisect: rehearse each chain-touching commit since the last pass (up to 6 in parallel), name the first failing | fixture with three commits, the middle one bad, names the middle one |
| W5 | Push path: `push-main -Rehearse off` and `-ChainQueue off` become the defaults; pre-push skips `-CheckPush`; post-commit starts no early rehearsal | push-main self-tests updated by case NAME; a chain push lands with no rehearsal and no queue in a sandbox drill |
| W6 | One week later, after Brad says so: delete the switched-off code and its fixtures | separate change |

W1 to W4 land before W5, so there is never a day with neither protection. W5 is the change Brad will feel.

## Cost

Today: about 10 chain rehearsals a day at about 18 minutes (99 in ten days), plus queue waits of up to 26 minutes on a
push. After: 1 rehearsal a day, plus one on a day something chain-touching lands after 06:10, plus a bisect only on a
failure. New machinery: one scheduled task and two modes of an existing script; three mechanisms (the per-push leg, the
chain queue, the early rehearsal) leave the push path.

## Decisions for Brad

- **D1. When the 07:00 run finds code landed after the pre-flight, should it wait about 18 minutes to rehearse it, or
  run on the last rehearsed commit?** Recommendation: wait. Running older code means checking out a second copy of the
  pipeline and is where new bugs would come from; a late board on a rare day is the cheaper failure.
- **D2. On a failed pre-flight, hold the whole run, or run everything except publishing?** Recommendation: run
  everything except publishing, so captures still happen and the morning's prices are not lost, while nothing broken
  reaches readers.
- **D3. Separately and later: make the history re-check incremental** (only weeks whose board changed). It is the
  slowest step of the real morning run too, 4 to 6 minutes that fixed nothing on both days measured. Not part of this
  plan; recommended as its own small change.

## Rollback

Every step is a flag until W6: `push-main -Rehearse live -ChainQueue live` restores today's push path, and disabling the
pre-flight task plus `capture-run -NoPreflightCheck` restores today's run.

## Knowledge consulted

- searched `"push lock queue status pane"`, `"claude code plugin mod hook statusline"`, `"rehearsal ship stage slow minutes"`.
- `skills/reliability-craft/MAP.md` section 7: "In a staged pipeline latency is owned by the **slowest stage**". Used:
  the ship stage is 95% of a rehearsal (1,203 of 1,269 s in the 08:03 verdict record), and one step is half of that.
- `skills/concurrency-craft/applies-here.md`, "Landing a push on the shared ThriftyCrew main": `refs/heads/main` is one
  compare-and-swap shared by many sessions. Used: serialising chain pushes behind each other's rehearsals multiplies
  the wait, which is the 26 minutes measured.
- `design/MEASURE-daily-chain-stages-2026-09-09.md`: ship=645 s then. Used as the baseline the 1,089 s median is
  compared against.
- `.claude/rules/measurement.md` ms-01 and ms-07: every rate above carries its denominator, and the files read are cited
  by blob.
