# PLAN: after the review of the dedup work - what is open, ranked by what it buys

queue_id: after-review-2026-09-04
shipped_commit: SHIPPED_SHA (2026-09-04 evening) - P5, P1, P2 and P3 are DONE: verify and report,
do not rebuild. P4 and P6's second half are Brad-launched by design and are NOT built. P7 is parked
on rulings, and this build ADDED to it - see the note at the end of P7.
OUTCOME, measured against the live files after the build:
  available 3,258 -> 1,185 after the eviction, then 1,205 once the 20 stranded takes were released
  0 available rows carrying the no-Recipe reason; 0 rows `taken:` by any run; 13,169 rows, none deleted
  the ingest ask is deleted outright: 7 functions, 13 fixtures, 2 flags, 1 verb
  all five suites carry --names-out/--names-diff; 16 case names removed in total, every one named
author: Fable 5.1, 2026-09-04 evening, PLAN ONLY. Written for Opus to build from. Every number
below was measured this evening against the files; every claim about a file names the line it was
read at. Bands are per-run and Brad's; none is hard-coded here or may be by the build.
ruled by: Brad's standing instruction for this session - review, then plan; change no code.
review this hangs off: `REVIEW-after-dedup-2026-09-04.md` (sections numbered R1-R7 below).

## 0a. What the brief for this plan got wrong (verified against the files)

Four claims in the review brief were wrong; they are corrected in the review's 0a and the plan is
built on the corrections, not the brief. In one line each:

1. The 2,125 "unverified" candidates are 2,069 non-recipes (pages with no JSON-LD Recipe block,
   named from the URL path: "Diy Dice Drinking Game") plus 56 recipes. The road is eviction, and
   `--classify-nutrition` already exists for the 56.
2. The rubric's vehicle sentence reaches ONE prompt (`harvest.py:2028`), not three. The decider's
   own rule ("three of four" and the cross-protein twin) calls the flagged pairs duplicates anyway.
3. None of the 300 "decider-ruled" negatives came through a decider: 17 of 584 live recipes did.
4. P3 finished at 16:05:20 and did not move down (R6). The Opus session committed it as 492353b6
   with the same numbers and the right diagnosis: a per-candidate ratio whose denominator the run
   selects cannot answer the question; only the same dossiers ruled twice can.

And one correction to the plan before this one: P2 of `PLAN-after-dedup` said "the daemon suite
already pins the bounded call (`_dedup_is_bounded`)". No such fixture existed. This plan cites
line numbers for every fixture it claims exists.

## 0. Read these first, in this order

1. `REVIEW-after-dedup-2026-09-04.md` sections 0a, 1, 3, 5 and 6. The measurements everything
   below hangs off, and the four defects (R5d-R5g) found while sweeping.
2. `harvest.py`: `qualify` at line 950-966 (the `node is None` branch), `cmd_crawl` at 1858-1872
   (URL-path naming), `write_pool` (search `def write_pool`), `cmd_mark_taken` around 2314-2323,
   `judge_near_dupes` / `dedup_pending` / `dedup_ingest_pool` / `pool_health` / `format_pool_health`,
   `cmd_classify_nutrition` at 2513, and lines 1005-1019 (`band_computed` / `meets_round_band`).
3. `hunt-daemon.py`: the decide lane at 1236-1298 (`mark_taken` before dispatch, `apply_verdict`
   after), `ingest_dedup_preflight` at 8314, `candidate_in_band` at 1067.
4. `decide_apply.py`: `apply_verdict` 96-150 (the unknown-slug pre-flight), `_mark_ruled` (search).
5. `hunt_daemon_selftest.py`: `names_report` / `names_diff` and `run()` (search `names_ref`).
6. The commits 69289acc, f6e098f7, bb8de6a0 - the record of what was measured and what was
   deliberately not done.

