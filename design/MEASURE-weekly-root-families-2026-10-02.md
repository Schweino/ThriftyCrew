# MEASURE: the 27 weekly items and the six root families (Phase 0 of PLAN-weekly-root-families-2026-10-02)

Measured 2026-10-02 by the session that took the plan (Brad ruled D1 A, D2 A, D3 A that day). Source of the rows:
each item's full queue body and notes in `grocery/triage-queue.json` (27 open, read at 2026-10-02 ~13:00, main
checkout), plus today's outputs named per row. The plan's own family table was an input built from titles and the
first 420 characters of each body; this file is the measurement it asked for.

## Verdict first

- **Bar (written in the plan before this ran): at least 22 of the 27 (81%) map to one of the six families with a
  named preventing step. Measured: 25 of 27 (92.6%). MET.** The two that do not: `a82e6c` (the knowledge store's
  nightly pass, outside grocery, D4) and `1ed278` (five recipe-side leftovers of 177835 with no single owner).
- **A stricter reading does not meet it, and that is the finding worth keeping.** If "named preventing step" must
  cover every instance inside the item, it is 21 of 27 (77.8%). The gap is one missing step, not noise: 5 of the 8
  sale cells with no everyday fallback today are **Hy-Vee** (chicken-drumsticks, frozen-cauliflower-rice, gruyere,
  quinoa-uncooked, white-wine), and the plan's family 4 root is the Family Fare 86-day rotation, which explains only
  the 3 Family Fare cells. `e40f92` and `e7f9b9` carry that Hy-Vee half. `465acc` and `ab2257` are the other two: a
  second signal or a basis contract supplies evidence there, but the call itself may stay with a product-detail read
  (olive oil mayo) or the band (Aldi shampoo at 0.5576/oz against 0.0941 may be a real premium price). Recorded in
  section 4 as an open item for Phase 7, not a reason to re-plan: every family still has its preventing step.
- **Family sizes, last 30 days (2026-09-03..2026-10-02), by census type:** 154 of 473 alerts (32.6%) map by type to a
  ruled step: step 11 (review intake) 86, Phase 7 (capture coverage) 18, step 8 (row basis) 16, Phase 5 (chain data
  flow) 16, step 9 (identity) 11, Phase 6 (traps) 7. Another 100 alerts (21.1%) were triage's own residuals and
  findings, which carry no type a step can match; 21 of the 27 open items are of that kind and are joined by row
  below. The remaining 219 (46.3%) belong to no family here (knowledge store, silent-death, capture watchdog, guards
  failed with mixed causes, store registry, push and ghost checks).
- **Order for Phases 2 to 4** (the plan: "that count orders Phases 2 to 4", families 1 and 2): family 1 has 16 typed
  alerts plus 7 open items, family 2 has 11 plus 6. So the row contract (Phase 2) leads identity (Phase 3). Step 11
  carries the most volume (86) and lands as soon as it is verified. All three were built in parallel on 2026-10-02.

## 1. One row per item

"Reproduces today" is read from today's files where one was cheap to read; "not re-measured" says so rather than
guessing. A latent item is one whose shape is still in the code but has no live instance today.

