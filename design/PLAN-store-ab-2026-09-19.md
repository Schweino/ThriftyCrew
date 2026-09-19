# PLAN: does searching the knowledge store produce better code? A paired replay, 2026-09-19

Brad, 2026-09-19: "I think we should do this and see what happens." The question is his: the store
citation check proves a search happened and a Store: line was written, and says nothing about whether
the code came out better. Over the three hours before this plan, 22 code changes landed; about 2 show a
visible fingerprint of a store section, at least 9 citations were written after the code, and no
store-versus-no-store comparison has ever been run here. This is that comparison, as a pilot.

## Knowledge consulted

- `experiment-craft/effect-size-and-power.md`, "Having paired the design, do not then run the unpaired
  test": the arms share tasks, so the analysis is on per-task differences, and the per-task verdict is
  recorded for every arm (one row per case per arm), never as totals.
- `synced/skill-creator/agents/comparator.md` and `SKILL.md` "Blind comparison": the judge sees two
  outputs labelled X and Y and is not told which produced which.
- memory `cc-ai-can-judge-code-given-a-rubric`: a code verdict needs a rubric AND the context; both are
  handed to the judge in writing.
- memory `pick-the-best-run-is-selection-on-noise`: the within-arm spread is measured (two same-arm
  pairs) before any between-arm gap is believed.
- `.claude/rules/measurement.md`: bar before the run, denominators, one row per case per arm, name the
  harness and cite blobs.
- `experiment-craft/applies-here.md` section 4 (within-pairs design), `growth-craft/applies-here.md`
  section 3 (threshold before the data).

## Design

**Unit.** A task is a real change that already landed or was built this week, replayed from the commit
just before it. Both arms get the same worktree base, the same prompt, the same model, and the same
instruction files (global CLAUDE.md, project CLAUDE.md, `.claude/rules`, the memory index).

**The one difference.** Arm S (store) may search and read `~/.claude/skills`. Arm B (blocked) is
refused by permission deny rules on any Read of that tree and any shell command naming it. Hooks are
disabled in BOTH arms (`disableAllHooks`), because the recall hooks inject store sections
automatically and the agent-spawn hook appends store pointers to every spawned prompt; with hooks on,
arm B would receive the store anyway. Probed before this plan: under the blocked settings the global
and project CLAUDE.md are present, no hook output appears, and a Read and a PowerShell command against
the store are both denied.

So what is measured is the marginal value of **deliberate store search** on top of the always-loaded
rules and memories. Automatic recall is off in both arms and is not what this measures.

**Tasks (6), each checked for leakage** (the store and the memory directory are grepped for the fix's
own identifiers; a task whose answer is written down anywhere either arm can read is dropped):

| id | reference fix | base | area | store at the time |
|---|---|---|---|---|
| T1 capture cursor slice | eb98181f2 | 23ef8f58a | grocery PS | cited concurrency-craft 31 |
| T2 heartbeat held-vs-dead | baece0f29 | e6309fd58 | grocery PS | "nothing applicable" |
| T3 price tie-break | efc9c335f | 7695b84c1 | grocery PS | none cited; the store names the unstable Sort-Object |
| T4 graph import atomicity | 2c6a2b5b5 | 2c250d017 | graph Python | "designed from the store" |
| T5 stale identity edges | 522a9046f | e92d64fee | graph Python | "nothing applicable" |
| T6 memory-backup self-test offline | 015d207cb | 8038bb2cb | ops PS | cited test-design 8 |

Dropped: the propagate scope refusal (4ab747b98), because the memory `propagate-has-no-slugs` was
updated afterwards and states the fix, and both arms would read it.

**Noise floor.** T3 and T4 are each run a second time in arm S (S and S'), and the S-versus-S' pair
goes to the judges exactly like a real pair, unlabelled. If the judges find a consistent winner
between two runs of the same arm, they are seeing noise, and the between-arm verdicts are read against
that.

**Runs.** 8 headless `claude -p` sessions (6 tasks x 2 arms, plus 2 repeats), model `claude-opus-5`,
permission mode bypass with the deny rules above, each in its own worktree at `C:\Codex\tc-exp-<code>`
under a random code that does not name the arm, seeded with `ops\seed-worktree.ps1`. Arms do not
commit, do not push, do not run `run-gates`, and write nothing outside their worktree. The store arm's
searches are logged to an experiment log (`RECALL_LOG`), not the weekly report's. Transcripts are kept
as stream-json.

**Judging.** For each pair, two judges (fresh headless sessions, hooks off, store blocked so the judge
cannot reward a store-shaped answer for being store-shaped), one with S as X and one with S as Y. Each
judge gets the task statement, both diffs with store citations scrubbed from comments (replaced by
`[citation removed]`), both arms' self-test exit codes as run by me, and read access to the repo at the
base commit. It does NOT get the reference fix. Rubric, 1 to 5 per dimension with one line of evidence
each:

1. **Correctness** - fixes the stated problem, no regression, edge cases handled.
2. **Traps avoided** - this estate's known failure modes: a silent pass, a could-not-look scored as
   pass or fail, PS 5.1 traps, exit codes, partial writes, concurrency.
3. **Fit and reuse** - uses what exists rather than rebuilding it; reads like the surrounding code.
4. **Test strength** - a must-fire on the founding bug, a must-not-fire or clean twin, and whether the
   tests would go red with the fix reverted.
5. **Scope** - the change stays inside the task.

Then an overall verdict: X, Y or TIE, where TIE means the difference would not change which one a
careful reviewer merges.

**Pair verdict.** S wins a pair only if both judges pick S; B wins only if both pick B; anything else
is a TIE. Position bias therefore cannot manufacture a win.

**Contamination.** A B-arm transcript that shows any store content reaching the model voids that pair
(it is reported, not rescored). An S arm that never searched is kept and reported as "treatment not
taken", because that is part of the answer.

## Acceptance bar, written before any arm is run

Over the 6 real pairs, let `d = S wins - B wins` (TIEs count for neither).

- **HELPS, worth a larger run:** `d >= 4`. (5-0 or 6-0 with ties is what a sign test would call
  unlikely under no effect, one-sided p = 0.031 and 0.016; 4-0 is p = 0.0625 and is accepted at this
  pilot's bar because the decision it drives is only "run a bigger one".)
- **NO DETECTABLE HELP:** `d <= 1`.
- **INCONCLUSIVE:** `d` of 2 or 3.
- **Noise override:** if BOTH S-versus-S' pairs return a consistent winner, the verdict is
  INCONCLUSIVE whatever `d` is, because the judges separate two runs of the same arm as readily as the
  two arms.

Secondary, reported and not tested: per-dimension paired score differences (S minus B, the mean of the
two judges), and for each S arm which store sections it opened and whether a design decision in its
diff traces to one (read by me after unblinding, stated as my reading).

**What n = 6 can and cannot say.** It can see a large effect. It cannot see a small one, and
NO DETECTABLE HELP at this size is not "the store does not help"; it is "not by enough to show in six
tasks". The tasks are replays of fixes this estate already found, so they lean toward the problems
the estate's rules already describe, which favours arm B.

## Outputs

- `design/MEASURE-store-ab-2026-09-19.md` - the result, the harness blobs, every number with its
  denominator.
- `design/store-ab-2026-09-19-cases.jsonl` - one row per task per arm per judge.
- Worktrees removed after the diffs and transcripts are saved.

## Blast radius

None on the live estate: nothing is committed by an arm, nothing is pushed but this plan and the
result documents, no board, page or graph.db is written. Cost is agent time: 8 build sessions and 16
judge sessions.