## 1. Where things stand (measured 2026-09-04 ~16:10, after P3)

    pool            3,254 available; 1,129 band-verified; 2,125 not
                    2,069 of the 2,125 have NO Recipe node, 0 ingredient lines, URL-path names
    locked          21 rows `taken:` by runs that are not running (20 five, 1 p3); no release verb
    ruled           192 no-Recipe pages already ruled (191 excluded by rule, 1 by a decider call)
    ledger          406 rows; 93 accepted; 17 of 584 live recipes came through a decider
    dedup ask       off by default; its "would have refused" counter is structurally 0 (R3)
    band tags       `band_computed`/`meets_round_band` written on every row, read by nobody (R5b)
    P3              output per candidate ruled 882 -> 1,102 (+25%); input per call ~110k -> ~41k
    suites          harvest 164, hunt-run 160, harvest-crawl 15, daemon 536, decide_apply 46:
                    only the daemon has --names-out/--names-diff

## 2. The work, ranked by what it buys

### P1 - Evict the 2,069 non-recipes, and stop the crawl admitting more

**What it buys.** The shelf reads as 1,185 candidates instead of 3,254. Every downstream reading
that counts `available` - `pool_health`, the crawl's nightly summary, `-Status`, the daemon's
"popping nothing further" - stops counting "Fall Fashion Made Easy" as a dinner. A no-band run
(`band_constrains_anything()` False -> `candidate_in_band` True for everything) stops being able to
pop a craft-blog post to an Opus decider; one already reached a decider (`ruled:rejected-not-fit`,
R1 measurement). The nightly `--rescore` stops embedding 2,069 rows that carry only a title. And
the 0a.1 question - "how do we verify two thirds of the shelf" - is answered: we do not, they are
not recipes.

