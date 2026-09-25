# PLAN: cut the daily triage run's token cost (2026-09-25)

Brad, 2026-09-25, after the day's run: "Doesnt the token usage seem really high?" then "Yes please" to a plan.
This file is that plan. **Nothing is built by it.** Pick it up in a FRESH session: the session that wrote it was at
93% of its budget, and a carried-forward session pays again for everything already in its context.

## 0. The numbers this starts from

The source is the 2026-09-25 run, session `2b1aec82`, from `grocery/triage-cost.py --append` (the rows are in
`grocery/triage-plans/cost-ledger.jsonl`; the last row is uncommitted and lands with the next run).

- **Total:** 9,275,890 cost_units against the 10M interim cap. 12 agent rows (11 spawns plus the
  orchestrator), about 430 API calls, context averaging about 110k.
- **Output:** 13 queue items closed, and 5 of them shipped code: 0c8e6e, a09096, c9f0f3, 5ad03d, 80f302.
  That is about 1.9M per code fix.
- **Earlier single-day runs:** 18M, 26M and 45M (SKILL COST CONTROLS). This was the cheapest run measured.
  That does not make it cheap.
- **Calibration** (SKILL, one reading on 2026-09-24): about 7M is 1% of the weekly plan limit. So this job
  alone costs about 1.3% of the week per day, and about 9% per week.

| agent | cost_units | calls | ctx_avg | note |
|---|---|---|---|---|
| orchestrator | 2,098,238 | 82 | 162,753 | the target is 60 calls; follow-on work ran in the same session after the report |
| developer aee6ba8 (ruling A, then resumed) | 1,309,168 | 47 | 151,610 | the SendMessage resume re-read a 150k context on every call |
| reviewer | 1,298,052 | 42 | 141,636 | 3 items: 1 deferred, 1 changed under it before the developer ran |
| ops JOB 3 (16 cheap items) | 1,022,488 | 45 | 130,346 | |
| 5 other money developers | 2,570,387 | 10-30 each | 63k-135k | two paid 512,478 in wait re-writes |
| ops 90de7b (Hy-Vee) | 544,468 | 24 | 81,479 | nothing shipped: 28-call ceiling, needed about 40 |
| 2 small spawns | 274,450 | 10 each | about 42k | the floor: even a 10-call spawn averages 42k context |

## 1. The four changes, in order of expected size

Each change is measured against the next run's ledger. The bar is set in cost_units before the change ships.
"The number moved" is not "it improved": report the change over the number of runs, and the number of variants tried.

### W1. Measure the per-spawn floor, then trim it (expected to be the biggest; UNPROVEN)
A 10-call spawn averages about 42k context before it has done much. I **guessed** in chat that this was the
global CLAUDE.md, the workspace CLAUDE.md and the long MEMORY.md index being loaded into every subagent. The
store contradicts that guess: `course/procedure.md` Step 5 says CLAUDE.md is "main sessions only". So do not
act on the guess.
1. Measure first. From a spawn's transcript, take its first API call. Break its input into: system prompt,
   agent definition, injected context (memory index, rules, recall hook blocks), and the dispatch.
   `triage-cost.py` already reads these transcripts, so add a `--first-call` breakdown there. Do not write a
   second reader.
2. Cut only what the breakdown names. The likely levers: the three triage agent definitions (their size in
   bytes, each loaded on every call), the recall and reflex hooks injecting blocks into subagents, and any
   memory index a subagent does receive.
3. The bar: the median ctx_avg of small spawns (10 calls or fewer) drops from about 42k to 25k or less.
   Keep the agent definitions' three copies identical (`triage-cost.py --check-agents`).

### W2. The orchestrator stops at the report (cost today: about 2.1M, or 23%)
- Make it mechanical: after STEP 5, a run of `triage-cost.py` with a flag such as `--session-closed` stamps
  the session. Any later spawn from that session prints a refusal line telling you to open a fresh session.
  The SKILL already says this in prose ("THIS SESSION IS THE DAILY RUN, NOT A WORKSPACE"), and today it did
  not hold: the ruling-A work and two landings ran in the same session.
- Keep the orchestrator's own reads small: triage-due's RETURN/ROUTE block printed about 10k characters into
  context. Have triage-due write the full block to a file and print one line per id.
- The bar: 60 orchestrator calls or fewer, and orchestrator cost_units at 1.2M or less.

### W3. Never resume a big agent; spawn fresh from the plan item (cost today: about 0.5M or more)
- Add it to the SKILL (STEP 3 and STEP 3.9) and to the rules each agent file carries: a follow-up goes to a
  fresh spawn seeded with `triage-plan-item.py show`, never a SendMessage to an agent whose context is over 60k.
- Make it mechanical where possible: a PreToolUse hook on SendMessage refuses when the target agent's last
  context (from its transcript) is over 60k. The recall-brief-gate hook is the model to copy.

### W4. No model waits on a long test (cost today: 512,478 in wait re-writes, or 5.5%)
- test-auditors takes about 5 minutes, and the prompt cache expires after 5 minutes of idle time. Agents
  should start the full suite in the background, write the exit code to a file, and end their turn.
  Alternatively they commit and let `triage-land.ps1` run it (it does already: prepush-test-auditors), then
  report `full_suite: deferred-to-land`.
