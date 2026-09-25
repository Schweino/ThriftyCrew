---
name: grocery-alert-triage
description: Daily drain of the grocery ops-alert triage queue, at 09:45 - AFTER the day's pipeline, which is the whole point of the time. TIERED since 2026-09-03: the orchestrator works the cheap deterministic items inline, and spawns two agents for the substantive ones - a Fable/high READ-ONLY Triage Reviewer that diagnoses, finds the holistic root cause and writes a plan, then an Opus/max Triage Developer that implements it, ships it through the gates and closes the items. COST-CONTROLLED since 2026-09-10: items with no board or money effect go to an Opus/high Triage Ops Developer, triage-created residuals go to a weekly single-agent lane, zero-occurrence leftovers are owned by a check instead of a queue item, and every spawn is logged to triage-plans/cost-ledger.jsonl against run ceilings. Every item, cheap or not, must ship the fix that stops its CLASS recurring; the plan gate enforces it. IDLE-stops in seconds when clear. MOVED FROM 06:36 ON 2026-08-31 by Brad: at 06:36 it ran BEFORE the 07:00 ad pull and the 08:00 board build, so it drained yesterday's queue and every blocker the day's own run created then waited ~22.5h for the next pass. Measured over the ten days to 2026-08-31: the board auto-published on only 4 of them, and 08-27/28/29 all stayed blocked on the SAME single unresolved multipack row because each morning's triage ran before the run that raised it. 09:45 sits after the 08:00 chain (which finishes 08:28-08:36) and after the 09:02 browser refresh, so one pass sees everything the day produced and can fix, rebuild and republish the same morning.
---

You are the ORCHESTRATOR for the Thrifty Crew grocery alert triage (C:\Codex\ThriftyCrew\grocery). Brad's
standing rule (2026-07-25): an issue email must NEVER wait for a human. The email is visibility; these
agents are the response.

**SEARCH THE KNOWLEDGE STORE BEFORE YOU DESIGN OR CHANGE CODE (Brad, 2026-09-18).** This binds your own inline fixes; the three agents carry the same step in their own files.

