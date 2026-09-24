# PLAN: the rest of zero-alert days (row contract, two-signal identity, muffins, the review packet)

**Status: RULED 2026-09-10 (carried from PLAN-zero-alert-days), not started.**

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

- step 8: `design/SPEC-capture-row-contract.md`, `grocery/row-contract-lib.ps1`
- step 9: `grocery/audit-store-category-share.ps1`, `grocery/audit-crown-identity-shadow.ps1`
- step 11: `grocery/review-adjudication-lib.ps1`
- R11: `design/TRIAL-aldi-fareway-page-json.md`

### Named when their step starts (file names only, so the check does not read them yet)

| Step | Existing files the step changes | Session commits since 2026-09-16 that touched them |
|---|---|---|
| 8, row contract | the seven builders `build-walmart-deals.ps1`, `build-aldi-regular.ps1`, `build-fareway-regular.ps1`, `build-sams-deals.ps1`, `pull-regular-hyvee.ps1`, `pull-regular-familyfare.ps1`, `pull-regular-bakers-api.ps1`, and the two batch importers `import-walmart-batch.ps1` and `import-instacart-batch.ps1` (all under `grocery/`) | 32 |
| 9, two-signal identity | none until enforcement; the crown selection file joins only if the enforcement bars are met | |
| 10, muffins | the commodity catalog `commodities.json` and its search and category files (under `grocery/`), in one change through the registrar and the money lane | 23 (the catalog file alone) |
| 11, review packet | `send-alert.ps1` (the review-class route), `triage-due.ps1` (triage works the packet), `audit-alert-census.ps1` (row-count parity), all under `grocery/` | 15 |
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

### 9. Ruling 3, two-signal identity

Ruling, verbatim (ruling 3): "**Two independent signals must agree** for a crown; 2 weeks in shadow before it refuses
anything".

Build step and bar, verbatim: "First measure what share of each store's rows carries a usable category. Then 14 days
of shadow on crowns. Enforce only if a hand-checked sample of at least 30 disagreements is at least 80% real wrong
products, and enforcement would empty no more than 2% of live cells. Both numbers are first guesses, recorded as such,
to be revisited against the shadow data."

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
