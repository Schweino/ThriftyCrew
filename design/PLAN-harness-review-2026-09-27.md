# PLAN: whole-estate harness review (2026-09-27)

Status: PROPOSED. Rulings R1-R8 below are Brad's. Nothing here is built.

Origin: Brad asked for a thorough review of everything about Thrifty Crew (the learning brain and whether
it is actually learning, the routines, the system, the processes) against the six-layer agent harness in
Ichigo's "Harness Engineering: Build a Reliable AI Agent in 6 Layers" (x.com, 2026-08-29): task contract,
compiled context, tool gateway, durable state, evidence gates, traces that turn failures into infrastructure.
Its headline metric, accepted outputs per human review minute, is adopted here as the estate's efficiency
metric (W7.1).

## Knowledge consulted

- `searched "harness context budget agent trace learning loop"`: skills/agent-workflow-craft/agent-memory.md
  section 2, "context compilation... turning state into a prompt is a step you own"; skills/claude-code-craft/
  applies-here.md, "A spawn's total_tokens is its last call's context, not what it cost".
- `.claude/rules/graph.md`: "Learning must be per-batch, not nightly - check WHICH half before believing it is
  not learning."
- `.claude/rules/ops-and-gates.md` header: rules hold "OPERATIVE text only... The measurements, dates and
  incidents behind a rule live in docs/rules-history/".
- `.claude/rules/measurement.md`: a rate carries its denominator; write the acceptance bar before the run.
- `design/PLAN-rules-trim-2026-09-25.md`, `PLAN-bot-dedicated-checkout-2026-09-25.md`,
  `PLAN-faster-pushes-no-accuracy-loss-2026-09-25.md`, `PLAN-triage-token-cut-2026-09-25.md`,
  `PLAN-graph-learning-reconcile-2026-09-23.md`, `RETIRE-dead-scripts-2026-09-27.md`: this plan finishes or
  unblocks them and does not restate them.

## How the review was done

Five read-only auditors, one per area (learning brain, routines, context load, agent pipelines, gates and
code). Their findings are INPUTS. The four that carry the most weight were re-checked by hand on 2026-09-27
against the data, and each line below says which kind it is: **[checked]** re-read by me, **[reported]** an
auditor's number not yet re-read. Every [reported] number is re-measured in W0 before any work item uses it.

## What we found

### 1. The learning brain: partly learning, and the learning loop itself stalled on 2026-08-21

What works:
- `question_verdicts` (17,145 rows) grows most nights and `graph/pipeline/resolve.py` reads it back, so an
  answered question is not re-asked. [reported]
- Brad's known-wrong rulings reach the live board through `grocery/known-wrong-lib.ps1`. [reported]

