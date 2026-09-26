# Q-recall-judgement-queues: the nightly memory pass waits on your judgement

**The question.** The knowledge store's nightly pass (TC Recall Sleep 0435) exits nonzero while judgement queues are
unruled. Rule on them now and keep that rule, or change what a waiting night reports?

Raised by 2026-09-23-a83841, carried in `grocery/triage-plans/plan-2026-09-25-4.json` and `plan-2026-09-26.json`.

## What I checked

`C:\Users\Owner\.claude\recall-sleep-latest.md` (run of 2026-09-26 11:07), and the scheduled task's last result:

- **Scheduled task:** last run 2026-09-26 12:35, result **1**.
- **forgetting (exit 1, waiting on a judgement):** 10 sections never opened after 5 or more offers across 3 or more
  sessions, of which **1 unruled**; 0 reflexes below the 0.60 standing. Mark 0.
- **memory clusters (exit 1, waiting on a judgement):** 25 clusters, of which **2 unruled**; 11 cross-project
  clusters, 0 unruled. Mark 0.

Matches your numbers (1 forget candidate, 2 clusters). On 09-25 it was 9 unruled clusters, 2 cross-project and 1
forgetting candidate, so the queue has been worked down since.

**Separate from the judgement queues, the same run's gate is BROKEN for two reasons no ruling here fixes:** dangling
memory links in the ThriftyCrew store rose to 4 against a mark of 3, and MEMORY.md links one file git does not track
(`the-board-has-three-dates.md`). Those need a session to fix the link and commit the memory store. Even if every
queue is ruled, the task stays at exit 1 until they are.

## Options

- **A. Rule on the queues now** (`recall-forget` for the 1 candidate, `recall-consolidate` for the 2 clusters) and
  keep the rule that a waiting night is nonzero. The task goes green once the gate's two BROKEN causes are also fixed,
  and pages again whenever new memory writing adds a cluster.
- **B. Keep the queues for a weekly sitting,** and let a night whose only failures are waiting judgements exit 0 with
  the counts in the report. Fewer red nights; the queue can grow quietly between sittings.
- **C. Move the marks to today's counts** so only growth pages. Green now, but 3 items are never judged unless they grow.

## Recommended (best long-term): A

The 4fc24c ruling that a waiting night is nonzero is the only thing that makes a judgement happen; B and C both turn
a queue that needs a person into one nobody reads, which is the "an intention has no exit code" failure. The queue is
small today (3 items, down from 12 on 09-25), so ruling now is cheap.

## What executes once ruled

- **A:** you (or a session you sit with) run `recall-forget` on the 1 candidate and `recall-consolidate` on the 2
  clusters, writing each cluster's gist; separately a session fixes the dangling link and commits
  `the-board-has-three-dates.md` in the memory store; next 04:35 run should exit 0.
- **B:** a change to the recall-sleep exit rule so a waiting-only night exits 0, with a fixture for a waiting night
  and a broken night.
- **C:** the two marks are moved to 1 and 2; nothing else.