**Build.**
- In `qualify()` (`harvest.py:957`), a `node is None` page is no longer kept `available`. It
  becomes `ruled:excluded` with `exclusion: "no JSON-LD Recipe block - not a recipe page"` and is
  `slim_ruled` like every other exclusion. The evidence (url, domain, first_seen, the reason) stays;
  nothing is deleted. The 2026-08-24 reasoning for keeping unverified pages ("a structurally
  low-carb dish with an unverifiable band needs judgment") applies to pages WITH a recipe and
  WITHOUT a nutrition block - those keep `band-unverified` exactly as today. The distinction is
  `node is None` (no recipe) versus `node` present with no nutrition (a recipe), and both branches
  already exist; only the first one's disposition changes.
- `cmd_crawl` line 1867-1870 stops inventing a name from the URL path for a page with no node. The
  entry still gets a slug (it must be addressable to be excluded) but `name` records that no
  recipe name was read, so a later reader cannot mistake it for a dish.
- A one-shot `--evict-non-recipes` road (or a flag on `--reingredients`, whichever keeps ONE status
  filter per fixture) that re-applies the rule to the 2,069 already on the shelf, from the page
  cache, no network. It must report the count it moved and refuse to touch a row that has a node.
- `pool_health` grows one count: `non_recipe_excluded`, so the reading says where they went.

**Bars, stated before the build.**
- After the road runs: `available` = 3,254 - 2,069 = 1,185 (minus whatever P2 releases and plus
  nothing), and 0 available rows whose `band.reason` is "no JSON-LD Recipe block". Anything else
  means the filter is wrong and the build stops.
- The next 18:00 crawl admits 0 such rows as available (read the crawl's summary line).
- No recipe with a node changes status. Count `available` rows WITH a node before and after: equal.

**What each outcome forces.** If the counts match: done. If the evicted count is under 2,069, the
remainder are pages whose cache changed since qualify ran - list them, do not guess. If any row with
a node moved: revert by md5 and stop.

**Fixtures** (harvest suite): MUST FIRE a page with no Recipe node is `ruled:excluded`, its name
records that none was read, and its url/domain/reason survive `slim_ruled`; CLEAN TWIN a page with a
Recipe node and no nutrition block is still `available` / `band-unverified` with its lines; MUST FIRE
the eviction road moves a no-node row and refuses a with-node row. Neuter: the `node is None`
branch restored to `available` -> the first must-fire and the road's count both redden; measure.

### P2 - Release the 21 locked rows, and stop the mechanism that locks them

**What it buys.** 21 candidates come back to the shelf now, and every future stopped or restarted
run stops eating candidates. R5d shows the shape: `mark_taken` runs BEFORE dispatch by design (so
two runs never pay for one dossier), and there is no counterpart for "the run that took it is gone".
A daemon restart of the SAME run drops its own earlier takes as "another run". Plus the ruled-but-
not-landed row (R5e) and the whole-batch refusal (R5f). 492353b6 found the same 21 and called the
fix "a lease-expiry ruling and not a patch"; this item is written so the ruling is one sentence
from Brad - a take with no live owner process is expired - and everything else is mechanism.

**Build.**
- `harvest.py --release-taken --run <id>`: every `taken:<id>` row with no ledger ruling goes back to
  `available`, untouched otherwise; a `taken:<id>` row WITH a ledger ruling is marked ruled from the
  ledger's own verdict, reason and `dupe_of` (the ledger is authoritative; `--mark-ruled` already
  takes all three). Refuses if a daemon process for `<id>` is alive (read the process list - name
  the owner from process shape, never from timing).
- The daemon, at start, releases ITS OWN run's stale takes before popping - the same verb, called
  once, logged with the count. A restart that finds its own batch half-dispatched should reclaim
  it, not strand it.
- `write_pool`: retry `os.replace` on `PermissionError` (bounded, ~5 tries over ~2 s), then raise.
  `_mark_ruled` in `decide_apply` puts the verb's stderr tail into the finding - "did not land"
  must say why.
- `apply_verdict`'s unknown-slug pre-flight refuses ONLY the unknown decision and records a finding
  naming it; the other nine land. (R5f. The current all-or-nothing is defensible as a transport
  check but it strands nine takes per bad slug.)

**Bars.** After the release road: 0 rows `taken:` by any run without a live daemon process; the
ledger's 29 P3 rows all have a matching pool status. After a deliberate kill of a dry run mid-batch
(a drill, on a scratch pool): the restart reclaims every take and the pool shows 0 stranded.

**Fixtures.** harvest: MUST FIRE a taken row of a run with no live process is released; CLEAN TWIN a
taken row of a live process is refused; MUST FIRE a taken row with a ledger ruling lands as that
ruling. decide_apply: MUST FIRE a failed pool write's stderr reaches the finding; MUST FIRE one
unknown slug does not refuse the other nine. daemon: MUST FIRE start-up reclaims the run's own
stale takes and says how many. Neuters, one at a time, counts measured: the process check dropped
(the live-process twin reddens); the retry removed (the stderr case still passes - say so, it is
not that case's net; the retry needs its own MUST FIRE with a reader holding the file open).

### P3 - Delete the ingest ask outright (review item 3)

**What it buys.** 243 lines of function body across seven functions (measured by `ast`: 190 in
`harvest.py`, 53 in `hunt-daemon.py`), thirteen fixtures (8 harvest, 3 daemon, 2 crawl), two
flags and one verb that read as a safeguard and count with a conjunction that cannot be true. The "would have refused" number cannot move; the `llm` tag now means "asked a
question with a fixed answer". Every surface that prints `dedup at ingest (unset)=N` prints a
reading of nothing.

**Build.** Remove the list in R3: `judge_near_dupes`, `dedup_pending`, `dedup_ingest_pool`,
`cmd_dedup_ingest` + `--dedup-ingest`, `llm_same_dinner` / `llm_different_dinner` (move the rubric
sentence to the open item's file so it is not lost - it is Brad's to keep or strike), the
`dedup_at_ingest` writes, `pool_health`'s `dedup_tags` / `undeduped`, the second line of
`format_pool_health` on all three surfaces, `ingest_dedup_preflight` + both flags + its three
fixtures, the crawl's `$tagLine` + its two bb8de6a0 fixtures, and the eight harvest fixtures that
assert the ask (five at lines 3590-3636, three at 3754-3771). **Keep**: `dedup_shortlist`, `dedup_ask_floor`, `neighbours`, the embed index,
`--rescore`, `blind` / `index_stale` and the STALE-INDEX alert. Say in the commit which fixtures
went and why, with the case-name diff for all five suites (P5 makes that cheap; do P5 first).

**Bars.** Suites: harvest and daemon each lose exactly the named cases and no others (name diff, not
count). `pool_health` still exits 1 on `blind` or a stale index (that is the alert chain; a neuter
that breaks it must redden the crawl's STALE-INDEX must-fire). The P3 run shape - decide lane, no
model start - is unchanged.

**What the outcome forces.** Nothing to measure beyond the name diffs; if any survivor in the keep
list breaks, the deletion took evidence with it and stops.

### P4 - The published near-duplicates: rule them, with the decider's own rule

**What it buys.** The catalog's duplicate rate is unmeasured by any gate: 17 of 584 live recipes
came through a decider (0a.3). Eighteen flagged pairs (the open item's seventeen plus the one R1 added:
`Slow Cooker Chicken Taco Rice Bowls || Slow Cooker Salsa Chicken Burrito Bowl`) are the cheapest
place to find out. And the rubric question is sharper than the brief said: the decider's rule
("three of four", cross-protein twins) already calls these duplicates; the local sentence is
downstream of it. The question for Brad is whether the DECIDER's rule is the catalog's rule.

**Build (costs Claude tokens; Brad launches it, not a session).** One dispatch to the
`recipe-dedup-selector` agent carrying the 18 pairs as dossiers built from the live recipes
(`ingredients_display`, protein, method from the spec) with the instruction to rule each pair
`same-dinner` or `distinct` with a reason, under its own rubric. Nothing is retired, held or edited
on the result; the verdicts go into the open item as a table.

**Bars, before the call.** Every pair gets a written verdict and a reason naming which of the four
axes differ. If the decider rules >= 12 of 18 `same-dinner`, the catalog contradicts the decider's
rule and disposal is Brad's next ruling (`retire-recipe` retires LIVE recipes only; the
memory of the same name). If it rules <= 6 same, the rule is looser in practice than in prose and
the "three of four" sentence needs Brad's edit before the next run. In between: the pairs, not the
count, go to Brad.

**What this deliberately does not do.** It does not ask the local model anything, does not write
`dupe_of`, does not touch the rubric sentence, and does not retire a recipe.

### P5 - `--names-out` / `--names-diff` on the other four suites

**What it buys.** P3 and every later gate. Today only the daemon suite can pin and diff names;
harvest (164 cases), hunt-run (160), harvest-crawl (15) and decide_apply (46) need
`sed | sort | comm` by hand, and the review reproduced the daemon diff only because the Opus session's scratchpad
survived. Cheap: `names_report` / `names_diff` already exist in `hunt_daemon_selftest.py` and
strip indentation; lift them into `hunt_lib` and call them from the four `T(` helpers. The two
PowerShell suites need the same in PS (one function, in the shared `T` helper each already has).

**Bars.** Each suite: `--names-out` writes N lines where N equals its "cases ran" count; a
reference carrying one name the suite never runs exits 2 with that name printed; an identical
reference exits 0; an empty or missing reference exits 2 with CANNOT DIFF. Verified end to end for
the daemon suite this evening (see the review's foot).

### P6 - P3's follow-up: what shrank the decider's input by 2.7x, and does output track dupes

**What it buys.** Input per decider call fell from ~110k to ~41k tokens between five-b and p3 with
the dossier JSON as the whole prompt (`decide_prompt`, `hunt-daemon.py:1300`). If b3c1833c's
evidence shape did that, it is a ~70k-token-per-call saving that nobody has claimed; if something
else did (a smaller neighbour list, a lost `prior_rulings` block), the decider may be ruling on
less than it was. Output per candidate rose 25%; whether that tracks the dupe share (53% vs 32%)
or the evidence is one measurement away.

**Build.** Not code, in two halves. First, reconstruct one dossier as five-b dispatched it
(b3c1833c's parent) and as p3 did, from the same candidate, and diff the keys and sizes. Second,
the experiment 492353b6 names and this plan adopts: the SAME dossiers ruled twice by the decider,
once with the neighbour block and once without, output tokens read per dossier from the
transcript (not the envelope). A ratio whose denominator the run selects (dupe share 32% vs 53%)
cannot answer "does evidence make rejection cheaper"; a within-pairs difference can. Costs Claude
tokens; Brad launches it, and it is one batch of ten, not a run.

**Bars.** The size diff names the field that changed. If a field the decider's prompt says it needs
(`neighbours` with both sources, `prior_rulings`, `catalog_checked`) is missing from the p3 shape,
that is a regression and it outranks everything above P3 here. If the shrink is the evidence fix
compacting what it should, record the saving and close.

### P7 - Parked on rulings, listed so they are not lost

- **`band_computed` / `meets_round_band` / `band_conflict`** (R5b): written on every row against a
  hard-coded 450-800 / 40 g, read by nobody. Under Brad's no-hard-coded-bands rule the constant may
  not stay; whether the computed macros are worth keeping as decider evidence (the dossier does not
  carry them today) is his call. Either way the tag is dead as written.
- **`--classify-nutrition`** for the 56 real unverified recipes: one local run, and it needs to
  RECORD "no printed panel" on the row so a re-run does not retry the same 56 forever (today it
  writes nothing on a no-panel page - a could-not-look with no tag).
- **`Read-Entries`** (R5g): a null-parsing state file is reported as a run-level ledger.
- **Section 7 of the EVAL** needs its one-line supersession note; **section 8** needs the
  `norm_line` correction and the negatives' provenance (0a.3). Both are doc edits; do them with P3.
- **The two stale worktrees** under `.claude\worktrees` still carry the pre-P1c `refuse_near_dupes`;
  harmless until someone reads one as current.
- **NEW, from the build itself: `dedup_shortlist` and `dedup_ask_floor` now have NO production
  caller.** P3's deletion took their only one. This plan's P3 said to keep them as "the decider's
  evidence"; that justification was WRONG and the build checked it - the decider's evidence is the
  `neighbours` block `build_dossier` carries, and the shortlist only ever chose who to ask. They are
  kept, and their docstrings now say they have no caller and why. Deleting them would also strand
  the nightly chain's `--calibrate` step, whose ordering has its own crawl fixture, so it is a
  ruling and not a cleanup. Decide: delete both plus the calibrate step, or wire the shortlist to
  something that needs it.
- From the previous plan, unchanged: the near-name shelf scorer (plural-stem ruling),
  `DEFAULT_COND` reaching three agent prompts, the `99/1 ground turkey` term-ladder defect and its
  registrar ruling, and whether a fresh checkout should say the two gitignored index files are
  absent by design.

## 3. What this plan deliberately does NOT do

- **It does not touch the dedup question again, in any prompt, with any model.** Four designs were
  measured; the corrected numbers say the same thing. The next dedup work is P4, and it is the
  decider judging the catalog, not a local model judging candidates.
- **It does not delete a pool row.** P1 excludes with the evidence kept; P2 releases or lands a
  ruling that already exists in the ledger. Nothing is removed from `candidate-pool.json`.
- **It does not retire, hold, unpublish or edit a live recipe**, and does not write `dupe_of` on
  the strength of any model's opinion. P4 produces a table for Brad.
- **It does not change the rubric sentence or the decider's rule.** Both are rulings.
- **It does not hard-code a band, and removes one** (P7's `meets_round_band`) only on Brad's word.
- **It does not backfill `nutrition_serving` or macros by inference.** `--classify-nutrition`
  transcribes or writes nothing.
- **It does not start llama-server from any script.** P7's classify run is by hand, with the
  server up (`serve.ps1 -Slots 1`).

## 4. Fixtures and neuters, per item

Every item ships with MUST-FIRE / CLEAN-TWIN pairs in the suite that owns the code, listed under
the item, and at least one neuter run ONE AT A TIME with the count MEASURED and the file restored
by md5. Write the measured counts into the commit message; never predict them. Verify every
"the suite already pins X" claim by opening the suite: this plan cites none it did not read.

## 5. Gates

`harvest.py --selftest`, `decide_apply.py --selftest`, `hunt-daemon.py --selftest --names-diff
<ref pinned from HEAD's bytes>`, `hunt-run.ps1 -SelfTest`, `harvest-crawl.ps1 -SelfTest`. After
P5, every one of them with a name diff. Exit code first, tally second. Nothing removed from any
suite unless the commit says which and why. Commit with `git commit -F`, explicit `git add` paths,
never `-A`; the pool file is committed WITH the source that changed it.

## 6. Order

P5 first - it is small and every later gate is cheaper with it. P1 next, in its own commit: it is
the largest single change to what the estate believes about its shelf, and its bar is a subtraction
anyone can check. P2 after P1 (the release road's "0 stranded" bar is easier to read on a shelf
without junk). P3 after P2, with the EVAL doc edits. P6 whenever the next Brad-launched run happens;
P4 only when Brad launches it. P7 on rulings.