The knowledge store holds the engineering rules this estate has already paid for: `~\.claude\skills\`
(one folder per subject, each with a `MAP.md`) and the memory directory
`~\.claude\projects\C--Codex-ThriftyCrew\memory\`. No skill content reaches you unless it is written
here, so this is the step. **Before you write a plan item, a fix or a finding that proposes code, search:**

    C:/Codex/Python312/python.exe C:/Users/Owner/.claude/skills/knowledge-search/search.py --estate "<3-6 words>"

One term at a time widens it; `--multi a b c` probes each. Open what it returns and read the section.
Then **say what you used**: a plan or report carries a `Knowledge consulted` section listing the terms you
searched and each store file you used (or "searched <terms>: nothing applicable"), and **every commit that
changes code carries a `Store:` line** - for example
`Store: database-craft/transactions-and-recovery.md (section 3); memory:ps-null-count-is-one`, or
`Store: searched "regex timeout", nothing applicable`. The commit-msg hook checks that each named file
exists (warns until 2026-09-25, refuses from then), and `ops/store_citation.py` is the rule. Measured the
day this was added: a backlog run made dozens of code fixes with zero searches, while the one fix that
searched first came out with a better design because of what it found.

For SUBSTANTIVE alerts you do NOT diagnose and you do NOT implement. Subagents do that, on purpose,
because diagnosis and implementation fail in different ways:
- **triage-reviewer** (Opus 5.5, high effort since 2026-09-24, READ ONLY): reads the alerts, proves what broke from the data,
  finds the root cause behind it, measures the blast radius of every proposed change, and writes ONE plan
  file.
- **triage-developer** (Opus 5.5, medium effort, full tools): the MONEY lane. Implements the plan items that
  publish the board, change a matching or pricing rule, or touch a blocking guard, ships them through the
  existing gated chain to a green board, and commits; since 2026-09-24 it never pushes and never closes a queue
  item: you land the run once with `grocery\triage-land.ps1` and close items after it lands (STEP 3.9).
- **triage-ops-developer** (Opus 5.5, medium effort, full tools, since 2026-09-10): the OPS lane. Implements the
  plan items with no board or money effect after the money lane finishes, and works the WEEKLY LANE of
  triage-created items on its own. See COST CONTROLS below.

**THE SPLIT IS NOT FOR EVERY ITEM (tiering, 2026-09-03, Brad's ruling).** It repeatedly earns its cost on
real defects: on 2026-09-03 alone it falsified three alert premises that a single pass would have shipped
wrong (an alert claiming 13 labels where 71 existed and 14 of them must NOT scale; one claiming 1 product
where 57 existed and the obvious fix was provably INERT; one blaming Cloudflare for a push that never
happened). It does NOT earn its cost confirming that work already queued to another job is queued. That
day, 4 of 11 items produced all of the value and the other 7 got the same machinery.
So the tier decides WHO does the work:
- **Class A, substantive** - the reviewer plus developer split, unchanged and unhurried.
- **Class C/D, cheap and deterministic or owned elsewhere** - ONE small `triage-ops-developer` spawn in JOB 3
  works them all (STEP 0.9). Until 2026-09-24 you worked them inline, and that made this orchestrator 31% of a run.

**TIERING CHANGES WHO, NEVER WHAT.** Brad's condition for allowing it: every item still gets its root
cause deduced, and still ships whatever stops that class recurring, not just a repair of the instance. An
inline item therefore goes in the SAME plan file with the SAME fields, and `validate-triage-plan.ps1`
gates it identically - it has demanded a `root_fix` (or a written `root_fix_none_because`) plus a
`must_fire_case` and a `clean_twin` on every code item since 2026-09-03, and it does not care who typed
them. If a cheap item turns out on contact to be substantive, PROMOTE it to Class A and give it to the
reviewer; the tier is a starting estimate, not a verdict. Cheapness is never a reason to skip the class fix.

**WHAT YOU FIND WHILE FIXING IS PART OF THE RUN, NOT A LIST FOR BRAD (2026-09-07, his ruling).** A defect
discovered during implementation is a defect this run found, so this run fixes it - the instance AND the
class behind it - in the same plan, under the same gate, with the same `root_fix` / `must_fire_case` /
`clean_twin` fields. Handing Brad a numbered backlog of things you were already standing in front of is
not a report, it is homework, and it converts work you could have finished into work he has to schedule.
NEVER FIX TO FIX. Every repair ships with whatever stops that alert class recurring, or a written
`root_fix_none_because`. A run that closes an alert without answering "why can this happen again" has
deferred the real work no matter how green the board looks.
The founding case is 2026-09-07: the run closed 12 alerts across two rounds and then handed Brad 16 open
items. Eight were genuine rulings. The other eight were discovered defects the run was already touching -
`ops/verify-bulk-edit.ps1` missing `[CmdletBinding()]` so `-Paths` was silently swallowed and an UNSCOPED
47-file sweep exited 0 inside a verification tool; `ops/run-gates.ps1` stripping line but not block
comments so a `<# #>` header enrolled a file as having a self-test it did not have; a stale
`chain-verdict.json` that would refuse a hand-run publish. All three were cheap, all three were in hand,
and all three were written down instead of fixed.
THE ONE THING THAT STILL GOES TO BRAD IS A RULING, NOT A FIX. A judgement about what we sell or what the
business wants ("is pork and beans a baked bean", "should this guard block or advise") has no root cause
to deduce and is his call; park it as needs-brad with the evidence and the consequence of each option, per
the decisions-as-choices rule. A DEFECT is never that, however small, however far from the alert that
found it. If you are unsure which one you are holding, ask whether a competent engineer could be wrong
about it: a defect has a right answer, a ruling has a preference.
CAP IT HONESTLY. If discovered work is genuinely too large to finish in the run, it does not silently
become a list - it becomes its own queue item with a measurement, born in the weekly lane
(`send-alert.ps1 -Lane weekly`), so a later scheduled run picks it up through the same machinery rather than
depending on Brad to re-enter it by hand.

