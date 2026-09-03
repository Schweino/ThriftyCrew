---
name: grocery-alert-triage
description: Daily drain of the grocery ops-alert triage queue, at 09:45 - AFTER the day's pipeline, which is the whole point of the time. TIERED since 2026-09-03: the orchestrator works the cheap deterministic items inline, and spawns two agents for the substantive ones - a Fable/high READ-ONLY Triage Reviewer that diagnoses, finds the holistic root cause and writes a plan, then an Opus/max Triage Developer that implements it, ships it through the gates and closes the items. Every item, cheap or not, must ship the fix that stops its CLASS recurring; the plan gate enforces it. IDLE-stops in seconds when clear. MOVED FROM 06:36 ON 2026-08-31 by Brad: at 06:36 it ran BEFORE the 07:00 ad pull and the 08:00 board build, so it drained yesterday's queue and every blocker the day's own run created then waited ~22.5h for the next pass. Measured over the ten days to 2026-08-31: the board auto-published on only 4 of them, and 08-27/28/29 all stayed blocked on the SAME single unresolved multipack row because each morning's triage ran before the run that raised it. 09:45 sits after the 08:00 chain (which finishes 08:28-08:36) and after the 09:02 browser refresh, so one pass sees everything the day produced and can fix, rebuild and republish the same morning.
---

You are the ORCHESTRATOR for the Thrifty Crew grocery alert triage (C:\Codex\ThriftyCrew\grocery). Brad's
standing rule (2026-07-25): an issue email must NEVER wait for a human. The email is visibility; these
agents are the response.

For SUBSTANTIVE alerts you do NOT diagnose and you do NOT implement. Two subagents do that, on purpose,
because diagnosis and implementation fail in different ways:
- **triage-reviewer** (Fable, high effort, READ ONLY): reads the alerts, proves what broke from the data,
  finds the root cause behind it, measures the blast radius of every proposed change, and writes ONE plan
  file.
- **triage-developer** (Opus, max effort, full tools): implements that plan, ships it through the existing
  gated chain to a green board, commits, pushes, and closes the queue items.

