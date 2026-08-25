# EVAL: the m1 drill - what M1 through M4 actually measured

Date: 2026-08-25. Author: the M1-M4 build session (all four units built, fixtured and pushed; this is
the drill and its report). Status: MEASUREMENT. The map lane's standing target is MET for the first
time on a pre-qualified batch and MISSED on a residual-heavy one, both with their numbers. Two new
findings for Brad at the end, neither of them a build item.

Scratch root C:\tmp\m1, NO --publish, no headless store contact, `--lanes map,write,qa`, every seam
engaged: --pool --ledger --specs --costed --food-db --queue --carriage --considered. State files
seeded through hunt-run's own -Advance, so every one carries `reject_reason` (lf1 finding 6, closed).

## 0. The one-paragraph verdict

The contract deadlock is broken and it is provable on disk: the drill wrote food-DB rows citing
`fdc:2067385` and `fdc:171241`, which the mapper could not have produced before M1 because the shelf
never rendered an id. On the like-for-like batch - the SAME three pre-qualified slugs the lf1 round-2
tail ran - the mapper fell from **22 turns / 643,565 raw to 4 turns / 115,898 raw**, which is the
first time the map lane has ever come in under its <=6 turns / <=300k target. The transcript shows
why: 3 tool calls, against lf1's 21, and every one of the lf1 classes M1 and M2 were built to delete
is simply absent. On the residual-heavy batch the mapper came in at **13 turns / 295,972 raw** - raw
inside target, turns twice over it - and the residue is exactly what plan 3.3 said would remain:
label acquisition for foods FDC does not carry. Two things did NOT go to plan and both are reported
with their measurements: M4's one-fetch-one-fallback cap is not being obeyed (9 web calls on batch B),
and on batch A it produced the opposite failure - the mapper returned NO food-DB row for a food it
previously acquired, which blocked the write lane. The tail (write, QA, audit) was therefore NOT
measured on this drill.

## 1. What was run

Two batches, one run dir each, both from the corpora the lf1 drill left behind so the numbers compare.

- **Batch A (C:\tmp\m1\a)**: the SAME three slugs as lf1 round 2 - baked-cauliflower-mac-smoked-sausage,
  philly-cheesesteak-stuffed-peppers, sheet-pan-smoked-sausage-broccoli-cheddar - copied from
  C:\tmp\lf1\run2\extracted. Their mapped-pre tables came out byte-identical to lf1's, which is what
  makes this a twin and not a rerun.
- **Batch B (C:\tmp\m1\b)**: three residual-heavy slugs from the C:\tmp\lf1scan corpus, chosen at 5-6
  residual lines each - pulled-pork-stuffed-peppers (5 of 5), italian-sausage-peppers-onions-skillet
  (5 of 7), chicken-bacon-ranch-cauliflower-bake (6 of 8). This measures the round-1 acquisition shape.

Batch A needed a second daemon start to reach the write lane, and the reason is NOT the one lf1 hit -
see finding 1.

## 2. hunt-run.ps1 -LaneSummary, verbatim

Batch A, first start (the map lane alone):

```
hunt-run lane summary: a
  lane       calls  turns  trips   items        input       output        total   share re-asks  mean_sec total_min
  map            6      1      4      12       98,370       17,528      115,898  100.0%       0        38       3.8 [+735 delegated out]
  TOTAL          6      1      4      12                                115,898
HUNT-RUN-COMPLETE lane-summary lanes=1 tokens=115898
```