- Size the ceiling honestly: the reviewer's `est_tool_calls` for 90de7b was 28, and the work needed about 40.
  Have `validate-triage-plan.ps1` compare each estimate against the finished calls of the same classification
  in recent plans, and warn when it is under the median.

## 2. Not in this plan
- Lowering effort levels or switching models. The 2026-09-24 lean plan already moved the reviewer to high,
  and both lanes to medium.
- The 10M cap itself. Brad still owes a ruling on the weekly share triage may use (SKILL COST CONTROLS).
- The "deviated" status overload. It is its own weekly queue item (filed 2026-09-25), but it costs tokens
  too: 3 finished items return as RESUME tomorrow, and each one is a spawn.

## 3. Order and proof
W2 and W3 first: they are cheap, mechanical, and remove today's largest avoidable costs. W1 second, and it
starts with the measurement. W4 last. Every change carries a must-fire fixture and a clean twin, as the
triage gates require, and the proof is 5 runs of `triage-cost.py --report` lines afterwards, compared with
today's 9,275,890 per run and 1.9M per code fix.

## 4. What was built, and what W1 measured (2026-09-25, same day, a fresh session)

Brad picked "build all four in order". Nothing below has been measured on a run yet: the five `--report` runs in
section 3 are still the proof, and until then every saving here is an estimate.

**W1 measurement** (`grocery/triage-cost.py --first-call --session 2b1aec82-f692-4005-8acb-a36b51910a3a`, 12
transcripts). The guess in section W1 was half right, and the half that was wrong is the bigger one.
- Every spawn's first call is 28,304 to 31,665 tokens. Its recorded prelude is 49k to 59k characters: the agent
  definition (18.7k ops, 26.8k reviewer, 27.7k developer), the C--Codex `MEMORY.md` index (16.3k), the two
  CLAUDE.md files (4.8k and 4.9k) and the dispatch (3.4k to 6.5k). The rest is the harness system prompt and tools.
  So `course/procedure.md`'s "CLAUDE.md is main sessions only" was wrong; it is corrected there.
- **The bigger cost is a load AFTER the first call.** The first time a spawn touches a file under ThriftyCrew, the
  harness adds ThriftyCrew's CLAUDE.md and all six `.claude/rules/*.md` files: 154,825 characters, a context jump of
  61,329 to 70,254 tokens, re-read on every later call. It happened in 8 of 11 spawns, 9 loads in all (the resumed
  aee6ba8 loaded it twice); the other 3 never read a ThriftyCrew file. Priced by what it did (1.25 x the
  jump once, plus 0.1 x the jump per later call): **about 1,861,417 cost_units, 20% of the 9,275,890 run.**
  `ops-and-gates.md` alone is 90,563 of those 154,825 characters (58%).
- The bar in W1 (small spawns' median ctx_avg from about 42k to 25k) is not reachable by trimming what W1 named:
  the three small spawns never loaded the rules, and their floor is about 28k at the first call. The rules load is
  the lever, and cutting it contradicts the W2.3 ruling that the rules load in every session. **That is Brad's
  decision and it is not built.** The options are in the report of this session.

**W2 built.** `triage-cost.py --session-closed` stamps the session under `%LOCALAPPDATA%\ThriftyCrew\triage-closed`;
`~/.claude/skills/triage-spawn-guard-hook.py` (PreToolUse Agent|Task|SendMessage, in `~/.claude/settings.json`)
refuses any Agent or Task call from a stamped session. SKILL STEP 5 runs it last. `triage-due.ps1` prints one line
per RETURN and writes the full RETURN and ROUTE lines to `%LOCALAPPDATA%\ThriftyCrew\triage-due-returns.txt`
(`TC_TRIAGE_DUE_RETURNS_FILE` overrides it for fixtures); the SKILL names the file in the reviewer's dispatch.

**W3 built.** The same hook refuses a SendMessage to a triage agent whose last call's context is over 60,000
tokens. On 09-25's transcripts it refuses a resume of aee6ba8 (256,959) and allows add1e97 (49,072). The SKILL's
STEP 2 said to send a failed plan back to the same reviewer by SendMessage; that now goes to a fresh reviewer spawn.

**W4 built.** Both developer definitions say never wait on the full test-auditors and report
`full_suite: deferred-to-land` (triage-land's push-main runs it), and write `actual_tool_calls` on close.
`validate-triage-plan.ps1` warns at handoff when an estimate is under the median `actual_tool_calls` of its
classification over 21 days, with at least 3 finished items. No plan carries that field yet, so the warning is silent
until three items of a classification have closed with it.

## Knowledge consulted
- Searched "subagent context CLAUDE.md memory index loaded".
  `course/procedure.md` Step 5: "`CLAUDE.md` - main sessions only". That contradicts the chat guess, so W1
  starts with a measurement.
- `claude-code-craft/applies-here.md`, the section "A spawn's `total_tokens` is its last call's context, not
  what it cost". So every number here comes from `triage-cost.py`, never from the harness usage block.
- SKILL `grocery-alert-triage` COST CONTROLS (the four rules of 2026-09-24, the 10M cap, and the
  7M-is-1%-of-the-week calibration).