| Item | Family | Step that prevents it | Reproduces today (2026-10-02) |
|---|---|---|---|
| 9ee1f9 Hy-Vee pack x size; each over multibuy | 1 row basis | remainder #8 (row contract: pack count, price basis) | latent: both ad lines left with their ad on 09-27; no change to the parser since |
| 7c3a24 N-for-M on each-unit commodities, no count | 1 | #8 (pack count with source and refusal code) | not re-measured (30 rows on candidates-2026-09-28) |
| 6adf51 multibuy refusal half misses a pack count; Muscle Milk powder to milk | 1 (+2 for the routing half) | #8 (+ #9 for the routing half) | not re-measured |
| 1eac5a Sam's count-per-pound read as pieces | 1 | #8 (unit kind and pack count from their own fields) | not re-measured (Sam's capture of 09-27) |
| 35fdeb guard 4 exempts Fareway ttl and Walmart rollback; garlic-bread / Fareway 0.13x | 1 | #8 (price basis per row); the guard-widening half is a guard decision | not re-measured |
| 44c416 fl oz read as weight oz, 410 rows on 35 commodities | 1 | #8 (unit kind, density declaration) | yes: candidates-2026-09-30.json is still the newest candidate file |
| ab2257 band refusals with no basis evidence | 1 (partial) | #8 supplies the evidence; the call stays with the band or worklist | yes: 66 shampoo band rows (Aldi Head & Shoulders among them) on today's worklist, 1,135 band rows in all |
| 6fc290 Family Fare household lines routed to food; store department unread | 2 identity | remainder #9 (store department as the second signal) | latent: both founding lines are known-wrong; the class is open |
| 184b1d 4 worklist keys need a two-rule fix | 2 | #9 | yes: carrots, milk and garlic contested and canned-pears coverage all still undecided on today's worklist |
| 356c4e facial tissues moved by a lotion exclude | 2 | #9 | not re-measured |
| 465acc 3 identity cells need a product-detail read | 2 (partial) | #9 (a store category may not tell olive oil mayo from dressing) | not re-measured (exit 2, rise 3 on 09-29) |
| 88bd45 single-signal soundness quarantine hits good cells | 2 | #9 (replaces the single-signal trigger) | rate to watch: cell_by_contest is empty in today's soundness report |
| a57d2e NEW CONTESTED | 3 review | remainder #11 (packet with adjudication) | yes: coffee and pasta-sauce contested rows undecided today |
| 0210a6 stores dropped from a commodity | 3 | #11 | yes: beef-short-ribs (widen) and canned-pears undecided; the brussels-sprouts row is gone |
| 8415b9 semantic sweep | 3 | #11 | yes: both Prairie Fresh spareribs rows undecided |
| dc03c3 soundness roll-up opens a duplicate item | 3 | #11 (one condition, one packet row) | latent: 3 in 30 days |
| e40f92 Family Fare everyday capture "throttled"; Hy-Vee has no drumsticks | 4 capture | this plan Phase 7 (Family Fare half); **no step for the Hy-Vee half** | yes, and grown (next row). The "throttled" record is the 7-a-day rotation working as ruled (memory `ff-term-budget-is-quarterly-by-design`), not a wall |
| e7f9b9 sale cells with no everyday fallback | 4 | Phase 7 (3 Family Fare cells); **no step for 5 Hy-Vee cells** | yes: 8 escalated cells in `grocery/out/sale-fallback-gaps.json` (08:31), all owned, all `terms_attempted=true`, so the alert's "NO ONE IS WORKING THEM" wording is wrong for every one |
| c6bafd feed one run behind top5-weekly | 5 chain data flow | this plan Phase 5 (step-order gate) | yes, in code: `check-ad-cycles.ps1` runs the daily feed export at line 1246 and top5-weekly at line 1941 |
| 1d4206 post and feed built from different boards | 5 | Phase 5 (board pin) | latent: the newest verified board is verified-2026-08-16, older than every comparison |
| 871301 chain stale-artifact check unsound at 8 sites | 5 | Phase 5 (a declared input/output list may close it; the Phase 5 build says) | yes: an unsound check cannot report its own misses |
| 2bcd10 foreign writers during the chain | 5 | `design/PLAN-bot-dedicated-checkout-2026-09-25.md` Stage 2 (W2.1), RULED; this plan does not duplicate it | latent: 1 proven content move in 26 runs |
| 3849bc `@(... \| ConvertFrom-Json)` ungated | 6 traps | Phase 6 (ratchet) | yes: 91 matching lines today over grocery, ops, lib and meal-prep (the item said 90) |
| c12baf reaper MUST FIRE depends on box load | 6 | Phase 6 (static check, fix at source) | 1 occurrence (push of 2026-10-01) |
| ae8b7a match-lib reds under load | 6 | Phase 6 (load reds read BLIND, not red) | not at rest; 2 occurrences in 30 days under the chain |
| a82e6c knowledge store nightly pass | none | D4, Brad's own read | n/a |
| 1ed278 177835 leftovers (routes, dangmyeon, identity mark, rebid cache, pepperoncini) | none (mixed, recipe side) | no single step | (b) dangmyeon: 3 recipes still held NO PRICE BASIS |