Batch A, cumulative after the second start (the write lane's one dispatch included):

```
hunt-run lane summary: a
  lane       calls  turns  trips   items        input       output        total   share re-asks  mean_sec total_min
  map            7      1      4      13       98,370       17,528      115,898  58.7%       0        33       3.8 [+735 delegated out]
  write          5      1      2       5       71,310       10,128       81,438  41.3%       0        29       2.5 [+21 delegated out]
  TOTAL         12      2      6      18                                197,336
HUNT-RUN-COMPLETE lane-summary lanes=2 tokens=197336
```

Batch B:

```
hunt-run lane summary: b
  lane       calls  turns  trips   items        input       output        total   share re-asks  mean_sec total_min
  map            8      2     25      16      372,807       46,566      419,373  100.0%       0        76      10.1 [+1717 delegated out]
  TOTAL          8      2     25      16                                419,373
HUNT-RUN-COMPLETE lane-summary lanes=2 tokens=419373
```

## 3. hunt-run.ps1 -StageSummary, verbatim

Batch A (first start):

```
hunt-run stage summary: a
  lane      stage                              n  total_min  mean_sec   share  kind
  map       map:3x                             1        3.7       221   97.8%  judgment
  map       map-preresolve                     1        0.1         3    1.3%  mechanical
  map       map-preresolve verify              3        0.0         1    0.9%  mechanical
  map       fdc-fill                           1        0.0         0    0.0%  mechanical
  measured 3.8 min across 4 stage(s). Lanes OVERLAP, so this exceeds wall clock - it ranks, it does not budget.
HUNT-RUN-COMPLETE stage-summary stages=4 measured_min=3.8
```

Batch B:

```
hunt-run stage summary: b
  lane      stage                              n  total_min  mean_sec   share  kind
  map       map:3x                             1        8.5       512   84.6%  judgment
  map       registrar:2x                       1        1.1        65   10.7%  judgment
  map       fdc-fill                           1        0.3        15    2.5%  mechanical
  map       map-preresolve                     2        0.2         5    1.7%  mechanical
  map       map-preresolve verify              3        0.1         1    0.5%  mechanical
  measured 10.1 min across 5 stage(s). Lanes OVERLAP, so this exceeds wall clock - it ranks, it does not budget.
HUNT-RUN-COMPLETE stage-summary stages=5 measured_min=10.1
```

## 4. Every target, against its measurement, beside all three baselines

Per-dispatch figures are read off the lane log's own end lines, so the map dispatch and the registrar
dispatch are separated rather than summed into one lane row.

| stage | target | m1 A (the lf1 twin) | m1 B (residual-heavy) | 6b | jc1 | lf1 | verdict |
|-------|--------|---------------------|-----------------------|----|-----|-----|---------|
| map, per batch of 3 | <=6 turns / <=300k | **4 turns / 115,898** | **13 turns / 295,972** | 22 / 1,084,231 | 12 / 444,300 | 22 / 643,565 (r2), 22 / 814,866 (r1) | **A MET, B turns MISSED / raw MET** |
| registrar, per batch | <=3 turns / <=120k | not dispatched | **12 turns / 123,401** (batch of TWO) | ~9 / ~94k each | 10 / 81,929 | 3 / 40,098 (batch of ONE) | **MISSED, and see finding 2** |
| write, per recipe | <=4 turns / <=250k | **2 turns / 81,438** | never reached | 23 / 1,169,531 | never ran | 1 / 40,440 | MET |
| source-QA, per recipe | <=3 turns / <=120k | never reached | never reached | 6-8 / 104k-143k | never ran | 3 / 35,957 | not measured |
| audit, full wave | <=10 turns | never reached | never reached | 28 / 1,006,166 | never ran | 11 / 302,974 | not measured |
| recipe-local repair | <=5 turns / <=200k | never reached | never reached | 20 / 1,223,492 | never ran | 1 / 37,828 | not measured |

Seconds per turn, the F5 correlate: batch A 221 s / 4 = **55 s/turn**, batch B 512 s / 13 = **39
s/turn**, against lf1's 16.7 (r2) and 28.7 (r1), jc1's 61 and 6b's 26-61. **Sec/turn went UP and that
is the shape of the win, not a regression**: the cheap tool round trips are the ones that left, so
what remains per turn is generation over a much larger inlined dossier. Wall clock is what moved -
3.7 min against lf1 round 2's 6.1 for the identical batch.

Shelf coverage, from the drill logs:

```
map shelf: 2 of 4 term(s) with no food-DB row carry FDC candidates; FDC lacks: smoked sausage, andouille smoked sausage   (batch A)
map shelf: 15 of 15 term(s) with no food-DB row carry FDC candidates                                                      (batch B)
```

Batch A's line is byte-identical to lf1 round 2's, which is the twin holding. Batch B's 15 of 15 beats
lf1 round 1's 13 of 13 on a wider term list.

## 5. The transcripts, decomposed tool call by tool call

This is the half the lf1 drill left for somebody else, so it is done here for both batches.

**Batch A mapper** (`1ca191fa-...jsonl`, 3.7 min): **7 assistant messages, 3 thinking blocks (all of
them EMPTY - 0 characters, so the plan's zero-thinking finding stands), 3 tool calls.**

**CORRECTED 2026-08-25 (the T-shakedown run).** "EMPTY - 0 characters" is a misreading, and it
propagated from here into the plan and into EVAL-registrar-batch. These blocks carry a `signature`
of tens of thousands of characters with the `thinking` text redacted out of the local transcript;
they are not empty, they are unreadable. On the T-shakedown mapper ~83% of output tokens were
reasoning rather than payload. Every "zero thinking" claim in this estate's design docs traces to
this line and none of them is evidence about how much the models reason.

1. `WebSearch` "Johnsonville Andouille Smoked Sausage nutrition facts label serving size grams calories protein"
2. `WebSearch` "Kraft shredded sharp cheddar cheese nutrition facts label 1/4 cup 28g calories protein fat"
3. `Read` `C:\tmp\m1\food-db.json` (limit 40)

Against lf1 round 2's 21 calls, EVERY class M1/M2/M4 targeted is gone: 0 extraction Reads (was 3), 0
Greps of the food DB (was 1), 0 re-reads of `mapped-pre\<slug>.json` (was 4), 0 environment-friction
turns (was 3), and the ONE food-DB read that remains went to the SCRATCH file - lf1's four went to the
LIVE one. The two web calls are for the two foods the coverage line correctly says FDC lacks; lf1
spent 9 calls on those same two foods.

**Batch B mapper** (`68d27a1b-...jsonl`, 8.5 min): **18 assistant messages, 5 thinking blocks, 12 tool
calls.**

1. `Read` `C:\tmp\m1\food-db.json` - the SCRATCH DB, first action
2-4. `WebSearch` x3 - branded labels for pulled pork, sausage, BBQ sauce
5. `Grep` the scratch DB for eight canon items at once
6. `WebFetch` tools.myfooddata.com/nutrition-facts/780862/wt1
7. `WebFetch` nutritionix.com/i/curlys/pulled-pork-...
8. `Grep` the scratch DB again, narrowed to `"item": "(...)"`
9. `WebFetch` foods.fatsecret.com/.../johnsonville/mild-italian-sausage
10. `WebFetch` world.openfoodfacts.org/product/0704051705104/curly-s-sauceless-pulled-pork
11. `WebFetch` myfooddiary.com/foods/7440942/g-hughes-hickory-sugar-free-bbq-sauce
12. `WebSearch`

Against lf1 round 1's 21 calls: **ZERO queries to api.nal.usda.gov, ZERO uses of DEMO_KEY, and ZERO
turns of fdc_lookup archaeology** - that was 11 of round 1's 22 turns (6 direct FDC queries plus 5
turns discovering the tool it was re-implementing) and plan 3.3 predicted it would disappear entirely.
It did. What is left is 9 web calls for three genuinely branded foods FDC does not carry, plus 2
greps of the scratch DB, plus the one seam read.

## 6. The deadlock, proven closed on disk

The scratch food DB gained five rows across the two batches, and two of them cite the shelf directly:

```
Italian Sausage        | https://foods.fatsecret.com/calories-nutrition/johnsonville/mild-italian-sausage
Bell Peppers           | fdc:2067385
Pulled Pork            | https://world.openfoodfacts.org/product/0704051705104/curly-s-sauceless-pulled-pork-naturally-hickory
Gouda Cheese           | fdc:171241
Sugar-Free BBQ Sauce   | https://www.myfooddiary.com/foods/7440942/g-hughes-hickory-sugar-free-bbq-sauce
```

An `fdc:<id>` source was **unobtainable** before M1: the shelf rendered description, data_type,
calories, protein and carbs and never the id, while `write_food_db_rows` refuses a row citing neither
an id nor a URL. Those two rows are the deadlock closing, in the estate's own data.

## 7. The seams, checked

Live `meal-prep\food-macros-db.json` still carries its pre-drill bytes (last written 19:18 the previous
evening; the drill ran 09:18-09:37). `grocery\ingredient-queue.json`, `grocery\carriage.json` and
`meal-prep\db\considered-dishes.json` all still carry their 08:25 daily-pipeline bytes. Every food-DB
row above landed in `C:\tmp\m1\food-db.json` and nowhere else.

**One file the drill DID write live, named rather than hidden: `meal-prep\db\fdc-cache.json`.** The
FDC cache has no seam - neither H2 nor this plan gave it one - so the per-run fill added this drill's
terms to the live cache. It is a cache of public USDA facts rather than a ledger, nothing gates on it,
and warming it is the behaviour F1 exists for; but a drill that writes a live file should say so, and
it is finding 4.

## 8. Findings for Brad - conversations, not build items

**1. `--lanes map,write,qa` closes the write channel before the map lane can fill it.**
`Daemon.CLOSES` maps `price -> ("write",)`, so a run without the price lane closes the write channel at
startup. The write worker's first `take()` sees an empty CLOSED channel and returns immediately; every
recipe M3 later routes to `priced` is pushed into a channel nobody is reading. Batch A's two
fully-resolved recipes needed a second daemon start to reach the writer - the same restart lf1 needed,
for a DIFFERENT reason. lf1's restart was needed because the recipes were stuck at `pricing` and only
`-Derive` could move them; M3 fixed that half, and this half is what is left. It is a lane-wiring
decision, nobody ordered it, and the honest options are (a) `--lanes` implying the closes it needs,
(b) the drill recipe always including the price lane, or (c) leaving it and documenting the restart.

**2. The registrar at a batch of TWO cost 12 turns and 123,401 raw, against 3 turns and 40,098 at a
batch of one.** This is the first N>1 measurement of the batch road F2 built, and it MISSES the <=3
turns / <=120k target on both edges. The claim F2 was built on - that N proposals cost one session
rather than N - is still true in DISPATCH count (one dispatch, two proposals), but the session itself
grew four times as long. Thursday's wide run is where this matters; it is worth knowing before it.

   **CORRECTED 2026-08-25 (registrar-batch review, EVAL-registrar-batch-2026-08-25.md).** The
   decomposition now exists, and "grew four times as long" is the TURN metric only: on raw it is
   3.08x, on API requests 2.5x (5 vs 2 - the lane log counts parallel same-request tool calls as
   separate turns), on wall 1.77x. Measured off the transcript: 7 of the session's 11 tool calls
   were recovery from two REPRODUCED harness Grep defects (a slash-bearing glob member silently
   matching nothing and poisoning its whole brace alternation; the minified smp-feed rendering as
   an omitted long line), not batch work - the two pure-recovery API requests alone cost 44,109
   raw, 35.7% of the session. The batch road is ruled INNOCENT of the miss; even as measured it
   cost 25% less per proposal than jc1's single road. The surviving finding is the target's own
   arithmetic (its 3-turn edge equals the N=1 zero-friction floor and carries no N term), which is
   that eval's section 6 and Brad's conversation.

**3. M4's cap is not being obeyed, and on the other batch it bit too hard.** Batch B made 9 web calls
against a stated cap of "ONE fetch and ONE fallback per food", so the sentence did not bind. Batch A
shows the reverse and it is more expensive: the mapper made 2 WebSearches for `Pork Smoked Sausage`
and `Cheddar Cheese`, returned NO food-DB row for either, did NOT say why in `detail` as the same
sentence instructs, and the write lane then refused the recipe ("no food-macros-db row for 'Pork
Smoked Sausage'"). On lf1 that same mapper spent 9 calls and SUPPLIED both rows. My reading, offered
as a hypothesis: the cap counts READS, and a WebSearch is not a label read - two searches burn the
whole allowance without ever fetching a page to transcribe. Plan section 8 named this trade in advance
("M4's cap could stop a legitimate third read"); this is what it cost, measured.

   **BUILT 2026-08-25 as unit T5 (commit 23a52c3d), on Brad's order.** The hypothesis above was
   right and is now written into the sentence so the model cannot hold the other reading: the cap
   counts LABEL READS, a WebSearch finds the label and never spends the allowance, two fruitless
   searches leave both reads unspent, and a row nobody even looked for is not a cap working. Suite
   213 -> 214, neuter run.

**4. The FDC cache is the one live file a seamed drill still writes.** See section 7. Whether it wants
a seam is Brad's call; the argument against one is that a warm cache is the whole point of F1 and
these are public USDA facts, not estate rulings.

**5. `salt and pepper to taste` STUCK two recipes, one in each batch.** Both times the mapper ruled it
as a purchasable line and the assembler correctly refused the file: "a purchasable line with no weight
cannot be costed". It is the same class as the garnish-line rule map-preresolve already has
(`Test-IsGarnishLine`) and it is a mechanical call, not a judgment one - which is the argument for
handling it the way the unbid hold is handled. Not touched: nobody ordered it.

**BUILT 2026-08-25 as unit T1 (commit ac8ce6e4).** Brad ordered it and ruled the NARROW version: a
line qualifies only when every word of its food half is a seasoning word and at least one is salt or
pepper, so `harissa, to taste` keeps its price and macros and still parks. It fires inside the
zero-weight refusal, exactly where the garnish rule fires, so it cannot touch a line that works
today. map-preresolve -SelfTest 113 -> 121; both neuters run (deleting the branch is 2 red, widening
it to the rejected any-to-taste option is 4 red).

**6. The spec build refused philly-cheesesteak-stuffed-peppers on a costed-row disagreement** -
"Yellow Onion ceil(385g/453.592g)=1 != engine buy_n 4 - spec grams and costed row disagree" - which is
the `--specs`/`--costed` seam family lf1 finding 4 already opened, on a slug that exists live. Same
conversation, one more instance.

## 9. What shipped, and what proves it

| unit | commit | fixtures | daemon suite |
|------|--------|----------|--------------|
| M1 the shelf renders a whole row | 03fb589e | 10 (in map-preresolve -SelfTest) | 192 -> 192 |
| M3 the terms decide the route | ba847b1c | 5 | 192 -> 197 |
| M2 the map dossier carries the estate | 2fc2e9e1 | 5 | 197 -> 202 |
| M4 four prompt patches | 07d6bbc2 | 5 | 202 -> 207 |

hunt-daemon --selftest **207 ok** (baseline 192), hunt_lib --selftest and --parity **63/63** green,
map-preresolve.ps1 -SelfTest **113 cases** green (was 103), ops\audit-prompt-backup.ps1 -Sync clean
(no agent definition was touched).

Neuter proofs, ALL RUN AND REVERTED, each recorded in its own fixture section with the count the suite
actually printed rather than the count the plan predicted: the three-number render (5 red, not 2); the
`page_size=3` restore (1); the `state == "priced"` clause restored (3 red, not 2, and the first one
reproduced the lf1 park verbatim in its got line); each of M2's three dossier sections dropped (3, 3,
2) and the food-DB read pointed back at the live path (2); the extras cap raised (1); each of M4's four
sentences removed (1, 1, 2, 1 - the seam-note inversion takes both the seamed case and its twin).

CORRECTED blocks written into PLAN-map-lane-latency-M1-M4: 3.1.1 (the cache could not hold a fourth
row), 3.1.3 (portions are dormant - `/foods/search` does not return `foodPortions`, 0 of 170 terms
carry one), 5.2.3 (there was no existing `-Add` call for optional terms to ride) and 5.2.4b (the
unhold road's identical condition, named and deliberately left).

## 10. What this does not measure, said plainly

The tail. Neither batch reached source-QA, the wave audit, the repair road or a publish gate, for the
three separate reasons in findings 1, 3 and 6. The price lane was never entered (deliberate, as on
lf1). The registrar is now measured at N=2 and MISSES; at N>2 it is still unknown. Throughput at width
is Thursday's wide proving run, which is a separate session and was not started here.
