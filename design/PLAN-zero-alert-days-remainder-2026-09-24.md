# PLAN: the rest of zero-alert days (row contract, two-signal identity, muffins, the review packet)

**Status: RULED 2026-09-10 (carried from PLAN-zero-alert-days). Under way since 2026-10-02: step 8 in SHADOW (Brad's D1 A in PLAN-weekly-root-families-2026-10-02.md), step 9 in shadow, step 11 built; R18, R11, 3b and step 10 not started.**

Source: `PLAN-zero-alert-days-2026-09-10.md` in `design/`, section 7, and Brad's rulings recorded there (the first set
and the second set of 2026-09-10). That plan closed at build step 7 on 2026-09-24 (RULED close 1 to 7 by Brad,
2026-09-24, "Close 1-7, new plan for 8-11 (Recommended)"). Every ruling and every bar below is carried from it
verbatim; nothing here is a new ruling. Where a step has no bar in the source, this plan says so and does not invent
one as if it were ruled.

Why a separate plan: the plan-citation check (`plan_citation.py` under `ops/`) asks a session commit to cite every under-way
plan whose text names a file the commit changes. The source plan named the alert registry, the daily chain and the
gate runner, which the daily triage and ops lanes change almost every day for reasons unrelated to these steps, so 83
of 86 warnings in the replay since 2026-09-16 were routine commits being asked to cite work they were not doing.

## Knowledge consulted

- Backlog inbox `pd-plancite-2026-09-23.md`, first finding: "The rule reads the FIRST status word, so
  `DONE 2026-09-xx (ruled 2026-09-10)` works." and "83 of those 86 come from one plan", which names the alert
  registry JSON (45 commits), the daily chain script (43) and the gate runner (13); the file names are paraphrased
  here so that this plan does not name them to the check. REFUSE_FROM is 2026-09-30.
- memory `a-ruling-lands-in-its-plan-the-turn-it-is-given`: record a ruling as
  `(RULED <answer> by Brad, <date>, "<option label>")` in the plan's own decision line; a chat-only ruling is
  invisible to agents.
- The measurement rules (`measurement.md` under `.claude/rules/`): "A rate is printed with its DENOMINATOR, always" and "NAME THE HARNESS AND THE
  COMMIT IT RAN AT ... cite the BLOB".
- memory `recommend-the-best-long-term-solution`: why the split, rather than a Plan line on every routine triage
  commit.

## 1. Files this plan changes

The plan-citation check reads this plan's text for whole repo-relative paths. A session commit that changes a file
named that way must cite this plan with a `Plan:` line, or say `Plan-not-applicable: <reason>`. So this section keeps
two lists, and only the first one is written as paths.

**A file is named to the check while its step is being built, and not before.** Every file below is one a step
changes, but most of the existing ones are shared: other lanes change them for their own reasons every week. Naming
them all now would repeat the defect this split exists to fix. Measured with the replay described in section 4, naming
every existing file below as a path from today would have asked 51 of the 572 session commits since 2026-09-16 to cite
this plan while no step here had started. So the first commit of each step moves that step's files into the named list,
written as paths, in the same change, and from then on every commit to them cites this plan. A step that finishes
moves its files back out.

### Named to the check now (paths)

Only files that no other lane writes, because they do not exist yet and each step creates its own:

