# REVIEW: the dedup work shipped 2026-09-04, read adversarially

author: Fable 5.1, 2026-09-04 evening. REVIEW ONLY - no code changed, nothing published, no recipe
touched, no pool write. Every number here was measured against the files this evening; where a
measurement was re-run it was run from the scratchpad against COPIES or read-only.
reviewed: 69289acc, f6e098f7, bb8de6a0 against `PLAN-after-dedup-2026-09-04.md`, and
`EVAL-dedup-shortlist-2026-09-04.md` section 8.
next plan: `PLAN-after-review-2026-09-04.md`.

## 0a. What the review prompt got wrong, so nobody builds on it

Four claims in the brief for this review do not survive contact with the files. Each is also in the
plan's own 0a.

1. **"The 2,125 unverified candidates: two thirds of a shelf that cannot be popped at any band, and
   no road exists to verify one."** Wrong twice. Measured on the pool at 16:10: 3,254 available,
   1,129 verified, 2,125 unverified - and **2,069 of the 2,125 (97%) are pages with NO JSON-LD
   Recipe block at all**, zero ingredient lines, signature `protein: any / method: any /
   starch: none`, entered by the crawl and NAMED FROM THE URL PATH because there was no recipe name
   to read. A random sample of ten: "Fall Fashion Made Easy With Stylist George Brescia", "Diy Dice
   Drinking Game", "Christmas Countdown Calendar", "Primal Greens Review", "Best Frozen Chicken
   Nuggets Cheaper Than Fast Food". Top domains: lynnskitchenadventures.com 531, everydaydishes.com
   352, eatthis.com 301. These are not recipes with unverifiable macros; they are not recipes. The
   road is EVICTION, and it is mechanical: `qualify()` line 957 keeps a `node is None` page as
   `available` / `band-unverified` on purpose, and `cmd_crawl` line 1867-1870 titles it from the
   URL. Separately, a verification road DOES exist for the 56 that are recipes:
   `harvest.py --classify-nutrition` (local transcription of a printed panel, no assertion) - called
   by nothing in the estate, and never run on this shelf (0 of 2,125 carry `nutrition_serving`;
   all 2,125 have a cached page body).
2. **"The rubric sentence reaches three agent prompts."** It reaches ONE: `harvest.py` line 2028
   (`llm_same_dinner`), plus the committed drill script. The decider's own prompt
   (`.claude/agents/recipe-dedup-selector.md`) never mentions vehicles; its rule is "compare main
   protein, sauce/flavour family, starch and method; three of four matching means near-duplicate",
   and it names "a cross-protein twin (the same dinner in beef and in turkey)" as the collision the
   stage exists to catch. So Chicken vs Turkey Tetrazzini is a duplicate under the DECIDER's rule,
   and burrito vs burrito bowl (three of four match) is too. The open item's framing - "either the
   rubric is wrong or the acceptances are" - is right, but the rubric in question is the decider's,
   not a local-model sentence.
3. **"The 300 clean negatives ... every one a known non-duplicate a decider ruled distinct."** (EVAL
   section 8, the open item, and this brief.) **Zero of the 300 pairs contain a decider-era
   recipe.** The ledger holds 93 accepted candidates; only 16 join to a live recipe by slug and 16 by
   source URL (the same 16, plus one more by URL = 17 of 584 live recipes came through a decider).
   The 300 hardest pairs are the pre-hunter catalog, whose distinctness was never ruled by any gate
   this estate has. That does not weaken the safety measurement - a live recipe thrown away is a live
   recipe thrown away - but it changes what the open item is: not "the decider let these through",
   but "the catalog was never deduplicated by the decider's rule at all".
4. **"P3 was still running when this prompt was written."** It finished at 16:05:20 and the Opus
   session committed it at 16:08 (492353b6) while this review was reading the same files. Its
   table agrees with section 6 below to the token (16,761 / 33,057; 882 / 1,102; 6 / 16), it found
   the 21 stuck `taken:` rows independently (R5d), and it names the experiment that would actually
   answer the P3 question - the SAME dossiers ruled twice, with and without the neighbour block -
   which the next plan adopts as P6. Its message also records that it probed the failed pool write
   by running `--mark-ruled` with a fabricated verdict against the LIVE pool and then restored the
   bytes; this review's reproduction (R5e) was against a copy.