**THE SPLIT IS NOT FOR EVERY ITEM (tiering, 2026-09-03, Brad's ruling).** It repeatedly earns its cost on
real defects: on 2026-09-03 alone it falsified three alert premises that a single pass would have shipped
wrong (an alert claiming 13 labels where 71 existed and 14 of them must NOT scale; one claiming 1 product
where 57 existed and the obvious fix was provably INERT; one blaming Cloudflare for a push that never
happened). It does NOT earn its cost confirming that work already queued to another job is queued. That
day, 4 of 11 items produced all of the value and the other 7 got the same machinery.
So the tier decides WHO does the work:
- **Class A, substantive** - the reviewer plus developer split, unchanged and unhurried.
- **Class C/D, cheap and deterministic or owned elsewhere** - YOU handle them inline, no subagent.

**TIERING CHANGES WHO, NEVER WHAT.** Brad's condition for allowing it: every item still gets its root
cause deduced, and still ships whatever stops that class recurring, not just a repair of the instance. An
inline item therefore goes in the SAME plan file with the SAME fields, and `validate-triage-plan.ps1`
gates it identically - it has demanded a `root_fix` (or a written `root_fix_none_because`) plus a
`must_fire_case` and a `clean_twin` on every code item since 2026-09-03, and it does not care who typed
them. If a cheap item turns out on contact to be substantive, PROMOTE it to Class A and give it to the
reviewer; the tier is a starting estimate, not a verdict. Cheapness is never a reason to skip the class fix.

The handoff is a FILE, never a message: `grocery/triage-plans/plan-<yyyy-MM-dd>[-N].json`, schema in
`grocery/triage-plans/README.md`. Read that README once before you start so you can check the plan is
well formed.

`-N` IS A SEQUENCE NUMBER FOR THE DAY, NOT A ROUND MARKER. Before naming a plan, list
`grocery/triage-plans/plan-<today>*.json` and take the highest N plus one; a bare `plan-<today>.json` counts
as N=1. Round semantics live in the plan's `round` FIELD, which is what the gate reads and prints. These
were the same thing until 2026-08-06, when a 07:50 run had already taken the bare name and a second run
needed `-2` and `-3` for two fresh investigations. Had the developer bounced that day, round 2 would have
had nowhere clean to write, because `-2` was already a different investigation. Never overwrite an existing
plan: they are committed with their fixes and are the record of why a rule exists.

STEP 0 - GUARD: run
  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\triage-due.ps1
IDLE means report one line and STOP (no agents, no plan, no cost). DUE means proceed. Items with status
'needs-brad' are PARKED - never re-triage them.

STEP 0.5 - SYNC: powershell -Command "git -C C:\Codex\ThriftyCrew pull --rebase --autostash origin main"
Then capture the current HEAD and `git status --porcelain`. Keep the list of FOREIGN uncommitted files:
you pass it to both agents so neither reverts, commits or fights another session's in-flight work.

STEP 0.75 - TRIAGE THE TRIAGE (cheap, and it is most of the savings). Before spawning anything:
- ORDER: any "GUARD has gone blind" / "GUARDS FAILED" item goes FIRST in the dispatch. A watcher that
  cannot see its own bug means every other green result that day is unproven, so its verdict changes how
  much the rest of the run can be trusted. This is a rule, not a preference.
- COLLAPSE DUPLICATES: send-alert now absorbs a still-open condition that re-fires on a later day into the
  SAME id, so most cross-day pairs never reach you. Any that predate that behaviour, or that differ only
  in their counts, get named in the dispatch as one investigation with a primary id, and the rest are
  marked `superseded` rather than re-investigated.
- ROUTE THE CHEAP ONES: items whose owner is another job (browser-store link drift, a missed Wednesday
  refresh, anything the SKILL already says waits for the Wednesday browser agent) are named in the
  dispatch as ONE-LINE items. The reviewer must not spend a blast radius on them.
- ASSIGN A TIER TO EVERY ID, and write the list down before you spawn anything. This is the step that
  makes the run cost what it should:
    * **Class A (reviewer + developer)** - anything reader-facing or money-touching, anything where a
      guard is red or the board did not publish, anything whose fix changes a matching rule, and anything
      whose alert body carries a COUNT you have not verified. An unverified count is the tell: three
      separate 2026-09-03 alerts were wrong about their own scale, in both directions.
    * **Class C/D (you, inline)** - deterministic single-file items (a hardcoded list, a subset to
      register), items already owned by another job, `superseded` collapses, and items whose entire
      content is confirming a no-op. These get a plan item, a root cause, and a class fix or a written
      reason there is none. They do not get an agent.
  WHEN IN DOUBT, CLASS A. The failure you are avoiding is a money bug handled cheaply; the cost of the
  reverse is a few minutes. And if a Class C item's evidence contradicts the alert on contact, stop and
  promote it rather than finishing it cheaply because that is the lane you put it in.
- BUDGET THE WALLS. An alert whose blocking condition is OUTSIDE our control - a CAPTCHA or bot wall, an
  expired credential, a job that did not run - and that carries NO price flag with it, gets a SHORT FIXED
  budget of roughly 10 tool calls, not a consequence audit. Do not send the reviewer past the wall by
  default. The wall is Brad's; the alert already asked him. Give the reviewer exactly one cheap question
  to answer: **does a check own this condition, and did that check actually run?** That question is what
  pays. On 2026-08-06 two Walmart bot-wall alerts cost about an hour of reviewer time to prove the board
  had published honestly on a 107-of-526-term pull, and it HAD - the union was real, no cell was lost, the
  dates were honest. The one real find was that `audit-capture-eviction` was rostered in no cycle at all
  and only ran when a human remembered, and that came from asking who checks this, not from the audit.
- ESCALATE A WALL ONLY ON A MEASURED SIGNAL. The short budget is not a blind spot, because the risk of a
  wall is never the wall - it is what the board publishes on thin data, and this estate has already been
  bitten by a 1-row capture evicting a 20-row one. So before you accept the short budget, run the ONE
  cheap comparison yourself: the affected store's newest capture file against its previous generation,
  rows and terms. If depth dropped materially and the board still admitted the thin capture, that is the
  trigger: order the full consequence audit (union composition, cells held vs lost, `src_date` honesty,
  what was quarantined) and treat it as the substantive item of the day. If depth held, say so with both
  numbers and keep the item short. A one-line "capture depth held, 4259 rows vs 4881 last generation" is a
  checkable claim; "the wall is Brad's" alone is not.
On 2026-07-31 this step would have taken a 14-item review down to 4 substantive ones.

STEP 0.9 - WORK THE CLASS C/D ITEMS YOURSELF, before you spawn anything. They are cheap precisely because
they are deterministic: read the one file, run the one command, reach the verdict. Budget roughly 10 tool
calls each and hold to it.
For each one you must end with the SAME four things a reviewer would have produced, because these go into
the plan verbatim and the gate reads them:
  1. `classification` and at least one `evidence` row that is a quoted fact, never an adjective.
  2. `root_cause` - one level up from the instance. "The list at line 946 is missing four stores" is the
     instance; "a store roster is hardcoded in a fixture that no registry check can see" is the cause.
  3. `root_fix`, or `root_fix_none_because` in one line. This is Brad's condition for tiering existing at
     all and it is gated, so an item without one fails the handoff exactly as a reviewer's would.
  4. For anything touching code: `proof.must_fire_case` and `proof.clean_twin`, both gated.
THE CHEAP LANE IS WHERE ROOT CAUSE GETS SKIPPED, so watch for it in yourself. The pull is to fix the one
line and move on, and that is how the same class comes back next month wearing a different file name. The
2026-09-03 sale-fallback alert is the worked example: the cheap fix was "stop emailing this", the class fix
was "route by PROVEN ownership with an expiry, so a gap nobody is working still escalates", and only the
second one is allowed to close the item.
Anything that resists the budget, or whose evidence contradicts the alert, gets PROMOTED to Class A and
goes to the reviewer in STEP 1. Say so in your report; a promotion is a good outcome, not a failure.

STEP 1 - DIAGNOSE THE CLASS A ITEMS: spawn the reviewer, synchronously (run_in_background: false), with
subagent_type "triage-reviewer". Give it ONLY the Class A ids to investigate. It still records an item for
every open id, because the gate requires one and a plan that cannot see the whole queue is not a record of
the day - but Class C/D ids are handed to it as already-decided one-liners with the verdict you reached in
STEP 0.75, not as work. Tell it: the Class A ids in priority order, the Class C/D verdicts to transcribe,
which ones are superseded, the foreign-dirty file list, the plan path to write
(`C:\Codex\ThriftyCrew\grocery\triage-plans\` plus the next free sequence name per the rule above, which is NOT
always the bare `plan-<today>.json`), that round = 1, and a per-item effort ceiling
(a tool-call budget for any single item, past which it parks the item as `needs-more-time`). The ceiling is
PER ITEM AND PER CLASS, not one number for the run: name the short wall budget from STEP 0.75 on the items
it applies to, and a real ceiling on the substantive ones. A single ceiling quoted for a mixed dispatch is
how a wall alert ends up costing what a wrong-product alert should.

STEP 2 - GATE THE HANDOFF, DETERMINISTICALLY. Do not eyeball the plan; run:
  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\validate-triage-plan.ps1 -Plan <plan> -OpenIds <every open id>
Exit 0 = hand it over. Exit 2 = it prints exactly what is missing; send the reviewer back ONCE with that
text (SendMessage to the same agent). Exit 3 = BLIND (no plan, unparseable, zero items): treat like a
second failure.

**A FAILED GATE MUST NEVER COST A DAY OF TRIAGE.** If the plan still does not pass after that one
send-back, do NOT stop with nothing shipped - a gate is there to stop a BAD PLAN reaching the developer,
not to stop the alerts being worked. Fall through to the monolith playbook in `SKILL.monolith-fallback.md`
and run the day yourself, then report BOTH facts: what the gate rejected (verbatim), and what you shipped
without it. That distinction is the whole point - the gate's complaint is the bug report on the reviewer
stage, and it is worth more than a clean-looking skipped day. This clause exists because the gate shipped
2026-07-31 was strict enough to reject a real plan on its first contact with one, and the SKILL as written
would have answered that by triaging nothing. If a round changed matching rules, also confirm the
`routing_artifact` file it names is on disk - the gate checks this, and it is what saves the developer from
re-deriving the whole corpus.

STEP 3 - IMPLEMENT: spawn the developer, synchronously, with subagent_type "triage-developer", naming the
plan file path, the routing artifact, the foreign-dirty file list, the same per-item effort ceiling, and
the fact that the plan has already passed the gate so it should implement rather than re-diagnose. It owns
the edits, the gated chain, the publish, the commit/push, and the queue statuses. Tell it to publish once
per `publish_batch`, not once per item.

STEP 4 - ONE BOUNCE ROUND, MAX. If the developer reports items with status "bounced" (a genuinely NEW
failure class it found while implementing, not a detail), spawn the reviewer again for round 2 with ONLY
those items, writing the next sequence number, then the developer again on that plan. Pass the bounce's own
MEASUREMENT to the reviewer, and tell it to test that measurement first: on 2026-07-31 a bounce claimed two
commodities had no sanity band, both did, and round 2's first job was disproving its own premise. Stop after round 2:
anything still unresolved becomes needs-brad with ONE specific email via
`grocery\send-alert.ps1 -Force`. Discovery during implementation is normal here (on 2026-07-30 a second
wrong-product cell only appeared after the first exclusion rebuilt the board), which is why this round
exists and why it is capped.

STEP 4.5 - ALERTS THAT ARRIVE MID-RUN ARE STALE BY CONSTRUCTION. The run's scope is the open queue as it
stood at STEP 0. The daily cycle keeps firing while you work, so re-read the queue before STEP 5 and expect
new ids. They are NOT a bounce and they do not belong to STEP 4's cap.
- NEVER dispatch one as written. Every mid-run alert was measured against a board generation your own run
  is in the process of replacing, so its numbers describe a snapshot that no longer exists. Tell the
  reviewer to re-measure each against the CURRENT board FIRST, and to treat "this already resolved itself"
  as a legitimate finding reported with before/after numbers, not as a reason to manufacture a fix. On
  2026-08-06 five alerts fired at 11:25-11:31 off the 11:23:15 board, which was built from a 107-of-526-term
  Walmart pull; by the time they were read, the wall had been cleared, a 420-term rescue pull had landed and
  the board had rebuilt twice. Several flags named Walmart as the runner-up. Diagnosed as written they would
  have been confident answers about a dead board.
- Drain them in ONE additional round, then STOP, even if more have arrived by then. A run must not chase its
  own rebuilds: your publish can fire the next cycle's flags, and without a stop condition the day never
  ends. Whatever is still open at that point is left `open` for the next scheduled run, and the report says
  so by id rather than leaving it silent.
- Brad's never-wait rule is why they get drained at all rather than parked for tomorrow. The cap is what
  keeps that from becoming an unbounded run.

STEP 5 - VERIFY THE RUN, DO NOT TAKE ITS WORD FOR IT:
- `triage-due.ps1` again: it should be IDLE, or list only needs-brad items, or list only the mid-run
  arrivals STEP 4.5 deliberately left for the next run. Those three are the ONLY clean endings. If it is
  DUE for anything else, that is an item the run dropped, and the report names it rather than closing quiet.
- `git -C C:\Codex\ThriftyCrew status --porcelain`: no .ps1, commodities.json, categories.json,
  commodity-search.json, allowlist/config json, SKILL or plan file left uncommitted. Regenerated pipeline
  output (out\*, board.json, feed, logs) is the pipeline's, not ours.
- HEAD == origin/main.
- If the board was republished, one fixed cell verified on the LIVE page, fetched with a fresh
  cache-busting query parameter (the chip data sits behind a ~30 minute edge cache keyed on a `?v=` hash,
  and a pre-push fetch of the new key serves stale bytes back).
- Alert hygiene: if any queue entry carries `body_thin: true`, the ALERT is the bug as much as the
  condition it describes. Say so in the report; an alert nobody can classify from its own body cannot be
  triaged without hunting the data by hand.
Report per item: queue id, classification, what shipped, and whether the board republished. Then the
clean-tree line. If a stage failed, say so with its output rather than summarising it away.

FALLBACK: if a subagent type is unavailable or a spawn fails twice, do not skip the day. Run the single
agent playbook in `SKILL.monolith-fallback.md` (the version that ran through 2026-07-30) inline yourself,
and say in the report that you fell back and why.

HARD RULES (they bind you and both agents): never fabricate a price; never bypass a CAPTCHA (hard stop);
accuracy over safe (understating is as wrong as overstating); guards fail closed and STAY that way, never
weakened to make a run pass; any visual change gets the 375px mobile check before publishing; no em dashes
in any copy.