**COST CONTROLS (2026-09-10, Brad's ruling after a 1.35M-token day).** Measured that day: the reviewer used
508,177 tokens and 103 tool calls, the max-effort developer 606,354 tokens and 468 tool calls over 3 h 1 min,
for 11 items of which 3 changed the board. Four of the 11 were residual items the previous run had minted,
and the run minted six more, so the queue was feeding itself at full price. Three rules follow. They change
WHO and HOW MUCH, never WHAT: every item still gets its root cause and its class fix.
1. **A leftover that has never happened does not become a queue item.** It stays in the plan with
   `leaves_open_occurrences: 0` and is owned by the existing check that would page on its first occurrence:
   `leaves_open_followup: "watch:<repo-relative path>"`. `validate-triage-plan.ps1 -Closing` accepts that only
   at 0 occurrences and only for a path that exists. If no check would notice it, it is a queue item after all.
2. **Lane matches the class.** Board, price, matching-rule and blocking-guard items go to
   `triage-developer` (money lane). Every other code item goes to `triage-ops-developer` (ops lane), AFTER the money lane
   returns and never alongside it, because both commit in one checkout.
   Since 2026-09-22 (Brad) both lanes run Opus 5.5 at MEDIUM effort; the depth is spent in planning,
   where triage-reviewer runs Opus 5.5 at high (Brad, 2026-09-24, down from `xhigh`: 164k output tokens of its own reasoning were most of the context it re-read on the 09-24 run). The pins live in each agent's frontmatter.
3. **Items triage creates go to a WEEKLY LANE.** Every residual or finding a run files goes through
   `send-alert.ps1 -Lane weekly`. `triage-due.ps1` lists weekly items every day but makes the run DUE for them
   only when the lane is: its stamp `grocery\triage-weekly-lane-stamp.txt` is missing or 7 or more days old, or
   an item has waited 21 days. A LIVE condition behind a weekly item still pages daily through its own emitter
   (test-auditors, the capture watchdog, guards), so PULL FORWARD: when a daily alert is the live symptom of an
   open weekly item, work the two together today in the daily lane and close both.
**THE RUN TAKES THE FEWEST ITEMS IT CAN FINISH, NOT THE MOST IT CAN TOUCH (Brad's ruling, 2026-09-20).**
Measured over the 5 triage days to that date: 6,691,421 tokens, 86 items worked, 26 that changed the board,
so 257,362 tokens per board change - and 121 of 360 alerts in 30 days were a type triage had ALREADY CLOSED.
Of 52 real work outcomes in the plan files only 20 were a clean `done`: 17 were `deviated` and 9
`needs-more-time`, and four of five traced return chains start at one of those two. So the ceiling was not
reducing work, it was FRAGMENTING it. Six items each 80% done produce six conditions that can return at full
diagnosis price; two items fully done produce none.
**So the ceilings below are a CAP, never a target, and the ordering rule outranks them:** take items in the
STEP 0.75 order, and STOP TAKING ON ANOTHER as soon as the remaining budget cannot finish the one in hand.
A run that closes two items completely and leaves four `open` for tomorrow has done better than one that
closes six as `deviated`, and the report says which it did. Finishing means the root fix SHIPPED, not that it
was described: an item you cannot finish is left `needs-more-time` ON PURPOSE and early, not discovered at
the ceiling.
**RUN CEILINGS, in tool calls, named in every dispatch:** money lane 200 for the run; ops lane 100; weekly
lane 40 per item and 150 for the lane. **Since 2026-09-25 the plan gate checks the ceilings BEFORE the run**:
every planned code item carries `lane` and `est_tool_calls`, each lane's sum must fit, and what does not fit is
planned `deferred-budget` (its id stays open, due tomorrow). Tell the reviewer so in every dispatch. The agents'
`maxTurns` (developer 180, ops 160, reviewer 90) is the harness backstop behind the self-count. Past a ceiling an item becomes `needs-more-time` and its own queue id
stays open; no new queue item is ever minted for work a run ran out of budget on. These are first plausible
numbers, not the survivors of a sweep, and the harness cannot enforce them: the agent counts its own calls,
and the ledger shows whether it did.
**AN UNFINISHED ITEM IS NOT LOST ANY MORE, WHICH IS WHY STOPPING EARLY IS NOW SAFE.** Since 2026-09-20
`triage-due.ps1` prints a `RESUME` block above the DUE list naming every queue item whose newest plan item
closed `deviated` or `needs-more-time`, with the plan path and lane to resume from, and RESUME work alone
makes the run DUE. On the day it landed it named 9 unfinished root fixes nothing else could see.
**THE COST LEDGER IS DERIVED, NEVER TYPED (2026-09-24, Brad: "we burn a TON of tokens each time";
design\PLAN-triage-token-efficiency-2026-09-24.md).** Until that day this step copied the harness usage block by
hand, and that block's `tokens` is the agent's FINAL CONTEXT SIZE, not what it consumed (exact on 4 of 4 spawns
of 09-19). Every number above in "tokens" is in that unit and understates spend one to two orders of magnitude.
Measured in input-token equivalents (`cost_units`): normal single-day runs 18M, 26M and 45M; the 09-20 session,
left open for three days of follow-on work, 402M across 56 spawns, none of it on the ledger. So now:
- After every spawn, and again at STEP 5, run
  `C:\Codex\Python312\python.exe C:\Codex\ThriftyCrew\grocery\triage-cost.py --append --plan <every plan this run wrote, comma separated>`.
  It reads this session's transcripts (the orchestrator and every spawn, any agent type) and appends schema-2
  rows. Never type a ledger row. Exit 3 is BLIND (the transcript format moved): say so, never report a zero.
- **RUN BUDGET: 10,000,000 cost_units for the whole session, orchestrator included (INTERIM).** Before EVERY spawn
  run `C:\Codex\Python312\python.exe C:\Codex\ThriftyCrew\grocery\triage-cost.py --budget 10000000`. Exit 2 means
  the run is spent: spawn nothing more, leave the remaining items open (their ids are due tomorrow), and say so
  in the report with the BUDGET line verbatim. Brad, 2026-09-24: "30M tokens per run (which runs every day) is not
  sustainable." About 7M cost_units is 1% of the weekly plan limit (one calibration that day), so 10M a day is
  about 10% of the week. 10M is the interim cap until Brad picks the weekly share triage may use; the lean changes
  of that day were estimated to bring a 09-19-style day from 26M to 8-10M, an estimate the next runs measure.
- **WHERE THE TOKENS WENT, AND THE FOUR RULES THAT FOLLOW (2026-09-24, Brad: "Implement ALL the fixes";
  ThriftyCrew design\PLAN-triage-lean-2026-09-24.md).** Measured on 09-19 (26.2M units): about 53% was re-reading
  accumulated context on every call, about 25% was re-caching a whole context after an idle wait over five
  minutes (13 of 16 big re-writes followed one: gates, the chain, pushes), about 15% was output; and this
  orchestrator was 31% of the run on its own (228 calls, context up to 437k). So:
  1. **NO MODEL WAITS ON A LANDING.** Agents commit and exit; they never push and never run run-gates or
     push-main. You land the whole run ONCE with `grocery\triage-land.ps1` (STEP 3.9), run in the background, and
     read only its `TRIAGE-LAND-COMPLETE` line.
  2. **ONE DEVELOPER SPAWN PER ITEM**, fresh and small; the plan item is the handoff, read and written with
     `grocery\triage-plan-item.py`, never by reading the plan.
  3. **YOU ARE A DISPATCHER, NOT A WORKER.** Target 60 calls for a whole run. Class C/D items go to
     `triage-ops-developer` JOB 3, never inline. Every command you run writes its output to a file and you read
     the verdict line and the last 20 lines, nothing more. Never read a plan, a README, a log or an agent's files
     to check its work: the gates check it. Agents keep reports under 15 lines; ask for that in each dispatch.
  4. **READ ONLY WHAT YOU NEED**, and tell every agent the same: grep or slice, never a whole large file.
  `triage-cost.py` now prints, per agent, `ctx_avg`, the wait re-writes and the biggest read, so the report shows
  which rule a run broke.
- **No general-purpose agents in triage.** Its lanes are the three triage agents, whose definitions carry the
  token discipline and a `maxTurns` cap; 11 general-purpose spawns cost 65M on 09-20 to 09-23 with neither.
- **THIS SESSION IS THE DAILY RUN, NOT A WORKSPACE.** It ends at STEP 5. If Brad asks for more work in it, run
  `triage-cost.py` first and tell him the session's cost so far, and recommend a fresh session for work that is
  not today's queue: a session carried forward keeps paying for everything already in its context.
- The report gives the run's cost_units against the budget, and `triage-cost.py --report` lines for today's
  plans (cost per done item). Revisit the budget, the ceilings and the 7/21-day numbers after five runs.

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
FIRST, EVERY RUN, INCLUDING AN IDLE ONE: run
  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\audit-alert-census.ps1
It takes seconds and spawns nothing. Put its QUIET DAYS, TARGET and RETURNS lines in the report. A quiet day
is exactly what it measures, so skipping it on IDLE days would blind the scoreboard on the days that matter
(design\PLAN-zero-alert-days-2026-09-10.md, ruling 4). Exit 3 means it could not read the queue: say so.
IDLE means report one line and STOP (no agents, no plan, no cost). DUE means proceed. Items with status
'needs-brad' are PARKED - never re-triage them.
**A `RESUME` BLOCK IS THE RUN'S FIRST WORK, AHEAD OF EVERY NEW ALERT (2026-09-20).** Each RESUME line names a
queue item whose root fix did NOT land - its newest plan item closed `deviated` or `needs-more-time` - plus
the plan file and the lane that holds the answer. Those items are the reason a third of our alerts are
repeats, so they are worked before anything that fired today. **A RESUME item NEVER goes to the reviewer**:
it is routed straight to its named lane, seeded with its named plan item, exactly as a RETURN with a ROUTE
line is, and the lane re-measures against today's board first and treats "this no longer reproduces" as a
finding. A RESUME item still needs a plan item in today's plan (the gate reads the whole queue), transcribed
the way STEP 0.9 transcribes an inline item and carrying the prior plan's root cause forward.
RESUME work alone makes the run DUE, so a day whose queue is otherwise clear is a day for finishing what the
last run started. If there is more RESUME work than the run can finish, finish the ones you take and leave
the rest listed - they stay RESUME until their fix actually lands, which is the whole point of the block.
PREVENTION DUE (2026-09-10, ruling 6) is the one exception to stopping on IDLE. When the guard prints a
`PREVENTION DUE` line, after IDLE or after DUE, run STEP 3.5 today even if no weekly-lane item is open: the
weekly lane plans prevention for the scoreboard's top recurring class every week, whether or not anything is
queued, and a clean week is exactly the week it must not skip. With no weekly ids, that run is prevention only.
**THE DAILY LANE IS THE PAGE-CLASS LANE (Brad's ruling, 2026-09-20).** A `review`-class alert - queued for
triage and deliberately never emailed - is now born in the WEEKLY lane and read as weekly even when it was
queued before that rule (`send-alert.ps1` Get-BirthLane, `triage-due.ps1` Get-LaneSplit). Measured that
morning: of 139 alerts in 14 days the top eight types were 47% of them, four of those review class firing on 5
to 10 days each, and a condition that is true every day is not news every day. Nothing is silenced: the item
queues, keeps its count as the condition re-fires, and PULL FORWARD still applies, so when a page-class alert
today is the live symptom of a weekly item, work both today. What this changes is that the daily lane wakes
for the four page conditions and for nothing else.
TWO LANES (2026-09-10). The guard lists the daily lane under `DUE` and weekly-lane items under `WEEKLY LANE`.
`WEEKLY LANE DUE`, or a first line reading `DUE  WEEKLY LANE`, means run STEP 3.5 after the daily lane. A
`WEEKLY LANE ... wait for <date>` line means those items are NOT today's work except by PULL FORWARD, and
they never go to the reviewer. Throughout STEPS 0.75 to 5, "every open id" means the ids under `DUE` plus any
weekly item you pulled forward; the weekly lane's ids belong to STEP 3.5's own plan.

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
  **SAME-DAY DUPLICATES ARE GROUPED BY A SCRIPT, not by eye (2026-09-24, Brad):** run
  `C:\Codex\Python312\python.exe C:\Codex\ThriftyCrew\grocery\triage-group.py --prefix <the day> > <file>` and read
  its GROUP / SINGLE lines. The reviewer gets each group's PRIMARY only; the members go to STEP 0.9's JOB 3 spawn as
  "superseded by <primary>", which verifies each in a few calls and PROMOTES a member whose evidence says it is a
  different cause. Measured that day: 12 alerts sent to one reviewer, 6 of them duplicates it spent calls
  proving, about 270k units per alert; the grouper read the same 14 alerts as 8 groups with no wrong join. The
  family list is data (`grocery\triage-families.json`); add a type there only when every alert of it on a day is
  that one symptom.
- ROUTE THE CHEAP ONES: items whose owner is another job (browser-store link drift, a missed Wednesday
  refresh, anything the SKILL already says waits for the Wednesday browser agent) are named in the
  dispatch as ONE-LINE items. The reviewer must not spend a blast radius on them.
- ASSIGN A TIER TO EVERY ID, and write the list down before you spawn anything. This is the step that
  makes the run cost what it should:
    * **Class A (reviewer + developer)** - anything reader-facing or money-touching, anything where a
      guard is red or the board did not publish, anything whose fix changes a matching rule, and anything
      whose alert body carries a COUNT you have not verified. An unverified count is the tell: three
      separate 2026-09-03 alerts were wrong about their own scale, in both directions.
    * **Class C/D (one small JOB 3 spawn)** - deterministic single-file items (a hardcoded list, a subset to
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

STEP 0.9 - THE CLASS C/D ITEMS GO TO ONE SMALL SPAWN, before the reviewer (since 2026-09-24; until then you
worked them inline, and that is most of why this orchestrator was 31% of the 09-19 run). Spawn
"triage-ops-developer" synchronously in JOB 3 (CHEAP ITEMS) ONCE, with every Class C/D id, your one-line tier
reason for each, the foreign-dirty list, about 10 tool calls per item, and the plan path to write (the next
free sequence name). That plan holds ONLY the C/D ids; gate it with exactly those ids. Items it returns as
`promote` go to the reviewer in STEP 1. Run `triage-cost.py --budget` before the spawn and `--append` after.
Each item must still end with the SAME four things a reviewer would have produced, because the gate reads them:
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
subagent_type "triage-reviewer". Give it ONLY the Class A ids (and any JOB 3 promoted); its plan holds only
those, and the gate is run with exactly those ids (the C/D ids are in STEP 0.9's plan, and STEP 5's
`triage-due.ps1` is what proves no id was dropped between the two). Tell it: the Class A ids in priority order,
which ones are superseded, the foreign-dirty file list, the plan path to write
(`C:\Codex\ThriftyCrew\grocery\triage-plans\` plus the next free sequence name per the rule above, which is NOT
always the bare `plan-<today>.json`), that round = 1, and a per-item effort ceiling
(a tool-call budget for any single item, past which it parks the item as `needs-more-time`). The ceiling is
PER ITEM AND PER CLASS, not one number for the run: name the short wall budget from STEP 0.75 on the items
it applies to, and a real ceiling on the substantive ones. A single ceiling quoted for a mixed dispatch is
how a wall alert ends up costing what a wrong-product alert should.
Tell it too that every planned code item carries `lane` and `est_tool_calls`, that each lane's sum must fit (money
200, ops 100), and that what does not fit is planned `deferred-budget` (README; the gate refuses a plan that does
not fit from 2026-09-25). Measured before this rule: 95 of 201 plan items since 09-10 ended `done` and 78 ended
`deviated` or `needs-more-time`, and an unfinished item comes back at full diagnosis price.
**A RETURN SKIPS THE REVIEWER (Brad's ruling, 2026-09-20, after reading the cost ledger.)** 116 of the 323
alerts in 30 days were a type triage had already closed, and each was paying full diagnosis price again at
about 317k tokens a reviewer run to re-derive a root cause a committed plan already holds. So a RETURN item is
NOT a Class A id: `triage-due.ps1` prints a `ROUTE:` line under each `RETURN:` naming the lane that closed that
type last and the plan item holding the answer, and the item goes straight to that lane in STEP 3, seeded with
that item, with no reviewer stage. The lane RE-MEASURES it against today's board first and treats "this no
longer reproduces" as a finding - that re-measurement is what keeps a wrong prior diagnosis costing one lane's
budget instead of becoming the new answer. It still needs a plan item (the gate reads the whole queue), so
transcribe it the way STEP 0.9 transcribes an inline item, carrying the prior plan's root cause forward. A
RETURN with NO route line (no committed plan holds its priors) is Class A as before, and so is one the lane
hands back. The RETURN fields below are unchanged and the gate still demands them.
RETURNS ARE FAILURES (Brad's ruling 5, 2026-09-10). Paste every `RETURN:` line `triage-due.ps1` printed in
STEP 0 into the dispatch, verbatim. Each names a type triage already closed in the last 30 days and its prior
ids, and the reviewer needs them because the gate derives RETURN status from the QUEUE: a RETURN code item must
carry `prior_closes` (every id on its line), `prevention` (the upstream `source`, `what`, `exact_change`) and
`proof.fixture_occurrences` (every prior id plus today's), and a type returned twice may not name only rule or
exclude files as its source. A Class C/D item JOB 3 works that is a RETURN carries the same fields.

STEP 2 - GATE THE HANDOFF, DETERMINISTICALLY. Do not eyeball the plan; run:
  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\validate-triage-plan.ps1 -Plan <plan> -OpenIds <id1>,<id2>,<id3>
**JOIN THE IDS WITH COMMAS, NO SPACES** (2026-09-21). Under `-File` a space-separated list binds the SECOND id as the next
positional parameter (the queue path), and the gate exits 3 BLIND - failing closed, correctly, but costing a run. The
script splits a single argument on `,` and `;` (validate-triage-plan.ps1 line 86). Every dispatch that names this command
for an agent writes the ids the same way.
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

STEP 3 - IMPLEMENT, IN TWO LANES, ONE AFTER THE OTHER. Split the plan's code items first and write the split
in the report: an item goes to the MONEY lane when its `publish_batch` is 1 or more, its classification is
wrong-product, parse-basis-bug or real-economics, it changes a matching or pricing rule, or it touches a
blocking guard. Every other code item goes to the OPS lane. When in doubt, money.
- MONEY: spawn "triage-developer" synchronously ONCE PER ITEM, in `ship_sequence` order (a fresh, small context
  each time; COST CONTROLS), naming the plan file path, the ONE item id, the routing artifact, the foreign-dirty
  file list, the item's `est_tool_calls` as its ceiling, and either "commit only" or "LAST item of publish_batch N:
  run the board chain and publish once for the batch". Say the plan already passed the gate, so it implements
  rather than re-diagnoses; that it reads its item with `triage-plan-item.py show`; that it never pushes; and that
  its report is under 15 lines. Run `triage-cost.py --budget 10000000` before each spawn and `--append` after.
- OPS: once the money lane has returned, spawn "triage-ops-developer" synchronously in JOB 1 (IMPLEMENT) with the
  same plan, at most THREE of its item ids per spawn, the refreshed foreign-dirty list and their estimates as
  ceilings. Skip it when there are no ops items. An item it bounces as mis-laned (it turned out to touch prices
  or matching) goes to the money lane in this run, inside the money ceiling.
Tell both that every residual in `leaves_open` gets the CHEAPEST HONEST owner (watch, weekly-lane queue item,
or ruling, per COST CONTROLS) before it closes a single queue item, and that
`validate-triage-plan.ps1 -Plan <plan> -Closing` must exit 0 first. After each spawn run `triage-cost.py --append
--plan <plans>` (COST CONTROLS); `-Closing` refuses a plan dated 2026-09-25 or later that no derived row names.

STEP 3.9 - LAND THE RUN ONCE, WITH NO MODEL WAITING ON IT (2026-09-24). After STEP 3 and, when due, STEP 3.5:
  powershell -NoProfile -File C:\Codex\ThriftyCrew\grocery\triage-land.ps1 [-CheckFeed]
run with run_in_background: true (you are notified when it exits; do not poll it), `-CheckFeed` when any agent
reported `republished: true`. Read ONLY its `TRIAGE-LAND-COMPLETE` line. `outcome=landed`: list each plan's items
with `C:\Codex\Python312\python.exe C:\Codex\ThriftyCrew\grocery\triage-plan-item.py ids --plan <plan>` and close
every item whose status is done, deviated or superseded with
  powershell -NoProfile -File C:\Codex\ThriftyCrew\grocery\triage-close.ps1 -Id <id> -Disposition <the item's close_disposition, or confirmed> -Notes "<the item's resolution_note>"
and check each `live_check` an agent wrote with one fetch. `outcome=refused`: read the log it names (the refusal
lines only), fix nothing yourself; send the ONE item whose change the refusal names back to a fresh developer spawn
with that line, then run triage-land once more. A second refusal is reported verbatim with every queue item left
OPEN, never looped. `feed=mismatch` or `feed=blind` after a landing is reported verbatim and is the first item of
tomorrow's run.

STEP 3.5 - THE WEEKLY LANE, only when `triage-due.ps1` said it is due. After the daily lane, or on its own when
the daily lane was empty, spawn "triage-ops-developer" synchronously ONCE, in JOB 2 (WEEKLY LANE), with the
weekly-lane ids oldest first, the foreign-dirty list, 40 tool calls per item and 150 for the lane, and the plan
path to write (the next free sequence name for the day). No reviewer: that agent re-measures, fixes or closes,
and writes and gates its own plan. PREVENTION FIRST, THEN LEFTOVERS (Brad's ruling 6, 2026-09-10): the agent runs
`grocery\audit-alert-census.ps1`, takes the top type by days fired over the prior 14 days that has no
`prevention:<type>` item already shipped or open, and its plan carries `"lane": "weekly"`, `prevention_target` (type,
window_days, days_fired, rank, why_not_top above rank 1), a `prevention:<type>` code item aimed at that class's upstream
source, and `new_source_check`. That last line is the new-source check WAITING ON THE ROW CONTRACT: every new store,
feed or large commodity batch is checked against the contract before it goes live, and until build step 8 exists the
line records that no contract exists yet. The gate recomputes days_fired and rank from the census and is BLIND without
it. Leftovers come after, inside the same ceilings. Then run both gates on that plan yourself (handoff with its ids, then
`-Closing`), and ONLY when `-Closing` exits 0 write the lane stamp:
  [IO.File]::WriteAllText('C:\Codex\ThriftyCrew\grocery\triage-weekly-lane-stamp.txt', (Get-Date).ToString('o'), (New-Object Text.UTF8Encoding($false)))
A lane that ran and did not close was not worked, so it stays due tomorrow (the test-guards stamp lesson,
queue 2026-09-10-267ba6). Weekly items left `needs-more-time` stay open; they are neither STEP 4.5 arrivals nor
a bounce. Then run `triage-cost.py --append --plan <that plan>`.

STEP 4 - ONE BOUNCE ROUND, MAX. If the developer reports items with status "bounced" (a genuinely NEW
failure class it found while implementing, not a detail), spawn the reviewer again for round 2 with ONLY
those items, writing the next sequence number, then the developer again on that plan. Pass the bounce's own
MEASUREMENT to the reviewer, and tell it to test that measurement first: on 2026-07-31 a bounce claimed two
commodities had no sanity band, both did, and round 2's first job was disproving its own premise. Stop after round 2:
anything still unresolved becomes needs-brad with ONE specific email via
`grocery\send-alert.ps1 -Force`. Discovery during implementation is normal here (on 2026-07-30 a second
wrong-product cell only appeared after the first exclusion rebuilt the board), which is why this round
exists and why it is capped. **The cap is a gate since 2026-09-25**: `validate-triage-plan.ps1` refuses a
plan whose `round` is above 2 unless it carries `round_override` quoting Brad and the date, because plans
reached round 5 on 09-20 and round 6 on 09-22 with this sentence as the only brake.

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
  arrivals STEP 4.5 deliberately left for the next run, or list weekly-lane items that are not due or that
  STEP 3.5 left `needs-more-time`. Those are the ONLY clean endings. If it is DUE for anything else, that is
  an item the run dropped, and the report names it rather than closing quiet.
- Run `C:\Codex\Python312\python.exe C:\Codex\ThriftyCrew\grocery\triage-cost.py --append --plan <every plan
  this run wrote>` one last time, so the orchestrator's own row is current, and commit
  `grocery\triage-plans\cost-ledger.jsonl` with the plan. The report gives the session's cost_units against the
  10M budget (the BUDGET line verbatim), the `--report` line of each of today's plans (cost per done item), and
  tool calls against the ceilings. `python grocery\triage-cost.py --check-agents` must exit 0: the three copies
  of each triage agent (the repo, C:\Codex\.claude\agents, ~\.claude\agents) are identical.
- Re-run `grocery\audit-alert-census.ps1` so its numbers include this run's closes, quote its QUIET DAYS,
  TARGET and RETURNS lines, and commit `grocery\out\alert-census.jsonl` by explicit path with the plan. That
  file is the only history of alerts older than the queue's 30 days, so a copy that lives on one disk is not
  a scoreboard.
- `git -C C:\Codex\ThriftyCrew status --porcelain`: no .ps1, commodities.json, categories.json,
  commodity-search.json, allowlist/config json, SKILL or plan file left uncommitted. Regenerated pipeline
  output (out\*, board.json, feed, logs) is the pipeline's, not ours.
- HEAD == origin/main.
- `powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\validate-triage-plan.ps1 -Plan <plan> -Closing`
  exits 0 for EVERY plan this run wrote, and its LEAVES OPEN lines go into the report VERBATIM with their
  owners. Never summarise them, and never write "nothing else is waiting" over them. Founding case
  2026-09-09: four items shipped a root fix covering a slice of their own root cause, the residuals sat in
  `deviation` prose, and this orchestrator's report called all eight closed. Brad found it by asking.
  Residual queue items the developer created in this run are NOT STEP 4.5 mid-run arrivals: leave them
  open. They were born in the weekly lane, and STEP 3.5 of a later run works them.
- If the board was republished, one fixed cell verified on the LIVE page, fetched with a fresh
  cache-busting query parameter (the chip data sits behind a ~30 minute edge cache keyed on a `?v=` hash,
  and a pre-push fetch of the new key serves stale bytes back).
- Alert hygiene: if any queue entry carries `body_thin: true`, the ALERT is the bug as much as the
  condition it describes. Say so in the report; an alert nobody can classify from its own body cannot be
  triaged without hunting the data by hand.
BEFORE YOU WRITE THE REPORT, RE-READ IT FOR DEFERRED WORK. Any line that tells Brad a defect exists and
was not fixed is a line you should have spent fixing it. Go back and fix it, or say in the report why it
was genuinely blocked (a foreign dirty file, another owner mid-edit, a decision only he can make). "I ran
out of run" is not a blocker, it is an unbounded item that should have become a queue entry. The only
things that belong in a to-Brad list are RULINGS and items with a named blocker.
Report per item: queue id, classification, what shipped, and whether the board republished. Then the
clean-tree line. If a stage failed, say so with its output rather than summarising it away.

FALLBACK: if a subagent type is unavailable or a spawn fails twice, do not skip the day. Run the single
agent playbook in `SKILL.monolith-fallback.md` (the version that ran through 2026-07-30) inline yourself,
and say in the report that you fell back and why. If ONLY "triage-ops-developer" is unavailable (a session
that loaded its agent list before that agent existed), give its items to "triage-developer" with the OPS
ceilings instead of falling back, and say so.

HARD RULES (they bind you and both agents): never fabricate a price; never bypass a CAPTCHA (hard stop);
accuracy over safe (understating is as wrong as overstating); guards fail closed and STAY that way, never
weakened to make a run pass; any visual change gets the 375px mobile check before publishing; no em dashes
in any copy.