Also: the commit says 3,282 available after the crawl; after P3 consumed 28 pool rows and stranded
one it reads 3,254 (the daemon's own status at 16:05 said 3,253; one deferred acceptance went back
to the shelf).

## 1. `norm_line` is unfair to the LIVE side, and the numbers in section 8 are wrong by 1-5 points

**The defect.** `QTY` in `dedup_prompt_drill_pairs.py` strips a leading quantity and an OPTIONAL
unit, and the unit alternation has no word boundary. On a line that carries a quantity, the unit
consumes the optional group and the food survives: `1 lb ground beef` -> `ground beef`. On a line
with no quantity the optional group bites the food word: `Ground beef 93/7` -> `round beef`,
`Garlic` -> `arlic`, `Cannellini beans` -> `nellini beans`, `Pinto beans` -> `o beans`, `Sliced
mushrooms` -> `d mushrooms`, `Greek yogurt` -> `reek yogurt`, `Ginger` -> `inger`. Candidate lines
(`ingredients_verbatim`, raw recipe lines) nearly always carry a quantity; live lines
(`ingredients_display`, "<strong>Garlic:</strong> 5.5 tbsp") never do.

**Measured, on the pairs the Opus session actually asked about** (its `pairs.json` and
`ask-results.json` survive in its scratchpad; the results file re-tallies to exactly the section 8
table):

| side | lines mangled |
|---|---|
| all live `ingredients_display` lines (7,845) | 1,374 (17.5%) |
| all `ingredients_verbatim` lines on rejected-dupes (2,176) | 61 (2.8%) |
| positives: pairs with a mangled LIVE side | 123 of 134 |
| positives: pairs with a mangled CANDIDATE side | 30 of 134 |
| negatives (both sides live): pairs with any mangled side | 298 of 300 |

So on the recall set the model was shown `garlic; ground cumin` on one side and `arlic; round
cumin` on the other, on 123 of 134 pairs; on the safety set both sides were mangled alike.

**Re-run, same 434 pairs, same model, same prompt, same grammar, unit group requiring a boundary**
(scratchpad `rerun_d_fixed.py`, 868 calls, 285 s, read-only):

| design | section 8 | with the boundary fixed |
|---|---|---|
| D1 ingredients, ONE order - recall | 29.9% (40/134) | 35.1% (47/134) |
| D1 - wrong refusals | 4.67% (14/300) | 5.00% (15/300) |
| D ingredients, BOTH orders - recall | 23.9% (32/134) | 24.6% (33/134) |
| D - wrong refusals | 2.00% (6/300) | 2.67% (8/300) |

