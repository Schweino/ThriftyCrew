# EVAL: the lf1 drill - what F1 through F4 and H1/H2 actually measured

Date: 2026-08-25. Author: the latency build session (F1, H1, F2, F3, F4, H2 built and pushed; this is
the H3 drill and its report). Status: MEASUREMENT. Two targets are MISSED and both are reported with
their numbers rather than softened. Nothing here is a build item; the two findings at the end are
conversations for Brad.

Scratch root C:\tmp\lf1, NO --publish, no headless store contact, seams engaged: --pool --ledger
--specs --costed --food-db and the new --queue --carriage --considered.

## 0. The one-paragraph verdict

The tail is finally measured and it is where the plan hoped: the writer costs 1 turn, source-QA 3, the
recipe-local repair 1, against 23, 6-8 and 20 on 6b. The FDC shelf now fills for a run's own terms
(13 of 13 covered on round one, against jc1's 4 of 19) and the mapper's seconds-per-turn fell from 61
to 17-29, which is the label-acquisition signature disappearing exactly as F1 predicted. But the
mapper's TURN COUNT did not move at all: 22 turns on both drill rounds, the same 22 as 6b, including
on a batch where two of the three recipes had ZERO residual lines. That is the single finding this
drill exists to surface, and it says the remaining map cost is not retrieval. The registrar's batch
road came in at 3 turns and 40k against jc1's 10 turns and 82k, but on a batch of ONE, so the batch
claim itself is still unproven at width.

## 1. What was run

Two rounds, because the first one's candidates were not actually pre-qualified.

- **Round 1 (C:\tmp\lf1\run)**: three 6b recipes chosen by LOWEST RESIDUAL COUNT. All three reached
  the mapper, all three came back with unpriced terms (fresh mozzarella, whole grain mustard, fresh
  parsley, shredded mozzarella, Italian breadcrumbs) and parked at pricing. Measures the mapper and
  the registrar. **My error, stated plainly**: residual count is not the plan's criterion. Plan 8.H3.2
  says every line must be `resolved+bid or optional`, and a residual line is one the mapper still has
  to rule - which is exactly where a new unpriced term comes from.
- **Round 2 (C:\tmp\lf1\run2)**: the criterion applied properly. map-preresolve was run standalone
  over all 51 extractions in the estate's five previous runs; exactly **2 of 51** came back with zero
  residual and zero unbid lines (baked-cauliflower-mac-smoked-sausage,
  philly-cheesesteak-stuffed-peppers), and one more at a single pantry residual
  (sheet-pan-smoked-sausage-broccoli-cheddar). Those three ran the tail.

Round 2 needed one daemon restart to reach the write lane; see finding 3.

## 2. The two baselines, reproduced

**6b, from PLAN-hunter-judge-contract section 1** (pre-judge-contract):

| dispatch              | turns | raw tokens | ctx/turn |
|-----------------------|-------|-----------|----------|
| select decide:8x      | 1     | 27,379    | 27k      |
| map map:3x            | 22    | 1,084,231 | 49k      |
| write (one recipe)    | 23    | 1,169,531 | 51k      |
| audit wave-2:audit    | 28    | 1,006,166 | 36k      |
| audit wave-2:repair   | 20    | 1,223,492 | 61k      |
| qa repair             | 14    | 501,882   | 36k      |
| registrar (each)      | ~9    | ~94k      | 10k      |

**jc1, from EVAL-latency-cold-read section 1.1** (post-judge-contract, pre-F1):

| stage       | wall     | share | turns | sec/turn | note |
|-------------|----------|-------|-------|----------|------|
| mapper      | 12.3 min | 77%   | 12    | 61       | 15 of 19 residual lines needed label acquisition |
| pricer      | 1.2 min  | 7%    | 6     | 12       | evidence pre-gathered; unusable stores parked it |
| registrar   | 0.9 min  | 6%    | 10    | 5.5      | one new commodity (prosciutto) |
| decider     | 0.5 min  | 3%    | 1     | 31       | 3 candidates ruled in one turn |
| pre-pass    | 0.5 min  | 3%    | 0     | -        | mechanical store gathering |
| mechanical  | 0.1 min  | <1%   | 0     | -        | preresolve, verify x2 |
| local       | 0.03 min | <1%   | 0     | -        | both extractions, rung 1 |

## 3. hunt-run.ps1 -LaneSummary, verbatim

Round 2 (the tail):

```
hunt-run lane summary: run2
  lane       calls  turns  trips   items        input       output        total   share re-asks  mean_sec total_min
  map            7      1     22      15      615,848       27,717      643,565   60.7%       0        54       6.3 [+1108 delegated out]
  audit          3      2     12       2      325,387       15,415      340,802   32.1%       0        82       4.1 [+46 delegated out]
  write          5      1      1       5       32,788        7,652       40,440    3.8%       0        22       1.9 [+21 delegated out]
  qa             1      1      3       1       34,545        1,412       35,957    3.4%       0        27       0.5 [+380 delegated out]
  TOTAL         16      5     38      23                              1,060,764
HUNT-RUN-COMPLETE lane-summary lanes=4 tokens=1060764
```

Round 1 (map and registrar only):

```
hunt-run lane summary: run
  lane       calls  turns  trips   items        input       output        total   share re-asks  mean_sec total_min
  map            8      2     25      16      801,130       53,834      854,964  100.0%       0        87      11.6 [+395 delegated out]
  TOTAL          8      2     25      16                                854,964
HUNT-RUN-COMPLETE lane-summary lanes=1 tokens=854964
```

## 4. hunt-run.ps1 -StageSummary, verbatim

Round 2:

```
hunt-run stage summary: run2
  lane      stage                              n  total_min  mean_sec   share  kind
  map       map:3x                             1        6.1       368   48.3%  judgment
  audit     wave-1:audit                       1        2.9       174   22.8%  judgment
  write     philly-cheesesteak-stuffed-pep     1        1.8       108   14.2%  judgment
  audit     wave-1:repair-patch:philly-che     1        0.9        54    7.1%  judgment
  qa        philly-cheesesteak-stuffed-pep     1        0.5        27    3.5%  judgment
  audit     wave-preaudit w1                   1        0.3        17    2.2%  mechanical
  map       map-preresolve                     2        0.1         3    0.8%  mechanical
  map       fdc-fill                           1        0.1         3    0.4%  mechanical
  write     build-intake-skeleton              2        0.0         1    0.3%  mechanical
  map       map-preresolve verify              3        0.0         1    0.3%  mechanical
  write     build-v2-spec                      1        0.0         1    0.1%  mechanical
  write     skeleton verify                    1        0.0         0    0.0%  mechanical
  measured 12.7 min across 12 stage(s). Lanes OVERLAP, so this exceeds wall clock - it ranks, it does not budget.
HUNT-RUN-COMPLETE stage-summary stages=12 measured_min=12.7
```

Round 1:

```
hunt-run stage summary: run
  lane      stage                              n  total_min  mean_sec   share  kind
  map       map:3x                             1       10.5       631   91.1%  judgment
  map       registrar:1x                       1        0.6        38    5.5%  judgment
  map       fdc-fill                           1        0.2        12    1.7%  mechanical
  map       map-preresolve                     2        0.2         5    1.4%  mechanical
  map       map-preresolve verify              3        0.0         1    0.3%  mechanical
  measured 11.6 min across 5 stage(s). Lanes OVERLAP, so this exceeds wall clock - it ranks, it does not budget.
HUNT-RUN-COMPLETE stage-summary stages=5 measured_min=11.6
```

## 5. Every target, against its measurement

| stage | target | MEASURED (lf1) | 6b baseline | jc1 baseline | verdict |
|-------|--------|----------------|-------------|--------------|---------|
| map, per batch of 3 | <=6 turns / <=300k | **22 turns / 814,866** (r1), **22 turns / 643,565** (r2) | 22 / 1,084,231 | 12 / 444,300 | **MISSED** |
| registrar, per batch | <=3 turns / <=120k | **3 turns / 40,098** (batch of ONE) | ~9 / ~94k each | 10 / 81,929 | MET, unproven at width |
| write, per recipe | <=4 turns / <=250k | **1 turn / 40,440** | 23 / 1,169,531 | never ran | MET |
| source-QA, per recipe | <=3 turns / <=120k | **3 turns / 35,957** | 6-8 / 104k-143k | never ran | MET |
| audit, full wave | <=10 turns | **11 turns / 302,974** | 28 / 1,006,166 | never ran | **MISSED by one turn** |
| scoped re-audit | <=4 turns | **not measured** | - | - | see below |
| recipe-local repair | <=5 turns / <=200k | **1 turn / 37,828** | 20 / 1,223,492 | never ran | MET |

Seconds per turn, the F5 correlate: mapper 631s/22 = **28.7 s/turn** on round 1 and 368s/22 =
**16.7 s/turn** on round 2, against jc1's 61 and 6b's 26-61. The acquisition turns are gone; the turns
themselves are not.

**The scoped re-audit was not measured, and the reason is a feature working.** The wave-1 audit
returned a recipe-local NO-GO, the patch road ran (1 turn), the repair returned `no_change` with its
reason, and the changed-nothing guard refused to pay for a re-audit. So F4's delta block never
rendered in production. It is proven by fixture only (`_reaudit_carries_the_repair_delta`, with the
first-audit clean twin and both neuter proofs), and Thursday's wide run is where it will first render
for real.

**The registrar batch is MET but on one proposal.** Round 1's mapper proposed exactly one new id, so
`registrar:1x` is a batch of one. It is still a fair comparison against jc1's single-proposal 10 turns
and 81,929 raw - same shape, same gate, 3 turns and 40,098 - but the claim that N proposals cost one
session is not yet measured at N>1.

## 6. F1, measured directly

The shelf-coverage line, from the drill logs:

```
map shelf: 13 of 13 term(s) with no food-DB row carry FDC candidates          (round 1)
map shelf: 2 of 4 term(s) with no food-DB row carry FDC candidates; FDC lacks: smoked sausage, andouille smoked sausage   (round 2)
```

Against jc1's measured 4 of 19. The fill itself is cheap and mechanical: 11.8 s for 15 terms on round
1, 2.6 s for 4 terms on round 2, and the second pre-resolve pass costs 4.5 s and 2.7 s. Round 2's two
lacking terms are the correct residue - FDC genuinely does not carry "andouille smoked sausage" under
that phrasing, so those are the mapper's licensed web reads, exactly as plan 3.3.3 says.

## 7. H1 and H2, measured

**H1.** Round 1 produced six food-DB conflict findings and every one of them was a SERVING-BASIS
difference (100 g against 4 oz / 0.25 cup), not a rounding difference. The rule refused all six, the
existing rows stood, and the recipes proceeded - which is the Pork Chops save firing six times. No
rounding-noise finding appeared at all, which is the half H1 was built to delete. But see finding 2:
the basis conflicts are a NEW class that F1 itself created.

**H2, proven in production.** The live ledgers were last written at 07:00 by the daily pipeline bot;
the drill ran from 07:40. grocery\ingredient-queue.json, grocery\carriage.json,
meal-prep\db\considered-dishes.json and meal-prep\food-macros-db.json all still carry their pre-drill
bytes. The five terms round 1 could not price sit in C:\tmp\lf1\queue.json and nowhere else, and the
six refused food-DB rows hit the scratch DB copy. Before this build, all of that would have landed
live.

## 8. Findings for Brad - conversations, not build items

**1. The mapper takes 22 turns no matter what you hand it. This is the finding.**
Round 2's batch had 4 unshelved terms across three recipes and TWO of the three recipes had zero
residual lines - every ingredient already resolved, bid wired, food-DB row present. It still took 22
turns, the same as 6b's 22 and this drill's own round 1. Sec/turn fell (61 -> 17), and total tokens
fell 41% against 6b, so the retrieval half really did leave. What is left is turn-shaped and it is not
label acquisition. Plan 7 anticipated exactly this ("if turns stay high with a warm shelf, that is a
NEW finding for Brad, not a build-time improvisation"), so it is reported and nothing was improvised.
My reading, offered as a hypothesis and not a diagnosis: the residual contract asks for a `buy` string
on EVERY purchasable line plus a macro cross-check, and the mapper appears to spend a turn per line of
thinking rather than one turn over the batch - the decider's shape has not actually reached this
stage. Proving that needs a transcript read, which is its own piece of work.

**2. The FDC shelf feeds per-100 g rows into a DB of label rows, and every one is a basis conflict.**
All six of round 1's conflicts were the same shape: the mapper took an FDC row (per 100 g, which is
how FDC states everything) for a food the DB already carries from a printed label (4 oz, 0.25 cup).
H1 correctly calls that a full conflict - a different basis IS a different claim - so nothing was
written and nothing was lost. But this is a new noise class that F1 created, it will scale with the
shelf, and the two honest options are (a) teach the row contract to carry the FDC portion data
alongside the 100 g basis, or (b) accept the findings as the price of a warm shelf. Both are yours.

**3. A recipe with ZERO absent terms still routes to the price lane.**
`map_lane` advances to `priced` only when the mapper's own `state` field says "priced"; otherwise it
routes to pricing even when `absent_terms` is empty. Both of round 2's fully-resolved recipes went to
`pricing` with an EMPTY term list and sat there. The estate's own resume road fixed it - a second
daemon start ran `hunt-run -Derive`, which moved them to `priced` and into the write lane - but that
is a whole process restart in the middle of what should be a straight line, and on an unattended run
it is a park with nothing to unpark it. Not touched: changing that routing is a state-machine decision
and nobody ordered it.

**4. The --specs seam does not cover the audit path.**
The wave-1 auditor found that "the certified spec is the stale 2026-08-16 lowcarb-100 build", i.e. it
read meal-prep\db\recipes rather than the drill's scratch spec store, because the drill reused a slug
that already exists live. It produced a real NO-GO on a real disagreement, so no gate was fooled - but
a drill on a fresh slug would never have surfaced it, and Thursday's run at width will read live specs
during audit whatever --specs says.

**5. Pre-qualified candidates are RARE: 2 of 51.** Across every extraction the estate has kept, only
two recipes have a fully resolved, fully bid ingredient list. That is worth knowing before Thursday:
the tail this build optimised is reached by a small minority of candidates, and the price lane is what
the rest wait on. It does not change any target; it changes what "a clean recipe" means in practice.

**6. One artifact of my own seeding, recorded so nobody hunts it.** The drill's state files were
written by hand and lacked the `reject_reason` property, so hunt-run's `-Advance` to rejected-audit
threw when the wave trimmed. Not an estate defect; real state files carry the field.

## 9. What shipped, and what proves it

Six units, one commit each, all pushed:

| unit | commit | fixtures | suite |
|------|--------|----------|-------|
| F1 the FDC shelf is filled | 6b8be346 | 7 | 168 -> 175 |
| H1 rounding is not a conflict | 10723525 | 2 | 175 -> 177 |
| F2 the registrar batch dossier | 0c47012c (message in 877a660d) | 4 new + 6 re-pointed | 177 -> 181 |
| F3 the QA dossier and the verdict pen | 3dd0c945 | 4 | 181 -> 185 |
| F4 the re-audit delta | 9af5515f | 2 | 185 -> 187 |
| H2 the drill seams | 19a59904 | 5 + 1 in ingredient-queue.ps1 | 187 -> 192 |

hunt-daemon --selftest 192 ok (baseline 168), hunt_lib --selftest and --parity 63/63 green,
ingredient-queue.ps1 -SelfTest and considered-dishes.ps1 -SelfTest green,
ops\audit-prompt-backup.ps1 -Sync clean after both agent-definition edits.

Neuter proofs, all RUN and reverted, and recorded in each suite section's header: the fill call, the
re-run, the shelf marker and the fill-list filter (F1); the tolerances zeroed (H1); dispatch-per-
proposal, the three dossier blocks, the batch validator (F2); the dossier, the announcement, the
verdict write, the empty-verdict guard (F3); repair_by_patch returning None and the block rendered on
every audit (F4); queue_args, the considered seam and the pricer note (H2). Both concurrency locks
(food_db_lock, fdc_lock) have their neuter as a LIVE case that runs every suite run, not a comment.

CORRECTED blocks written: PLAN-hunter-judge-contract 3.1 ("so candidates arrive" - false in
practice); PLAN-recipe-hunter-v3 S4 (the two-pass pre-resolve, and the conflict rule refined);
PLAN-latency-F1-F7 3.3.3 (the coverage line named the wrong population) and 5.2.3 (nothing reads
qa\<slug>.json, so the pen moved); EVAL-latency-cold-read F2 (BUILT note).

## 10. What this does not measure, said plainly

The price lane (never entered - deliberate, per plan 10), the decider and the extraction ladder (not
run), the registrar at a batch of more than one, F4's delta block in production, and throughput at
width. Thursday's wide proving run is where those live, and it is a separate session.