Count: family 1 = 7, family 2 = 5, family 3 = 4, family 4 = 2, family 5 = 4, family 6 = 3, none = 2. 25 mapped.
The plan's table had family 2 at 6 with `1ed278` in it; read whole, `1ed278` is recipe routing, a rebid cache key and a
floor row, not name-based commodity matching.

## 2. The census's top 10 recurring types (days fired, 2026-09-03..2026-10-02, 28 days with data)

| Days | Alerts | Type | Family | Step |
|---|---|---|---|---|
| 18 | 18 | grocery new price flag s | 3 (content is often family 1) | #11 |
| 18 | 16 | grocery semantic sweep found product s no rule can see | 3 | #11 |
| 15 | 18 | grocery store s dropped from a commodity they carry | 3 | #11 |
| 15 | 16 | the knowledge store s nightly pass went red | none | D4 |
| 14 | 20 | grocery guards failed board not published | mixed, not attributed | step 8's bar counts its basis-class share |
| 13 | 13 | grocery capture watchdog issue s | none of the six | capture health; R18 and R11 are the nearest steps |
| 10 | 10 | automation silent death issue s | none | scheduling |
| 10 | 10 | grocery matching soundness new contested | 3 | #11 |
| 9 | 10 | grocery matching soundness review needed | 3 | #11 |
| 9 | 7 | grocery a guard has gone blind test auditors failed | 6 | Phase 6 |

6 of the top 10 belong to a family with a step. "Guards failed" is left unattributed on purpose: one type carries
basis, identity and freshness failures, and assigning it whole to step 8 would overstate that step's reach.

## 3. Harness

The family counts come from the committed map and library, so they can be re-run:
`grocery/ruled-steps.json` (type prefixes per step) and `grocery/ruled-step-lib.ps1` `Get-RuledStepAttribution`, over a
scratch copy of `grocery/out/alert-census.jsonl` as of 2026-10-02 (554 day/type rows in the 30-day window), with
`-Days 30` and `-Days 14`. The census prints the 14-day figure daily (its RULED STEPS line); on this day it read 100
of 330 alerts attributed, steps 8, 9 and 11 STALLED. Blobs are named in the commit that lands this file, per rule ms-07.
Variants tried: one map. Two prefixes were left out deliberately (guards failed, board cells quarantined: mixed causes).

## 4. Open items this measurement leaves

- **Hy-Vee everyday coverage has no step.** 5 of today's 8 no-fallback sale cells are Hy-Vee, and `e40f92` records
  that `pull-regular-hyvee.ps1` returned no drumstick row on 09-28. This is capture coverage (family 4) at a store the
  86-day Family Fare ruling does not touch. Carried into Phase 7 as a question to measure, and into the plan's status.
- **The no-fallback alert's wording is wrong today for all 8 cells** ("NO ONE IS WORKING THEM" while every cell is
  owned with `terms_attempted=true`). That is a detective-wording fix inside Phase 7, buildable without any ruling.

## Knowledge consulted

- `experiment-craft/analysis-preflight.md` items 2 and 3, as the plan quotes them: every rate here carries its
  denominator (25 of 27, 154 of 473), and the 81% bar was written in the plan before the rows were read.
- `.claude/rules/measurement.md` ms-03: "A number that moved is not a number that improved" (no before/after is
  claimed here; this is a baseline). ms-07: blobs, not an unlanded hash.
- memory `ff-term-budget-is-quarterly-by-design` ("The Family Fare pull buying 7 terms of 602 per day is DELIBERATE,
  not a throttle defect"): why `e40f92`'s "throttled" is read as the rotation, and why the Hy-Vee half stands apart.
- Observed while measuring, not from the store: the first attribution run read 0 of 473 while the census read 100 of
  330 for the same map. The disagreement was a relative path read by `[IO.File]` against the process directory, fixed
  in `ruled-step-lib.ps1` before any number here was taken.
- searched "plan status step owner residual" (knowledge-search --estate): memory `triage-cost-controls`, the basis
  for D3 and for where the residual rule is taught (the triage skill's COST CONTROLS block).
