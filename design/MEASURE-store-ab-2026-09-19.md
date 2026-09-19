# MEASURE: does searching the knowledge store produce better code? Pilot result, 2026-09-19

The plan and its acceptance bar landed before any arm ran: `design/PLAN-store-ab-2026-09-19.md`, on
origin/main at 17712906a. This is what the run found, measured against that bar and nothing chosen after.

## The verdict against the pre-registered bar: INCONCLUSIVE, on both counts

| | count |
|---|---|
| real pairs (store arm S against blocked arm B, same task, same base) | 6 |
| S wins (both judges picked S, arm order swapped between them) | 4 (T1, T4, T5, T6) |
| B wins | 1 (T2) |
| ties (the two judges disagreed) | 1 (T3) |
| d = S wins - B wins | **3** |
| same-arm pairs (S against a second S run) with a consistent winner | **2 of 2** |

The bar said `d >= 4` HELPS, `d <= 1` NO DETECTABLE HELP, 2 or 3 INCONCLUSIVE. `d = 3`. Separately, the
noise override was written to fire if BOTH same-arm pairs returned a consistent winner, and both did. So
the verdict is INCONCLUSIVE by the bar's own arithmetic and by the override, independently.

**The override is the finding worth keeping.** Two runs of the SAME arm on the SAME task were told apart
by both judges, in both orders, as decisively as the two arms were. On T4 the losing S run had a real
defect: its derive-phase savepoint is released by commits inside the resolve and state stages, so every
nightly `--observations` run would mark the live index incomplete and exit 1. That judge caught it and
its sibling S run did not have it. On T3 the losing S run moved a tied crown onto a membership-only club
and left the golden regression guard red. **Run-to-run variance in what an agent builds is at least as
large as anything the store did here**, which means a single run of a single session is not evidence
about the store in either direction, and the Store: line on one commit cannot be either.

## Post hoc, labelled as such, and it does not change the verdict

T2's S arm never searched the store (0 searches), so that pair compared two runs without the store and
is the "treatment not taken" case the plan said to keep. It is also the only B win. Leaving it out is a
choice made after seeing the result, so it is not the verdict: over the other five pairs S won 4, B 0,
tie 1, and the mean paired rubric total (S minus B, mean of both judges, out of 25) was +1.0, against
+0.17 over all six. Even taken at face value this is 4 of 5 at n = 5, one-sided sign-test p = 0.0625 on
the four decisive pairs, beside a noise check that says the judges separate same-arm runs just as
readily. It is a reason to run the larger version, not a result.

## What the arms did

| | |
|---|---|
| build runs | 14 of 14 finished, 14 of 14 left a change (6 tasks x 2 arms, plus 2 repeat S runs) |
| self-tests of changed files, run by the organiser afterwards | 23 files across 14 runs, every one exit 0 |
| S runs that searched the store | 7 of 8 (T2 did not) |
| searches in S runs | 29, a median of 4 per run that searched |
| distinct store files opened in S runs | 4 (`algorithms-craft/applies-here.md`, `database-craft/sqlite-engine.md`, `database-craft/transactions-and-recovery.md`, `data-quality-craft/moving-data-in-flight.md`) |
| B runs that tried to reach the store | 6 of 6 (17 calls into the store) |
| of those calls, refused by the deny rules | 17 of 17. One further call matched the audit pattern, a Grep of the repo's own `.claude/skills/lesson` script, which is project code, not the store |
| B runs contaminated | 0 of 6 |

Every B run tried the store first, because the global CLAUDE.md tells it to, and paid a few turns for
the refusals. That is part of what "the store is unavailable" costs and is inside the B numbers.

## Did the store visibly shape the winners? My reading, after unblinding

- **T5 (stale identity edges), plausibly yes.** Both judges preferred S for scoping a retraction to "what
  the read can vouch for": an edge is removed only when the namespace's manifest proves a complete
  snapshot. The S run searched "moving data in flight upsert delete reconcile" and opened
  `data-quality-craft/moving-data-in-flight.md`, whose CDC section sets a full snapshot against delete
  tracking. The idea is there; whether the run would have reached it anyway is not observable.
- **T6 (memory-backup self-test offline), confirmed rather than supplied.** The S run's loopback
  HttpListener fixture is what both judges rewarded, but its own search query already named "loopback
  HTTP listener / test double seam" before any result came back.
