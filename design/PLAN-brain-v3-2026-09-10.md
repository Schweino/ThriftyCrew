# PLAN brain v3 - one episode record, memory recall with precision, and a judgement lane that runs

Written 2026-09-10 after PLAN-brain-v2 closed. Three builds, chosen by Brad from four ("can we do the first
three?"). Each has blast radius - what every learner reads, what every prompt injects, and the nightly GPU
schedule - so this file comes before the code, and every bar below is written before its run.

## Status block - the builder updates this after every build

| Build | Name | Status | Commit | Measured |
|---|---|---|---|---|
| E | One turn-keyed episode record | NOT STARTED | | |
| M | Memory recall with a precision layer | NOT STARTED (needs E's cases) | | |
| J | A judgement lane that runs, and a ruling inbox | NOT STARTED | | |

---

## 0. What v2 measured that these three answer

- **Every learner re-joined a dozen logs by hand, and each hit the same join failures.** Census 2026-09-10:
  `recall-log.jsonl` 3,095 rows of which 587 carry a `turn`; `recall-reflex-log` 879, `recall-reflex-outcome`
  550, `recall-failure-log` 2,676 and `recall-consulted-log` 191 carry none; only `recall-structural` (12) does.
  Per-cue weights found **2 opens in 419 turn-keyed offers**, and nothing can say whether sections go unused
  or the open counter misses reads. The store's own note (`reliability-craft/applies-here.md` section 4) already
  ruled that every row carries `sid` plus `agent`; nothing carries the per-prompt correlation id.
- **Memory never reaches a prompt by relevance.** The prompt hook's lexical path searches the skills corpus only.
  Adding memory corpora as-is cost a consult hit and raised off-topic firing (proxy) from 5 to 7 of 13.
- **Every judgement queue drains only when a person sits down.** 60 alias proposals 20 days old, 27 approved
  patches unapplied, 13 cross-project clusters and 7 failure classes unruled. The dream skipped its model pass
  because none was up at 04:35, and none can be: the card is an RTX 5070 Ti with 16,303 MiB, 10,688 MiB in use
  by day, and the local model's weights are 12.2 GiB. **The model only fits inside the nightly window.**

## 1. Build E - one turn-keyed episode record

**The property.** One correlation id threaded through every row a turn produces, and one derived record per
turn that every learner reads instead of re-joining logs.

**E0 - prerequisite, NOT MINE TO COMMIT.** The turn id on open rows comes from edits to
`skills/recall-log-open.py` that a session left **uncommitted on 2026-09-09 09:42**, with its probe
`skills/recall-join-probe.py` untracked. They are live on disk - 568 open rows, some with `turn` - and in no
commit, so any checkout loses the join. **Needs Brad's OK to commit, or the owning session to finish it.**
Build E stands on it either way and says so.

**E1 - one shared stamp.** `recall_core.current_turn(payload)` reads the per-session turn sidecar the prompt
hook already writes, and returns `(turn, parent_turn)`: a subagent never receives a prompt, so its own sidecar
is empty and its rows carry the PARENT session's current turn as `parent_turn`. Every writer stamps both:
reflex fires, reflex outcomes, the consulted hook, the correction hooks, the leg and timing rows. Rows written
before the change are not backfilled and are counted as such.

**E2 - the footer says what it used.** The consulted hook records the items named after `Consulted:`,
normalised to store paths where they resolve, beside whether a footer existed. Today it keeps no text.

**E3 - the episode table.** `recall-episodes.py`, a sleep step, derives one row per `(sid, agent, turn)`: the
cue tokens, the offers with score and leg, the opens and how, the footer's named items, reflex fires and
blocks with their outcome verdicts, failures assigned to the turn whose sidecar time precedes them in that
session, a correction on the NEXT turn, and commits. Derived and rebuildable, never hand-edited; totals are
derived from the rows (backlog E24).

**E4 - settle the open question.** For turns whose footer names a store section, count how many also carry an
open row for it. Bar, before the run: if footers name sections with no open on **more than 20%** of such turns
over **at least 30** of them, the open counter undercounts and gets fixed before any learner trusts opens; under
30 named turns the answer is NOT READY, with the date the rate projects.

**Bars for E.** (1) A cross-hook proof in the self-test, like the join probe: prompt, reflex, open, outcome,
footer and correction rows from one redirected session all carry the same turn. (2) After 3 days, at least 95%
of main-session rows from each stamped writer carry a `turn`, printed per writer with its denominator.
(3) Every turn id in the prompt log has exactly one episode row. (4) At least one learner reads episodes, with
its number before and after, and the two agree or the difference is explained.

## 2. Build M - memory recall with a precision layer

**Depends on E**, because the only honest labelled cases are real turns where a memory was opened or named in
a footer. Hand-written memory probes would be the author grading their own recall.

**M1 - labelled cases from episodes.** `(prompt cue, memory used in that turn)` pairs, `source: episode`, plus
negatives: the 13 hand-written off-topic prompts, and turns where a memory was offered and not used. **Bar
before measuring: 30 pairs across 10 sessions.** Short of that, the build reports NOT READY with the date.

**M2 - a memory leg behind a precision layer.** Candidates from this project's memory corpus, scored against
descriptions; a floor derived from the labelled cases and the off-topic set, registered in
`sidecar/THRESHOLDS.md` if it is a score; at most ONE memory pointer per prompt; the sidecar's cross-encoder
reranks when it is up, and the lexical floor alone applies when it is not. Behind a flag, default OFF.

**Open design question for Brad, stated not assumed:** `MEMORY.md` is always loaded, so every memory's index
line is already in context. A pointer adds relevance ordering and the memory's own description at the moment
it matters, not new existence. M3 measures whether that ordering changes what gets used.

**M3 - measured through the real hook.** `recall-scale-harness.py` runs `recall-hook.py` as a subprocess with
redirected logs, so injection is the hook's true decision, not a proxy. Bars, before the run:
right-domain@1 on the labelled skills probes does not fall (paired McNemar, b > c at p < 0.05 fails);
recall@4 does not fall; off-topic injection stays at **4 of 13** or under through the real hook; memory hit@3
on M1's cases is at least **50%** and above the no-memory arm; hook latency p95 stays under the existing
1,000 ms bar. Fail any: the flag stays off and the file records why.

## 3. Build J - a judgement lane that runs, and a ruling inbox

**J1 - the dream gets its model inside the nightly window.** A nightly stage after stage 5b, while llama-server
is up, runs the dream (`~/.claude/skills/recall-dream.py`) against the local endpoint with a reserved slice,
`DREAM_RESERVE_MIN = 20` (a first plausible value), and its existing cap of 40 items. The resolve stage's
budget shrinks by that reserve. The 04:35 sleep dream then KEEPS a packet a model wrote in the last 12 hours
instead of overwriting it with a skipped one. Ruling R3 holds: local model, no cloud spend.
**Built AFTER tonight's nightly (2026-09-10 21:30)**, the first run with 6,222 contested questions, so the
reserve is set against a measured resolve baseline and not a guess. If resolve ends PARTIAL tonight, the
reserve is a trade with graph adjudication and comes back to Brad with the numbers.

**J2 - one ruling inbox.** `recall-inbox.py`, a terminal walk through every item across both halves:
forgetting candidates and memory clusters (their owners' ruling commands), failure classes, shadow-proven
reflex drafts, memory drafts (accept = move into the store plus a MEMORY.md line; delete), and the graph's
alias proposals (verdicts collected into the file `stage2_review.py --ingest` reads; `--apply` stays gated by
its shadow evaluation). Each item shows its evidence and the model's proposal if any. **Nothing runs until the
end**: the inbox prints the exact commands it will run, asks once, runs them, and logs every ruling with who
confirmed it. A terminal first, because a page cannot run local commands and a click on one would still need a
session to apply it; a phone page is a later surface.

**J3 - the digest points at it.** The morning mail gains one line: how many items wait in the inbox, oldest
first, and the command.

**J4 - the digest's native calls, and a banner nobody saw.** `[CORRECTED 2026-09-10]` This section first
said the "System error" record in the digest's transcript came from the run-log library stopping a transcript
that was not running. A probe of the library alone produced no such record, so that was wrong. What the probes
DID prove: (1) `& $PY script 2>$null` under `$ErrorActionPreference = 'Stop'` turns any stderr line from the
child into a terminating error in PS 5.1 - the digest made four such calls, so one warning would silently read a
queue as UNKNOWN - and the digest now routes them through a helper that discards stderr without throwing;
(2) `Start-RunLog` wrote its banner with Write-Output, so all six callers captured banner plus path, no
transcript ever showed its start line, and capture-run.ps1 recorded the glued string as its log path - it now
writes the banner to the host. The exact "System error" wording is still unexplained and is recorded as such.

**Bars for J.** J1: the first night after it lands writes a model packet with a proposal on at least one item
of each kind present, or states why per kind; resolve's questions settled that night are reported beside the
2026-09-10 baseline. J2: its self-test drives every ruling kind against temp stores and a temp packet, proves
no command runs without the final confirmation, and proves every applied ruling is logged; a live dry run
lists the real queues with counts matching the digest's.

## 4. Order

1. **E** now, and **J2 to J4** alongside it - neither depends on the other.
2. **J1** after tonight's nightly reports.
3. **M** when E's episodes hold 30 labelled memory pairs across 10 sessions.

## 5. Decisions only Brad can make

| # | Question | Default here |
|---|---|---|
| V1 | Commit the 2026-09-09 uncommitted turn-join edits to the open logger? | Not committed by this build; E is built on them and flags the risk |
| V2 | May the dream take a reserved slice of the nightly window from graph adjudication? | 20 minutes, set after tonight's baseline and returned to you if resolve ends PARTIAL |
| V3 | Is a memory pointer worth injecting when MEMORY.md already lists every memory? | Measured by M3; not assumed |
