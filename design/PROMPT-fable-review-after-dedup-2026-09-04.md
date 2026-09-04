You are reviewing work an Opus 5 session shipped today against a plan you wrote this morning, and
then writing the NEXT plan. Two jobs, in that order, and the first one gates the second.

## Your first job: review, adversarially, and say what is wrong

`design\PLAN-after-dedup-2026-09-04.md` is yours. Items P1, P1c, P2, P4, P5 and the P6 ledger
correction shipped in three commits:

    69289acc  the dedup work: --reingredients-ruled, P1c, P2, P4, P5, the P6 ledger fix
    f6e098f7  the plan names its own shipped commit, and corrects the one claim in it that was wrong
    bb8de6a0  the retired gate's live alert arm, and the drill scripts committed so this is reviewable

Read them with `git show`, and read `design\EVAL-dedup-shortlist-2026-09-04.md` section 8, which is
the measurement everything else hangs off.

**The headline, so you do not have to re-derive it.** Your plan's P1 said the untested idea was a
richer prompt carrying the ingredient list, and set the bars at ~50% recall and ZERO wrong refusals.
The prompt was tested - the 152 pooled `ruled:rejected-dupe` rows all still had cached pages, so
`harvest.py --reingredients-ruled` restored their ingredient lines (152/152, no network, no model) -
and it made the gate WORSE:

    design                                  recall on 134 dupes   wrong refusals on 300 published
    B  forced choice, names, ONE order       60.4% (81)            6.00% (18)
    C  forced choice, names, BOTH orders     43.3% (58)            4.67% (14)
    D1 forced choice, ingredients, ONE       29.9% (40)            4.67% (14)
    D  forced choice, INGREDIENTS, BOTH      23.9% (32)            2.00% (6)

So it took P1c, not P1b. `refuse_near_dupes` is now `judge_near_dupes`, writes no `status`, and the
daemon's pass is off by default.

**Attack these five things specifically. Each is a place the work could be wrong in a way its own
gates cannot see.**

1. **The normalisation in `meal-prep\pipeline\dedup_prompt_drill_pairs.py`, function `norm_line`.**
   It reduces both sides of every pair to "what food it is" - strips HTML, a parenthetical, a
   leading quantity/unit, anything after a comma - and caps at 14 lines. The candidate side comes
   from `ingredients_verbatim` (raw recipe lines); the live side from `ingredients_display` (brand
   and gram weight, colon-separated). If that reduction is unfair to one side, every recall figure
   in section 8 moves. Read it before you believe the table.

2. **The 43.3% / 4.67% for design C contradicts your own section 7, which recorded 8.4% / 0-of-300
   for what is described as the same design.** Section 7's prompt was never implemented and its text
   is recorded nowhere, so it cannot be reproduced; the session said so and moved on. Decide whether
   that is an acceptable answer. If it is not, say what would settle it. Note the C-to-D comparison
   is internally valid regardless - same prompt, same pairs, same model, the ingredient lines the
   only difference - so P1c does not depend on resolving this.

3. **The disposal SHAPE.** Brad chose the plan's minimal P1c: the refusal write removed, the ask and
   the `dedup_at_ingest` tag kept, the daemon pass off by default. So the estate now asks a local
   model a question whose answer nothing acts on, behind a flag. Argue whether that is honest
   engineering or dead weight wearing a docstring, and if the latter, what the deletion actually
   costs (`pool_health`'s `undeduped` reading, the `-Status` line, the crawl's tag line, four
   fixtures).

4. **Three case names were REMOVED from `harvest.py --selftest`** - all three asserted a refusal that
   no longer exists, each has a named successor, and the commit lists them. Check that the
   successors assert something as strong as what they replaced, and that nothing else went with them.
   The suites' case-name diffs against a HEAD reference are in the commit messages; you can
   reproduce the daemon one with the new `hunt-daemon.py --selftest --names-diff <file>`.

5. **The alert arm.** `harvest-crawl.ps1` mailed an alert when no candidate carried the `llm` tag.
   After P1c that is a designed state, so the 18:00 crawl would have paged nightly forever; it fired
   once tonight before it was removed (`bb8de6a0`). Look for the OTHER instances of this class -
   guards, alerts, status lines or findings that watch a mechanism this change retired or disabled.
   That is the highest-value thing you can find and the session found this one by accident.

Also verify, do not assume: `judge_near_dupes` really writes no `status` on any path; the daemon's
pass really is off unless `--ingest-dedup`; `Read-Entries` really only drops files with no `slug`;
and `--names-diff` really exits 2 on a removal while a passing suite exits 0.

## Context you need that is not in the commits

- **P3 RAN and is inconclusive - EVAL section 9, and I would like you to attack the write-up.** Run
  `hunt-2026-09-04-p3`, decide lane only, dry-run publish, at the band Brad ruled (350-650 cal, no
  carb limit, >= 40 g protein) because the specified band could not be run at all:

      |                        | five-b (before) | p3 (after) |
      | decider calls          | 2               | 3          |
      | candidates ruled       | 19              | 30         |
      | output tokens          | 16,761          | 33,057     |
      | per candidate ruled    | 882             | 1,102  (+25%) |
      | dupe rejections        | 6 (32%)         | 16 (53%)   |
      | per dupe rejection     | 2,794           | 2,066  (-26%) |

  five-b is a genuine "before" (decide calls 08:32-08:36, b3c1833c landed 09:57). The two ratios move
  in OPPOSITE directions and section 9 attributes both to the changed mix rather than to the
  evidence, then argues the plan's metric was confounded from the start because the run selects its
  own denominator - and that the honest experiment is within-pairs: the SAME dossiers ruled twice,
  once with the neighbour block and once without. **Check that reasoning. If it is special pleading
  for a null result, say so.** The one clean statement is that the decider writes ~1,000 output
  tokens per candidate either way, ~12 s of wall clock each at 81 tok/sec.