**Verdict.** The defect is real, it is asymmetric in exactly the direction that flatters
"ingredients made it worse", and it must be recorded in section 8. It does NOT change the ruling:
fixed, D is still 25 points under the recall bar and above zero wrong refusals; the C-to-D
comparison still says the ingredient lines made the gate more conservative in both directions. With
the fix, D's eight wrong refusals drop `Chicken Tetrazzini || Turkey Tetrazzini` and add
`Louisiana Red Beans and Rice with Sausage || Red Beans, Turkey Sausage and Rice` and `Korean Beef
Bibimbap Bowls || Korean Ground Beef Rice Bowls` (both already on the open item's names-only list)
and one pair the open item does not have: `Slow Cooker Chicken Taco Rice Bowls || Slow Cooker
Salsa Chicken Burrito Bowl`.

Two smaller things in the same function: the `</strong>`/`**` colon-split never fires on the live
side because `live_lines` strips tags before calling it (harmless, the split is done by the
caller); and `dedupe(cap=14)` truncates in page order, so a candidate whose protein is line 15
loses it - symmetric, unmeasured, not worth chasing.

## 2. Section 7's 8.4% / 0-of-300 against section 8's 43.3% / 4.67%

The session's answer - "section 7's prompt text is recorded nowhere, so it cannot be reproduced;
moved on" - is acceptable, with one addition. It is acceptable because nothing downstream depends on
it: the ruling rests on C versus D under one recorded prompt, and on the observation that safety
swung from 0 to 14 wrong refusals on wording alone, which is itself the strongest argument against a
gate. What would settle it is a re-run of section 7's design with its prompt, and that prompt is
gone; paying local-model time to guess at it would produce a third number, not an answer.

The addition: section 7 still reads as a live result. It needs one sentence saying its two tables
are superseded by section 8 and unreproducible, or the next reader will average them.

## 3. The disposal shape: dead weight wearing a docstring

Brad chose the minimal P1c and the session built it faithfully. Read against the code it is worse
than "asks a question nothing acts on": the surviving ask computes its one output with the
mechanism section 6 proved cannot be true.

`judge_near_dupes` line 2213-2219: `looked += 1` fires only when `llm_same_dinner == "yes" AND
llm_different_dinner == "no"` - the two-polarity conjunction that "answers yes to both questions
on every pair, a name against itself included". So the status line's "N candidate(s) the model would
have refused are reaching the decider" is structurally 0, watches nothing, and still costs up to two
local-model calls per neighbour per candidate whenever `--ingest-dedup` is passed. The tag `llm` it
writes distinguishes "asked a question with a fixed answer" from "not asked".

**What deletion actually costs, measured by reading the callers:**

- `harvest.py`: `judge_near_dupes`, `dedup_pending`, `dedup_ingest_pool`, `cmd_dedup_ingest`
  (`--dedup-ingest`, called by nothing), the `dedup_at_ingest` tag writes, `llm_same_dinner` /
  `llm_different_dinner` (the rubric lives here - see item 0a.2). The five P1c-era fixtures (lines 3590-3636) plus the
  `dedup_pending` trio (lines 3754-3771).
- `pool_health`: `dedup_tags` and `undeduped` (today permanently `(unset)=3253, unavailable=1` -
  a reading of nothing) and the second line of `format_pool_health`, which three surfaces print.
- `hunt-daemon.py`: `ingest_dedup_preflight`, `--ingest-dedup` / `--no-ingest-dedup`, three
  preflight fixtures in the daemon suite, the two status lines every run now prints.
- `harvest-crawl.ps1`: the `$tagLine` reading, its "is a reading, not an alert" line, and two
  fixtures added in bb8de6a0.
- `hunt-run.ps1 -Status`: the pool-reading block at line 2645 prints the same three lines.

**What must survive deletion**, because it is the decider's evidence and not the gate's:
`dedup_shortlist`, `dedup_ask_floor`, the `neighbours` block, the embed index, `--rescore`, and the
`blind` / `index_stale` halves of `pool_health` with the STALE-INDEX alert. Item 0a.2 adds one more
survivor: the rubric sentence, which is Brad's to strike or keep on the open item, not a deletion
side-effect.

Verdict: delete, as a plan item, with the list above as its fixture set. The honest-engineering case
for keeping it ("a number to watch") fails because the number cannot move.

## 4. The three removed case names, and their successors

`git diff a83e470a 69289acc -- harvest.py` removes exactly three `T(` lines and no others; the
daemon suite's diff in the commit (0 removed / 9 added) and hunt-run's (0 / 3) reproduce from the
session's pinned references in its scratchpad.

| removed | successor | as strong? |
|---|---|---|
| CLEAN TWIN a mirrored-contradiction verdict refuses the candidate BEFORE it is stored | MUST FIRE even the STRONGEST verdict this contract can produce refuses nobody (asserts status `available`, tag `llm`, no `exclusion`) | Yes - the same injected verdict, the opposite assertion. |
| MUST FIRE a model that answers YES to both framings refuses NOBODY | CLEAN TWIN a candidate that WAS asked about is tagged `llm` and left available, whatever the model said | Yes - same injection (`different_dinner` forced to yes), same assertion; only the label moved. |
| MUST FIRE refuse_near_dupes ITSELF acts on a candidate whose only evidence is embedding | MUST FIRE judge_near_dupes ITSELF reaches a candidate whose only evidence is embedding | Rename only. |

Plus a second net with no predecessor: `"ruled:" + "rejected-dupe"` must not appear in
`inspect.getsource(judge_near_dupes)`. It catches the literal only (the commit says so: 2 red when
the write is concatenated), so the behavioural case above is the real net. Fine.

**Verified, not assumed:**
- `judge_near_dupes` has three branches that write anything - `no-neighbour`, `unavailable`, `llm` -
  and each writes `dedup_at_ingest` only. No path touches `status`. The docstring's "NOTHING HERE
  MAY WRITE `status`" is true of the code under it.
- The daemon's pass runs only through `ingest_dedup_preflight(..., enabled=a.ingest_dedup)`, default
  False; the P3 run's log shows the OFF lines and no model start.
- `Read-Entries` drops a file when `Read-Json` returns null OR the parsed object has no `slug` - so
  "only files with no slug" is not quite true: an empty or null-parsing state file is also dropped,
  and it is then reported on `-Status` as a "run-level ledger". A truncated recipe state file would be
  mislabelled. `Write-JsonAtomic` makes that unlikely, not impossible. Small; recorded.
- `names_report` returns 2 on a removal, 0 on identical, 0 on an added case (checked by calling the
  function directly). End to end through `hunt-daemon.py --selftest --names-diff`: see the line at
  the foot of this file, filled in when the two 300 s runs finished.

## 5. The alert-arm class: what else watches a retired or disabled mechanism

By literal text, nothing else live watches the ingest gate: outside `harvest.py`, `hunt-daemon.py`,
its suite and `harvest-crawl.ps1`, the only hits for `dedup_at_ingest` / `undeduped` / `llm=` /
`refused as near` are design documents and the two stale worktrees under `.claude\worktrees`. The
18:00 task runs `harvest-crawl.ps1` only; no scheduled task runs `--dedup-ingest` or
`--classify-nutrition`. So the session's fix closed the literal class.

The SHAPE of the class - a reading, guard or tag that a change left pointing at nothing - turned up
three more instances and four defects while sweeping:

- **5a. The "would have refused" counter** (item 3): a reading computed with a conjunction that
  cannot be true. Same shape as the alert arm, one level down.
- **5b. `band_computed` / `meets_round_band` / `band_conflict`** (`harvest.py` 1005-1019): written on
  every candidate at qualify time, `meets_round_band` against a HARD-CODED 450-800 cal / 40 g band
  (comment: "so a run can demand it"). Read by nobody: `grep` finds no reader in `hunt-daemon.py`,
  `decide_apply.py` or `hunt_lib.py`; only harvest's own fixtures. A dead tag carrying a band Brad's
  rule says may not exist.
- **5c. Two verbs with no callers**: `--dedup-ingest` and `--classify-nutrition`. The second is the
  verification road item 0a.1 says exists; nothing runs it.
- **5d. DEFECT - 21 pool rows are locked `taken:` by runs that are not running.** Twenty carry
  `taken:hunt-2026-09-04-five` with NO ledger ruling: the run's first process (a DRY RUN, 09:49:53Z)
  ran decide batch 2 to "0 ruling(s)" and had batch 3 dispatched when a LIVE process for the same
  run started at 09:54:14Z and dropped its own predecessor's takes as "already taken by another run".
  One carries `taken:hunt-2026-09-04-p3` with a ledger ruling (`creamy-chicken-feta-pasta`,
  rejected-not-fit, 16:03:12) whose pool write failed - "the pool ruling did not land". No verb
  releases a taken row; `--reingredients` explicitly preserves taken state; `mark_taken` refuses to
  re-take. These 21 can neither be popped nor ruled, and every future stopped run adds to them.
- **5e. DEFECT - `write_pool` cannot survive a concurrent reader on Windows.** It writes `.tmp` and
  `os.replace`s once, no retry. A reader that has the 100 MB pool open (the CRT opens without
  `FILE_SHARE_DELETE`) makes the replace raise, the verb exits 1, and `decide_apply._mark_ruled`
  captures stderr and throws it away - the finding says "did not land" and nothing else. Re-running
  the identical `--mark-ruled` against a COPY of the pool succeeds (rc 0). The 16:03:12 failure
  coincides to the second with this review's own scratch read of the pool (process created
  16:03:13); that is timing, not proof, and the class does not depend on who the reader was: the
  18:00 crawl, `-Status`, `--pool-health` and the daemon's own pool lane all read that file.
