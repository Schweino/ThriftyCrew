# PLAN: the brain, v2 - everything the learning system still lacks to work like one, and the build for each

**Status: PROPOSED, not built. Written 2026-09-09 at Brad's direction. Plan only. Nothing here is
built. Written for an Opus session to code out, one workstream at a time, each gated on a measurement
whose bar is written in this file before the run.**

> Brad, 2026-09-09: *"review our entire brain/learning system and list off literally everything still
> needed to be like a human brain. Brains learn every day, we learn from mistakes and errors as soon as
> they happen, we constantly look for better and more efficient ways to do things."*

This plan covers BOTH halves of the brain, because they are one loop and have been reviewed as two:

| Half | Where | What it learns about |
|---|---|---|
| The personal store | `C:\Users\Owner\.claude\skills\` (its own git repo), the memory stores under `C:\Users\Owner\.claude\projects\*\memory\`, the hooks in `C:\Users\Owner\.claude\settings.json` | how Claude works: what to recall, what to refuse, what Brad corrected |
| The estate | `C:\Codex\ThriftyCrew\` - `graph/learning`, `ops/`, `grocery/`, `sidecar/`, the daily chain | what the data means: aliases, wrong products, alert precision, gold |

**Read these four before building anything. They are the previous reviews and each one records what
was measured, what was refuted and what waits. This plan does not restate them; it extends them.**

- `~/.claude/skills/course/PLAN-brain-parity-2026-09-07.md` - seven brain properties, all seven built
- `~/.claude/skills/course/PLAN-whole-brain-2026-09-08.md` - the ten-stage loop, five organs
- `~/.claude/skills/course/PLAN-learn-from-mistakes-2026-09-08.md` - the reflex ladder, all six builds done
- `~/.claude/skills/course/PLAN-does-the-store-help-2026-09-08.md` - the one honest number, not built

## Status block - the builder updates this after every workstream

| WS | Name | Status | Commit | Measured |
|---|---|---|---|---|
| 0 | Repair the starved stages | NOT STARTED | | |
| 1 | Sense organs that do not depend on phrasing | NOT STARTED | | |
| 2 | Learn from a mistake the moment it happens | NOT STARTED | | |
| 3 | Metacognition: a claim of absence is refused without a search | NOT STARTED | | |
| 4 | Plasticity per cue | NOT STARTED | | |
| 5 | Sleep v2: an OS clock, a red that pages, a dream, a morning digest | NOT STARTED | | |
| 6 | Encoding at write time: memory lint, cost, index integrity | NOT STARTED | | |
| 7 | Forgetting v2: memories, verdicts, holds, conclusions all expire on evidence | NOT STARTED | | |
| 8 | Generalisation: across projects, across domains, across negatives | NOT STARTED | | |
| 9 | Efficiency-seeking: an effort ledger and habits mined from success | NOT STARTED | | |
| 10 | The estate closes its loops: gates, alerts, gold, phantom citations | NOT STARTED | | |
| 11 | One nervous system: a brain report over both halves, with floors | NOT STARTED | | |

---

## 0. The state on 2026-09-09, measured before writing

Every number here was read today by running the tool named, not quoted from a document. Re-run them
before building; several move daily.

### 0.1 The personal store, from `recall-brain.py` and the logs

| Stage | Live | What it means |
|---|---|---|
| perceive | 1 correction recorded in 40 turns; 0 recurrences | the only human-sourced signal fires on 1 turn in 40 |
| retrieve | 2026-09-08: 723 semantic, 0 lexical. 2026-09-09: 0 semantic, 208 lexical | **the sidecar on 127.0.0.1:8077 has been down all day** and nothing restarted it |
| prompt hook latency | p50 3,195 ms, p90 3,339 ms, max 5,131 ms over 157 rows | against a pre-registered bar of **200 ms p95**. Two sidecar calls at a 1.5 s timeout each, paid on every prompt while it is down. Nothing reads the timing rows |
| act | 658 fires, 15 rows: 9 remind, 2 rewrite, 5 block | works; it blocked this session twice, correctly |
| observe | 226 of 658 fires resolved: **0 burned, 226 fine** | the outcome hook is `PostToolUse`, which **does not fire on a failed call** (measured, `automatic-recall.md`). Burned is zero by construction |
| learn | **0 events**. hold 4, insufficient 10, silent 2 | no rung has ever moved on evidence, and the tool that would move one (`recall-reflex-ladder.py`) is in neither the sleep pass nor the gate |
| answer outcome | 160 turns, 2 corrected, 158 unchallenged | silence counted as an absence, correctly; the signal has almost no input |
| propose | 31 drafts, 61 recurring-failure MISSES the table has nothing for | a person rules; none has been ruled since 2026-09-07 |
| consolidate / forget | 17 clusters and 17 candidates, 0 unruled on 09-08; **2 unruled on 09-09 and the sleep pass went red on it** | the human half worked once, on the day Brad sat down to it |
| sleep | ran 04:37, **14 of 16 steps, RED** (forgetting exit 1, gate exit 1), nothing committed, nobody told | two steps added 09-09 (`pointer check`, `self-corrections`) have never run inside a pass. The task is a Claude scheduled agent, not a Windows task, against Brad's own rule for routines |
| memory store | 156 files; **1 carries a `cost`**; 82 unique slugs cited from rules/agents/skills/design, so 74 are cited by nothing | the un-backfillable field ruled on 09-07 is not being written, and nothing refuses a memory without it |
| pointer ratchet | `recall-pointer-baseline.json` unlinked = 37; set at 15 the same morning | a mark that may only go down was accepted upward twice in one day |
| self-map | `knowledge-search/automatic-recall.md` section 2 lists six hooks; nine are installed | the file whose subject is the hooks is wrong about the hooks |

### 0.2 The estate, from the surveys and the files

| Loop | Live | What it means |
|---|---|---|
| `graph/learning` Stage 1 | runs nightly; `proposals.json` = applied 159, proposed **60**, rejected 18, held 5 | every applied row is dated 2026-08-20/21; the 60 pending accrue since 08-21. **Stage 2 has no scheduler and no caller but a README line** |
| gold scoreboard | `graph/eval/eval-runs.json` latest run **2026-08-21** | the README rule "re-score after any change" is a sentence |
| model lane | `contested: 0 of 20,478`; 0 model calls; all 4,141 question verdicts and 3,092 cell-state rows stamped 2026-08-21 | the GPU window scores nothing new; no verdict expires |
| gold provenance | 189 of 6,476 corpus rows come from a recorded failure; `hunter-gold.jsonl` is 281 MATCH, **0 NO_MATCH** | a corpus with no negatives cannot measure over-firing |
| generalisation | `local_triage.py --cluster-rejections` and `lint_adjacency.py`: **zero callers** | the two engines that turn 3,755 negatives into classes are built and unwired |
| corrections | 148 alerts, 139 resolved, 15 dispositioned; 14 alert types all "too few to state a precision"; `board-price-overrides.json` fixes 9 cells | a correction changes one cell, one row, one report; **no parameter anywhere reads a precision** |
| control constants | 10 in `docs/CONTROL-CONSTANTS.md`; 7 say "not recorded", 3 say "first plausible value"; **0 auto-tuned** | the only threshold computed from data in the estate is `sidecar/lib_match.py calibrate()` |
| red gates | `run-gates.ps1` has one caller (the pre-push hook), no history, no alert, no queue entry | a red gate is a terminal line and a blocked push; nothing counts it, nothing turns it into a fixture |
| phantom guard | `ops/audit-hook-installed.ps1` **does not exist**; cited by `CLAUDE.md`, `ops/hooks/pre-push`, `ops/hooks/pre-commit`, `ops/install-hooks.ps1`, `ops/test-precommit-hook.ps1` | the property "the gate runs on every push" rests on an untracked file asserted by a guard nobody wrote |
| transcripts | read by `graph/pipeline/scorecard.ps1` and `lane-tokens.ps1` for tokens only | the richest outcome record the estate produces is a billing meter |
| incidents | one incident record in the repo's life; template shipped 09-08; no trigger | the detective and responsive halves of an RCA have no habit behind them |
| conclusions | 14 `design/EVAL-*` and `MEASURE-*`; 5 say nothing is ordered; 3 record themselves wrong; no index, no expiry, no harness back-link | two confounded verdicts stood for months and were caught by luck (`check-ad-cycles.ps1` "THE MEASUREMENT WAS CONFOUNDED"; `EVAL-hunter-wall-clock` 44) |

### 0.3 The one-sentence diagnosis

**The brain has excellent perception of its own plumbing and almost none of its outcomes, its
judgement queues drain only when Brad sits down, and every measurement that could move a parameter
ends as a printed string.** It observes itself 13,944 times (the row count across `~/.claude/recall-*.jsonl`)
and has changed one number because of it (`MIN_SCORE`, 9.0 to 8.5). That is a brain that keeps a
perfect diary and never reads it.

---

## 1. The rubric: what a brain has, and where this system stands

Property list from the memory literature, not the metaphor, extended past the seven of 2026-09-07
with the properties found missing today. Verdicts are HAVE, PARTIAL, MISSING, and each names the
workstream that closes it. Section 12 of the brain-parity review still stands: confabulation,
recency-over-importance, retelling-strengthens and emotional flooding are NOT copied.

| # | Property | The brain | Here | Verdict | WS |
|---|---|---|---|---|---|
| 1 | Sense organs for outcomes | a burn is felt without anyone saying "that burned" | tool failures cannot reach the outcome join (`PostToolUse` never fires on failure); human corrections need one of six phrasings; wrong claims that exit 0 are invisible | PARTIAL | 1, 3 |
| 2 | Prediction error gates encoding | surprise encodes, routine does not | the failure harvester and the proposer are this, for actions; for answers and for the estate, nothing | PARTIAL | 1, 2 |
| 3 | Learning at the moment of the mistake | the hand withdraws on the burn, not at the next review | a failure becomes a draft at 04:35 and a rule when a person rules; corrections are ruled "by repetition across sessions", which is right for prose and wrong for a cue | MISSING | 2 |
| 4 | Habit from repetition, both signs | a burn makes a flinch; a success makes a habit | reflexes are mined from failures only; nothing turns a repeated successful sequence into a command or a skill | PARTIAL | 9 |
| 5 | Retrieval strengthens what it retrieves (per cue) | the association between THIS cue and THAT memory | global use-weight measured and refuted (103 to 70 right-domain); per-cue version waits on data the offer log only started carrying 09-07 | PARTIAL | 4 |
| 6 | Active forgetting | prunes on evidence, expires on time, and the survivors retrieve better | sections and reflexes forget by ruling; memories, question verdicts, promotion holds, EVAL conclusions and rules-file claims never expire | PARTIAL | 7 |
| 7 | Episodic to semantic | the episode fades, the lesson stays | built and ruled once; the pointer half orphaned three lessons the first day; 7 deferrals cannot fade into a rules file or CLAUDE.md | PARTIAL | 6 |
| 8 | Cost at encoding | "cost me a day" encodes harder than "cost me a retry" | the field exists; 1 of 156 memories carries it; nothing refuses a memory without it | MISSING in practice | 6 |
| 9 | Metacognition: knowing you do not know | a tip-of-the-tongue state; a claim carries its confidence | `Consulted:` is enforced; six claims of absence in one session were wrong and nothing refused them | PARTIAL | 3 |
| 10 | Interoception: noticing a faculty has stopped | you notice you cannot see | the semantic leg was down all day and the brain report calls it "normal"; the nightly ran red and nobody was told; two floors are uncalibrated | MISSING | 0, 5, 11 |
| 11 | Homeostasis: effort has a budget the body feels | fatigue is a signal | a 200 ms latency bar exists and the hook runs at 3.2 s with no reader; no ledger of tool calls, retries, wall time or tokens per task | MISSING | 9 |
| 12 | Sleep: offline replay, mechanical AND judgement | the dream re-runs the day and files it | the mechanical half runs nightly; the judgement half waits for Brad; on a red night nothing pages | PARTIAL | 5 |
| 13 | Curiosity: looks for a better way unprompted | tries the alternative when the cost is low | `RECALL_EXPLORE` explores below the floor on retrieval only; nothing proposes a faster path for a slow one | MISSING | 9 |
| 14 | Generalisation and transfer | a lesson in one place applies in another | memory is per project (ThriftyCrew 156, workspace 191, income 5, Fantasy 0) and nothing moves a lesson across; the estate's negative-clustering engines are unwired | MISSING | 8 |
| 15 | Social learning: from the person | corrections, rulings, praise all encode | six phrasings; rulings live in `design/` and are joined to code by a ratchet; praise is not a signal and should not be (retelling-strengthens) | PARTIAL | 1 |
| 16 | Inhibition: knowing when not to fire | most of cortex suppresses | `must_not_fire`, fire-rate caps, floors as cost controls | HAVE | - |
| 17 | Anticipation: act before the burn | withdraw on the cue | `PreToolUse` rungs, and they work | HAVE | - |
| 18 | Working memory is tiny, long-term is vast | seven items | pointer design, 20 KB session budget | HAVE | - |
| 19 | Truth maintenance: contradiction is noticed | two beliefs that conflict itch | `[CORRECTED]`/`[REFUTED]` marks by hand; twin-drift and ruling-drift audits in the estate; nothing checks a rules-file claim is still true, nothing joins a changed harness to the verdicts measured through it | PARTIAL | 7, 10 |
| 20 | Motor loops close: sensing drives acting | reflex arcs, not reflex reports | in the estate every measurement ends in a log: ratchet trend, alert precision, calibration emitter; 0 of 10 constants auto-tuned | MISSING | 10 |
| 21 | One nervous system | every organ reports to one place | `recall-brain.py` covers the personal store; the estate has `health-heartbeat` for tasks and nothing for learning; no view puts both on one page | MISSING | 11 |
| 22 | Immune memory: a failure class is recognised as a class | the second infection is met faster | `INCIDENT-TEMPLATE.md` has a "the class" section and one record ever; failure signatures cluster but never name a class in the estate | PARTIAL | 2, 10 |

**Twelve of twenty-two are PARTIAL and six MISSING.** The three HAVEs are the three the first review
built well. The dependency is again the finding: **properties 3, 5, 6, 12 and 13 all wait on property
1**, because a brain cannot learn at the moment of a mistake it cannot feel, and today it cannot feel
a failed tool call, a wrong claim, or a red gate.

---

## 2. Rules for every workstream, carried in from the estate's own rules files

These are not restated in each section. A build that skips one is not done.

1. **The acceptance bar is written here before the run**, in the metric's own units
   (`.claude/rules/measurement.md`). A bar moved after seeing the number is recorded as moved, with
   the reason, as the brain-parity review did for gap 1.
2. **Every rate prints its denominator.** `examined N of M`. Never a bare percentage.
3. **One row per case per arm**, totals derived from the file. Every new log is `.jsonl`, one event
   per row, raw values, never a mean, never a pre-bucketed histogram (backlog I81).
4. **Every detector ends with `<NAME>-COMPLETE`** as its last line, carries a
   `SCOPE OF A CLEAN REPORT:` line saying sound or unsound, and prints what its target set RESOLVED
   to (backlog I39). Python detectors get `--selftest`, and the self-test never greps its own source.
5. **Fixtures carry three labels with three jobs**: `MUST FIRE` (the founding bug), `MUST NOT FIRE`
   (a legal input), `CLEAN TWIN` (an adjacent behaviour that still works, a positive assertion).
6. **No gate red on day one.** Anything with a backlog arms as a ratchet with a high-water mark that
   may only go DOWN, refuses a fall to zero and a fall over `-MaxDropPct`, keeps the old baseline and
   SAYS it refused (`lib/ratchet.ps1`).
7. **Every threshold says what it does when the producer stops.** If the answer is "goes quiet", the
   floor ships in the same change (backlog I80). This plan adds floors to every queue and every rate.
8. **A tuning constant records what else was tried** (backlog I94). A first plausible value says so.
9. **A one-way actuator has a rate limit and a plausibility bar**, keeps the old state on refusal,
   and speaks the refusal (backlog I93, `docs/CONTROL-CONSTANTS.md`). Every new constant goes in that
   register with its direction and its stop behaviour.
10. **A measurement names its harness and the commit it ran at** (backlog I47).
11. **Hooks fail OPEN, write their heartbeat on the way IN, key state on `session_id` plus
    `agent_id`, and never inject the same section twice in a session.** `recall_core.py` owns these.
12. **A hook that cannot fire is worse than none.** Before wiring any hook event, prove it fires with
    a probe row, the way `PostToolUse`-on-failure was disproved.
13. **Cue tables, not classifiers**, for anything that labels Brad's words or mine: precision is
    measured per cue against real traffic with `--rate`, and a cue over its cap is refused.
14. **Judgement stays with a person unless a ruling says otherwise, and a default never dies**
    ([[mint-loop-is-closed]]): the machine may execute an APPROVED ruling itself; it may not invent
    one. Where this plan proposes automatic acceptance it says exactly what threshold Brad rules on.
15. **No em dashes. No fabricated numbers. Commit messages from a file with `-F`.** Verified work is
    committed and pushed without asking; a commit not ready to push does not go on `main`.
16. **`[string]::Equals(..., Ordinal)` and `[StringComparer]::Ordinal` for anything that arrived
    from outside.** PowerShell `-ne` ignores a NUL.
17. **Windows scheduled tasks are the only routines that fire** (Brad, 2026-08-22,
    `grocery/expected-automations.json`). Every schedule this plan adds is a Windows task, registered
    through `ops/install-grocery-tasks.ps1`'s `$OWNED` table or a sibling registrar, declared in
    `expected-automations.json`, and therefore watched by `health-heartbeat.ps1`.

---

## 3. Workstream 0: repair the starved stages

**Why first.** Nine of the other eleven workstreams read a number that today is wrong or absent for
a mechanical reason. Building on them would be building on the confound that
[[check-the-commit-clock-behind-a-recorded-measurement]] warns about.

### 0a. The outcome join that can see a failure

**Defect.** `recall-reflex-outcome-hook.py` runs on `PostToolUse`, which the store's own measurement
says does not fire when a tool call fails. So `burned` is zero for every fire, forever, and the ladder
in `recall-reflex-ladder.py` can never promote on burn. The brain report shows this as
`observe: 0 burned, 226 fine` and reads it as health.

**Build.** A second outcome source that reads the transcript, joined by the same key.

- `recall-failure-harvest.py` already pairs `tool_use` with `tool_result{is_error}` and keeps the
  command. Add to each harvested failure row the `recall_reflex.command_hash` of its command and its
  transcript timestamp (both computable from what it already reads).
- A new step in `recall-sleep.py`, `join outcomes`, runs `recall-reflex-outcome-join.py`: for every
  fire row in `recall-reflex-log.jsonl` with no resolution, look for a harvested failure with the same
  `chash` inside a 120 s window in the same session; write `verdict: burned` rows into
  `recall-reflex-outcome.jsonl` tagged `via: "transcript"`. Fires with no failure and no PostToolUse
  row stay `unresolved`; count an absence, never judge one.
- **First, probe whether the harness now has a failure-side event** (`PostToolUseFailure` or any
  event that fires on `is_error`): run a command that exits 42 under a probe hook and look for the
  row, exactly as the 09-07 measurement did. If such an event exists, wire the existing hook to it
  as well and keep the transcript join as the backfill. Record the probe result in
  `knowledge-search/automatic-recall.md` section 2 whichever way it goes.

**Bar, before the run.** Over the existing 658 fires: the join resolves at least 30 fires to
`burned` OR prints, per unresolved fire, why (no transcript, no failure, outside window). Fixtures:
MUST FIRE - a fire whose command failed 5 s later in the same session resolves `burned`; MUST NOT
FIRE - a failure 10 minutes later with the same hash does not resolve it; CLEAN TWIN - a fire the
PostToolUse hook already resolved `fine` is not overwritten.

### 0b. The sidecar watchdog and the circuit breaker

**Defect.** `sidecar/app.py` on 127.0.0.1:8077 is started by hand, has no watchdog, and was down all of
2026-09-09. While down, every prompt pays two 1.5 s timeouts (`recall_semantic.py` `TIMEOUT`), the
intent hook goes silent by design, and the leg log records `lexical` all day, which `recall-brain.py`
labels *"the sidecar was down, which is normal"*.

**Build.**

- `ops/sidecar-watchdog.ps1`, a Windows task every 15 minutes: `GET /health`; if down and the GPU
  window is not held by `TC Graph Nightly Matching` (read `graph/out/logs/graph-nightly-status.json`
  for a running stamp; the nightly owns the card 21:30 to 06:30), start `sidecar/app.py` the way
  `sidecar/README.md` documents, then re-probe. Registered in `$OWNED`, declared in
  `expected-automations.json` proving a dated stamp file, so a dead watchdog is itself paged.
  **Open ruling for Brad (section 15): whether the sidecar may run during the nightly GPU window.**
  Default here is NO, and the hook falls back to lexical during those hours by design.
- A **circuit breaker** in `recall_semantic.py`: after two consecutive timeouts, write
  `~/.claude/recall-sidecar-state.json` `{down_since, next_probe}` and skip the sidecar for 60 s,
  probing once per minute. The hook then costs the lexical path (about 4 ms warm) instead of 3 s.
- `recall-brain.py` retrieve line changes its parenthetical: a day with 0 semantic offers and more
  than 20 lexical ones is reported as **DEGRADED: sidecar down N hours**, never "normal".

**Bar.** Prompt-hook p95 under 200 ms with the sidecar down, measured over 50 real prompts from the
timing rows (`ev: "timing"`), harness `recall-hook.py` at the commit named in the status block. A
new `check-skills.py` check reads the last 100 timing rows and fails above 1,000 ms p95 (a hard
gate, because 200 ms would be red on day one with the sidecar up; the ratchet then lowers it).

### 0c. The ladder runs, and every step of the sleep pass runs

- Add `recall-reflex-ladder.py` to `recall-sleep.py` as step `ladder` (report only, no `--rule`;
  the split fixture still passes).
- Run the two never-run steps (`pointer check`, `self-corrections`) once by hand, read their exit
  codes, and fix whatever they say before the next scheduled pass.
- `recall-pointer-baseline.json`: the mark went 15 to 37 in a day. Rule on the 37 (write the
  backlinks or record why not), set the mark to the ruled remainder, and add the ratchet's refusal
  (`lib/ratchet.ps1` semantics) to `recall-pointer-check.py` so it cannot be raised without a
  `--accept-mark <reason>` that is logged.

### 0d. Calibrate the two blind floors, or silence them honestly

`recall-floors.json` reports `path 0 of 17` and `prompt 4 of 17` as TOO FEW PROBES TO JUDGE. The intent
and path surfaces are gated by numbers nobody can defend. Either harvest enough probes (the probe
harvester already reads transcripts; the deficit is that few transcripts carry those payload shapes)
or set both floors to `FALLBACK_FLOOR` explicitly with `_meta.reason` and have `recall-brain.py`
print them as UNCALIBRATED. Bar: 100 holdout probes per kind, or the honest label.

### 0e. The self-map is corrected

`knowledge-search/automatic-recall.md` section 2 lists six hooks; nine are installed. Rewrite the
table from `settings.json`, and add a `check-skills.py` check that the table's script names equal the
set in `settings.json` (a MUST FIRE for a missing row, a CLEAN TWIN for the current table). The file
whose subject is the hooks must not be wrong about the hooks.

---

## 4. Workstream 1: sense organs that do not depend on phrasing

**The brain.** Pain does not require the injured person to say "ouch" in one of six ways.

**Here.** Every human-sourced signal is a cue table over Brad's words (six cues, 1 fire in 40 turns).
Every machine-sourced signal is an exit code, and roughly eight wrong claims on 2026-09-09 exited 0.
`PLAN-does-the-store-help` stated the principle: **an outcome signal must not depend on how anybody
phrases anything**, and proposed two signals that read artefacts. Neither was built.

### 1a. Structural corrections, from what Brad DOES rather than says

New rows in `recall_correction.py`, each a **structural** cue rather than a phrase, each with its own
`--rate` precision on real transcripts and a cap:

| cue id | fires when | evidence it reads |
|---|---|---|
| `repeat-request` | Brad's turn is within 0.8 token-set similarity of one of his last three turns and follows an assistant turn | the transcript alone |
| `quoted-back` | Brad's turn quotes 8+ consecutive words of the assistant's previous message | same |
| `undo` | Brad's next turn arrives inside 3 minutes and a git revert, `checkout --`, or a re-edit of a file the assistant wrote in that turn follows within the session | transcript plus `git reflog` of the cwd |
| `hand-edit` | a file the assistant wrote or edited this session has an mtime later than the assistant's last write and the session has no tool call touching it | the filesystem, checked at `Stop` |
| `plan-rewritten` | a `design/PLAN-*.md` the assistant wrote is edited by a non-Claude process before the next session opens it | same, nightly |

`hand-edit` is the one Brad named: *"time spent hand-editing is a signal that something belongs in the
process"*. Recorded per file, with the diff size, never the diff.

**Bar.** Over the last 25 transcripts (the same corpus `recall_selfcorrection.py` measured against):
each new cue under its cap; the union of all cues fires on between 5% and 15% of Brad's turns; and
in one labelled session at least 6 of the 8 corrections the whole-brain plan listed as vanished are
caught. Written as a fixture per row.

### 1b. Estate events become perceptions

The estate produces objective outcome events that no learning stage reads. One append-only bus,
`ops/out/events.jsonl` (gitignored; it is data), one row per event, written by the thing that
already knows the event happened:

| event | written by | fields |
|---|---|---|
| `gate-red` | `ops/run-gates.ps1` on exit 1 or 3 | gate names, exit, commit, branch, who (hook or hand) |
| `alert-closed` | `grocery/triage-close.ps1` | type, disposition, age-at-close |
| `known-wrong-added` / `-reversed` | the writer of `known-wrong.json` | commodity, store, product, retire_when |
| `override-pinned` | `generate-board-overrides.ps1` | cell, board_was, source |
| `hold-added` / `-recheck` | `promote_aliases.py` | commodity, factor, verdict |
| `sleep-red` | `recall-sleep.py` | failed steps |
| `hunter-qa-fail`, `mapper-ruling` | already in `meal-prep/db/ingredient-events.jsonl`; mirrored, not duplicated |

`ops/audit-event-bus.ps1` ratchets that every writer above still writes (a MUST FIRE per producer: a
day with a red gate and no `gate-red` row fails), and it carries a floor: a bus with 0 rows in 3 days
while the daily chain ran is a dead bus, exit 1.

**What reads it**: WS 2 (a class is a cluster of events), WS 7 (expiry), WS 10 (actuators), WS 11
(the report). Nothing acts on a single event.

### 1c. The session leaves a trace without anyone writing a memory

**The brain** keeps a hippocampal trace of the day whether or not anything was worth remembering; the
dream decides. **Here**, a session leaves a trace only if Claude hand-writes a memory, which is why
three of five corrections on 09-08 vanished.

A `SessionEnd` hook (probe the event fires; if it does not, `Stop` with a 30-minute idle test)
writes one row per session to `~/.claude/recall-session-digest.jsonl`: session id, project, turns,
tool calls, failures (from the failure harvester's signature set), reflex fires and verdicts,
corrections (WS 1a), self-corrections, files written, commits made, memories written, the first
prompt's first 200 characters. **No prose, no judgement, no model call.** It is the raw material
for WS 5's dream and WS 9's effort ledger. Retention: the file is append-only and the transcript
cleanup period does not touch it, so it outlives the transcripts it was derived from.

---

## 5. Workstream 2: learn from a mistake the moment it happens

**The brain.** The flinch forms on the burn. It does not wait for the night.

**Here.** A failure becomes a draft at 04:35 and a live row when a person rules. The gap between
a mistake and its reflex is measured in days and one human sitting. This is the property Brad
named first, and `PLAN-learn-from-mistakes` built every rung of the ladder but left the ENTRY to
the ladder as a nightly proposal plus a human ruling.

### 2a. Shadow mode: a draft that fires silently and learns its own precision

Named in `PLAN-learning-loop` and `course/reflex-routing.md` as *"what would settle it"*, not built.

- Every row in `recall-reflex-drafts.json` with both fixtures present is evaluated on every
  `PreToolUse` the live table sees, and a `shadow: true` row is written to `recall-reflex-log.jsonl`
  when it would have fired. **Nothing is injected.** The outcome join (WS 0a) resolves shadow fires
  exactly like live ones.
- After `MIN_FIRES = 20` resolved shadow fires across `MIN_SESSIONS = 3`, the ladder reports the
  draft's burn rate beside the live rows. A draft whose burn rate clears `BURN_WARN` is listed as
  **READY** with its numbers.

### 2b. Same-session promotion: the second burn in one session earns a remind

**This is the moment-of-the-mistake mechanism.** When the outcome join (or the failure harvester
run at `Stop`) sees the same failure signature twice in one session, and a shadow draft matched
both commands, that draft is promoted to `remind` **for the rest of that session only**, written to
the session state, not to `recall-reflexes.json`. The row's message names both failures. The
session-scoped promotion is logged as an event; the nightly ladder reads it as evidence.

This does not violate rule 14: the promotion is to `remind`, which cannot stop anything, and it
expires with the session. A default never dies; a session-scoped remind is not a default.

### 2c. Automatic acceptance to `remind`, under a ruled threshold

**Open ruling for Brad (section 15).** The proposal: a draft that has cleared shadow-mode
precision (fires on under its declared `max_fire_rate` over 5,900 real commands, MUST FIRE and
MUST NOT FIRE both pass) AND burned at or above `BURN_WARN` over 20 resolved shadow fires in 3
sessions is accepted to `remind` by the sleep pass, at most `MAX_AUTO_ACCEPT_PER_NIGHT = 2` per
night, each acceptance logged with its numbers and reversible by a `demote` ruling. `block` and
`rewrite` stay human-ruled. Without this ruling, 2a and 2b still ship and the sleep report simply
lists READY drafts for a person.

### 2d. A failure class is named, once

The proposer clusters failures by signature; the estate's incident template has a "the class"
section and one record. Join them: when a signature cluster reaches 3 sessions, the sleep pass
writes a **class card** to `~/.claude/recall-classes.jsonl`: signature, first seen, sessions,
commands (hashes), which shipped rows cover it, which draft matches it, and the memory or rules
line that names it if `knowledge-search` finds one above the floor. A class with no memory and no
draft is the sharpest miss there is, and it sorts first in the sleep report. Estate failures from
the event bus (WS 1b) cluster the same way under `ops/out/classes.jsonl`.

**Bar for WS 2.** Written before the run: within 14 days of shipping, the `learn` stage of the brain
report shows at least one rung moved on measured burn, and the median time from a signature's
second occurrence to a firing reflex (session-scoped counts) is under one session, measured over the
class cards. Fixtures: MUST FIRE - two identical signatures in one session with a matching draft
produce a session-scoped remind on the third matching command; MUST NOT FIRE - two signatures in
two sessions do not; CLEAN TWIN - a live `block` row is unaffected by any shadow row.

---

## 6. Workstream 3: metacognition - a claim of absence is refused without a search

**The brain.** You can tell the difference between "I do not know" and "there is nothing to know".

**Here.** [[always-on-delivery-is-not-sufficient]] measured six false claims of absence in one
session with the rule in context every turn, and concluded *"a lesson prevents nothing until it
REFUSES something."* The only refusal on the answer surface is `Consulted:`, which proves a source
was named, not that a search happened before a negative.

### 3a. The absence gate on `Stop`

Extend `recall-consulted-hook.py` with a second rung, same three loop brakes: if the reply contains
an **assertion of absence** (a cue table over MY prose, which is controllable: "there is no",
"does not exist", "nothing in the tree", "is not scheduled", "has no caller", "nobody", "never
runs", each with `--rate` against the 1,052-turn corpus and a cap), the reply must also carry a line
`Checked: <command or search>` naming what was run. Refuse once with the reason; accept
`Checked: not checked` because an honest unqualified claim is legal and the line makes it visible.
[[a-negative-search-result-must-prove-itself]] is the memory this enforces.

### 3b. The confidence line is scored

`recall-answer-outcome.py` already joins `Consulted:` to the next-turn correction. Add `Checked:` to
the join: an absence claim followed by a correction (WS 1a's structural cues included) is scored
`absence-wrong`, printed with its denominator as the sharpest metacognitive number the system has.

**Bar.** Over the next 100 answered turns: the absence cue fires on under 15% of turns, and every
fire in a labelled session of 30 is a genuine assertion of absence (precision 30 of 30, or the cue is
sharpened, never the cap raised). MUST FIRE - "there is no watchdog for the sidecar" with no
`Checked:` is refused; MUST NOT FIRE - "the watchdog exists" passes; CLEAN TWIN - a reply with both
lines passes on the first Stop.

---

## 7. Workstream 4: plasticity per cue

The brain-parity review built global use-weights and refuted them for the ranker (103 to 70). The
per-cue version was named and its data started accruing 09-07 (the offer row carries the query's
tokens). Since 09-09 the offer-to-open join is keyed on a turn id (backlog I77). This is the version
that matches the testing effect: the association between THIS cue and THAT section.

**Build.** `recall-weights.py --per-cue`: for every (query token, section) pair with at least 5
offers across 3 sessions, a shrunk hit rate (k = 10, the corrected prior from the review), clamped
[0.8, 1.25] (the narrow clamp that cleared significance and lost 16 for 8 globally; per cue it is a
different measurement and gets its own bar). Applied at rank time only to sections the cue itself
retrieved. The answer-outcome verdict (consulted and not corrected) is a second, weaker signal that
moves the same weight by half.

**Bar, before the run.** Right-domain@1 over the 136 labelled probes must not fall (paired McNemar,
b > c at p < 0.05 fails), AND hit@3 on the 30 consult questions rises by at least 2, AND the
per-cue file is neutral (1.0) on every pair under 5 offers. Fail any and the weights ship at 1.0 with
the file recording why, exactly as gap 1 did. **Do not ship a variant that is "not provably worse".**

---

## 8. Workstream 5: sleep v2 - an OS clock, a red that pages, a dream, a morning digest

### 5a. The clock is a Windows task

The nightly runs as a Claude scheduled agent (`~/.claude/scheduled-tasks/recall-sleep/`), which is an
LLM session that shells out, against Brad's rule that Windows tasks are the only routines that fire.
Register `TC Recall Sleep 0435` through the estate registrar, running
`C:\Codex\Python312\python.exe C:\Users\Owner\.claude\skills\recall-sleep.py --cwd C:\Codex\ThriftyCrew --commit --push`,
proving `~/.claude/recall-sleep-latest.md`'s date, declared in `expected-automations.json`, so
`health-heartbeat` pages when it does not run. Disable the agent task after the first green Windows
run, and record the swap in `recall-sleep.py`'s header.

### 5b. A red night pages, through the same channel as the estate

`recall-sleep.py` on any non-zero step writes `sleep-red` to the event bus and calls
`grocery/send-alert.ps1` with type `recall-sleep-red` (one per day, the existing suppression). A red
that nobody is told about is the founding defect of this workstream: 2026-09-09's pass failed on two
unruled forgetting candidates and the gate, committed nothing, and was discovered by a survey.

### 5c. The dream: a bounded model pass that DRAFTS the judgement half

The mechanical half runs unattended. The judgement half (rule on a cluster, write a gist, rule on a
forgetting candidate, accept a draft, name a class) waits for a person, and it drained once, on
the day Brad sat down. A brain does not wait for its owner to consolidate.

`recall-dream.py`, run by the sleep pass after the mechanical steps, calls a headless
`claude -p` (a pinned model; **open ruling for Brad on spend, section 15**; default is the local
llama-server if it is up, which the estate already uses for Stage 1) with: the session digests since
the last dream (WS 1c), the unruled queues, the class cards, and the READY drafts. It returns a
**review packet**, `~/.claude/recall-dream-packet.json`, the same shape `graph/learning/review-packet.json`
uses: one proposed ruling per item with evidence and a confidence, plus proposed memory DRAFTS
(front matter complete, cost band set, links resolved) for any session digest that carried a
correction or a repeated failure and produced no memory.

**It applies nothing.** The fixture from `recall-sleep.py` (no `--rule`, no `--apply` in any argv)
extends to the dream. The packet is what Brad rules on in the morning, and WS 2c's ruled threshold
is the only automatic acceptance anywhere.

### 5d. The morning digest

One email at 06:45 (a Windows task, `ops/brain-digest.ps1`), the way the capture watchdog sends
one: what the night moved, what went red, the WEAKEST LINK, and **what waits for a ruling with its
cost-if-undrained** in the same vocabulary `expected-automations.json` uses for queues
(`recipe-specs-awaiting-propagate` 72 h). Every queue gets a floor here: forgetting candidates
unruled over 7 days, clusters over 14, READY drafts over 7, dream packets over 3, estate proposals
over 14. A queue over its floor is a line in the digest and an event on the bus; it never blocks.

**Bar.** Thirty consecutive nights with a Windows-task stamp; every red night has an alert-log row
the same morning; the median age of the oldest unruled item across all queues, read from the digest,
is under 7 days over the 30 days. Measured from the digests themselves, one row per night.

---

## 9. Workstream 6: encoding at write time - memory lint, cost, index integrity

**The brain.** Encoding happens once, at the moment, and the cost is stamped then.

**Here.** 1 of 156 memories carries the `cost` field ruled un-backfillable on 09-07. Memories are
written by hand with no check on their front matter, their links, their index line, or their
duplication of an existing memory. `audit-memory-backup.ps1` guards reachability and encoding and says
of itself *"SOUND about currency, silent about content."*

### 6a. A memory lint, at write time and in the gate

`~/.claude/skills/memory-lint.py`, run by `check-skills.py` and by a `PostToolUse(Write|Edit)` hook
scoped to `*/memory/*.md`:

- front matter has `name` equal to the filename, `description` under 200 characters and not
  starting with the name, `metadata.type` in the four types, `metadata.cost` in
  `{retry, session, shipped}`;
- every `[[link]]` resolves inside the same store or the workspace store;
- the `MEMORY.md` index has exactly one line for the file, and the line's gist is not a copy of
  the description's first eight words (the index is a hook, not a restatement);
- **near-duplicate refusal**: the description scores under 0.85 cosine (sidecar) or under a BM25
  self-match ratio of 0.6 against every existing memory in the store, else the hook prints the
  existing slug and says *"extend that one"*. The mutual-kNN clusterer already computes this;
  reuse `recall-consolidate.py`'s scoring.

Ratchet: the 155 memories without `cost` are the baseline; the mark may only fall; a new memory
without one is refused outright (a hard rule on new rows, a ratchet on old, the pattern
`audit-write-seam` uses).

### 6b. Consolidation can fade into the estate's rules files

Seven cluster rulings were deferred because the gist belonged in `.claude/rules/*.md` or the
workspace `CLAUDE.md`, and `recall-consolidate.py --apply` can only fade into a skills
`applies-here.md`. Add `rules:<project>` and `claude-md:<path>` as legal gist targets; the pointer
check (`recall-pointer-check.py`) resolves them the same way; `ops/audit-memory-citations.ps1`
already verifies the reverse direction for rules files.

### 6c. The dream writes memory drafts; the lint refuses bad ones

WS 5c's packet carries memory drafts. A draft that passes 6a is written to
`~/.claude/projects/<proj>/memory/_drafts/` (not indexed, not in `MEMORY.md`) and listed in the
digest. Accepting one is a file move plus an index line, done by a person or by the next session
that reads the digest. **No memory is written to the live store by a model unattended.**

**Bar.** After 30 days: `cost` set on every memory written after the ship date (100%, printed as N of
N); duplicates refused at least once (the refusal log is the evidence); `audit-memory-backup.ps1`
reachability unchanged or better.

---

## 10. Workstream 7: forgetting v2 - everything expires on evidence

**The brain.** Forgetting is active and it improves what remains. Nothing is permanent by default.

**Here.** Sections and reflexes forget by ruling (built). Five things never expire:

| thing | count | never expires because |
|---|---|---|
| memories | 156 + 191 + 5 | no signal exists for "never recalled, never cited, never opened" |
| question verdicts (estate) | 4,141, all stamped 2026-08-21 | no re-adjudication, no confidence decay |
| promotion holds (estate) | 16, 13 inert today | one-way actuator, cleared by a human running the full guard suite |
| EVAL/MEASURE conclusions (estate) | 14 | no index, no expiry, no harness back-link |
| rules-file claims | about 40 across six files | prose with no freshness signal; `grocery.md` carried a wrong number for months |

### 7a. Memory decay candidates

`recall-forget.py --memories`: a memory is a candidate when, over 60 days, it was never offered by
the hook, never opened (`via: read` or `via: bash`), never cited by a `[[link]]` outside the memory
store, and its description scores above 0.9 against another memory (a near-twin that survived the
6a lint because it predates it). Candidates are ruled `retire | merge-into <slug> | keep <reason>`.
A retired memory keeps its file, loses its index line and its index chunk, and its `[[links]]`
are rewritten to point at the merge target. Same ratchet shape as sections: unruled is a mark
that may only fall, with the 7-day floor from WS 5d.

### 7b. Verdict expiry in the graph

`graph/state/question-verdicts.json` rows gain `expires_at` = `decided_at` + 90 days (the board's
own quarter, read from `capture-policy.ps1`, never hard-coded). An expired `llm_rejected` verdict
is re-asked on the next nightly if the product is still captured; an expired `llm_confirmed` one
is re-asked only if the commodity's gold changed. `resolve.py` layer 4.5 treats an expired verdict
as absent. Rate limit: at most `MAX_REASKS_PER_NIGHT = 200`, a first plausible value, recorded as
such in `docs/CONTROL-CONSTANTS.md` with its stop behaviour (a night that re-asks 0 with more than 0
expired is a line in the status file).

### 7c. Hold expiry and re-test

`promote_aliases.py --recheck-holds` already re-tests daily and reports INERT. A hold inert for 30
consecutive rechecks becomes a `clear` PROPOSAL in the review packet with its 30 factor readings.
Clearing stays human (Brad's 09-09 ruling, backlog I92); the proposal is the machine's half.

### 7d. Conclusions carry their harness, and a changed harness un-qualifies them

`ops/audit-measurement-provenance.ps1` already requires an EVAL/MEASURE file to name its harness and
commit (ratchet at 8). Add `ops/audit-conclusion-currency.ps1`: for every file that names a harness
path and a commit, check whether the harness has a newer commit touching it; if so, the conclusion
is **UNQUALIFIED** and the audit prints it with the two commits. Ratchet on the count; the nine
that the measurement rule says are already stale are the baseline. This is the back-link that would
have caught both confounds in section 0.2 the day the harness moved rather than months later.

### 7e. Rules-file claims are dated and re-verified

Every dated claim in `.claude/rules/*.md` (a line carrying `(YYYY-MM-DD` or `Measured YYYY-MM-DD`)
older than 90 days is listed by `ops/audit-rule-currency.ps1` with the number it states. The audit
also validates every `globs:` entry matches at least one tracked file (a disarmed rules file is the
fail-open shape). Ratchet on stale claims; hard fail on a glob that matches nothing.

**Bar for WS 7.** Each audit ships with its MUST FIRE, its baseline printed as N of M, and a
`SCOPE OF A CLEAN REPORT` line. After 30 days: at least one memory retired or merged by ruling, at
least one hold proposed for clearing, zero rules-file globs matching nothing, and the verdict store
carries a `decided_at` distribution with more than one date.

---

## 11. Workstream 8: generalisation - across projects, across domains, across negatives

**The brain.** A lesson learned in the kitchen applies in the workshop.

### 8a. Cross-project memory

Memory is per project and *"whether one project's memory corpus helps another"* is listed as
unmeasured in `automatic-recall.md`. Measure first: index the workspace store (191) alongside the
ThriftyCrew store (156) as a second `memory:` corpus for prompts issued in ThriftyCrew, and run the
30 consult questions plus the 136 probes. **Bar**: hit@3 does not fall and off-topic stays at 4 of 13
or under. If it passes, ship the second corpus at a 0.9 multiplier (a first plausible value, recorded).

A `generalise` ruling in `recall-consolidate.py`: when a cluster contains memories from two projects
saying the same thing (the PowerShell array trio has twins in both stores), the gist goes to the
workspace store or `C:\Codex\CLAUDE.md` and both originals fade. This is the ruling that turns
a project lesson into a lesson about how Claude works.

### 8b. One-hop expansion over the `[[link]]` graph (backlog I77)

Designed, control group named (the 53 zero-in-degree memos), blocked on a case set that started
accruing 09-09. Build the case set from the turn-keyed join over the next 14 days, then run the
expansion arm against control with the bar I77 already wrote. Not before.

### 8c. The estate's negative-clustering engines get callers

`graph/learning/local_triage.py --cluster-rejections` (3,755 adjudicated negatives into candidate
category-exclude classes) and `lint_adjacency.py` (excludes defeated by word order and plurals, the
class behind four wrong prices) have zero callers. Both go into `graph/pipeline/nightly.ps1` as
report-only stages after Stage 1, inside the same time budget rule (skipped under 120 s left), their
output filed into the review packet as proposals of kind `add_exclude_class`. Stage 2's shadow
gate scores them like any other patch. MUST FIRE in `nightly.ps1`'s own tests: both stages exist and
precede `stop`.

---

## 12. Workstream 9: efficiency-seeking - an effort ledger and habits mined from success

**The brain.** Effort is felt, and a path that keeps costing more than it should is noticed and
replaced without being told to look.

**Here.** No ledger of effort exists on either half. Transcripts are read for tokens as a billing
meter; hook latency is written and never read; the estate has `MEASURE-daily-chain-*` documents
that were written by hand on one day. Reflexes are mined from failures only; a successful sequence
repeated forty times is not a candidate for anything.

### 9a. The effort ledger

From the session digests (WS 1c) and the transcripts, nightly, one row per session in
`~/.claude/recall-effort.jsonl`: wall time, turns, tool calls by tool, failures, retries (the same
command hash run twice within 5 minutes), reflex fires and blocks, hook milliseconds summed,
tokens where the transcript carries them, commits. From the estate's `ad-cycle-log.txt` and
`graph-nightly-status.json`, one row per scheduled run: stage timings as the chain already prints
them. `recall-brain.py` gains an `effort` line: this week's median session against last week's,
with the denominators. **A number that moved is not a number that improved**; the line says what
moved and over how many sessions and never says "better".

### 9b. Habits from success: repeated sequences become commands

`recall-habit-propose.py`, a sleep step: over the harvested probes (5,900 real commands with
session and order), find n-gram sequences of 3 to 6 commands (normalised through the failure
signature's path and hash stripping) that occur in 3 or more sessions with no failure inside the
sequence. Each is a **habit draft**: the sequence, its sessions, its total wall time, and a proposed
home (a `.ps1` in `ops/`, a skill, or a line in a rules file). Listed in the digest; nothing
installs itself. The estate's own `count-source-lifters` was hand-written for exactly this shape
of repeated work; the proposer finds the next one.

### 9c. Slow paths are named

The same pass names the top five commands by median wall time across sessions and the top five
hook invocations by milliseconds, with their counts, and asks in the digest whether a faster path
exists. This is curiosity with a budget: it costs a line, and a person or the dream answers it.

### 9d. Latency is a gate with a floor

WS 0b's `check-skills.py` latency check is the gate. Its floor: a day with fewer than 5 timing rows
while sessions ran is a dead instrument, exit 1.

**Bar.** After 30 days: the effort ledger has one row per session for 90% of sessions (N of M
printed); at least three habit drafts proposed with sessions counts; the latency gate has been green
for 14 consecutive days.

---

## 13. Workstream 10: the estate closes its loops

Every item here is a measurement that already exists and connects to nothing. Each gets an
actuator, a floor, or a record, in that order of ambition, and never a gate that is red on day one.

### 10a. A red gate leaves a record and an obligation

`ops/run-gates.ps1` on exit 1 or 3 appends to `ops/out/gate-history.jsonl` (gitignored) one row per
failed gate: name, exit, commit, branch, timestamp, whether the push was blocked. A new detector
`ops/audit-gate-followthrough.ps1` reads it: a gate that went red twice in 14 days with no commit
since touching a `-SelfTest` block or a fixture file is listed as **RED WITHOUT A FIXTURE**.
Ratchet, and the founding rule `CLAUDE.md` states as a habit becomes a count.

### 10b. Alert precision drives re-arm

`grocery/audit-alert-precision.ps1` computes per-type precision and refuses under 5 cases. Add the
actuator, bounded: `grocery/alert-tuning.json`, written by the audit, one row per type with
`rearm_days` derived from precision (5 cases and under 0.4 precision: `rearm_days` doubles from
`$REARM_DAYS`, capped at 56; 10 cases and over 0.8: halves, floored at 7). `check-ad-cycles.ps1`
reads the file where `$REARM_DAYS` is used today. Rate limit: one move per type per 14 days;
plausibility: never below 7 or above 56; refusal spoken; registered in `CONTROL-CONSTANTS.md` with
"first plausible values, NOT a sweep, and what else was tried" filled in when the second value is
chosen. Stop behaviour: a type with no closes in 30 days is printed, not tuned. **The floor Brad
left open in `grocery/ALERTS.md`** (a reader on a clock for the queue) is the ruling in section 15.

### 10c. The graph loop consumes what it produces

- `stage2_review.py --emit-packet` becomes a nightly stage after Stage 1; `--apply` stays human,
  and the packet age gets a floor in the digest (14 days).
- `graph/gold/seed_gold.py` runs nightly after the hunter ingest, so a `known-wrong` ruling reaches
  gold the same night. MUST FIRE: a new known-wrong entry appears as a NO_MATCH gold row after the
  run.
- `graph/eval/score.py` re-scores the gold set nightly when any of prompt, resolver or gold changed
  since the last run (content hash), appending to `eval-runs.json`. `ops/audit-eval-currency.ps1`
  fails when the latest run is older than the latest change to those files. Baseline: red today,
  so it ships as a ratchet on days-stale.
- `hunter-gold.jsonl` gains negatives: every `recipe-source-qa` FAIL and every mapper rejection in
  `ingredient-events.jsonl` is a NO_MATCH gold row with `source`. Bar: at least 20 negatives within
  14 days, printed as N of total.

### 10d. Phantom citations

`ops/audit-phantom-paths.ps1`: every `ops/*.ps1`, `grocery/*.ps1`, `lib/*.ps1` path named in
`CLAUDE.md`, `.claude/rules/*.md`, `ops/hooks/*`, `docs/*.md` and `design/RULINGS-*.md` must exist
in the tree. The founding bug is `ops/audit-hook-installed.ps1`, cited five times and never
written; the first build either writes that guard (the `-Check` mode of `install-hooks.ps1` is what
it calls) or removes the five citations, and the audit's MUST FIRE is a prose line naming a `.ps1`
that is not there. Hard gate, because the baseline is one and it is fixed in the same change.

### 10e. Ratchet trend is read

`lib/ratchet.ps1`'s `Get-RatchetTrend` prints *"flat at 7 across the last 10 runs"* and nothing
consumes it. The daily chain collects every ratchet's trend line into one `ratchet-trends` block in
the watchdog email, and a detector flat for 30 runs with a non-zero mark is listed as
**STOPPED LOOKING**. Report, not gate; the digest carries it.

### 10f. The incident practice gets a trigger

An `INCIDENT-*.md` is opened automatically (from the template, header filled from the event) when
the event bus shows the same alert type `confirmed` three times in 30 days, or a `gate-red` on the
same gate three times in 14 days, or a `known-wrong` reversal. The file lands in `grocery/` with
status DRAFT and a line in the digest. The five-whys stays human; the trigger and the timeline are
the machine's half, and *"the gap between it broke and we noticed"* is filled from the bus.

---

## 14. Workstream 11: one nervous system

`recall-brain.py` shows ten stages of the personal store on one page and says which is starving.
The estate has `health-heartbeat.ps1` for scheduled tasks and nothing for learning. No page shows
both, and the estate's learning stages have no floors, which is how 60 proposals sat for 19 days.

**Build.** `ops/brain-report.ps1`, the estate half, same contract as `recall-brain.py`: reads and
never writes, one line per stage with its live number and its owner file, a stage with no data says
NO EVIDENCE. Stages: perceive (event bus rows, last 24 h), propose (Stage 1 proposals pending, age
of oldest), review (packet age), apply (patches applied, last date), score (eval-runs latest vs
latest change), generalise (class proposals), correct (dispositions in 7 days, types at the 5-case
bar), tune (actuator moves in 30 days), forget (holds inert, verdicts expired, conclusions
unqualified), incidents (drafts open). Then `recall-brain.py --with-estate` runs it and prints one
WEAKEST LINK across both halves. The digest (WS 5d) carries that page.

**Every stage gets a floor in the same file**: a stage whose producer stopped (no rows in its
window) is RED in the report and an event on the bus. This is the property the estate's rules file
calls the one no upper bound can supply.

**Bar.** The report runs in under 10 s, has 15 fixtures (one per stage, one for the cross-half
weakest link, one for a stopped producer), and its first live run names a weakest link that a
person agrees is the weakest, written in the status block.

---

## 15. Rulings only Brad can make

Each is a default in this plan; the build proceeds on the default unless ruled otherwise.

| # | Question | Default here |
|---|---|---|
| R1 | May the sidecar run during the nightly GPU window (21:30 to 06:30)? | No. The hook falls back to lexical in those hours; the watchdog respects the window |
| R2 | May the sleep pass accept a shadow-proven draft to `remind` unattended (WS 2c)? Threshold: fixtured precision, burn at or above `BURN_WARN` over 20 resolved shadow fires in 3 sessions, at most 2 per night, reversible | Yes, on those numbers, because `remind` cannot stop anything and a person can demote |
| R3 | What runs the dream (WS 5c): the local llama-server, or a pinned cloud model, and at what spend per night? | Local if up, else skip and say so. No cloud spend without the ruling |
| R4 | A reader on a clock for the alert queue (`grocery/ALERTS.md` open decision): re-enable the triage agent, or a weekly look? | Neither is assumed. WS 10b tunes re-arm from whatever dispositions exist; the digest lists the queue age daily |
| R5 | Cross-project memory (WS 8a): may ThriftyCrew prompts retrieve from the workspace store? | Measure first, ship on the bar |
| R6 | May a hold be CLEARED by the machine after 30 inert rechecks (WS 7c)? | No. Proposed only, per the 09-09 ruling |
| R7 | Should the estate's learning and the personal store's learning share one event bus file, or two mirrored ones? | Two (one per git root), each with the same row shape, joined by the report |

---

## 16. Build order, and what each build must show before the next starts

Dependency-ordered. Each row ends with the four gates read unpiped (`check-skills.py` first, then
`run-gates.ps1` in the estate), the status block updated with the commit and the number, and the
brain report re-run.

| Order | WS | Gate to pass before moving on |
|---|---|---|
| 1 | 0a, 0b, 0c, 0d, 0e | burned > 0 on the real log; hook p95 under 1,000 ms with the sidecar down; ladder in the pass; 16 of 16 steps green one night |
| 2 | 1b, 1c | the event bus has a row from every producer after one daily chain; a session digest for every session over 3 days |
| 3 | 1a, 3a, 3b | structural correction cues under cap and the labelled-session catch rate; the absence gate refused at least once in real use |
| 4 | 2a, 2b, 2d | a shadow row on the log; a session-scoped remind fixture; class cards written |
| 5 | 5a, 5b, 5d | Windows-task stamp; a red pages; the digest arrives at 06:45 |
| 6 | 6a, 6b | the lint refuses a costless memory; a gist fades into a rules file |
| 7 | 10a, 10d, 10c | gate history rows; phantom guard resolved; Stage 2 packet nightly and gold re-scored |
| 8 | 11 | one page, both halves, a weakest link |
| 9 | 5c, 6c, 2c (on R2) | a dream packet ruled on; a memory draft accepted |
| 10 | 4, 7a to 7e | per-cue weights on their bar; the five expiries each with a first real case |
| 11 | 8a, 8b, 8c | cross-project on its bar; I77's arm run; the two engines in the nightly |
| 12 | 9a to 9d, 10b, 10e, 10f | effort ledger; habit drafts; re-arm moved once by data; an incident opened by trigger |

**Estimated size**, stated so the deviation is visible later, not as a commitment: 0 is a day; 1
to 3 are two days; 4 to 6 three; 7 to 9 three; 10 to 12 four. Two to three weeks of Opus sessions.

---

## 17. The thirty-day bar for the whole thing, written now

The plan is judged on 2026-10-09 by these numbers, each from the tool named, each with its
denominator. They are the acceptance bar; the status block is where they are filled in.

| Number | Tool | Bar |
|---|---|---|
| burned fires resolved | `recall-reflex-stats.py` | above 0, and at least one rung moved on it |
| corrections captured per 100 of Brad's turns | `recall_correction.py` | between 5 and 15, with the labelled catch rate over 75% |
| absence claims refused and later shown wrong | `recall-answer-outcome.py` | the `absence-wrong` count exists and is under 2 in 100 turns |
| memories written with `cost` | `memory-lint.py` | N of N since ship date |
| oldest unruled item across all queues | the morning digest | median under 7 days over the 30 mornings |
| nights on a Windows task, red nights paged | `expected-automations.json` proof plus `alert-log.txt` | 30 of 30, every red paged |
| prompt hook p95 | timing rows | under 200 ms with the sidecar up, under 1,000 ms down |
| sidecar uptime during non-GPU hours | watchdog stamp | above 95%, N minutes of M |
| estate proposals pending over 14 days | `ops/brain-report.ps1` | 0 |
| gold scoreboard staleness | `audit-eval-currency` | 0 days against the latest change |
| phantom paths | `audit-phantom-paths` | 0 |
| re-arm moves made by data | `alert-tuning.json` | at least 1, with its precision and case count |
| habit drafts proposed | `recall-habit-propose.py` | at least 3 |
| the recurrence rate `PLAN-does-the-store-help` asked for | that plan's signal 2, now computable from the event bus and the class cards | **reported with its denominator**, whichever side of its 5% / 20% bar it lands |

**What this plan deliberately does not do.** No free-text classifier on any surface (refuted twice).
No global use-weight on the ranker (refuted). No cross-encoder as a gate (refuted). No
`PostToolUse`-on-failure hook without the probe row that proves it fires. No gate red on day one. No
memory written to a live store by a model unattended. No new course work until the recurrence
number in the last row exists, which is the finding `PLAN-does-the-store-help` closed on.

Related memories: [[always-on-delivery-is-not-sufficient]], [[an-intention-has-no-exit-code]],
[[cc-fix-process-not-code]], [[a-negative-search-result-must-prove-itself]],
[[exit-code-first-tally-second]], [[pick-the-best-run-is-selection-on-noise]],
[[an-agreeing-number-escapes-scrutiny]], [[semantic-recall-needs-the-sidecar]],
[[mint-loop-is-closed]], [[a-measurement-is-not-a-look]],
[[check-the-commit-clock-behind-a-recorded-measurement]], [[recommend-the-best-long-term-solution]],
[[what-actually-reaches-a-spawned-agent]].