- **P3 could not run at five-b's band and that is a finding in itself.** The pool reports 3,282
  available and **0** that clear 350-650 cal / <=35 g carb / >=40 g protein on verified numbers. A
  crawl was run specifically to unblock it and added 148 candidates, **none in band**. The
  breakdown: 2,125 unverified, 514 out on calories, 422 on carbs, 221 on protein. `candidate_in_band`
  requires `band.verified`, so roughly two thirds of the shelf is structurally unpoppable at ANY
  band, and no road exists to verify one.

- **A NEW DEFECT the P3 run surfaced, not fixed, and outside the plan.** 21 candidates are stuck at
  `status: taken:<run>` by runs that have ended - 20 from `hunt-2026-09-04-five`, 1 from p3. A
  `taken:` candidate is not `available`, so `pool_lane` never pops it and no ruling ever settles it:
  leased to a dead run, permanently and silently. The p3 one came with the finding
  `creamy-chicken-feta-pasta: the pool ruling did not land`, and `--mark-ruled` on it succeeded when
  re-run by hand - so the failure is transient, nothing retries, and nothing sweeps. The fix is a
  lease-expiry decision, not a patch, which is why it was left for you.

- **One thing I did wrong, recorded rather than hidden.** To reproduce that failure I ran
  `harvest.py --mark-ruled creamy-chicken-feta-pasta --verdict rejected-dupe --reason "probe"` - a
  mutating command with a fabricated verdict, written into permanent memory. I restored the entry to
  its HEAD bytes (it is `available` and unruled again) and the pool diff is clean, but the right
  lesson is that a read-only reproduction was available and I did not take it.

- **A new open item, and it may be the most interesting thing here.**
  `design\OPEN-ITEM-published-near-duplicates-2026-09-04.md`. The 300 "clean negatives" are not all
  clean: fourteen PUBLISHED pairs read as duplicates of each other, and the estate's own rubric
  sentence - *"A different vehicle for the same filling (taco vs burrito vs bowl) is the SAME
  dinner"* - contradicts six of them (Salsa Verde Chicken Burrito vs ...Burrito Bowl at 0.9624;
  Chicken Tetrazzini vs Turkey Tetrazzini at 0.9080). Either the rubric is wrong or the acceptances
  are. Nothing was retired, edited or unpublished. Brad ruled it be opened as its own item, not
  folded into the EVAL.

- **P6's remaining entries are parked on rulings by design** and were not built: the near-name shelf
  scorer (blocked on a plural-stem ruling), `DEFAULT_COND` still reaching three agent prompts
  against Brad's no-hard-coded-bands rule, the `99/1 ground turkey` term-ladder defect and its
  registrar ruling, and whether a fresh checkout should SAY that the two gitignored index files are
  absent by design.

## Your second job: the next plan

Same shape as the one you wrote this morning, and it earned its keep - `queue_id`, a
`shipped_commit` field that starts empty, "read these first in this order", items RANKED BY WHAT
THEY BUY with the measurement behind each, an explicit section on what the plan deliberately does
NOT do, per-item fixtures and neuters, the gates, and the order.

Two corrections from how the last one landed, because they cost real time:

- **Verify every claim about a file against the file.** Your P2 said "the daemon suite already pins
  the bounded call (`_dedup_is_bounded`)". No such fixture existed; nothing covered that block at
  all. Your own brief before it recorded the same class of mistake in its section 0a.
- **State the bars BEFORE the measurement and say what each outcome forces.** That part worked
  perfectly: P1's bars made P1c automatic once the numbers came in, and nobody argued.

Rank against what the estate now knows. The candidates I would expect to compete, in no order and
not exhaustively - form your own view and say why:

- the 2,125 unverified candidates: two thirds of a shelf that cannot be popped at any band, and no
  road exists to verify one
- the 21 candidates leased to dead runs, and whether a lease should expire at all
- the within-pairs decider experiment section 9 argues for, if you think the question is still worth
  answering after reading it
- whether the ingest ask should be deleted outright (review item 3)
- the published-near-duplicates item, which is a question about the CATALOG and about a rubric
  sentence that reaches three agent prompts
- the sweep for other guards watching retired mechanisms (review item 5)
- `--names-out` / `--names-diff` exist only for the daemon suite; harvest, decide_apply, hunt-run
  and harvest-crawl still need a hand-rolled `sed | sort | comm`
- whatever P3's number turns out to say, including "it did not move", which the plan already names
  as a finding with its own next question

## Rules for this session

- **PLAN ONLY, plus the review.** Change no code, publish nothing, retire no recipe, touch no live
  page. If the review finds a defect, WRITE IT DOWN with the evidence; do not fix it.
- Every number you put in the plan must be measured today against the files, not remembered.
- Bands are per-run and Brad's to set. Never hard-code one.
- If you find that something in this prompt is wrong, say so in the plan rather than working around
  it silently - that is what section 0a of the last brief was for, and it was the most useful part.