What does not:
- **Alias promotion, the only road by which the graph learns a new match, has applied nothing since
  2026-08-21.** `learning_proposals` in `graph/sqlite/graph.db`: 159 `applied`, every one created
  2026-08-20 to 08-21; 18 `accepted` (Brad's 2026-09-12 rulings, created up to 09-11) that were never applied;
  93 `proposed`, created 08-22 to 09-26, which nothing reads. [checked]
- The applier (`graph/learning/stage2_review.py` `shadow_and_apply()`) is human-gated by design
  (`nightly.ps1` leaves `--apply` to a person) and no person has run it since August. An intention with no
  exit code. [reported]
- Production matching reads `grocery/commodities.json`, not graph.db. The graph reaches the board only
  through `promote_aliases.py`, also human-gated. [reported]
- The nightly eval is scored against a gold set that changes every night (a new `gold_version` each run),
  and every run is the same deterministic arm, so no run-to-run change can be attributed to learning.
  Reported: nightly false merges rose from 1 to 10 between 09-22 and 09-26 (precision 0.9988 to 0.9885).
  `eval-runs.json` holds 58 runs but not in date order, so this trend is [reported] and W0.2 re-derives it.
- The 09-19 recall jump came from 5,093 aliases copied from the catalogue, not from learning. [reported]
- Written and never read: 16 promotion holds re-checked daily and never cleared (`hold-rechecks.jsonl`);
  `decision_log` escalate/verify pipelines silent since 08-23. [reported]
- A 0-byte `graph/graph.db` was created at 03:35 today beside the real `graph/sqlite/graph.db`. [checked]
  That is the "a graph.db that EXISTS may hold no nodes" trap waiting for a reader that looks at the wrong one.

Agent knowledge brain: 384 of 438 code commits (88%) carry a `Store:` line backed by a search, against an 80%
bar; 25 of 227 briefs were refused and all resent. That measures RECORDING, not whether the store changed
the code. [reported]

### 2. Routines: the two daily bots have not landed their own data for two weeks

- Both grocery bots (07:00 ad, 08:00 daily) failed on every logged day 09-13 to 09-26 (12 of 12). Failed lanes:
  guards-blocked x5, push x6, sync, foreign-held (52 and 611 files dirtied by other sessions), commit-size.
  The latest `capture-run-status.json` shows guards-blocked and sync. [partly checked]
- Runs of 5.3 h, 9.5 h and 6 h (09-20, 09-24, 09-26) are push retries with no wall-clock cap. [reported]
- Alerts rose from about 14 a day (09-13) to 45-62 a day (09-24 to 09-26). Of 176 closes since 09-13: 130
  confirmed (74%), 46 no-action (26%); 44 of 176 (25%) returned. [reported]
- Six liveness watchers (Boot Watch, Sidecar Watchdog, Process Reaper, Daemon Battery, Capture Watchdog, Slot
  Close) page on overlapping conditions. Recall Sleep exits 1 every day; Process Reaper and Capture Watchdog
  last result 0x1. Recipe Harvest Crawl has no next run. [reported]
- `PLAN-bot-dedicated-checkout` (ruled) has its harness and W8.2 landed; stages 1-3, the part that ends the
  foreign-held and sync failures, are open. `PLAN-zero-alert-days-remainder` is not started. [reported]

### 3. Context: every session pays about 34k tokens before it starts

- ~134 KB always loaded: three CLAUDE.md files, six rules files, MEMORY.md, skill descriptions. [reported]
- Only `ops-and-gates.md` has been converted to operative-text form (90.7 KB to 21 KB). The ThriftyCrew
  CLAUDE.md gate section is 12 KB, about two thirds history; `grocery.md` is ~20 KB, about 60% history. [reported]
- The same rules appear in two or three places (push-main and the push lock in CLAUDE.md AND ops-and-gates;
  the exit-code meaning in three files). [reported]
- The measured triage cost of the rules load is ~20% of a run (`PLAN-triage-token-cut` W1, awaiting a ruling).

### 4. Agent pipelines: good evidence gates, no stop reason, no failure class

Six-layer scorecard (P present, Pa partial, A absent) [reported]:

| Pipeline | Contract | Context | Gateway | State | Evidence | Trace |
|---|---|---|---|---|---|---|
| Triage | Pa (no done_when/escalate_when) | Pa (rules load ~20%) | Pa | P | P | Pa (no stop reason, no failure class) |
| Recipe Hunter | Pa | Pa (auditor re-reads prompt files) | Pa (pricer holds 28 raw browser tools) | P | P | Pa |
| post-publish-reviewer | A | Pa | Pa | Pa | P | A |
| commodity-registrar | P | Pa | Pa | Pa | Pa | A |

- **The triage cost ledger double-counts**: `grocery/triage-plans/cost-ledger.jsonl` holds 182 rows for 73
  distinct agents. [checked] A plain sum reads about twice the real spend, which can defeat the budget stop.
- De-duplicated triage spend: 105M cost units for 80 done items over 09-24 to 09-26, ~1.3M per done item; one
  session ran 52.7M against a 30M bar. Brad touched ~0.26 items per done item. [reported]
- Recipe Hunter: last measured run 154M input-side tokens for 22 published (~7M per recipe); no hunt since
  09-04. [reported]

### 5. System and process

- 260 push-main runs 09-20 to 09-27: median 7.8 min, p90 25 min; 89 refused (34%), 55 of them gate red, and
  **no refused row records why** (`reject_class` empty, no `blind=` token). The lock is held 18 s median, so
  the lock is not the cost; gates and the rehearsal wait are. [reported]
- `PLAN-faster-pushes` E1 (wait for a running early rehearsal of the same key) is ruled and not built. [reported]
- 1,001 scripts; 93 dead candidates; branch `retire-dead-scripts-2026-09-27` retires 83 on Brad's ruling and is
  not merged. The four largest files have a split plan with D1-D6 pending. [reported]
- 75 PLAN files, 3 saying NEEDS A RULING; backlog 327 items, 50 OPEN, 5 NEEDS A RULING. [reported]
- **I239 is OPEN: the price-alert endpoint tells a stranger which emails belong to paying members.** [checked]
  That is a live privacy leak on a paid site and outranks every efficiency item here.

## The pattern behind it

Most defects above share one shape: **a step owned by "a human will run it" with no mechanism that makes it
happen or says it did not.** The applier, the hold clearer, the bot landing, the rulings backlog, the refusal
reason. The estate is excellent at layer 5 (evidence) and weakest at layers 1 and 6: nothing states when a
run is DONE or when to ESCALATE, and nothing records WHY a run stopped, so a failure cannot be classified into
the four permanent fixes (a clearer map, a better tool, a stricter permission, a new test).

## Work items

Ordered by consequence, then by cost. Each carries its bar, written before the work.

### W0 - Re-measure before building (read-only, one session)
- W0.1 Re-derive every [reported] number above with a committed script (`ops/probe-harness-review.ps1`)
  printing each with its denominator. Bar: every number in this plan is either confirmed or corrected in
  place with the old value struck.
- W0.2 Sort `eval-runs.json` by `run_at` and print nightly false-merge counts for 09-10 to 09-27.
- W0.3 Identify what created the 0-byte `graph/graph.db` at 03:35 today.

### W1 - Privacy leak I239 (first, alone)
- Build the rung-1 fix already named in the backlog: the endpoint answers identically for a member and a
  non-member. Bar: MUST FIRE fixture (old response differs by membership), CLEAN TWIN (a real member still
  gets the alert). Verified live with two test addresses after deploy.

### W2 - Make the learning loop learn (R1)
- W2.1 Schedule `stage2_review.py --apply` behind its existing shadow gate, nightly, after `resolve`. Bar: the
  18 accepted proposals reach `applied` in the first run, or each refusal is printed with its reason.
- W2.2 Freeze a gold set (`graph/gold/gold-frozen-2026-09-27.jsonl`) and score every nightly against it as
  well as the rolling one. Bar: the eval row carries both, and a change is only called learning on the frozen
  set.
- W2.3 Diagnose the false-merge rise (after W0.2 confirms it) before any promotion runs. Bar: each new false
  merge named with its cause.
- W2.4 Age out the 93 `proposed` rows: anything older than 14 days goes onto the approvals page as one batch,
  and stage1 stops generating more while more than 50 are unread. Bar: unread count printed nightly, and it
  can only fall or hold without a human.
- W2.5 Auto-clear a hold after its declared N inert rechecks (`promote_aliases.py clear_proposals()` exists),
  or retire the recheck. Bar: `promotion-holds.json` changes, or the recheck stops running.
- W2.6 A learning-health line in the Brain Digest: proposals applied this week, frozen-set recall and false
  merges, days since the last applied patch. Bar: a stall of 7 days pages. This is the detector that would
  have caught August 21 on August 28.

### W3 - Routines land their own data (R2)
- W3.1 Finish `PLAN-bot-dedicated-checkout` stages 1-3. Bar: 5 consecutive armed bot runs land their own data.
- W3.2 A hard wall-clock cap on bot push retries (as Graph Nightly's `-HardStop`). Bar: no bot run over 90 min.
- W3.3 Fix Recall Sleep's daily exit 1 on judgement-only reds, and the watchdog's stale pre-commit report.
- W3.4 Collapse the six liveness watchers into one task that pages once per condition per day. Bar: pages per
  day, measured over 7 days before and after, with the same conditions still detected (fixture per condition).
- W3.5 Decide the Harvest Crawl (re-arm or retire).
- W3.6 Execute `PLAN-zero-alert-days-remainder`. Scoreboard: return rate below 10% of closes.

### W4 - Context: a map, not a manual (R3)
- W4.1 Convert ThriftyCrew `CLAUDE.md`'s gate section, `grocery.md`, `measurement.md` and `meal-prep.md` to the
  ops-and-gates format (operative text, a tag, history in `docs/rules-history/`). Extend
  `ops/audit-rule-format.ps1` to them.
- W4.2 One home per rule: remove the duplicates between CLAUDE.md, ops-and-gates and MEMORY.md; MEMORY.md
  lines become pointers.
- W4.3 State the citation preamble once.
- W4.4 Move history out of the four largest agent files (pricer, triage-developer, mapper, triage-reviewer).
- Bar for W4: fixed per-session load from ~34k to 25k tokens or below, measured by `triage-cost.py --first-call`
  on the next triage run; no operative sentence lost (a human read of each diff).
- W4.5 (R3b) Path-scope the domain rules files. Would save a further ~8.6k tokens outside those areas. It
  reverses the 2026-09-25 option-A ruling, so it is Brad's call and is not proposed as the default.

### W5 - Every run has a contract and a trace (R4)
- W5.1 A contract block required in every helper brief and plan item: `goal`, `constraints`, `done_when`
  (runnable checks), `escalate_when`. Enforced by the existing brief-gate hook and `validate-triage-plan.ps1`.
- W5.2 A run trace row for triage, Recipe Hunter and the bots: context loaded, tool calls, cost, `stop_reason`
  (done / budget / escalated / error / refused), `failure_class` (missing_context / bad_tool /
  missing_guardrail / weak_check / external).
- W5.3 A weekly roll-up of failure classes, so a recurring class becomes one of the four permanent fixes.
- W5.4 Fix the ledger double count: `triage-cost.py --append` skips a seen `agent_id`, and the report reads
  distinct agents. Bar: rows == distinct agents after a rebuild.
- W5.5 A per-session budget stop at 30M cost units (real, de-duplicated).

### W6 - Pushes (R5)
- W6.1 Record the refusal reason: fill `reject_class` and the `blind=` token on every refused push-main row.
  Bar: 0 refused rows with an empty reason over the next 7 days.
- W6.2 Build `PLAN-faster-pushes` E1 (already ruled). Bar: p90 push time, 7 days before and after, same rows.
- W6.3 Fix the seven most frequent non-zero gates, starting with `audit-stray-root-artifacts` and
  `audit-prompt-backup`.
- W6.4 Merge `retire-dead-scripts-2026-09-27` through push-main (already ruled).

### W7 - The metric
- W7.1 Weekly: accepted outputs (landed plan items, published recipes, landed bot runs) divided by Brad's
  touches (questions answered, approvals, rulings), and cost per accepted output. In the Brain Digest.

### W8 - The rulings backlog (R6)
- One sitting to clear: the 3 NEEDS A RULING plans, 5 backlog rulings, split-plan D1-D6, token-cut W1, the
  local-LLM pilot's three questions, 10 ready-for-brad items. Presented as one question batch, with a
  recommendation on each, not as prose.

## Rulings given (Brad, 2026-09-27)

- **R1, answered differently from both options offered.** Accepted learning proposals go to the existing
  "Waiting on Brad" UI, not to an automatic apply. And that UI is REDONE first, because its items today "just
  give the text details and it makes it very hard to understand what to do." Every item shows, in layman
  terms: **the issue, why it is a problem, and Claude's recommendation**; Brad decides. W2.1 now means: route
  the 18 accepted proposals (and future ones) to Waiting on Brad in that shape, and apply on his decision.
  W2.6's 7-day stall page stays. W8 is rewritten below to build the new item format.
- **R5: plan order**, as listed.
- **R3 and R4: approved.** W4.1-W4.4 trim; contract and trace fields on every brief, warn 7 days then refuse.
  R3b (path-scoping) is not approved.
- **R7: Recipe Hunter stays paused for now.**
- R2, R6, R8: not yet asked; they go onto Waiting on Brad in the new format as its first items.

### W8 (rewritten per R1) - Waiting on Brad, readable
- W8.1 Find the Waiting on Brad page's source and every writer that adds an item.
- W8.2 One item shape: headline (one line, plain words), "What's going on", "Why it matters" (what it costs
  or risks a reader or the business), "Claude recommends" (and why, one or two sentences), the choices as
  buttons, and a "technical detail" fold holding ids and paths. No jargon above the fold.
- W8.3 A gate refusing an item without the four plain fields, and a MUST FIRE fixture of today's raw-detail
  shape.
- W8.4 Rewrite every item currently waiting into the new shape; add the learning proposals, R2, R6, R8, and
  the rulings backlog (3 NEEDS A RULING plans, 5 backlog rulings, split-plan D1-D6, token-cut W1, the pilot's
  three questions, 10 ready-for-brad items).
- Bar: Brad can decide each item without opening anything else; judged by Brad on the first ten.

### W9 - Process: a pathspec commit sweeps a shared file's other edits
- Found while landing this plan: a pathspec commit of `MEMORY.md` in the memory store carried three other
  sessions' uncommitted index lines with it (all pointing at tracked files, so harmless this time). A shared,
  hand-edited index needs a hunk-level add, not a whole-file pathspec. Add the note to the memory store's
  commit guidance.

## Rulings Brad owns (as first proposed)

- R1 Learning: may accepted proposals apply automatically behind the shadow gate (W2.1), or stay a human step
  with a 7-day stall page (W2.6 only)? Recommend: automatic. A human step that has not run in 37 days is the
  defect.
- R2 Watchers: collapse the six into one (W3.4)? Recommend: yes.
- R3 Trim W4.1-W4.4 as proposed? Recommend: yes. R3b path-scoping (W4.5): recommend no for now, re-measure
  after W4.
- R4 Contract and trace fields required on every brief (W5)? Recommend: yes, warn for 7 days then refuse,
  as the Store: line did.
- R5 Order: W1, W0, W5.4, W2, W3, W6, W4, W5, W7. Recommend as listed.
- R6 Book the rulings sitting (W8).
- R7 Recipe Hunter: resume, or pause formally until W5 traces exist? Recommend: pause until W5.2.
- R8 Budget: this plan's build under 60M cost units total across all items, reported per item.

## What this plan does not do

- It changes no price, no board cell and no published page, except W1's endpoint response.
- It weakens no gate. Everything here either adds a record, adds a mechanism for a step that was "a human
  will do it", or removes duplicate text.