- **5f. DEFECT - `apply_verdict` refuses a whole batch on one unknown slug** (`decide_apply.py`
  105-110: any decision naming a slug the pool has never heard of returns `applied=[]`), and the
  batch's other nine stay `taken:`. Whether that is what zeroed the five run's batch 2 is unprovable:
  the dry-run process was killed before it printed its findings, so they are gone (the "crash loses
  the journal" class).
- **5g. `Read-Entries`' mislabel** (item 4). Minor.

## 6. P3, finished: the decider did not get cheaper

Read from `lane-log.jsonl` `decide:*` end rows (`out` = output tokens of the decider call):

| run | band | decider calls | candidates ruled | output tokens | per candidate | dupe rejections | output per dupe rejection | input per call |
|---|---|---|---|---|---|---|---|---|
| five-b (before b3c1833c) | 350-650 / <=35 c / >=40 p | 2 | 19 | 16,761 | 882 | 6 | 2,794 | 119,332 / 99,950 |
| p3 (after) | 350-650 / no carb / >=40 p | 3 | 30 | 33,057 | 1,102 | 16 | 2,066 | 38,743 / 41,197 / 43,272 |

Per candidate ruled, output ROSE 25%. Per dupe rejection it fell 26%, but P3 rejected 53% of its
batch as dupes against five-b's 32% at a different band, so the denominator moved with the band and
the two runs are not the same experiment. The honest reading is the one the plan pre-named: **it did
not move down.** The decider is not rejecting more cheaply with neighbours attached.

Two things the comparison turned up that the plan did not anticipate:
- **Input per decider call fell from ~110k to ~41k tokens.** The dossier JSON is the prompt
  (`decide_prompt`), so the dossiers shrank by ~2.7x between the runs. b3c1833c changed the evidence
  shape; that is the likeliest cause and it is unmeasured. It matters because input is what the run
  pays for at cache-creation rates, and a 70k-token-per-call saving is real money even if output did
  not move.
- The ledger shows 29 P3 rulings; the daemon logged 30 (item 5d: the thirtieth is the one that did
  not land in the pool but did land in the ledger).

## 7. What is right, briefly

The P1c decision was correct on the numbers, and it is still correct on the corrected numbers.
`--reingredients-ruled` is a clean road (`reingredient_targets` is one function with the status
filter a fixture can hold; the default road is untouched). The daemon preflight is fixtured on both
sides of the flag and the P3 log proves the default. `--names-out` / `--names-diff` do what they say
at the function level, strip indentation on purpose, and refuse an empty or missing reference. The
commit messages record the measured neuter counts rather than predicted ones. The open item was
opened rather than folded in, and it did not retire anything.

## Foot: the end-to-end names-diff proof

Filled in when the two `hunt-daemon.py --selftest --names-diff` runs finished (identical reference,
then a reference carrying one name the suite never runs):

NAMES-DIFF-RESULT (measured 2026-09-04 16:19-16:35, three full runs of the daemon suite):
`--names-out` wrote 536 names, suite PASS. `--names-diff` against that identical file: "0 removed,
0 added", SELF-TEST PASS, **exit 0**. Against the same file plus one line the suite never runs:
"1 removed, 0 added", the name printed with a `-`, "every case that RAN passed, and the pinned
reference names cases that did not run", **exit 2**. Verified end to end.