- step 8: `design/SPEC-capture-row-contract.md`, `grocery/row-contract-lib.ps1`, `grocery/test-row-contract.ps1`, `grocery/audit-row-contract-shadow.ps1` (the last two added by the step's first commit, 2026-10-02)
- step 9: `grocery/audit-store-category-share.ps1`, `grocery/audit-crown-identity-shadow.ps1`, `grocery/store-department-lib.ps1`,
  `grocery/store-department-map.json` (the last two added by the step's first commit, 2026-10-02; nothing else writes them)
- step 11: `grocery/review-adjudication-lib.ps1`, and since step 11 started (2026-10-02) its existing files
  `grocery/send-alert.ps1`, `grocery/triage-due.ps1`, `grocery/audit-alert-census.ps1`
- R11: `design/TRIAL-aldi-fareway-page-json.md`

### Named when their step starts (file names only, so the check does not read them yet)

| Step | Existing files the step changes | Session commits since 2026-09-16 that touched them |
|---|---|---|
| 8, row contract | the seven builders `build-walmart-deals.ps1`, `build-aldi-regular.ps1`, `build-fareway-regular.ps1`, `build-sams-deals.ps1`, `pull-regular-hyvee.ps1`, `pull-regular-familyfare.ps1`, `pull-regular-bakers-api.ps1`, and the two batch importers `import-walmart-batch.ps1` and `import-instacart-batch.ps1` (all under `grocery/`) | 32 |
| 9, two-signal identity | none until enforcement; the crown selection file joins only if the enforcement bars are met | |
| 10, muffins | the commodity catalog `commodities.json` and its search and category files (under `grocery/`), in one change through the registrar and the money lane | 23 (the catalog file alone) |
| 11, review packet | moved to the named list above on 2026-10-02, when the step started; they move back out when it finishes | 15 |
| R18, own Chrome tabs | `pull-walmart-instore.js`, `pull-sams-instore.js` (under `grocery/`), and the browser-stores prompt mirror `SKILL.md` under `ops/prompt-backup/scheduled-tasks/grocery-browser-stores-refresh/` | 11 |
| R11, in-page JSON trial | `pull-aldi-instore.js`, `pull-fareway-shop.js` (under `grocery/`) | 1 |
| 3b, Family Fare catalog walk | `pull-regular-familyfare.ps1` (shared with step 8) | |

The last column counts distinct session commits (a `Co-Authored-By: Claude` trailer) over the 572 in the replay window of
section 4, each commit once per row; a commit can fall in two rows, so the rows add to more than 51. The catalog row is
a `git log` count over the same window with the same trailer filter, because the catalog was not in the counterfactual.

### Deliberately not in either list, and why

- The alert registry JSON: no step changes it. Step 11 routes the five review-intake types at `send-alert.ps1`
  through the class the registry already gives them (all five are `review` today), so the registry stays as it is. If
  the build finds an entry must change, that commit adds the registry here, as a path, in the same change and says why.
- The daily chain script (`check-ad-cycles.ps1` under `grocery/`): step 9's shadow audit needs one daily lane wired in,
  once, and that one commit carries a `Plan:` line naming this plan. Four of the five review-intake emitters live in
  it, and step 11 is designed so their call sites do not change.
- The gate runner (`run-gates.ps1` under `ops/`): no step changes it. New self-tests are discovered by it without an
  edit.
- Outputs the steps' code writes at run time (the shadow reports): a run writes them, not a step's commit. The one
  exception is the review packet, whose path appears inside step 11's verbatim text below, so the check does read it
  as named; no such file exists or is tracked today, and step 11 decides whether it is tracked.

## 2. Build order and bars

The order is the source plan's: after step 6, **R18** own-tabs enforcement for Walmart and Sam's, **R11** the in-page
JSON trial for Aldi and Fareway, **3b** the Family Fare catalog-walk trial, then 7 to 11. Step 7 is done, so here it
is R18, R11, 3b's build decision, then 8 to 11.

### R18. Walmart and Sam's capture use Brad's own Chrome tabs, enforced in code

Ruling, verbatim (R18, 2026-09-10 evening): "**Walmart and Sam's capture must use Brad's own Chrome tabs, never new
windows**, to help with bot walls, and that must be enforced in the code, not left to habit".

Bar: none was written in the source plan. One is written here before the build starts, and until it is written this
step is not started.

### R11. Aldi and Fareway: read the page's own JSON inside today's sweep

Ruling, verbatim (R11, 2026-09-10 evening): "**Trial reading the page's own JSON inside today's sweep.** Assert the
Omaha In-Store shop on every read".

Context carried from the ruling 7 result: "Both pages load prices from the same Instacart JSON, with sale, regular
and per-unit price as separate fields. At Fareway that would retire four known silent capture defects." and
"**Unproven:** that the In-Store shelf price comes through it, and anything outside the browser session."

Bar: none was written in the source plan beyond the ruling's own assertion (the Omaha In-Store shop on every read).
The trial document states its rubric before the trial runs.

### 3b. Family Fare catalog walk: TRIAL DONE, NOT BUILT

Carried as the source plan left it: "**Step 3b, the Family Fare catalog walk: TRIAL DONE, NOT BUILT**" (616017aba,
`TRIAL-familyfare-catalog-walk-2026-09-10.md` in `design/`). Its rubric, verbatim: "Rubric: complete NOT MET;
follow-up search COULD NOT VERIFY; covers the rotation COULD NOT VERIFY. The lower bound: 2,339 of 5,395 everyday
rows found in the 35.6%."

The source's step 3 bar, verbatim: "a verdict per store backed by a captured network request, or a recorded wall; a
CAPTCHA is a hard stop and a verdict, never a bypass." The offers-endpoint defect found on the way was filed as
daily-lane queue item 2026-09-10-fa6ad6 and closed as resolved by the 2026-09-11 triage plan, so it is not carried.
What is open is only whether to build the walk, which needs a paced trial that can answer the two COULD NOT VERIFY
criteria first.

### 8. Ruling 2, the row contract

Ruling, verbatim (ruling 2): "**A row contract at capture, all 7 stores**, shadow first, enforced store by store".

Build step and bar, verbatim: "Written as a contract document first, then one validator the seven builders share, run
in shadow for 7 days per store, then enforced store by store in the census's order of returns. Bar per store: after
enforcement, 0 basis-class guard hard fails from that store over 14 days, and every cell the contract empties is one
the shadow report already named."

Input, verbatim: "Input, not a change to the ruling (backlog I165, 2026-09-18): two BATCH IMPORTERS write the same
regular files these builders write, `import-walmart-batch.ps1` and `import-instacart-batch.ps1` (Aldi and Fareway),
and they decide 4 feed-independent row conditions differently from each other. I165 carries the table and the reach
measured that day (20 of 3,188 board entries, 0 violating a sibling's rule). The contract's shadow run should cover
both importers as well as the seven builders."

Ruling 6 applies here too, verbatim: "every new store, feed or large commodity batch is checked against the row
contract before it goes live". The weekly lane's `new_source_check` records that the contract does not exist yet, and
starts checking against it once this step lands.

**Status note (2026-10-02, not a change to the ruling or its bar):** shadow under way since 2026-10-02, enforcement per
store after R18 (Walmart, Sam's) or R11 (Aldi, Fareway) has landed for that store and it has 7 shadow days. The contract
is `design/SPEC-capture-row-contract.md`, the validator `grocery/row-contract-lib.ps1`, the daily shadow
`grocery/audit-row-contract-shadow.ps1` (one fan-out lane of the daily chain, writing only the gitignored
`row-contract-shadow-<date>.json`, and covering both batch importers through the regular files they write). Ruling 6 is
on: the weekly lane's `new_source_check` quotes the shadow's per-store line for each new store, feed or large batch,
and the triage plan gate refuses the old "does not exist" wording. The first run's numbers are in the spec's last
section.

### 9. Ruling 3, two-signal identity

Ruling, verbatim (ruling 3): "**Two independent signals must agree** for a crown; 2 weeks in shadow before it refuses
anything".

Build step and bar, verbatim: "First measure what share of each store's rows carries a usable category. Then 14 days
of shadow on crowns. Enforce only if a hand-checked sample of at least 30 disagreements is at least 80% real wrong
products, and enforcement would empty no more than 2% of live cells. Both numbers are first guesses, recorded as such,
to be revisited against the shadow data."

**Status 2026-10-02: SHADOW STARTED, enforces nothing.** (Phase 3 of `PLAN-weekly-root-families-2026-10-02.md` in `design/`.)
- **Shadow started 2026-10-02**: the first day was measured by hand on `comparison-2026-09-30.json` (built
  2026-10-02T08:10) into a scratch directory. The daily chain records from its first run after this lands, expected
  2026-10-03, so **the 14 shadow days end 2026-10-16** if it records every day. Each day is one gitignored file,
  `grocery/out/crown-identity-shadow/crown-identity-shadow-<date>.jsonl`, one row per crown plus one per watch case, and
  the audit prints the days on record. A BLIND day (no board, or no crown) writes nothing and is not a shadow day.
- **How it reads.** The second signal is the department the store's own capture filed the crown's product in,
  translated into aisle-lib's department vocabulary by `grocery/store-department-map.json`, and judged against the
  expected departments aisle-lib ALREADY holds (its reviewed category and per-commodity tables, through
  `Test-AisleAllowed`). So the expected set is declared once, in aisle-lib, and the new data file holds only each
  store's field and its word-to-department map; `commodities.json` is neither read for this nor edited. Verdicts:
  agree, disagree, no-signal. A no-signal is counted and is never agree.
- **Coverage, measured 2026-10-02** (`grocery/audit-store-category-share.ps1`, blob e2b7999ec5c6, over the newest file
  of each family; usable means the value maps to a department). All rows, then the regular or deals file alone:

  | Store | Field | Usable, all captured rows | Regular file alone | Note |
  |---|---|---|---|---|
  | Hy-Vee | `store_department` | 628 of 2,058 (30.5%) | 628 of 1,546 (40.6%) | only freshly read rows carry it; carried rows and 512 ad rows do not |
  | Aldi | none captured | 0 of 4,024 (0%) | 0 of 3,950 | |
  | Family Fare | `dept` (from `canonical_url`) | 3,833 of 6,931 (55.3%) | 3,833 of 5,602 (68.4%) | Weekly Ad lines: flyer-link evidence 2026-09-27 gives a department on 171 of 171 resolved lines (171 of 191 lines resolved) |
  | Fareway | `taxonomy_path` | 15 of 1,132 (1.3%) | 15 of 915 (1.6%) | 96 rows carry the field, mostly an aisle number, which is a place and not a category |
  | Baker's | `store_category` | 7,222 of 7,508 (96.2%) | 7,222 of 7,362 (98.1%) | a set of Kroger tags joined with " > " |
  | Sam's Club | none captured | 0 of 210 (0%) | 0 of 210 | |
  | Walmart | none captured | 0 of 266 (0%) | 0 of 266 | |
  | All | | 11,698 of 22,129 (52.9%) | | |

- **First shadow day, 2026-10-02** (`grocery/audit-crown-identity-shadow.ps1` blob 52513e1933db, `store-department-lib.ps1`
  blob 3ac2f93f3149, `store-department-map.json` blob 4ba66c171119, `aisle-lib.ps1` blob ac1634c62bd5; board
  `comparison-2026-09-30.json` built 2026-10-02T08:10): **577 crowns; a signal on 101 of 577 (17.5%): 99 agree, 2
  disagree, 476 no-signal.** Per store, signal on: Baker's 73 of 79 (71 agree, 2 disagree), Hy-Vee 11 of 15, Family
  Fare 17 of 26, Walmart 0 of 174, Aldi 0 of 150, Sam's Club 0 of 109, Fareway 0 of 24. The two disagreements, first
  read only (this is not the ruled hand check): fresh-cranberries @ Baker's, "Kroger Sweetened Cranberries" 32 oz,
  filed Snacks, is dried fruit holding the only fresh-cranberries cell, which reads as a real wrong product;
  breakfast-sausage @ Baker's, "Farmland Hot Pork Sausage" 12 oz, filed Frozen, reads as a right product the map's
  meat set is too tight for.
- **What the numbers already say about the bar.** Crowns at Walmart, Aldi and Sam's Club (433 of 577, 75%) capture no
  category, so no amount of shadow can judge them; two signals cannot agree where one store gives only one. Day one
  found 2 disagreements, and a crown that disagrees today is mostly the same crown tomorrow, so 30 DISTINCT
  disagreements for the hand check may take longer than 14 days. Count distinct (commodity, store, product) across the
  daily files, not rows. Both are inputs for the revisit the ruling asks for, not a change to the bar.
- **Family 2 queue cases, read the same day** (watch_cases in the map; each re-read daily):

  | Queue item | Case | Second signal |
  |---|---|---|
  | 6fc290 | Glad Drawstring Odor Shield Lemon Tall Kitchen 40 Ct, lemons, Family Fare | DISAGREE: household, on flyer-link-evidence-2026-09-27.jsonl (the cited file, also today's newest) |
  | 6fc290 | Cascade Ap Comp Lemon, lemons, Family Fare | no signal: comparison-2026-09-11 predates every flyer-link evidence file |
  | 184b1d | Del Monte Peas And Carrots 8.5 Oz, carrots, Family Fare | AGREE (pantry): the vegetable set allows pantry, so a department cannot tell a can from fresh carrots |
  | 184b1d | Muscle Milk shake, milk; NY Bakery Cheesy Focaccia, garlic | no signal: both are Family Fare Weekly Ad lines the flyer linker never resolved |
  | 184b1d | Fareway Diced No Sugar Added Pears, canned-pears | no signal: the row carries no taxonomy_path |
  | 356c4e | Great Value Ultra Soft Facial Tissues, facial-tissues, Walmart | no signal: Walmart captures no category |
  | 465acc | Kroger Olive Oil Mayo, Baker's; California Sun Dry and Hy-Vee sun-dried tomatoes | AGREE on all three, today and on the cited 2026-09-29 files: a FORM question (mayo or dressing, oil-packed or dry) sits inside one department, so this signal cannot settle it |
  | 88bd45 | horseradish @ Aldi (good), carrots @ Aldi (bad), rotisserie-chicken @ Walmart (good) | no signal on all three: Aldi and Walmart capture no category, so this signal cannot yet replace the single-signal quarantine for these stores |

  So on today's data the step changes 1 of the 13 case rows (6fc290's Glad bags, which it catches), cannot see 8 for
  want of a category, and agrees on 4 that are form or can-versus-fresh questions a department cannot answer.

### 10. Ruling 8, muffins

Ruling, verbatim (ruling 8): "**Two commodities, muffins and mini muffins**, each with an explicit piece-size
definition".

Build step and bar, verbatim: "Through the commodity registrar and the money lane's gated chain. Bar: every current
muffins row routes to exactly one of the two commodities, no row is lost, guards exit 0, and both cells read correctly
on the live board."

### 11. Phase 3, review intake as a packet

Ruling, verbatim (ruling 1): "**Enforced alert registry.** Every alert type is `page`, `review` or `digest`. An
unregistered type is never dropped: it still queues, and it pages as a registry defect until someone registers it".
The registry exists (source step 4, done), which was this step's precondition: "**Phase 3, review intake as a
packet,** after the registry exists. Bar as in section 4."

What ships, verbatim from the source's section 4, Phase 3:
- "The five bucket-1 types write to `grocery/out/review-packet.json` instead of calling send-alert. Daily triage works
  the packet the way it works Class C items today."
- "Automatic adjudication runs first:
  - a flag that is the footprint of an earlier ruling (09-10's donuts +74% was the previous day's exclude working)
  - an acknowledged flag still inside its expiry
  - a move a committed routing artifact already predicted"
- "Only a crown change, or a move beyond the commodity's band, on a live cell that adjudication could not explain,
  pages."

Bar, verbatim: "those five types page on at most 4 of 14 days, while the packet carries every row the alerts used to.
The census checks row-count parity."

The five bucket-1 types, from the source's section 3: matching soundness review, new price flags, semantic sweep,
stores dropped from a commodity, wrong store department. Since 2026-09-20 a review-class alert is born in the weekly
lane and never mailed (`send-alert.ps1`, Brad's ruling of that day), so step 11 starts from there: it moves those
queue items into the packet and adds the adjudication, rather than reclassifying anything.

**Status: BUILT and LANDED 2026-10-02 (846e055cd); bar window opens 2026-10-03, closes 2026-10-17** (the 14 days 2026-10-03 to
2026-10-16). The bar above is unchanged. What was built, for the reader of the bar:
- The route is at `send-alert.ps1` once the registry class is known, so no emitter call site changed. A review-class
  alert whose registry entry is one of the five (the soundness entries by id or by `lineage_parent` match-soundness,
  `new-price-flags`, `semantic-sweep`, `stores-dropped`, `wrong-department`) writes one row of
  `grocery/out/review-packet.json` (gitignored, machine-local, beside the queue it replaces for these types) and is not
  queued. A row with an unexplained crown change or an engine-stated out-of-band move on a live cell ALSO queues as a
  review item did before (still not mailed: nothing is reclassified). Every failure falls back to the queue.
- The three adjudications are pure functions in `grocery/review-adjudication-lib.ps1`, each recording its evidence on the
  line: a ruling footprint (a catalog change or a known-wrong ruling on the commodity in the last 2 days), an
  acknowledgement in `review-ack.json` still inside its expiry, and a committed `*.routing.json` prediction from the last
  14 days. The band verdict is the engine's, read off the line; no band is computed.
- dc03c3 is folded in: one condition is one packet row (a repeat absorbs, as a queue item absorbs), and the soundness
  roll-up adds none. The roll-up subject was already registered on 2026-10-01 (`match-soundness-digest`), so the
  registry is unchanged.
- `triage-due.ps1` lists the rows a reader owes as Class C/D work for the JOB 3 spawn; a row makes the run DUE on its own
  after 7 days. `audit-alert-census.ps1` prints the page days against the bar and the row-count parity against
  `grocery/out/review-intake.jsonl`, the ledger the route appends before it adjudicates. A break is printed, not paged.
- Baseline for the bar, measured 2026-10-02 from the live queue with the lib's own page-day count: the five types plus
  the soundness crown page queued on 14 of the 14 days 2026-09-19 to 2026-10-02 (50 observations over 7 registry
  entries). The packet's effect on that number is not predicted here; the window measures it.

## 3. Not carried

- Steps 1 to 7 and the R19 push-check work: done, and recorded in the source plan with their leaves-open items and
  owners, which stay there.
- R12, the Walmart headed probe: recorded NOT PROBED (ba0eb1125).
- R13 to R16 and R17 (pace): applied in the source plan.

## 4. The measurement behind this split

Harness: `plan_citation.py --replay 2026-09-16 <ref>` (under `ops/`, blob `3e3fc44542991632a8ba87a0ff2101bc16c0dca3`,
unchanged since the finding used it), run 2026-09-24 from a linked worktree. The replay judges each commit against the
plans its FIRST PARENT held, so it cannot show the effect of a Status change made later: re-run after this lands, it
prints the same numbers. The "after" arm is therefore a counterfactual through the same `judge()`: the same commits,
each parent's plan set with exactly two plans replaced by this branch's text (the source plan with its DONE Status, and
this plan added). The counterfactual was a scratch script that monkeypatches `judge()` and changes nothing else; it is
described here rather than committed because the question it answers does not recur.

| Window | Arm | Session commits | Warnings | Plans named by the warnings |
|---|---|---|---|---|
| since 2026-09-16 to 23778c0760d5 (the finding's window) | before | 572 | 86 | zero-alert-days 83, push-derived-conflicts 4 (one commit names both) |
| same | after | 572 | 4 | push-derived-conflicts 4 |
| since 2026-09-16 to da90eea25 (origin/main on 2026-09-24) | before | 681 | 93 | zero-alert-days 85, push-derived-conflicts 7, bot-checkout-self-heal 2 (one names two) |
| same | after | 681 | 9 | push-derived-conflicts 7, bot-checkout-self-heal 2 |

Variants tried: two. The first named every existing file in section 1 as a path, and its after arm was 55 warnings of
572, 51 of them naming this plan (the per-row counts in section 1 come from that arm). The second, this one, names only
the files no other lane writes, and names this plan in 0 warnings of 572. No numeric bar was written down before
either arm ran, so these are measurements, not a bar met. What the second arm was designed to hold, and does: this plan
names none of the three files the finding counted, and names no tracked file at all today.