- **T4 (import atomicity), not traceable.** It searched four times and opened nothing; both judges
  preferred S for refusing to export from an incomplete index. The reference fix from 2026-09-18, which
  was designed from `database-craft/transactions-and-recovery.md`, has the same shape. The S run that
  won this pair never opened that file; the repeat S run did open it, and built the regression above.
- **T1 (capture cursor), not traceable.** The rewarded idea, a bounded, counted escape constant fixtured
  at and past its bar, is in `.claude/rules/ops-and-gates.md`, which both arms had.

So of four S wins, one plausibly traces to a store section, one used the store to confirm an idea it
already had, and two do not trace to it at all.

## Deviations from the plan, all stated

1. **The plan said 8 build sessions; the design it describes is 14** (6 tasks x 2 arms + 2 repeats). The
   arithmetic in the plan's "Runs" paragraph was wrong; the design table was run as written.
2. **The first judge launch hit the account's usage limit** (every judge returned 429, "session limit,
   resets 8am"). No judge had judged anything; the 16 were relaunched unchanged at 08:09 and those
   outputs are the ones scored. The failed attempt is not in this directory.
3. **5 of 16 judges wrote malformed JSON** (unescaped quotes in free-text evidence). Their `scores` object
   (integers only) and `verdict` token were intact and are read by a fallback that the scorer names
   (`T2-SB-o1`, `T3-SB-o2`, `T4-SB-o2`, `T6-SB-o2`, `T4-SS-o1`); their evidence text is not scored by
   anything and is recorded as unparsed.
4. **My collector first ran the Python self-tests without `--selftest`**, which printed usage and exited
   2 in both arms alike. It was fixed and re-run before any judge saw a result; the judges saw exit 0.
5. **The scrub removed 1 line in total**, a pre-existing context line in `docs/CONTROL-CONSTANTS.md` in
   a B patch. No S patch cited the store in its code, so the blinding the scrub was built for was not
   needed, and the arms were not distinguishable by citation.

## What this can and cannot say

It cannot say the store helps, and it cannot say it does not. At n = 6 it could see only a large effect,
and the noise check says a judge separates two runs of one arm as readily as the two arms. It does say
three things the Store: line cannot:

- A run that searched and a run that did not are both usually green; every changed self-test in all 14
  runs exited 0, so "the tests pass" does not distinguish them either.
- A search is not a read: 7 runs searched 29 times, and 4 of them opened a store file (4 distinct files).
- Variance between two runs of the same session is large enough to flip a verdict, so a per-commit
  judgement of whether "the brain helped" is not a measurement.

**What a decisive version would need, sized from this run:** each task run at least 3 times per arm, so
the within-arm spread is measured per task and the comparison is arm means rather than single draws, over
at least 10 tasks; that is about 60 build sessions and, at two judges per comparison, about 60 judge
sessions, roughly four times this pilot. Not started; that is Brad's call.

## Harness and evidence

Everything is in `design/store-ab-2026-09-19/`: `tasks.json`, both prompt templates, `map.json` (run code
to arm), `judges.json`, `cases.jsonl` (one row per judge per side, 32 rows), `score-output.txt`,
`store-use.txt`, every run's raw patch under `patches/` and its self-test results under `tests/`. The
harness scripts are kept as `.txt` under `harness/` so no tree walk mistakes them for live code; they
ran from a scratch copy. Blobs of what ran:

| blob | file |
|---|---|
| 31db506eeac60a5fc3b4145e3423949ed1b28a98 | harness/setup-and-launch.ps1.txt |
| c45f50d6811183819eabe315ac7fcfa10491b115 | harness/collect-one.ps1.txt (after the two fixes in deviations 4) |
| 11a2334fa4b25f1f121ce24a99abe006e8fa3888 | harness/judge-launch.ps1.txt |
| f238caeb7ce7f1907cec2407b60e7aef6960dc6e | harness/score.py.txt (with the fallback in deviation 3) |
| 15eabae56fbe562e89f6cd7195292a82b7746286 | harness/arm-blocked-settings.json |
| 394eec96784980b6b5778cc71080293ae470acce | harness/arm-store-settings.json |
| ae8fbc6b5981d6889f9a462655850c70d2ab8678 | tasks.json |
| 6186cc904ef6613c536873e7ce8c842a12c2f2ca | prompt-template.txt |
| 324acb2dd51f8ed9ded90b5d6ce4c59f427bd1ab | judge-template.txt |

Model `claude-opus-5` for every build and judge session, Claude Code 2.1.236, hooks disabled in all 30
sessions. Worktrees `C:\Codex\tc-exp-*` removed after collection.
