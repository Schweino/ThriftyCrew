# PLAN: after the dedup work - what is open, ranked by what it buys

queue_id: after-dedup-2026-09-04
shipped_commit: (none yet - if this field names a commit, the work is DONE: verify it and report,
do not rebuild)
author: Fable 5.1, 2026-09-04, PLAN ONLY. Written for Opus to build from. Every number below was
measured the same day; every claim about a file was checked against the file, not remembered.
ruled by: Brad, 2026-09-04 - "create a PLAN ONLY for Opus to address the above open items and/or
efficiency opportunities".

## 0. Read these first, in this order

1. `design\EVAL-dedup-shortlist-2026-09-04.md` sections 6-7. The ingest dedup gate has never fired
   and cannot; the two question-designs measured against it; and why name-only prompting cannot
   reproduce the decider's judgement. Everything in P1 hangs off that.
2. `design\BRIEF-dedup-before-the-decider-2026-09-04.md` section 0a - two of its instructions were
   wrong and were not followed. Read it so you do not re-propose starting llama-server from the crawl.
3. `meal-prep\pipeline\harvest.py`: `refuse_near_dupes`, `dedup_shortlist`, `dedup_ask_floor`,
   `dedup_pending`, `slim_ruled` / `DUPE_KEEP`, `cmd_reingredients` and `cached_body`.
4. `meal-prep\pipeline\hunt-daemon.py` main(): the block that calls `harvest.dedup_ingest_pool` at
   run start (search for "DEDUP BEFORE THE DECIDER").
5. The three commits that shipped today, in order: b3c1833c, 2e66151c, 1a940069. Their messages are
   the record of what was measured and what was deliberately NOT done.

## 1. Where things stand (measured 2026-09-04, after 1a940069)

    pool evidence   3134 available; 3134 carry neighbours, 0 BLIND to the decider
    dedup at ingest (unset)=3133, unavailable=1
    embed index     fresh, covering 3134 of 3134

The decider now receives evidence on every candidate. The INGEST gate - the thing meant to stop a
duplicate before it costs a decider call - has refused 0 candidates ever, and the reason is settled:

| design | wrong refusals, 300 hardest published pairs | recall, 155 real dupes |
|---|---|---|
| A  two-polarity contract (shipped) | 0 | 0.0% - cannot fire |
| B  forced choice, one order | 4 (1.3%) | 9.7% |
| C  forced choice, both orders agree | 0 | 8.4% |

The misses are systematic: `Ground Beef Stroganoff` vs `Ground Beef Stroganoff Pasta` reads as
different dishes. The decider rules on a dossier (ingredients, method, band, neighbours); the local
model is handed `"dish: <name>. protein: <protein>"`. No question design fixes absent information.

**One thing said today was wrong and this plan corrects it.** Section 7 of the EVAL says the richer
prompt "cannot be run today" because the 155 labelled dupes lost their ingredients to `slim_ruled`.
Checked after writing that: **all 152 rejected-dupes in the pool still have a cached page body**
(`cached_body(url)` is not None for every one, no network needed) **and all 152 have a ledger twin**
in `db\considered-dishes.json`. The ingredients are one re-parse away. P1 is unblocked.

## 2. The work, ranked by what it buys

### P1 - Test the richer prompt on the labelled pairs. Decide the ingest gate's fate on the result.

This is the only remaining road to an ingest gate that works, and it is now cheap: local GPU only,
zero Claude tokens, no network.

**Build:**
- A `--reingredients-ruled` road (or a flag on `--reingredients`) that re-parses ingredient lines
  from the page cache for `ruled:rejected-dupe` candidates. `cmd_reingredients` already does exactly
  this for `available` ones - lift the status filter, nothing else. It writes the pool through
  harvest's own verb; it is a re-parse of pages already fetched.
- A measurement script (scratch, not shipped) that for each of the 152 pairs builds BOTH sides with
  ingredients - the candidate from the pool, the twin from the live recipe (verify where live
  ingredients live: `meal-prep\db\recipes\` or the spec; do not assume) - and asks the local model
  ONE forced-choice question, both orders, with ingredients in the prompt. Same grammar
  (`root ::= ("same" | "different")`), temperature 0, same model.
- The same script against the 300 hardest PUBLISHED pairs with their ingredients, for wrong refusals.
  Both members of every one are live, so ingredients exist for all of them.

**The numbers to beat, and the decision they force:**
- Recall on the 155: today's best is 8.4% (design C). A prompt that does not clear ~50% is not worth
  a gate: at 6 dupe rejections per run it would save ~3 decider rejections of ~8,000 output tokens
  each, roughly 40 seconds of wall clock per run, against the pass's own cost.
- Wrong refusals on the 300: today's C scores 0. **Anything above 0 on the hardest published pairs
  is a recipe thrown away.** Report the actual pairs, not the count - Brad rules on the pairs.
- If recall clears the bar at 0 wrong refusals -> P1b. If it does not -> P1c.

**P1b - implement it.** Replace `llm_same_dinner` + `llm_different_dinner` conjunction with the
ingredient-carrying forced choice agreed across both orders. The ingredients reach the pass because
candidates carry `ingredients_verbatim` while available (check: 1,188 of 3,134 do - the rest were
ingested before `--reingredients` existed; run it first). The two-polarity fixtures in harvest's
suite change NAME - say so in the commit and show the case-name diff. Neuters: the order swap
dropped; ingredients removed from the prompt; both must redden.

**P1c - retire the refusal path.** If no prompt earns a gate, do not leave dead code that reads as a
working safeguard. Keep the tags and the shortlist (they are the decider's evidence), remove the
`ruled:rejected-dupe` write from `refuse_near_dupes`, and say in the docstring what was measured and
why. Then P2 becomes "remove", not "default off".

### P2 - Stop paying ~70 s per run for a gate that cannot fire

`hunt-daemon.py` main() now runs `dedup_ingest_pool` at every run start: 60 candidates took 106 s
for zero refusals. With cap `max(40, target*4)` that is ~70 s of local-model time per run buying
nothing until P1 lands. Add a `--no-ingest-dedup` flag, default it ON while the gate is inert, and
have the daemon SAY on its first status line that the pass is off and why (a silent skip is the
failure class this whole week was about). When P1b ships, flip the default. When P1c ships, delete.

Fixture: the daemon suite already pins the bounded call (`_dedup_is_bounded`); add the twin - with
the flag, no `dedup_ingest_pool` call happens and the status line names the reason.

### P3 - Measure whether the decider itself got cheaper now that dossiers carry evidence

This is the half of the original brief's section 7 that is still meaningful regardless of the ingest
gate. Every dossier now carries bge-m3 neighbours (was 70 of 3,134). The question is whether the
decider REJECTS FASTER when the evidence is attached - fewer output tokens per rejection - or whether
it re-derives from scratch anyway.

Baseline, hunt-2026-09-04-five-b: 16,761 output tokens across 2 decider calls, 19 candidates ruled,
6 rejected as dupes. One run at the same band and target, then compare output tokens per candidate
ruled and per dupe rejection, read off the transcript (not the envelope - see
EVAL-hunter-wall-clock section 2b). **This costs Claude tokens and the card; Brad launches it, not a
session.** If the number does not move, that is the finding: the decider is not reading the
neighbour block, and the next question is why.

### P4 - Make the pinned-reference gate a real tool, not a scratch script

The daemon suite is 300 s. Every gate today ran it TWICE - once for a HEAD reference, once for the
change - because the case-name diff needs a reference. That is the whole of the "13 minutes" and
it is avoidable: `hunt-daemon.py --selftest --names-out <file>` to emit the case-name list, and a
`--names-diff <file>` that reruns and reports removed/added by NAME with exit 2 on any removal.
Pin the reference once per session from HEAD's bytes. **Do not cut Q1-Q3** (43% of the suite) - they
launch the real scripts and are the only cases that can see what they see; EVAL section 5 records why.

### P5 - An entry with no state, in hunt-2026-09-04-five-b

`-Status` shows one recipe bucketed `(no state recorded)`. The label is new (2e66151c); the entry is
not. Find which state file it is, why it has no `state`, and whether the state machine can produce
that shape or whether something wrote around it. Small, but a stateless entry in a run that
publishes is a recipe that can neither advance nor be rejected.

### P6 - Parked on rulings, listed so they are not lost

- `BRIEF-near-name-shelf-2026-09-04.md`: blocked on the plural-stem ruling (three options in the brief).
- `BRIEF-no-hardcoded-bands-2026-09-04.md`: the prose side (`DEFAULT_COND`) still reaches three
  agent prompts. Brad's rule is bands are per-run, never hard-coded.
- The `99/1 ground turkey` -> `99/1turkey` term-ladder defect, and the registrar ruling for
  `99-1-ground-turkey`.
- The open-items ledger: section 4 says OPEN where section 3A says BUILT (four entries).
- `catalog-similarity.json` and `harvest-neighbours.json` are gitignored; a fresh checkout has
  neither until the first crawl runs. That is by design, but nothing SAYS so at checkout time -
  `--pool-health` reports `missing` and the crawl heals it. Decide whether that is enough.

## 3. What this plan deliberately does NOT do

- **It does not swap the dedup question again without ingredients in the prompt.** Two name-only
  designs were measured at scale; a third name-only design is not a test, it is a guess.
- **It does not let a script rule a duplicate.** P1b's gate refuses only what the local model judged
  under a contract that was validated on 300 published pairs at 0 wrong refusals. The decider stays
  the sole author of acceptances.
- **It does not backfill `dupe_of` or ingredients onto the 152 by guesswork.** The ledger's `dupe_of`
  is authoritative and joinable by slug; P1's re-parse comes from the page cache, not from inference.
- **It does not start llama-server from the crawl.** Three fixtures forbid it and the ruling behind
  them is recorded in the brief's section 0a.
- **It does not touch `DEDUP_SHORTLIST_MIN`, the band, or any live recipe.**

## 4. Fixtures and neuters, per item

Each item ships with a MUST-FIRE/CLEAN-TWIN pair in the suite that owns the code, and at least one
neuter run ONE AT A TIME with the count MEASURED and the file restored by md5. Write the measured
counts into the commit message; never predict them. Specifics:

- P1  `--reingredients-ruled` restores lines for a rejected-dupe from a scratch cache (must fire);
      leaves an `available` candidate's lines alone unless asked (clean twin). Neuter: the status
      filter reverted.
- P1b the gate fires on an injected `same/same` and not on `same/different` (must fire); the prompt
      carries the ingredient lines, asserted by reading the prompt the pass builds (must fire).
      Neuters: order swap dropped; ingredients dropped from the prompt.
- P2  flag on -> no model call, status names it (must fire); flag off -> the bounded call (twin).
- P4  a removed case name exits 2 (must fire); an added one exits 0 (twin). Neuter: the removal
      check reduced to a count.

## 5. Gates

`harvest.py --selftest`, `decide_apply.py --selftest`, `hunt-daemon.py --selftest` in the background
with a case-NAME diff against a reference pinned from HEAD's bytes (nothing removed unless the
commit says which and why), `hunt-run.ps1 -SelfTest`, `harvest-crawl.ps1 -SelfTest`. Exit code
first, tally second. Commit with `git commit -F`, explicit `git add` paths, never `-A`.

## 6. Order

P1 first - it decides the shape of P2 and whether P1b or P1c exists. P2 immediately after, in the
same session. P4 whenever a gate is about to be run twice again. P3 only when Brad launches it.
P5 and P6 as budget allows, P6 only on rulings.
