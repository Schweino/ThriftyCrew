# Estate backlog from the course programme

Everything the Claude/AI course queue has surfaced that we should CHANGE in this estate. Opened
2026-09-06 while working the 15-course queue (`~/.claude/skills/course/QUEUE.md`; per-course detail
in `LEDGER.md` beside it).

**This is a backlog, not a plan.** Nothing here is ordered work until Brad rules on it. Each item
says what, why, and what it would touch, so the size of the bet is visible before anyone takes it.

## The five states, and why there are exactly five

`OPEN` used to mean three different things at once - work nobody has started, a decision waiting on
Brad, and a measurement whose own conclusion was "do not build this". Reading a list of seventeen
open items and finding that five of them were never tasks is the same defect as I11's `CLEAN TWIN`:
one label, more than one meaning. So (Brad asked, 2026-09-07):

| State | What it means | Whose move |
|---|---|---|
| `DONE` | nothing left | nobody's |
| `PARKED` | investigated, and no work is proposed. Reopen if the situation changes | nobody's |
| `NEEDS A RULING` | nobody should build until Brad decides. The heading says what the question is | **Brad's** |
| `PARTLY DONE` | something shipped, more is proposed | mine |
| `OPEN` | proposed, nothing shipped yet | mine |

**They have a precedence, and it is what stops the two-meanings problem coming back.** An item that
is half built AND blocked on a ruling is `NEEDS A RULING`, not `PARTLY DONE` - the label exists to
surface what is blocking, not to record how much code got written. Order:
`DONE` > `PARKED` > `NEEDS A RULING` > `PARTLY DONE` > `OPEN`.

Free text after the state carries the nuance (`PARKED - MEASURED, DO NOT BUILD`). The state itself is
a closed vocabulary and `ops/audit-backlog-status.ps1` fails a heading that invents a sixth one or
carries none. `ops/audit-backlog-status.ps1 -Summary` prints the board grouped by state, which is
the answer to "what is open for me" without anyone reading 2,700 lines.

---

## Shipped

| ID | What | Commit |
|---|---|---|
| D1 | Reasoning before verdict in `recipe-dedup-selector` and `recipe-source-qa` | `b78e168e` |
| D2 | Worktree blindness + "reporting a result you did not observe" blocks added to the five writing agents | `c56ac827` |
| E2 | Agents stop decoding exit codes and read the verdict line; `run-gates` states its verdict in words on every exit path | `5a7fccf0` |
| I2 | `ops/audit-stray-root-artifacts.ps1`, both halves in the gate; four strays quarantined with a mapping | `558321d5` |
| E15 | Ask-for-Input closing statement on `lesson`, `meal-macro`, `recipe-hunter` | `8e3de6d9` |
| E7 | `.worktreeinclude` + `ops/seed-worktree.ps1`; a bare worktree went 183/6 to 187/2 | `4e8102c2` |
| E3a | Situational-tools block on the eight agents that declare a `tools:` list | `803af3d2` |
| E1 | Safety layer on the Ghost seam: staging (queue for approval) AND a journal (capture the inverse), staging first. **Partial** - no R2. | `723be4ad` |

Plan for the rest: `design/PLAN-backlog-2026-09-06.md`, which also records seven re-buckets and the
items nobody had bucketed (E8, I3, I4).

---

## Safety and correctness

### E1 - The estate takes irreversible actions with no safety layer `PARTLY DONE` `723be4ad`
*Source: AI Agents Architecture (course 7).* Board cells, `known-wrong` rulings, Ghost publishes
and R2 writes are all irreversible from an agent's side, and **`post-publish-reviewer` runs after
the irreversible step**, which is the wrong side of it. Two cheap patterns: **staging** (reads
execute, writes queue for a review pass) and an **action log that doubles as an undo log**, with a
`revert` tool the agent may choose itself. Touches every writing agent and the publish chain.
Biggest item on this list.

**Shipped 2026-09-06, and the premise was corrected first.** Every named LOCAL target is TRACKED
(`known-wrong.json`, `commodities.json`, `costed.json`, `public/board.json`), so git is already the
undo log there and a second one would only have obscured it. The surviving exposure is the remote
write, which is also the one `post-publish-reviewer` runs after.

Brad ruled BOTH mechanisms rather than one, and he was right that they solve different problems - the
two branches were built as rivals and scored as rivals, which was the wrong frame. Both hook
`lib/ghost-lib.ps1`'s `Invoke-GhostApi`, both are off by default, armed independently:

- **staging** (`TC_STAGE_WRITES`) queues a mutating call for approval instead of sending it. The
  approver can be `post-publish-reviewer` moved to run BEFORE the publish, which is literally what this
  item asked for.
- **journal** (`TC_WRITE_JOURNAL`) sends it as normal with the inverse captured first, so
  `ops/revert-ghost-write.ps1` can put it back - and an agent may call that itself.

Staging is checked FIRST, so a call that never went out leaves no journal entry. That ordering is the
only thing combining them can get wrong and it is a must-fire with both switches armed, plus a clean
twin proving the journal still records when staging is off.

**STILL OPEN, and the item is not closed:**

1. **R2 is not covered.** Both hook `Invoke-GhostApi` and R2 does not go through it. Separate seam,
   separate work.
2. **Neither would have caught the 2026-08-29 paywall leak** (22 paid recipes served free): that PUT
   reported success without taking effect. A downstream audit caught it, and still would.
3. ~~**Nothing is armed yet.**~~ **Half armed since 2026-09-07 (I21, Brad's ruling): staging is ON
   for agent dispatches and off for the daily chain.** Arming it immediately found that the approver
   would have corrupted the post - a `[byte[]]` body was recorded as the STRING `"(byte[] length N)"`
   and `-Apply` replayed that description to Ghost, on the only branch the live chain takes. The
   journal switch (`TC_WRITE_JOURNAL`) is still off everywhere.
4. **`publish.ps1:285` needs teaching before staging can be armed on the publish chain** - it GETs the
   public page after the PUT to confirm it shipped, and would report a failure when nothing shipped.

### E2 - Bare numeric codes cross agent boundaries `DONE` `5a7fccf0`
*Source: AI Agents in Python (course 6).* "An agent that receives error 32 is finished." Our gate
exit codes are exactly that shape. Anywhere a gate's exit code reaches an agent without a
words-level translation is a place an agent retries identically or invents a meaning. Grep for it.
Note the irony: while adding D2 I put "exit 2" into five agent prompts and had it wrong -
`run-gates` uses exit 3, the recipe battery uses 2. Corrected in `6a05dcd7`, but that is the exact
failure this item is about.

### E3 - Tool-list relevance hazard across twelve agent definitions `DONE - RULED 2026-09-07; THE PREMISE WAS STALE AND HALF THE RULING REFUTED` `803af3d2`
*Source: AI Agents in Python (course 6).* Given three well-named tools and no usage context, the
course's agent decided the unnecessary one must be needed and **invented bolts and screws to justify
it**. Several of our agents ship long tool lists with no statement of which are optional, how they
relate, or whether all must be used. `recipe-hunter-pricer` carries about twenty. Cheapest fix is a
sentence per agent naming which tools are situational.

**Split when it was worked, because it is two items.** `recipe-hunter-pricer` carries **28**, not about
twenty, and eighteen of those are two complete and overlapping browser sets.

- **E3a `DONE` `803af3d2`** - the situational-tools block on the eight agents that declare a `tools:`
  line. Prose, no behaviour change.
- **E3b `OPEN`, design-first** - the four that declare **no `tools:` line at all**
  (`post-publish-reviewer`, `recipe-batch-auditor`, `recipe-writer`, `triage-developer`) and therefore
  inherit every tool including `Write` and `Edit`. Two of those four are verdict-only agents, so this
  is a least-privilege hole of the same class as E1 rather than a documentation gap. Narrowing a tool
  list changes behaviour and needs a ruling: **does a verdict-only agent lose `Write`?**

**RULED 2026-09-07: Brad said yes, and measuring refuted half of it. Recorded rather than quietly
executed, because a ruling carried out on a wrong premise is worse than one that was never asked.**

- **The premise is stale.** All twelve agents now declare a `tools:` line - E3a's commit closed that,
  and this bullet was never updated. Read off disk 2026-09-07.
- **`recipe-batch-auditor` REQUIRES `Write`.** Its verdict IS a file: `waves\wave-<k>.audit.md`,
  read by `hunt-daemon.py:7522` and gated by `audit-wave-blocker-headings.ps1`. Taking `Write` breaks
  the publish chain outright, and the agent's own tool table says so at the line.
- **Removing `Write` from `post-publish-reviewer` narrows nothing.** It holds `Bash` and `PowerShell`
  and needs them - it checks live pages and pushed commits. An agent with a shell can write any file,
  so this would only move the write out of a sanctioned repo-relative path into an unaudited shell
  call. Strictly worse.

**So the intent landed where the facts allow it,** as two invariants in
`ops/audit-agent-tools.ps1`, both green on the day they shipped:

| Rule | Agents | Why |
|---|---|---|
| may not declare `Edit` | all five verdict agents | `Edit` is the tool that turns a reviewer into a participant, and a reviewer who can fix what it found stops reporting it |
| may not declare `Write` | the three that report through their RETURN VALUE (`recipe-dedup-selector`, `recipe-source-qa`, `triage-reviewer`) | they have no file to write, so `Write` is pure surface |

The two whose verdict is a file keep `Write`, and the list says which is which rather than leaving
the next reader to guess. Four fixtures, led by the must-not-fire case that keeps the publish chain
alive.

---

## Accuracy

### E4 - The dedup pipeline is embeddings-only `PARKED - MEASURED, DO NOT BUILD`
*Source: Building with the Claude API (course 2), RAG module.* Vector search fails **quietly** on
rare exact identifiers: it returns plausible irrelevance rather than nothing. Commodity ids, SKUs
and slugs are exactly that shape. A BM25 lexical index alongside the embedding index, merged with
reciprocal rank fusion, is a cheap and well-defined experiment. See `rag-craft`.

**Extended 2026-09-06 by NLP with Classification and Vector Spaces (queue 2, course 4): there is a
second quiet failure, and BM25 does not fix it.** A distributional word vector summarises the
company a word keeps, and a word and its opposite keep near-identical company because they are
interchangeable in a sentence. So an embedding scores **antonyms as near-identical**, and the pairs
that matters for are exactly ours: `unsalted` against `salted`, `boneless` against `bone-in`,
`low sodium` against `regular`, `no sugar added` against `sweetened`. A lexical index does not help
here either, because the two strings differ by one token that BM25 will treat as low-weight. This
needs an **explicit negation rule or a reranker asked the negation question**, not a better model or
a second index. It is recorded as a direction, not a measurement: nothing here was scored, and
`CLAIMS-REGISTER` C18 names the cheap check, which is to embed a handful of the estate's own
opposite pairs and read the scores against a same-meaning control. Do that before trusting any
embedding-only verdict about whether two products are the same product.

**MEASURED 2026-09-06, and the answer is do not build it.** `meal-prep/pipeline/bm25_dedup_probe.py
--head-to-head` scores BM25 and cosine on the same 31 labelled duplicate pairs over the same 14,448
rows, using the bge-m3 vectors the harvest lane already cached, so no model loads and the card is
never touched. Ranking the true twin:

| | cosine | BM25 |
|---|---|---|
| recall@10 | 19 / 31 | 17 / 31 |
| MRR | 0.216 | 0.241 |
| finds in top-10 what the other buries | 3 | **1** |

*(Figures re-taken 2026-09-06 after E24's fix; an earlier run of the same script reported 20/31 and
MRR 0.336 for cosine. Nothing in the code changed between them - `candidate-pool.json` was rewritten
at 18:09 and the embedding cache at 18:08, and the probe recorded nothing about what it had read. See
the coverage and reproducibility notes below, which are the more important half of this item.)*

**One pair.** A lexical index earns its place beside a vector one only by finding what the vector
one misses, and it misses in the same direction. The reciprocal-rank-fusion build is not worth its
second index.

Two further levers were measured on the same frozen pairs, because the first result raises the
question of what *would* move the **11 pairs both indexes bury**:

- **Index the whole signature.** The harvest lane computes `{protein, method, sauce_family, starch}`
  and embeds only `dish: <name>. protein: <p>` - three of the four fields are computed and thrown
  away. Adding them: MRR 0.230 to 0.284, 3 pairs rescued into top-10 and **2 lost out of it**. Net
  one pair.
- **Block on the exact signature tuple** - a dictionary lookup rather than a ranking. Ceiling is 3
  of the 11 buried pairs, at a cost of blocks running to 2,394 rows, which is 2.8M pairs to judge.

**Read all three against E21, which this item is now a worked instance of.** Three variants were
tried and the best of them moves one pair out of 31. No acceptance threshold was written before the
run, the sample is 31 cases, and the maximum of three noisy draws is optimistic by construction - so
"+1" is not evidence that anything helped. The defensible conclusion is the negative one: **no cheap
retrieval change moves these pairs**, and that holds across a lexical index, a richer key and a
structural block.

**Why they are buried is visible in the data and is not a retrieval problem.** Several of the 11
have *identical* signature tuples and genuinely different names - "Cowboy Chicken Recipe" against
"Tex Mex Baked Chicken", both `chicken/bake/tomato/bean`, ranked #252 by cosine. They are the same
dish only under a judgement that no index over these strings encodes. Others carry *contradictory*
signature fields despite a human ruling them duplicates (`bake` against `braised`, `null` against
`cheese`), which is a signature-quality defect and the more useful thread to pull.

Two incidental data defects found while looking: one pool name carries an unescaped `&amp;`, and the
signature's own fields disagree on rows a human called identical.

**This discharges the E19 concern for this one component:** the 31 pairs and the scoring script are
now a frozen, re-runnable test set, which is what E19 asks every retrieval-shaped component to have.

**Then E24's fix was applied to this very probe, and it changed how the numbers above should be
read.** Two things came out of it that the original run could not have shown.

**Coverage is 18%, not 100%.** The ledger holds **168** ruled duplicates. Thirty-one are scoreable;
**135 decline because the twin is not in the candidate pool** and 2 because both sides collapse onto
one cache row. That is E20 in this item's own measurement - a figure computed over the rows that
resolved, presented as though it were the whole labelled set. Worse, the missing 82% are almost
certainly **not** missing at random: a twin leaves the pool when its recipe is accepted and built, so
the drop-outs are weighted toward the cases the pipeline handled well, which is E23's publication
bias in the same breath. The direction of the result survives this. The precision of it does not.

**The run was not reproducible and nothing said so.** The probe reads mutable state and recorded
nothing about what it read, so two runs hours apart disagreed with no code change between them. It
now prints and stores an input fingerprint - size and mtime for the pool, the ledger and the cache -
so a moved input is visible as a different measurement rather than looking like a change in the
answer. Size carries the weight and mtime is only the tie-breaker, because this estate already has a
scar about mtime moving on byte-identical files after a reanchor.

**The bar is now written before the run, not after.** Build the hybrid only if BM25's fixed count
exceeds its broke count by at least 5 of the 31. It scores **fixed 1, broke 3, difference -2**, so
the verdict stands and is now stated against something rather than against nothing. One row per case
per arm is written to `meal-prep/db/dedup-headtohead-cases.jsonl`, with the discordant counts derived
from that file rather than being it.

### E5 - Validate at source `PARTLY DONE - FORMAT LAYER RECORDED AND ROUTED`
*Source: MCP (course 3).* A direct criticism of any tooling that hands a model raw rows to sift. The
four-layer stack is format -> business rules -> self-prompted semantic -> human review, with **low
confidence routed to review rather than rejection**. Applies to the ingredient queue and the
capture readers.

**BUILT 2026-09-06 on Brad's ruling for the full stack. `lib/ingest-ledger.ps1`, wired into
`import-walmart-batch.ps1`.** Measured before building, because E9 and E4 both inverted their own
premise once measured and this item's deserved the same:

| | |
|---|---|
| `capture-lib.ps1` | placeholder drops COUNTED, and a shape change already routes to REVIEW |
| `import-walmart-batch.ps1` | 3P / test / quarantine / reject each reach a NAMED list with a reason, and the rejects reach `out\walmart-batch-rejects-<date>.json` for a human |
| its PARSE loop | a line with no tab, a field group under three fields, and a row with no name - **no count, no record** |

**So the gap is narrower than the item describes and it is the worst-shaped one: the FORMAT layer.**
A business-rule rejection is loud by construction because somebody wrote the rule. A format drop is
silent by construction because it happens before anyone's rule runs, so a reducer that changed its
output shape would yield nothing and say so in no way at all.

`New-IngestLedger` / `Add-IngestRead` / `Add-IngestDrop` / `Get-IngestReview` count with their
**denominator** and route on two triggers. The second matters: a single reason taking more than 20%
of rows read is a shape change, **and separately, rows read with NOTHING kept is a review even though
no rule was violated** - in that case every share is 0 or 100 and a threshold tuned for normal noise
cannot see it. Verified end to end on a synthetic capture through the real importer with `-OutRoot`
pointed at a scratch directory: 5 read, 0 kept, four reasons recorded with examples, and the
not-one-kept review fired. Before this, that run printed `total 0` and nothing said why.

**Layer 3 is deliberately NOT wired as a gate, and the reason is a measurement from the same day.**
The semantic layer is `sidecar/`, and E19 has just shown its retrieval stage drops **186 of 2,816**
known-correct pairs under an absolute cosine floor. Wiring it to gate ingest would bake that blind
spot into the ingest path, where it would reject correct rows for the same reason the coverage sweep
cannot see missing ones. The estate's own precedent is the right shape here - `aisle.py` is marked
ADVISORY, AND BLIND-NEVER-BLOCK - so layer 3 stays advisory until the E19 finding is ruled on. Brad
ruled for the full stack and the full stack is what is built; this states the assumption rather than
quietly narrowing it.

**Still open:** `compare-deals.ps1` has 24 drop points in the pricing path and was left alone on
purpose - it is the core engine, its functions are lifted by three other scripts, and its business-rule
drops already produce `band-censorship.json` and `basis-outliers.json`. Wiring it is layer 2 work on
a live engine and wants its own change.

### E19 - No matcher in the estate has a scored test set `PARTLY DONE - MATCHER SCORED, BLIND SPOT FOUND`
*Source: Recommender Systems: Evaluation and Metrics (queue 2, course 1).* Every retrieval-shaped
component here - the commodity matcher, the dedup pipeline, `sidecar/`'s recall-then-rerank pair,
`knowledge-search` - is changed on the strength of "it fixed the case I was looking at". None has a
held-out set of query-to-correct-answer pairs scored the same way before and after, so no change has
ever been shown to help in general rather than on the one row that prompted it. Well-defined and
cheap: a frozen file of pairs, `recall@k` for a recall stage and `MRR` for a rerank stage, rerun as
a script. **The two-stage point is the load-bearing one:** one end-to-end number cannot say whether
the right answer was never retrieved or was retrieved and buried, and those need opposite fixes.
Method in `rag-craft/evaluating-retrieval.md` sections 12 and 18. Sits directly under E4, which
proposes a retrieval change with nothing to score it with.

**BUILT FOR THE COMMODITY MATCHER 2026-09-06 - `sidecar/matcher_eval.py` - and it found a live blind
spot on its first run.** Brad ruled this component first because its errors reach a price on a page.

**The two-stage point paid immediately.** `hardeval.py` already scored the RERANK stage well, against
GOLD - 45 pairs expanded from adjudicated `known-wrong` rulings, which is exactly the
recorded-failure corpus E23 says this estate does not build. **Nothing scored RETRIEVAL**, and that
is not a technicality: a true match scoring 0.54 against `sweep.py`'s `COVERAGE_COS_FLOOR` of 0.55 is
gone before the cross-encoder is asked, so a recall failure upstream makes the downstream AUC look
BETTER, not worse. The reranker's healthy numbers were computed on survivors.

**Measured over all 2,816 accepted board pairs, 100% of them resolving to a definition:**

| | |
|---|---|
| recall@1 | 2582 / 2816 (0.9169) |
| recall@10 | 2798 / 2816 (0.9936) |
| recall@25 | 2810 / 2816 (0.9979) |
| MRR | 0.9481 |
| **clearing `COVERAGE_COS_FLOOR` 0.55** | **2630 / 2816 (0.9339)** |

**Ranking is excellent and the absolute floor is the problem.** The right commodity is in the top 25
for 99.79% of pairs, so retrieval can find it - but **186 known-correct pairs score below an absolute
cosine bar** and are dropped before anything else runs. The floor is not a rank cut; it is an
absolute one, and a pair can rank first and still fail it.

**What the 186 look like is the useful half:**

| product | commodity | cosine |
|---|---|---|
| `Cantaloupe` | `cantaloupe` | 0.4290 |
| `Dole Classic Romaine` | `lettuce` | 0.3684 |
| `Wimmer's Wieners, Skinless 24 Oz` | `hot-dogs` | 0.3783 |
| `Bush's Best Chick Peas` | `chickpeas` | 0.4360 |
| `Our Family Mayo, Real 30 Fl Oz` | `mayonnaise` | 0.4444 |

Synonyms, abbreviations, spelling variants and bare category names - and `sweep.py`'s own comment
already says why: bge-m3 cosine ranks brand-and-format likeness, not food identity. This measures
what that costs. It is also E4's antonym finding from the other direction: an embedding scores
`Cantaloupe` against `cantaloupe` at 0.43 while scoring two unrelated seasonings at 0.81.

**The consequence is a blind auditor, not a wrong board.** These pairs are already accepted, so no
price is wrong today. What the floor costs is the COVERAGE sweep's ability to notice a MISSING one:
if a store stops carrying cantaloupe, or a new plain-named product appears, the sweep will not
propose it, because the correct pairing does not clear the bar. That is silence where an alert
should be.

**Nothing was tuned.** This commit scores and does not change the matcher, or the measurement would
be a description of a decision already taken. The obvious candidate fix is visible in the data - a
rank-based cut instead of an absolute cosine cut, since recall@25 is 0.9979 - and it is Brad's call,
not a side effect of building the scorer.

Only the `--selftest` is in `run-gates`. The live run needs torch and the model, which is not
hermetic, and it currently exits 2 on this real finding. Its must-fire is the abstention case: an
unranked row lowers MRR rather than vanishing from it, which is the trick that lets a matcher which
gives up on its hard rows outscore one that attempts everything (E20).

**Still open:** every other retrieval-shaped component - `knowledge-search`, the near-name shelf
scorer, the ingredient mapper. The pattern is now demonstrated twice, on dedup and on the matcher.

### E20 - Match rates are reported without their abstention rate `DONE - SWEPT 2026-09-07, 3 OF 45 SITES FIXED` `82377028`
*Source: same course, section 14 of the file above.* A matcher that returns `UNUSABLE`, `PENDING`
or nothing on the rows it finds hard, and is then scored only on the rows it answered, **outscores
one that attempts everything** - and neither number looks wrong. Any accuracy or match-rate figure
computed over non-null output has this in it. The fix is small: report coverage beside every such
figure, or substitute a documented fallback for the declines and score that too. Worth an audit of
where the estate already quotes a bare rate, starting with the pricing pre-pass and the ingredient
mapper. Cheap, and it changes how existing numbers should be read rather than requiring new code.

**FOUND IN THE WILD 2026-09-06, in this backlog's own work.** The E4 head-to-head was reporting
recall over 31 pairs. The ledger holds 168 ruled duplicates: 135 decline because the twin is not in
the candidate pool and 2 because both sides collapse onto one cache row, so the real coverage is
**18%**. The probe now prints the denominator and every decline by reason. **The decline is not
random**, which is the part that makes this worse than a missing caveat: a twin leaves the pool when
its recipe is accepted and built, so the 82% that dropped out are weighted toward the cases the
pipeline handles well. That is E23 arriving through E20's door.

~~Still open: the estate-wide sweep for bare rates.~~ **SWEPT 2026-09-07, and the estate was in far
better shape than this item assumed: 45 percentage computations across 25 tracked `.ps1` and `.py`
files, every print site read by eye, and 42 already carried their denominator** - `examined 15 of 17
(88%)`, `N of M captured row(s)`, `recall@25 41 / 168`. Three did not, and all three are fixed:

| Site | What it printed | What it prints now |
|---|---|---|
| `graph/pipeline/scorecard.ps1:308-309` | two shares of `$tot`, and `$tot` appeared nowhere on the page - the second line did not even say what it was a share OF | the settled total on its own line, and both shares as `% of the N settled` |
| `meal-prep/pipeline/map-preresolve.ps1` assemble | `assemble <slug>: 3 finding(s)` | `scanned=N findings=3` - three findings in four lines and three in four hundred are different events |
| `meal-prep/pipeline/map-preresolve.ps1` final | residual and hold LINE counts reported against a SLUG count, which is a different population | `scanned=N line(s), resolved=, residual=, holds=` |

**The sweep's own denominator, because this item is about exactly that.** It matched `100 *` and
`* 100`, so it sees a rate expressed as a PERCENTAGE and nothing else. A bare fraction reported as
"0.83 match rate" would not be found by it, and no claim is made about those. The pricing pre-pass
this item names (`map-preresolve`) was in the sweep and is now compliant; the ingredient mapper
prints no percentage at all.

### E21 - Nothing in the estate states how far a number has to move to count `DONE - THE CONVENTION IS AT THE POINT OF READ` `82377028`
*Source: Improving your statistical inferences (queue 2, course 2).* Every "did this change help"
read here is a comparison of two single numbers with no interval, no case count and no record of how
many variants were tried: a seed sweep, a threshold tune, a detector tweak, a prompt or agent
revision, a match-rate before-and-after. **The maximum of `k` noisy draws is optimistic by
construction even when all `k` settings are identical**, so the winner of a sweep is inflated by an
amount that grows with the sweep, and a change reverted because one seed of five disagreed was
probably reverted on noise: at 80% power, four runs on a real effect disagree with each other about
59% of the time. Three fixes, in ascending cost, none needing new infrastructure:
1. **Score both versions on the same frozen cases and compare paired, per case.** The largest free
   power gain available, and it also removes case selection as a source of difference.
2. **Write the acceptance threshold before the run** - the smallest move worth acting on, in the
   units of the metric. Currently always implicit and therefore always zero.
3. **Hold out a slice the sweep never sees** and quote the winner's score on that, which is the only
   clean answer to (1) above and is the same third-split fix `rag-craft` already prescribes for
   parameter sweeps.
Method in `experiment-craft` (`errors-and-inflation.md` 4 and 5, `effect-size-and-power.md` 9 and
11). Sits directly on top of E19: a scored test set with no threshold for "it moved" answers half
the question. Cheapest first step is (2), which is a convention rather than code.

**DONE 2026-09-07, and step (2) turned out to be already practised in both places that matter -
which is precisely why it needed writing down.** `sidecar/matcher_eval.py` states the acceptance bar
in its header, and `meal-prep/pipeline/bm25_dedup_probe.py:305-309` states its bar in the source
ABOVE the run, with the reason: "a threshold chosen afterwards is not a threshold". Two file headers
are not a convention, though - they are two people having independently done the right thing, and the
third person will not.

**So the convention now lives at the point of read: `.claude/rules/measurement.md`**, loaded on
`sidecar/**`, `**/*eval*.py`, `**/*probe*.py` and `**/audit-*.ps1`. It carries E20's denominator rule
and abstention rule, E21's acceptance bar and the "a number that moved is not a number that improved"
line, E24's one-row-per-case rule, and the input fingerprint - with `sidecar/matcher_eval.py` named
as the exemplar to copy rather than the rules described in the abstract.

### E22 - Rare-target rules are judged on fixtures with a 50% base rate `DONE - THE LIVE-PREVALENCE HALF SHIPPED 2026-09-07`
*Source: same course, and it sharpens `green-fixture-is-not-production-coverage` rather than
repeating it.* **Precision is not a property of a detector; it is a property of a detector and the
rate at which the thing it detects actually occurs.** A rule with 80% recall and a 13% false-alarm
rate, run against a population where the target is present in 3% of rows, is right **18%** of the
time it fires - with nothing mis-scored and no rows dropped. Every `-SelfTest` in the gate drives one
must-fire fixture and its clean twin: a 50% base rate by construction, which measures recall
honestly and overstates precision enormously. The consequences are estate-specific and concrete: a
detector moved to a rarer corpus loses precision with **no code change and no metric change on the
old corpus**, and comparing two detectors' precision across two different corpora compares the
corpora. Two things worth doing: state the live prevalence beside any precision or hit-rate figure we
quote, and for the rules that scan a whole board for a rare defect, track the **confirmed-hit rate on
live output** rather than the fixture verdict. Detail in
`rag-craft/evaluating-retrieval.md` 11.1 and `experiment-craft/errors-and-inflation.md` 3. Does not
weaken any gate; it changes how the gate's own numbers should be read.

**HALF DONE 2026-09-06, and the half that shipped is the durable one.** E22 is a convention rather
than a build, so it went where conventions for detectors are defined: `Write-GuardComplete` in
`lib/guard-contract.ps1` now documents that a summary carries the **denominator** and not just the
finding count - `scanned=3164 findings=3`, never `findings=3` - and states why, including the
base-rate argument in full. Every guard in the estate routes through that function, so a new detector
meets the rule at the point it is written rather than in a document nobody opens. Guards with no
denominator are told to name what they looked at instead.

Nothing was sprinkled across the existing audits, deliberately. Retrofitting a denominator onto forty
detectors on the strength of a general argument is a large diff with no measured defect behind it,
and several already carry one (`stores=7 shutouts=0`, `scanned=7 unregistered=0`). The convention
catches the next one and each existing guard can gain it when it is next touched for another reason.

~~**Still open: the live-prevalence half.**~~ **SHIPPED 2026-09-07.** It needed somewhere to record
which of a detector's live firings turned out to be true, and the honest constraint was that a NEW
ledger nobody fills in is worth nothing.

**It did not need a new ledger.** `grocery/triage-queue.json` already holds every alert raised since
the 2026-08-22 reset - 127 items, 124 of them closed with `status=resolved` and free-text notes. What
the notes cannot do is be COUNTED: *"RESOLVED on re-measurement, the signal no longer holds"* and
*"Rolling condition by design"* are opposite outcomes in identical prose. One closed-vocabulary field
beside the notes turns the queue that already exists into the precision record that did not.

**The vocabulary, and every word is a decision:**

| | Means | Counts as |
|---|---|---|
| `confirmed` | a real defect, found and fixed or found and filed | hit |
| `false-alarm` | the condition was not there, or was legal | **miss - and this is the one that matters. A detector nobody ever marks `false-alarm` has an UNMEASURED precision, not a good one** |
| `superseded` | real when raised, fixed by something else before triage arrived | neither |
| `by-design` | real, recurring and EXPECTED - a rolling worklist, an ad window between cycles. The detector works and the alert is noise, which wants a quieter threshold rather than a fix | neither |
| `wont-fix` | real, understood, deliberately not fixed | hit - the detector was right |

**Three files.** `grocery/triage-lib.ps1` holds the vocabulary and the pure judgements;
`grocery/triage-close.ps1` is the only way to close an item, so the disposition is a required
argument rather than a field somebody remembers; `grocery/audit-alert-precision.ps1` reports per-type
precision and runs daily from `check-ad-cycles`, alerting rather than blocking.

**It carries E20 and E21 by construction rather than by convention.** The reported line always prints
its denominator (`85.7% precision over 7 judged closes`, never a bare rate), and no rate is stated at
all below five judged closes - three closed alerts do not make a 33% precision, they make "too few to
say", and a number that reads as a measurement and is one coin flip is worse than none because it
gets quoted.

**Green on day one, deliberately.** The 124 historical closes are exempt: back-filling them would
mean guessing a disposition from prose, which is the exact judgement this machinery exists to stop
being guessed. Only closes on or after 2026-09-07 owe one. The first run reports the honest state -
*"no alert has a judged close yet, so no precision is claimed for any of them"* - rather than a pass
mark.

**The rubber-stamp guard is the fixture worth keeping.** A close is refused if its notes are under 20
characters: a disposition with no evidence is a vote, not a finding, and `ok` closing an alert is how
a queue becomes a formality.

### E23 - Our test sets are built out of successes `OPEN - EVIDENCE FOUND`
*Source: same course, section 12, and it is publication bias wearing our clothes.* Fixtures and
golden files here are assembled from bugs we found and cases we already handle correctly. Cases that
failed silently were never written down, so they are absent from the evidence and **their absence is
invisible in the score** - the literature's version of this at least leaves a detectable cliff in the
p-value distribution, and ours leaves nothing. Same root as the "one failing query per step" habit
E19 flags. The mitigation is a work habit rather than a build: **record the case at the moment it
fails**, including the ones fixed by hand and moved on from, so the corpus is not exclusively
successes. `known-wrong.json` and `research-worklist.json` are already the right shape for this and
are populated by rulings rather than by failures. Small, ongoing, and it compounds.

**A concrete instance surfaced 2026-09-06 and it is worth keeping because it is measured rather than
argued.** The dedup test set is 31 pairs drawn from 168 ruled duplicates, and the 135 that dropped
out did so because the twin had left the candidate pool - which is what happens when a recipe is
ACCEPTED and built. So the surviving evidence is filtered toward the pipeline's successes by the
mechanism this item describes, and the filtering was invisible until the denominator was printed. The
score was not wrong; it was answering a narrower question than it appeared to.

### E24 - Every A/B here logs counts, and counts cannot be un-aggregated `DONE - BOTH NAMED LANES COMPLY` `82377028`
*Source: `evaluate-llms-test-and-prove-significance` (course 18), and it is a correction of that
course rather than a lesson from it.* When we compare two versions of anything on the same case set
- two matcher builds over the identical board, two prompt variants over one frozen record set, a
detector before and after a threshold change - the natural log is a pair of totals: `old: 50 wrong,
new: 38 wrong`. **That summary has already destroyed the comparison's evidence.** The right test for
two systems on one shared set is McNemar's, which needs the *discordant* counts: how many cases the
new build **fixed**, and how many it **broke**. `50 vs 38` pins down only `fixed - broke = 12`, and
that is compatible with 50 fixed and 38 broken (88 verdicts churned, split nearly even, weak and
unactionable) and with 12 fixed and 0 broken (overwhelming) alike. Same headline, opposite
decisions, and nothing recovers the difference after the fact. It also silently discards the free power that running both arms on one
frozen set was supposed to buy - see `experiment-craft/effect-size-and-power.md` section 9.

**PARTLY DONE 2026-09-06 `82377028`, on one probe rather than across the estate.** The fix landed on
the E4 head-to-head because that was the comparison being run that day, and E24 is explicit that this
is impossible to backfill - so the argument is always to fix the run in front of you. What that one
application bought is recorded under E4: coverage of 18%, a run that was not reproducible and said
nothing about it, and a bar stated before the result instead of after.

**What is NOT done is the estate-wide sweep.** `sidecar/` and the recipe-dedup RESCORE lane are still
the two named candidates, both already re-scoring a fixed corpus and both still one column short.

**CHECKED 2026-09-07, and both named lanes already comply.** `sidecar/matcher_eval.py` writes one row
per case with the totals derived from the file rather than being it, and the recipe-dedup RESCORE lane
writes `meal-prep/db/dedup-headtohead-cases.jsonl` - `len(rows)` cases x 2 arms, keyed by slug, with
the discordant pairs at top-10 DERIVED from that file. It even reports honestly when it could not
write them: *"per-case rows NOT written - the totals below stand, but this run left no evidence"*.

So the build was done and the CONVENTION was not: two lanes doing the right thing is not a rule, and
the next comparison would have been written by someone who had read neither header. It is now
`.claude/rules/measurement.md`, loaded on the paths where a comparison actually gets written.

**The fix is a logging convention, not a statistics build**: any run that scores two arms over one
case set writes **one row per case per arm, keyed by case id**, and the totals are derived from that
file rather than being the file. Cheap to adopt going forward, impossible to backfill, which is the
argument for doing it before the next comparison rather than after. Overlaps E21 (nothing states how
far a number must move) and E20: those two say what to compare against, this one says keep the
evidence that lets you compare at all. **Worth pointing at `sidecar/` and the recipe-dedup RESCORE
lane first** - both already re-score a fixed corpus, so both are one column away from compliant.

### E25 - No similarity threshold here records which kind of space it was tuned on `DONE - REGISTERED AND GATED`
*Source: NLP with Classification and Vector Spaces (queue 2, course 4), and it sharpens what
`rag-craft` section 3 already said about reading a distance metric the right way round.* Two
distinct traps sit under every similarity number the estate computes, and neither is visible in the
code:

1. **Cosine and Euclidean answer different questions.** Euclidean distance is sensitive to
   magnitude, cosine is not. Comparing two texts of unequal length - a short ingredient string
   against a long product title, a query against a chunk - Euclidean will call the two long ones
   similar *because they are both long*. Cosine is the correct metric there. Where the magnitude
   genuinely carries meaning, Euclidean is the one that keeps it. Nothing in the estate states which
   it picked or why.
2. **Cosine's range depends on the space.** On a signed embedding it runs -1 to 1, so 0 is the
   middle. On anything built by counting (term frequencies, tf-idf, a BM25-shaped feature) every
   component is non-negative, so cosine is bounded 0 to 1 and 0 is the floor. **A threshold carried
   from one to the other is silently wrong by half the range**, and it fails by admitting or
   refusing rows rather than by erroring.

The work is an audit, not a build: find every hard-coded similarity threshold in `sidecar/`, the
dedup rescore and the near-name shelf scorer, and record beside each one which metric it reads and
which kind of space that metric came from. Cheap, and it is a precondition for E19's scored test
set meaning anything. Detail in `rag-craft/vector-space-foundations.md` sections 21 and 22.

**AUDITED 2026-09-06. Register at `sidecar/THRESHOLDS.md`, gated by
`ops/audit-threshold-register.ps1`.** Seven thresholds in scope, all now recording their space.

**The estate was in better shape than this item assumed, in one specific way.** Every threshold
already named its metric and most carry the measurement they were set from - `COVERAGE_COS_FLOOR`
cites the 0.58-0.69 band its true positives sat in, `--keep-above` cites 431 pairs against 159, and
`catalog-similarity.json` **derives** both its numbers rather than hand-setting them and says so.
`aisle.py` is the exemplar: it measured cross-encoder against cosine on the four founding failures
(4.4x separation against 0.6%, which is noise) and records why it pays the reranker's cost. What was
missing was never the metric. It was the **space**.

**Three non-comparable spaces run here at once**: bi-encoder cosine over L2-normalised bge-m3
(signed, so 0 is the middle and not the floor), cross-encoder sigmoid probability (0 to 1), and BM25
(counting, unbounded, 0 is the floor). **The two most confusable numbers sit ten lines apart in
`sweep.py`** - `COVERAGE_COS_FLOOR` 0.55 and `COVERAGE_RERANK_FLOOR` 0.90 - and read like a loose bar
and a strict one. They do not share a scale, and neither can be moved by reasoning about the other.
Worse for a reader: `aisle.py` reports a cross-encoder floor for RIGHT answers of **0.004334** while
`sweep.py` sets its cross-encoder floor at **0.90**. Both are S2 and both are correct; they score
different questions. **An operating point is a property of the question, not of the model**, so a
threshold may never be carried between callers even inside one space.

**A live hazard was found in the S2 space and it is currently not biting.** Verified against the
installed sentence-transformers 5.6.1 rather than recalled: `cross_encoder/model.py:114` applies
`nn.Sigmoid()` when `num_labels=1` - **but `get_default_activation_fn()` reads the model's OWN config
first**, either `config.sentence_transformers["activation_fn"]` or the legacy
`sbert_ce_default_activation_function`. So two copies of "the reranker" can return scores on
different scales with no error, and every threshold tuned on one silently means something else on the
other. Checked across the pinned model and all three local fine-tunes: `num_labels=1`, no declared
activation, sigmoid everywhere, so `hardeval --reranker` compares like with like today. **Re-check
whenever a new base is pinned**, because `finetune_reranker.py` saves an
`AutoModelForSequenceClassification` rather than a `CrossEncoder` and a declared activation is
exactly the key that would not survive that round trip.

**The gate is strict rather than a ratchet**, unlike `audit-write-seam`. A ratchet is right when a
backlog exists that nobody can clear in a sitting; here the register was written complete on the day
the gate shipped, so a new unregistered threshold is always a new omission. It checks that a
threshold is NAMED with a space, which is the one thing a static check can buy - it cannot check that
the recorded space is correct, and says so in its own header.

**Also confirmed independently:** `catalog-similarity.json` records
`signature_shape: "dish: <name>. protein: <protein>"`, which is the same two-of-four-fields finding
E4 arrived at from the other direction.

### E26 - A term that is identically zero on our fixtures is untested, not correct `DONE - SWEPT, ONE FOUND AND FIXED`
*Source: same course, its naive Bayes module, and it is a different mechanism from E22.* E22 is
about a **metric** being misread because the fixture's base rate is unrealistic. This is about a
**code path never running**. The course's worked case: the log-prior term of a naive Bayes scorer is
`log(D_pos / D_neg)`, which is exactly 0 on a balanced corpus, so a scorer that omits the term
entirely passes every test on a balanced fixture and is wrong the moment it meets real traffic. The
tidy annotated corpora are artificially balanced; reality is not.

The estate shape to look for is any correction, weight or prior that evaluates to 0, 1 or the
identity on a `-SelfTest` fixture: a per-store adjustment where the fixture uses one store, a
pack-size normaliser where the fixture is already 1 unit, a prevalence weight where the fixture is
50/50. **Nothing has been checked yet** - this is a proposed sweep, not an observed defect, and it
is recorded so it has an id rather than living in a report. The check is mechanical: for each such
term, assert the fixture actually exercises a non-identity value, or add a second fixture that does.

**SWEPT 2026-09-06. One instance found, and the estate came out of it better than the item feared.**

The two shapes this item names as most likely turned out to be the best-covered code in the file.
`min_pack_oz` and `min_piece_oz` drive fixtures at non-identity values (32, 12, 1.5), test both sides
of each bound, cover multipacks, count-first size idioms, ascending ranges, unreadable sizes and
undeclared commodities. `weight_is_one_unit` exercises a real division (`2 pack, 30 oz` to 2.99)
rather than only the one-unit case. Nothing to fix in either.

**The instance is `Test-Membership`, and it had no coverage of any kind.** One line:
`return ($store -eq "Sam's Club")`. Every fixture in `compare-deals.ps1` uses `Walmart`, so its true
branch had never executed in a test, and the function is referenced nowhere else in the tree. It is
**correct today** - the live board carries 376 Sam's Club rows and all 376 are flagged - which is
this item's thesis rather than a refutation of it. Untested is not wrong, and it is not safe either.

**What it would cost.** It decides the `membership` flag and the `membership` label on a live paid
page. A Sam's Club price shown without that label is a price the reader cannot actually get without
paying for a membership first, which is the understating half of the accuracy rule.

**The fragile part is the string, so the fixture pins it.** The code and the board both use U+0027,
checked byte by byte against `comparison-2026-09-06.json`. A curly U+2019 arriving from a capture, a
rename or an editor autocorrect flips the comparison false for every row at once with no other
symptom. Five cases shipped, and the mutation check that matters was run: swapping the function to a
curly apostrophe takes the suite from exit 0 to **exit 1 with two failures**, where before this block
the identical mutation exited 0.

**Two shapes were looked for and are not present.** There is no prevalence weight anywhere - the
estate's detectors are rule-based rather than probabilistic, so the naive-Bayes log-prior case that
prompted this item has no analogue here. And `Test-Membership` is the only per-store branch in the
comparison path; there is no per-store adjustment table to sweep.

Left open rather than closed: this was a targeted sweep of the shapes the item names, not exhaustive
coverage analysis. The general form - a term whose deletion no self-test notices - is answerable only
by mutation across the whole gate, which is a bigger build than this item asks for and has no defect
behind it yet.

### E6 - Fact Check List before we publish `PARTLY DONE` `a90b2081`
*Source: Prompt Engineering (course 4).* Ask the generator for the fundamental claims that would
undermine its own output, then diff that list against the prose. Cheap pre-publish check, close in
spirit to what `post-publish-reviewer` does afterwards - and on the correct side of the publish,
which is E1's whole point.

**Shipped as a declaration plus a ratchet, not as a second generator call.** `fact_claims` joined
`WRITER_FIELDS`, so the writer states the claims its card rests on, and
`meal-prep/pipeline/audit-fact-claims.ps1` fails when a NEW card ships prose claims it did not
declare. **Partly, because 584 live cards assert things nothing checks and 340 of those assertions
were never declared** - those are baselined, so the gate holds the line without going red on day one
over a backlog nobody can clear in a sitting. Clearing the 340 is what is left.

### E27 - The reranker fine-tuner ships the LAST epoch, not the best one `DONE - SHIPPED`
*Source: Fine-Tuning Transformers with Hugging Face (queue 2, course 5).* `sidecar/finetune_reranker.py`
scores holdout AUC after every epoch and appends it to `history`, then calls `model.save_pretrained(out)`
**after** the loop finishes. So the weights that reach disk are whichever epoch happened to be last,
and the per-epoch AUC it just measured is used for nothing. If epoch 2 is the peak and epoch 4 has
started to overfit, epoch 4 is what gets published, and the card records the whole history so the
regression is visible in the artifact we shipped.

Two fixes, and they are independent:
1. **Keep the best.** Track the best holdout AUC, snapshot the state dict at that epoch, restore it
   before `save_pretrained`. Roughly ten lines, no new dependency.
2. **Stop early.** There is no patience at all - the loop always runs `--epochs` to the end. A
   plateau costs full training time and buys a worse checkpoint.

The course's Trainer-API equivalents are `metric_for_best_model` + `load_best_model_at_end` +
`EarlyStoppingCallback`. We do not use the Trainer here and should not switch to it for this; the
hand-rolled loop is more capable than the course's (OneCycleLR warmup, grad clipping, bf16 autocast,
`pos_weight` for class imbalance, seeded, and it writes a real card). It simply has this one hole,
and the hole is invisible because the training log looks correct either way.

Touches: `sidecar/finetune_reranker.py` only. The gate downstream (`hardeval.py --stage score`)
would show the improvement, so the change is measurable before it is trusted.

**SHIPPED 2026-09-06, and fix 1 above was wrong as written.** "Keep the best epoch" is an argmax over
k noisy draws, and this file's own docstring already measured that noise: four runs of the same
recipe differing only by seed produced holdout AUC from 0.9641 to 0.9674. Restoring an earlier epoch
because it led by 0.002 is selecting on a shuffle while believing you corrected for one, which is
E21 committed inside the fix for E27.

What shipped instead keeps the LAST epoch unless an earlier one leads by more than a stated margin,
defaulting to that measured 0.0033 spread. `--best-margin 0` restores the plain argmax for a caller
who has a reason to trust smaller differences; nothing has produced that reason yet. The rule lives
in `sidecar/checkpoint_selection.py` rather than in the trainer for a practical reason: the trainer
imports torch at module scope and runs on the sidecar venv, so a rule left inside it could never run
in `run-gates`, which uses the pinned interpreter. It is registered there now with thirteen cases,
including the clean twin that separates a real mid-run peak from seed noise.

**The first real run vindicated the correction.** A two-epoch verification train, output to a scratch
directory so the live model was untouched: epoch 1 scored 0.9671 and epoch 2 scored 0.9663, so epoch
1 "won" by 0.0008 - a quarter of the noise floor. The version this item originally proposed would
have restored epoch 1 and recorded it as a correction. The margin rule shipped epoch 2 and wrote the
reason into the card.

E28 shipped with it: `train_auc` and `overfit_gap` are now recorded per epoch, and the same run shows
the gap widening from 0.0299 to 0.0331 while holdout AUC fell, with train AUC reaching 0.9994. That
is early memorisation, and until this change nothing in the estate could see it.

### E28 - No held-out overfitting gap is computed for the reranker `DONE - SHIPPED`
*Source: same course.* `finetune_reranker.py` reports holdout AUC against a stock baseline, which
answers "did fine-tuning help" but not "did it memorise". The train-versus-holdout gap is the cheap
second number, and the course's own demo is the argument for it: its diagnosis flipped between
"good generalization" and "moderate gap" on identical code because the dataset was too small to
test anything. Same exposure here if the pair corpus is small in some band. Would touch the same
file and the card schema. Smaller than E27 and best done with it.

---

## Efficiency and ergonomics

### E7 - `.worktreeinclude` `DONE` `4e8102c2`
*Source: Claude Code in Action (course 1).* A repo-root file listing gitignored files to copy into
every new worktree. Would automate the manual copy-in that `run-gates-blind-in-worktrees` and
`worktrees-lack-the-boards-the-engines-price-on` both describe. **Needs sizing first** - the full
ignored set is ~25 GB, so it must be a narrow list: the four gates' real inputs plus the three board
files.

### E8 - "Don't ask" permission mode for unattended runs `DONE - RULED 2026-09-07, BYPASS STAYS ON AND THE FLAG STAYS INERT`
*Source: Claude Code in Action (course 1).* Purpose-built for CI, scheduled jobs and overnight
batches: pre-approved tools only, everything else auto-denied with no prompt to hang on. May fit the
scheduled tasks and the daemon better than what they use now.


**Brad ruled: set the daemon's dispatch to dontAsk. Done - and then measured, and it does not
currently do anything.**

`hunt_dispatch` passed `--allowedTools` and no permission mode, so every agent inherited
`defaultMode` from `~/.claude/settings.json`. It now passes `--permission-mode dontAsk` on all three
roads, pinned by three must-fire cases including the resume road, which would otherwise be the one
path nobody exercises.

**Then it was tested rather than assumed**, with the prompt on stdin so the variadic `--allowedTools`
could not swallow it (an earlier test was malformed exactly that way and the correction matters):

| invocation | result |
|---|---|
| `--permission-mode dontAsk` + `--allowedTools Read` | a Bash command **RAN** |
| `--permission-mode default` + `--allowedTools Read` | **RAN** |
| `--permission-mode plan` - read-only by definition | **RAN** |

**A read-only mode running a shell command is the decisive one.** The CLI flag is not governing at all
while `~/.claude/settings.json` carries `defaultMode: bypassPermissions`. Two consequences follow and
neither was known before:

1. **`--allowedTools` is not a boundary.** The agent tool lists that `ops/audit-agent-tools.ps1` gates
   are documentation of intent, not enforcement. That audit is still worth having - it keeps the
   declarations honest - but it does not constrain anything.
2. **E8 and I6 are one decision, not two.** The flag becomes effective the moment the settings default
   changes and does nothing until then. That setting governs the surface these sessions run on and is
   Brad's to change, not mine.

The flag stays: it is right in principle, costs nothing, and arms itself when the default moves. It is
documented at the call site as inert, because an unarmed guard people believe in is worse than a
missing one.

### E9 - Model choice is pinned per agent, but MATE's M is per call `OPEN - THE SWAP IS REFUSED, AND NOTHING COMPARES A TRANSCRIPTION TO ITS PAGE`
*Source: AI Agents Architecture (course 7).* All twelve definitions pin one model. A tool that makes
its own LLM call can pick its own. Highest-leverage split: an expensive model for the up-front plan,
a cheap one to execute it.

**MEASURED 2026-09-06, and it answered a different question than it asked.**
`meal-prep/pipeline/extractor_model_probe.py --n 4` compares the pinned extractor (fable/medium)
against Haiku 4.5 on the same four live pages. Transcription has a right answer, so this asks whether
two models produce the SAME transcription rather than which output is nicer, and it compares them to
each other rather than to the August files, which may be stale against pages that have since changed.

**They agreed on 1 of 4 pages, so the swap is not licensed.** That is the answer to the question as
asked, and it would be the whole result if the disagreements had run one way. They did not.

**The disagreements say the incumbent is not doing verbatim transcription.** Checked against the
pages' own bytes, not inferred from the shape of the diff:

| the page's bytes | pinned (fable) | Haiku 4.5 |
|---|---|---|
| `"½ cup finely chopped onion"` | `1/2 cup finely chopped onion` | `½ cup finely chopped onion` |
| `"15.5 oz artichoke hearts (drained)"` | `15.5 oz artichoke hearts drained` | `15.5 oz artichoke hearts, drained` |
| `"chicken breasts ((See Note 1))"` | kept | **dropped** |

So **neither model produces a verbatim `raw`**, and they corrupt it differently: the incumbent
converts vulgar fractions to ASCII and deletes parentheses, the challenger keeps the fraction but
rewrites parentheses as commas and dropped a parenthetical note outright. `raw` is defined as the
page's own line, and the extractor is told in as many words to convert no units and rewrite no prose.

**The blast radius is provenance, not prices, and that was checked rather than assumed.**
`coverage_check.py` already reads both fraction forms - `_VULGAR` maps the glyphs and `parse_amount`
has a passing case for `½ cup` - and `stated_mass_grams` takes the first mass in the line through a
regex that never treats a parenthesis as a delimiter, so stripping one moves no mass. No cost, macro
or scaling figure changes either way. This is a fidelity defect in the record of what we found, not a
wrong number on a page.

**The gap worth acting on is that nothing compares a transcription to the page.** `recipe-source-qa`
rules whether the built recipe matches the transcription, which is one link downstream of where this
drift happens, so a transcription that quietly normalised its source passes every check we run. That
is the same shape as E19's complaint and is where the cheap fix goes.

Three things this does NOT establish. Four pages is four pages. Haiku's fraction fidelity here is not
a general claim about Haiku. And nothing was measured about cost or latency, so even a clean
agreement would not by itself have argued for the swap.

### E10 - Long-running lanes have no progress tracking `DONE - CALIBRATED 2026-09-07 AGAINST 3,253 GAPS` `9301d154`
*Source: AI Agents Architecture (course 7).* The Recipe Hunter daemon runs far past the point where
its initial plan is still near the front of context. Fix is a cheap end-of-iteration progress report
every Nth loop; calibrate N by running plan-only and watching for where drift starts.

**The premise was wrong and the fix that shipped is a different one.** The daemon is a Python
process, not a conversation: it has no context window to sink and no plan drifting out of the front
of one. What it actually had was silence - a run lasts hours and said nothing until it finished, so a
hung lane and a slow lane looked identical from outside. `status_heartbeat` plus `--status-every`
(default 600s) shipped in `9301d154`.

**Partly, because N is time-based and was never calibrated.** 600 seconds is a guess that has not
been checked against how long a real iteration takes, and the calibration this item asked for -
watching where drift starts - does not apply to the defect that turned out to be there. What would
be worth measuring instead is the longest legitimate gap between heartbeats, so a stall can be
distinguished from a slow page fetch rather than merely being visible.

**MEASURED 2026-09-07, and the interval was fine while the MESSAGE was wrong.**
`meal-prep/pipeline/measure_heartbeat_gap.py` reads every run's `lane-log.jsonl` - one timestamped
row per lane event - and takes the gap between consecutive rows, which is exactly how long the daemon
went without the `lane_lines` counter moving. Over **3,253 gaps across 17 runs**:

| p50 | p90 | p95 | p99 | max |
|---|---|---|---|---|
| 1 s | 39 s | 100 s | 542 s | **3,490 s** |

**600 s as a reporting cadence is defensible** - it sits just above the p99. **What was wrong is the
stall claim.** The longest LEGITIMATE quiet stretch is 3,490 s, which is 5.8 intervals, and the old
message called two intervals NO PROGRESS and added "if this repeats, look". It repeats, on ordinary
slow work. A stall warning that fires on normal work is a stall warning nobody reads - the same
argument this estate makes about a gate that is red on day one.

So the wording is split at the measured boundary and `LEGIT_QUIET_SEC = 3600` carries its derivation
at the line: below it the run is **quiet** and says what the measured normal is; at or past it it is
**NO PROGRESS** and names the boundary it passed, so a reader can judge the claim instead of trusting
it. Counted in SECONDS rather than intervals, because the boundary is a duration and
`--status-every` is an argument - at 300 s the old "2 intervals" meant ten minutes and at 1800 s
ninety.

**The overnight trap is handled and said out loud.** Eight gaps ran past an hour, the longest 10.9
hours: those are runs somebody paused, not lanes being slow, so they are reported separately and
excluded from the percentiles rather than silently kept - which makes the p99 meaningless - or
silently dropped, which hides that a run was interrupted at all.

**Both sides are pinned** in `hunt_daemon_selftest.py`, driven by a real interval, so a later edit
cannot collapse them back into one message in either direction. The old fixture asserted the
immediate NO PROGRESS and failed correctly the moment the behaviour changed.

### E18 - Tool arguments are untrusted model input, and our pattern does not validate them `DONE` `d2dc0cd5`
*Source: AI Agents in TypeScript (course 10).* The Python decorator pattern in E11 **derives** a tool
schema from the function signature and then never checks what comes back: the model's arguments
arrive and are passed straight into `execute`. The TypeScript route **declares** a schema once and
gets three things from it - the JSON Schema shown to the model, the inferred argument type, and
**runtime validation of the model's arguments before the tool body runs**.

That third thing is the point, and it is a correctness boundary rather than a typing convenience. A
tool argument is model output: it can be malformed, out of range, or a path we did not intend.
Anywhere the daemon hands model-supplied arguments to a tool that writes, reads a path, or shells
out, an unvalidated boundary is the same class of exposure as E1.

Take this together with E11 rather than separately: if we adopt decorators, add explicit argument
validation at the same time rather than inheriting the gap.

**Shipped standalone in `d2dc0cd5`, and the pairing rule is not broken by that.** The rule says do
not adopt decorators WITHOUT validation; this added validation without decorators, which is the safe
direction of the same constraint. It shipped alone because the exposure was concrete and located
rather than hypothetical: `graph/agentic/Executor` shells out on a plan's tool string, and
`os.path.join` discards the repo root the moment a tool name is absolute, so an absolute or
traversing name escaped the repo entirely. The plan-hash check sitting above it proves the plan was
not MUTATED, which is a different question and answers this one not at all.

`graph/agentic` was covered by nothing before this - not in the gate's Python list, no `-SelfTest`,
imported by no other suite - so the fix ships with `graph/agentic/executor_selftest.py`, which is
that directory's first coverage of any kind. **E11 stays open**, and nothing now forces it: it is a
refactor with no defect behind it, and the gap it would have inherited is already closed.

### E11 - Tool decorators and tag-scoped registries for the daemon `PARKED - BENEFIT ALREADY DELIVERED`
*Source: AI Agents in Python (course 6).* Derive each tool's schema from its signature, docstring
and type hints. Removes the class of bug where an agent's map of a tool has drifted from the tool,
and makes "which agents can write?" a grep instead of an audit.

**PARKED 2026-09-06 on Brad's ruling, and the reason is written down so nobody re-derives it.** Both
benefits this item claims already exist, by better mechanisms than the one proposed:

- *"which agents can write is a grep"* - it is an AUDIT, `ops/audit-agent-tools.ps1`, in the gate. It
  requires every agent to declare `tools:` and fails when a block names a tool the agent lacks. An
  audit beats a grep here for one reason: it cannot be forgotten.
- *"an agent's map of a tool has drifted from the tool"* - that is the same check, and E18's argument
  validation closed the correctness half of it in `d2dc0cd5`.

What remains is schema derivation from a Python signature inside the daemon's tool layer. That is an
ergonomics convenience with **no defect behind it**, and E18 already noted nothing forces it. Reopen
when a tool-schema drift actually bites; there is no instance today.

### E12 - Document-as-implementation `PARKED - ARGUES AGAINST ITSELF ON A LIVE SITE`
*Source: AI Agents Architecture (course 7).* Brad's rulings, the band rules and the naming
conventions are already written for humans and already change without a deploy. Loading the rules
file at run time and pairing it with a schema'd verdict is smaller than the equivalent code, and
removes the class of bug where the ruling document and the enforcing script have drifted.

**PARKED 2026-09-06 on Brad's ruling, and this one has an argument AGAINST it rather than merely an
absence of one for.** The drift it exists to remove is already detected: `ops/audit-ruling-drift.ps1`
plus `ops/ruling-implementations.json` fail when a ratified ruling goes unimplemented, with three
violations baselined.

The proposal's own mechanism is the problem on a live paid site. **Loading a rulings document at run
time means a bad edit to a markdown file changes live pricing behaviour immediately, with no gate in
between.** That trades a drift the gate can see for one it cannot, which is the wrong direction for an
estate whose standing rule is that a wrong number on a page is a real cost to a real reader. The
current shape - the document is ratified, the code implements it, and a gate compares them - keeps a
human between an edit and the board.

### E13 - Pass references, not copies `PARKED - MEASURED, THE PREMISE DOES NOT HOLD HERE`
*Source: AI Agents Architecture (course 7).* Models read far more than they can write, so a
delegating agent physically cannot restate a large memory as a task description. Emit memory ids and
inflate them in code. Beats the output cap and makes paraphrase of the referenced content
structurally impossible. Relevant anywhere we hand a brief to a spawned agent.

**Brad ruled BUILD IT 2026-09-06. Measuring first turned up two things that change the answer, so
this is recorded rather than built and the decision goes back to him.**

**1. The half that applies already shipped.** All twelve agent definitions carry `[[name]]` memory
citations plus a resolver block, gated by `ops/audit-memory-citations.ps1`, so a brief already passes
memory IDENTIFIERS rather than memory CONTENT. Before that gate an agent could not resolve an id at
all - no CLAUDE.md reaches a spawned agent and the MEMORY.md index is snapshotted at session start -
which is why this was impossible until this week.

A scan for the other failure mode found nothing: **zero duplicated prose** across the twelve agent
definitions against 16,275 distinct long lines from 97 design and docs files. No agent pastes a
ruling it should cite, so the copy-drift half has no instance to fix either.

**2. The premise does not transfer, and the estate has already measured the opposite.** E13's argument
is that *a delegating agent physically cannot restate a large memory*, which is a statement about a
MODEL's output cap. In this estate briefs are composed by **code** - `hunt-daemon.py`'s twelve
`*_prompt` builders - and code has no output cap. Worse, `map_prompt` carries a measured finding
pointing the other way:

> A2: THE EVIDENCE TRAVELS WHOLE. It was truncated at 220 characters, which cut the near-miss list
> [...] Truncating it sent the mapper back to the estate to re-derive what the table had already
> computed. **Phase 1 measured inlining beating tool-call reads by a wide margin.**

Converting those prompts to identifiers-plus-fetch would undo a finding the estate paid for. The one
place a MODEL composes a brief is the main session spawning through the Agent tool, and that is
exactly where the `[[name]]` citations already apply.

**So: nothing to build that would not make things worse.** If Brad wants it built anyway the concrete
scope would be re-measuring A2 first, because that measurement is the whole obstacle.

### E14 - Agent definitions front-load their rules `DONE` `6f3b6fd5`
*Source: MCP (course 3), mechanism from Mastering Claude Code (course 8).* A five-trigger framing
plus a hierarchical context walk is a cheaper shape for the estate's per-directory conventions than
the current front-loading.

**Course 8 supplied the actual mechanism: `.claude/rules/`, one topic per file, with YAML front
matter carrying a `paths` glob so the file loads ONLY when Claude touches a matching file.**

> **Verify the mechanism before building on it.** That account is **single-sourced from one course**
> and nothing on this machine corroborates it - no `.claude/rules/` directory, no `paths` key on any
> file. Registered as C3 in `~/.claude/skills/course/CLAIMS-REGISTER.md`. First step of this item is
> a two-file test proving a rule file actually loads conditionally, not a restructure. That is

> **VERIFIED 2026-09-06, AND THE COURSE NAMED THE WRONG FIELD. The key is `globs:`, not `paths:`.**
> This is exactly why the verification step was written in before the restructure: every rule file
> built to the course's description would have carried a `paths:` key, loaded never, and looked
> completely correct on disk. A scoping mechanism that silently matches nothing is worse than none,
> because nobody goes looking for the rules that did not appear. Five files shipped under
> `.claude/rules/` - `graph`, `grocery`, `meal-prep`, `ops-and-gates`, `site-and-publish` - each
> scoped with `globs:`, and `ops/audit-memory-citations.ps1` now checks that every `[[name]]` they
> cite resolves. C3 in the claims register is answered: corrected, not confirmed.

conditional loading, which we had written down nowhere - `claude-code-craft` had been posing the
attention-budget problem since course 2 without an answer to it.

Direct fit here: the estate's conventions are already per-directory. `grocery/`, `meal-prep/`,
`graph/`, `ops/`, `site/` each have rules that are noise when you are working anywhere else, and the
root `CLAUDE.md` currently carries the lot. Splitting them into path-scoped rule files would shrink
the always-on load without losing anything.

Related timing fact worth knowing before restructuring: **only CLAUDE.md files at or above the
current working directory load at session start**; a subdirectory CLAUDE.md loads lazily. So a
`meal-prep/CLAUDE.md` costs nothing until someone works in there.

### E16 - Plugin hooks written in bash fail on Windows `PARKED - MEASURED, NO ESTATE CHANGE OWED` - measured, no estate change owed
*Source: Building Apps and AI Agents (course 9).* The `ralph-loop` plugin ships a Stop hook written
in bash, which **fails on this machine because `bash` resolves to WSL**. Not our bug, but it is a
standing hazard for any plugin we install: a plugin's hooks fire on every matching tool call, and a
broken hook on Windows is a silent failure surface. Check the hook language before installing
anything with hooks. Recorded in `claude-code-automation` 8.3.

**Ruled 2026-09-06 after measuring, and the recorded diagnosis was wrong for this machine.** From a
clean Windows process `Get-Command bash` returns **nothing at all**: `wsl.exe` is present but
`C:\Windows\System32\bash.exe` is not, and Git Bash sits at `C:\Program Files\Git\usr\bin\bash.exe`
without being on the Windows PATH. So a bare-`bash` hook here does not die with a WSL error, it dies
with command-not-found - and `where bash` succeeds only from *inside* a Git Bash session, which is why
checking from a terminal gives the wrong answer. No plugin is installed on this machine
(`~/.claude/plugins/` holds only the marketplace cache), so **no change is owed in this estate**. The
durable half was the regime note, which is now in `claude-code-automation` 8.3 as a three-row table;
the rule to carry is the conclusion (never let a plugin hook invoke a bare interpreter name), not the
WSL story that only holds on a different machine.

### E19 - A fresh checkout starts two gates red, over bytes rather than drift `DONE` `39ad18d3`
*Found 2026-09-06 while working E7; not course-derived.* Every worktree, clone and CI checkout of this
repo begins with `run-gates` at 2 failed, and neither failure is a defect in the thing it names:

    meal-prep\engine\golden-test.ps1   "the FROZEN inputs changed - the fixture, not the engine, moved"
    grocery\audit-ghost-drift.ps1       budget-tracker-tool.html, 28,965 bytes committed vs 29,358

Measured: `db\label-folds.json` is 383 bytes in the main checkout and 390 in a fresh worktree over the
same 8 lines. That is 7 CR bytes, not an edit. `git diff` shows nothing
([[crlf-flip-is-invisible-in-git-diff]]).

**The mechanism, and it is working as designed.** `core.autocrlf` is true and `.gitattributes` carries
`* text=auto`, so the repository stores LF and a checkout writes CRLF. The main checkout's files are LF
only because they were written LF and never re-checked-out. A fresh one gets CRLF and the two
byte-comparing checks go red.

**A bulk `git add --renormalize` is already ruled out**, in `.gitattributes`' own header: it would touch
hundreds of files in one commit and collide with the daily bot's rebase. Files normalize as they are
touched instead. So the fix belongs in the two CHECKS, not in the tree.

**The fix has a precedent in this repo, shipped the same day.** `ops\audit-prompt-backup.ps1` had the
identical defect - it hashed raw on-disk bytes to compare two paths git deliberately holds identical
only after line-ending normalization, and reported six STALE BACKUP findings that were all CR noise.
It now hashes what git hashes. `golden-test` and `ghost-drift` need the same treatment.

**Why it matters more than two red lines.** `run-gates` is the change-time gate and a worktree is where
spawned agents work. A gate that is red on arrival in every worktree is a gate people learn to read
past, which is the exact failure `run-gates`' own header gives as its reason for excluding
`test-auditors`. It also means a genuine golden-test failure in a worktree is indistinguishable from
the standing noise.

**Not fixed here** because changing what a GOLDEN test compares is a semantic decision - byte-exactness
is arguably the point of a frozen fixture - and it deserves a ruling rather than a late edit at the end
of a long run.

**Fixed 2026-09-06, ruled by Brad: fix the tree, not the checks.** Two measurements, and the first
answer was wrong. `git add --renormalize` over every clean tracked file changed ZERO files - the repo
already stores LF - so the tree-side fix had to be about what a CHECKOUT writes. `* text=auto eol=lf`
makes the working copy LF on every platform and clone.

Tested on a throwaway branch first, and it broke golden-test before it fixed it: ghost-drift went green
and golden-test went from 3 drifted fixtures to TWENTY, because the golden fixture inputs were CRLF ON
DISK in the main checkout and MANIFEST.json had recorded their hashes from those bytes. The tree was
never uniformly one thing. The 20 inputs are now LF with their hashes re-recorded - line endings only,
no input regenerated, no expected output moved, and the engine's output stayed byte-identical
throughout because JSON parsing ignores line endings.

**Byte-exactness is preserved**, which was the argument against teaching the checks to normalise.

**A FRESH WORKTREE NOW PASSES 207/0.** It was 183/6 when first measured this morning.

### E17 - Skill invocation flags are a matrix, and ours are all set the same `PARKED - DECIDED, NO CHANGE`
*Source: Building Apps and AI Agents (course 9).* Invocation control is two independent flags, not
one switch: `disable-model-invocation: true` makes a skill user-only, `user-invocable: false` makes
it Claude-only. All eight of our personal skills set `user-invocable: true`.

**Closed 2026-09-06 as a decision, not as work.** It sat `OPEN` `LOW` while the body already
recorded the ruling, which is the worst of both - it reads as a task nobody is doing. The decision
stands and it is deliberate: the cost of leaving it is seven extra entries in the slash menu, the
benefit is being able to force-load a reference on purpose ("load `rag-craft` before we design
this"), and it does not suppress model invocation either way. Reopen only if the slash menu becomes
hard to use.

### E15 - "Ask for Input" for rules-first prompts `DONE` `8e3de6d9`
*Source: Prompt Engineering (course 4).* One statement, and it must come last. Fixes the annoyance
where a rules-first prompt invents its own first input instead of waiting.

---

### E29 - `run-log-lib.ps1` calls itself the one copy of the run-record rule, and covers two of five hidden tasks `DONE - ALL FIVE CONVERGED, AND THE GATE THIS ITEM CALLED IMPOSSIBLE IS BUILT` `2ff1df59`
*Source: `apply-powershell-scripting-for-automation-and-projects` (course 6), and it is a criticism
of that course rather than a lesson from it.* The course spends a full lecture arriving at a hidden
console window for a scheduled PowerShell job and never once mentions what hiding it costs. This
estate already paid that cost and wrote it down: `grocery/run-log-lib.ps1`'s header records that on
2026-08-22 all three `TC Grocery` tasks reported `LastTaskResult=1` for the previous day with no way
at all to learn why, because "the exit code was the entire diagnostic surface". Reading that file
against the rest of the tree is what turned up the gap.

**Measured 2026-09-06.** Five scheduled tasks run with `-WindowStyle Hidden` and they use **three
different hand-rolled diagnostic conventions**. Only two of the five are registered by a script in
this repo: `Register-ScheduledTask` appears in exactly two files, and the three `TC Grocery` tasks
have no in-repo registrar at all - they exist only in the Windows registry, which is why
`docs/RUNTIME-MAP.md:58` has to note that one of them is named 0930 and runs at 10:30 because "it is
the registry key".

| Task(s) | Registered by | Diagnostic surface |
|---|---|---|
| `TC Grocery` ad 07:00, daily 08:00, watchdog 09:30 | (existing registration) | `run-log-lib.ps1`, dot-sourced by `capture-run.ps1` and `capture-watchdog.ps1` |
| nightly matching chain | `graph/pipeline/install-nightly-task.ps1:84` | its own `grocery/out/logs/graph-nightly-status.json` |
| `TC Recipe Harvest Crawl` | `meal-prep/pipeline/install-harvest-task.ps1:94` | ad-hoc `Out-File -Append -Encoding utf8` at four sites in `harvest-crawl.ps1` |

**Nothing is unlogged**, which is why this is ergonomics and not correctness - do not read it as a
blind task. The defect is narrower and it is in the header comment: `run-log-lib.ps1` opens "ONE
copy of the 'write this run down' rule", and it is one of three. A file that claims to be the single
copy of a rule and is not is worse than no claim, because the next person to add a hidden task reads
that line, sees a library, and has no way to know two other tasks route around it. It also means the
two rules that file obeys and states explicitly - logging must never kill the run, and every
`Add-Content`/`Start-Transcript` under `$ErrorActionPreference = 'Stop'` must be guarded - are
enforced for two tasks and merely hoped for in the other three.

**The cheap half:** either bring the graph and harvest wrappers onto `run-log-lib`, or correct its
header to say what it actually covers and name the other two conventions. Worth doing either way.

**THE CHEAP HALF IS DONE 2026-09-06.** The header now opens by saying it covers the three TC Grocery
tasks and NOT all five, carries the table of which task uses which convention, and rule 2 no longer
claims to be the only copy - it says the one-copy argument applies just as well to the other two,
which is the open half. `ops/audit-run-log-claims.ps1` keeps it honest: it fired at exit 2 on the
false claim before the edit and passes at exit 0 after, with seven self-test cases.

**The gate checks the claim, not the convergence, and its header says so.** It cannot do more: three
of the five registrations live in the Windows registry, so a static detector reaches two. One case
worth noting is the `MUST FIRE` for **code is not documentation** - a mention of the other convention
in the file's body does not satisfy it, only the comment header, or the claim could drift back while
the gate stayed green.

**The durable half needs a ruling first, and the obvious version of it does not work.** The tempting
gate is a `run-gates` detector that greps `-WindowStyle Hidden` out of every
`Register-ScheduledTask` argument line and requires the target script to dot-source the lib. It
would be hermetic, and it would **miss three of the five tasks** - precisely the three the rule was
written for - because they are registered in the registry and not by any file the detector can read.
A static-analysis gate can only cover what is in the tree, and the tasks that hurt are the ones that
are not. So the honest options are: move the three `TC Grocery` registrations into an in-repo
installer alongside the other two and then gate all five, or accept that the gate covers the
in-repo half only and say so in its own header rather than letting a green run imply five. **The
first is the right shape** and it is a bigger job than this item looks; sizing it is the next step,
not writing the detector.


**THE DURABLE HALF, PART ONE, 2026-09-06: the definitions are in the repo.**
`ops/scheduled-tasks/*.xml` holds all five, exported from the live scheduler as a before-image, and
`ops/install-grocery-tasks.ps1` owns the three TC Grocery ones.

Two edits to the raw export, both load-bearing. The account **SID became `__CURRENT_USER_SID__`**,
substituted at registration time - a raw export carries `S-1-5-21-...`, which is identifying,
machine-specific, and would name a nonexistent account anywhere else; `gh` is not authenticated here
so the repo had to be treated as public. And the XML **declaration said UTF-16** (what the scheduler
emits) while the bytes were UTF-8, which fails in the confusing way rather than the obvious one.

**`-Verify` is read-only and is the default.** Run against the live scheduler it reports **zero
drift** on command, arguments and start time for all three, which is the result that matters: the
committed before-image is faithful. Its one finding is the naming lie - **the watchdog is named 0930
and its trigger is 10:30** - which `docs/RUNTIME-MAP.md` had to explain away because the registry was
the only authority. `-FixName` corrects the NAME and never the time: 10:30 is what the estate has
been running and validating against for months.

**Only the `-SelfTest` is in `run-gates`, and it is auto-discovered.** `-Verify` reads the live
Windows scheduler, so it is not hermetic, and it exits 2 today on something only a human can fix -
gating on it would be red on day one, which is how a red gate becomes one people skim. The self-test
is hermetic and covers drift on arguments, drift on time, a definition that lost `-WindowStyle
Hidden`, and the name lie with its twins.

**The registration itself was NOT executed.** It changes Windows scheduler state on a live estate,
and a rename is an unregister followed by a register with a window in between where no task exists.
The script is written, self-tested and verified against the live definitions; running it is one
command and it is Brad's to run:

```
powershell -File ops\install-grocery-tasks.ps1 -Install -FixName
powershell -File ops\install-grocery-tasks.ps1 -Verify
```

**INSTALLED 2026-09-07 06:33.** All three registered from the committed definitions; the watchdog is
now `TC Grocery Capture Watchdog 1030` and its trigger is untouched at 10:30. `-Verify` exits 0 with
zero drift, and all three actions are byte-identical to what ran yesterday - same executable, same
arguments, same `-WindowStyle Hidden`, same run-as. One watchdog, three tasks, no duplicates.

**The first attempt FAILED, safely, on a defect I had introduced.** Redacting the SIDs the day before,
I rewrote the XML declaration from UTF-16 to UTF-8 so it matched the bytes on disk. That broke the only
path that consumes it: `Register-ScheduledTask -Xml` takes a .NET string, which is UTF-16 in memory,
and refuses a declaration claiming otherwise. The self-test had ASSERTED the UTF-16 declaration was
absent, pinning the broken shape. The registration path now strips the declaration entirely, and the
self-test pins that instead. It failed before unregistering anything, so all three tasks were intact.

**A second hazard was closed after the rename.** `$OWNED` still named 0930 as primary with 1030 as a
rename target, so a later `-Install` without `-FixName` would have registered a SECOND watchdog under
the old name - and `-Verify` would have passed, because it falls back to the rename target when the
primary is missing. 1030 is now the name, 0930 is a legacy alias, and `-Verify` reports a machine
still carrying it.


**THE DURABLE HALF, PART TWO: the conventions have converged, and the gate this item said could not
be built now exists.** `graph/pipeline/nightly.ps1` and `meal-prep/pipeline/harvest-crawl.ps1` now
dot-source `run-log-lib`, so all five hidden tasks leave a run record with the exit code as the last
line. Both KEEP their own artefacts - `graph-nightly-status.json` and `crawl-<date>.log` - because
those persist subprocess output captured into a variable, which never reaches a transcript. Neither
of them was a run record: nightly's status file is written at the very END, so a run that died before
that line left nothing at all, which is indistinguishable from a run that never started.

All five records now land in `grocery/out/logs/`, which is the point of converging - one directory a
human already opens. Nightly does not start a transcript under `-SelfTest`, or `run-gates` would
leave a log behind on every run.

**`ops/audit-run-log-claims.ps1` is now the detector E29 rejected as impossible.** It reads
`ops/scheduled-tasks/*.xml`, extracts each task's `-File` target, and fails when a hidden task's
script does not dot-source the library. That was unbuildable while three of the five registrations
lived only in the registry; committing the definitions is what made it hermetic AND complete. It
still cannot see a task present in the registry and absent from the repo - `install-grocery-tasks.ps1
-Verify` is that check, and it stays out of the gate because it reads live scheduler state.

**RULED 2026-09-07 (Brad): converge the two wrappers - and it was ALREADY DONE when the ruling
landed, in `2ff1df59`. Checked rather than assumed before starting the work.** All five hidden tasks
now dot-source `run-log-lib`, so the two rules this file states - logging must never kill the run,
and every `Add-Content`/`Start-Transcript` under `$ErrorActionPreference = Stop` must be guarded -
are enforced for five tasks rather than hoped for in three.

`graph-nightly-status.json` and `crawl-<date>.log` deliberately SURVIVE the convergence. They persist
subprocess output captured into a variable, which never reaches a transcript, so they are a different
artefact rather than a third convention. What those two lanes gained is the run record itself - a
transcript, and the exit code stamped as the last line. Neither had one, and nightly writes its status
file at the very end, so a run that died before that left nothing at all, which is indistinguishable
from a run that never started.

**The half this item called impossible is built.** A static detector could not read three of the five
registrations because they lived only in the Windows registry; committing `ops/scheduled-tasks/*.xml`
gave it something to read, and `ops/audit-run-log-claims.ps1` now fails a hidden task whose target
script does not dot-source the library. It passes at 5 tasks, 0 without a run log.

**One detector defect found by the fix itself.** The ONE-copy check greped the whole header, so it
fired on the CORRECTED header - which quotes the old false claim in order to explain what changed. A
file explaining its own history is exactly what is wanted, so the detector learned the difference: it
now reads the TITLE line, where a file's assertion about itself actually lives, and carries a clean
twin proving a quoted historical claim does not trip it.

## Infrastructure and hygiene

Found while running the programme; not course-derived.



### I28 - A republished board does not re-cost the recipes, and no clock could ever have caught it `DONE`

**Found 2026-09-07 by asking why 153 files were dirty.** The open half of the 2026-09-06 feed incident.

That day `guards.ps1` hard-failed at 08:15, so the daily run's publish stage staged **inputs only** -
"guards BLOCKED this board, so `public\**` and the recipe files are NOT shipped". Triage unblocked the
guard and rebuilt the board at **11:55**. The FEED half of that asymmetry was caught the same day and
fixed (`efa08722`, and `audit-feed-week-parity.ps1` in the chain). **The RECOST half was not.**
`db/costed.json` stayed at **09:51**, priced off the superseded board, for twenty hours.

**Measured rather than asserted.** Re-costing to a scratch path against the corrected board, same
engine and same specs so the board is the only variable: **20 of 584 recipes moved, all in the same
direction - understated**, mean $0.098 and worst **$0.23 per serving** (`kielbasa-cabbage-potato-skillet`
2.35 to 2.58). All cabbage and kielbasa dishes, consistent with one commodity the triage corrected.
They never reached a reader only because the guards were still blocking; had they passed, they would
have. Understating is exactly as wrong as overstating - a reader budgeting from a low number is misled
in the direction that costs them at the till.

**NO CLOCK COULD HAVE CAUGHT THIS, which is why a stamp had to come first.** `cost-recipes.ps1` picks
its board by **filename descending**, and a rebuild REUSES the filename: `comparison-2026-09-06.json`
at 05:24 and the corrected one at 11:55 are the same name with different bytes. A filename comparison
sees nothing, and an mtime comparison is worse than nothing in an estate that already has a scar about
mtime moving on unchanged content. The only thing identifying a build of the board is its own
`built_at`, and the recost recorded nothing at all.

- `cost-recipes.ps1` now writes `db/costed.stamp.json` with the `built_at` of the board it priced from.
  A **sidecar, not a header**, because `costed.json` is a bare list many readers consume positionally.
- **A `-Slugs` recost deliberately does not advance the stamp.** A catalog is not priced off today's
  board because three of its rows are, and a guard that accepted that would lie in the reassuring
  direction. That case has its own must-fire.
- `meal-prep/pipeline/audit-recost-freshness.ps1` compares the two identities. **A missing stamp is
  `unknown`, not a pass** - every recost before today is in that state, and that is not evidence the
  costs are current.
- Wired into `check-ad-cycles.ps1` immediately after the recost. Alerts, does not block, matching the
  feed-parity check beside it: withholding a correct board would leave the recipe pages on the old
  costs too, which is the same divergence with fewer people looking at it.

**Separately, and this is why the tree looked alarming:** only **one of the five scheduled tasks
commits**. `capture-run.ps1` carries 12 git references; `capture-watchdog.ps1`, `graph/pipeline/nightly.ps1`
and `meal-prep/pipeline/harvest-crawl.ps1` carry none. `capture-run` last swept the whole tree at 08:33
on 09-06, so the 09:51 recost, the 11:55 corrected board, the midday audits and the entire evening
harvest and nightly-matching output had no committer. 153 dirty files is what twenty hours of three
uncommitting tasks looks like. Left as-is deliberately - one sweeper is the estate's design - but it
is worth knowing that anything produced between sweeps is invisible to any engine that reads the
newest COMMITTED artefact.


### I29 - The guards audited as a class, and the systemic worry was not borne out `DONE`

**Run 2026-09-07** after five of this session's findings turned out to be defects in the
defect-catching machinery. The worry was that those were a symptom rather than five separate bugs.
They were not. `ops/probe-detector-health.py` and `ops/probe-detector-gate-claims.py` over 108
detectors, asking the three questions nothing else gates:

| | |
|---|---|
| **Can it fail at all?** (the I17 shape) | 11 of 108 have no non-zero exit path, and **none of them claims to gate**. All are probes and verifiers that legitimately report. `backtest.py` was the only real instance and it is fixed. |
| **Can it lock in its own blindness?** (the I15 shape) | **0 of 108.** The `lib/ratchet.ps1` fix closed the whole class. |
| **Does it report a denominator?** (E20/E22) | 44 flagged, and the flag does not survive inspection - see below. |

**THE MOST USEFUL FINDING IS ABOUT THE METHOD, NOT THE ESTATE.** The probe returned **42** detectors
that "cannot fail", then 29, then 11, and finally **zero** real gate-claim contradictions. Every
correction was a bug in the probe, not in the tree:

- it missed `exit $(if (...) { 1 } else { 0 })`, this estate's most common idiom, and flagged
  `audit-guard-contract.ps1` - a core gate - as unable to fail
- it missed `{ Write-GuardComplete; exit 1 }`, where the exit follows a semicolon rather than starting
  a line
- it counted `-lib.ps1` files as detectors
- it read claim words like "refuses" and "block" that described a DIFFERENT script, or the phrase
  "resolver block"

And Q3's 44 dissolves the same way: `audit-feed-week-parity.ps1` is flagged for having no denominator
when it compares two single values and correctly names what it looked at (`board=... feed=...`), which
is precisely what the convention on `Write-GuardComplete` tells it to do. A static probe cannot
separate "needs a population" from "has not got one and says what it examined", so **no gate was built
on it** - one at 44 would be noise, and noise is how a red gate becomes one people skim.

**So the systemic concern is answered and closed.** The five defects were real and they were not a
rotten class: four are now structurally prevented (the ratchet library, the orphan gate that caught my
own detector, the must-fire census, the denominator convention on `Write-GuardComplete`). Reporting
the probe's raw first output would have been an agreeing number escaping scrutiny in the ALARMING
direction, which is the same failure as the reassuring one and easier to get away with.

Both probes are committed so the claim can be re-run rather than believed.

### Triage of I8-I27, 2026-09-07

Every claim checked against the tree rather than against its own write-up, by
`ops/probe-queue2-triage.py`. Four items on this backlog have already inverted their own premise once
measured, so nothing here was taken on trust. I19 was skipped: another session owns it.

| | Items |
|---|---|
| **VERIFIED** and now DONE | I12, I13/I14 (partly), I15, I17 |
| **VERIFIED**, not yet worked | I8, I9, I10, I18, I23, I26 |
| **NEEDS-LOOK** - not settleable mechanically | I11, I16, I20, I21, I22, I24, I25, I27 |

**Three of the probe's own answers were wrong and were corrected before use**, which is the reason it
is committed rather than thrown away:

- **I15** looked NOT VERIFIED because the probe's grep missed four baseline files that do pin a count.
  Reading the claim properly showed it stands and is sharper than written: those pin a MAXIMUM, not a
  time series, so a detector that stops firing sails through a high-water ratchet. That became the
  day's most serious finding.
- **I16**'s file was not where the probe guessed; the real one is `grocery/audit-unit-basis-outlier.ps1`.
- **I27** could not be checked at all - there is no `lesson/SKILL.md` under `~/.claude/skills`, so the
  premise needs locating before the claim can be judged.

**I11 is a NEEDS-LOOK worth stating**, because the number is large: 1,788 "CLEAN TWIN" lines across the
tree, 695 phrased as "must NOT fire" and 1,093 phrased positively. Two readings genuinely coexist, so
the item is right that the phrase carries opposite meanings - what it needs is a ruling on which one
is canonical, not a patch.

### I1 - `~/.claude` is backed up to a private remote `DONE` `3116e5b`
Seven-plus courses of distilled learning, the memory stores, the agent definitions and the scheduled
tasks lived on one disk with no repo and no remote. Closed 2026-09-06.

**Remote:** `github.com/Schweino/claude-store`, **private**, 6 commits, 232 files, 1.0 MB.
Confirmed on the live page rather than assumed: the Private badge is set, and the top level is
exactly the allow-list - `agents/`, `projects/`, `scheduled-tasks/`, `skills/`,
`workspace-context/` and four root files. No transcripts, no cache, no session state, no
credentials. `gh` would not authenticate, so the repo was created through the browser; git already
had credentials for `Schweino` in Windows Credential Manager, so the push handled no secrets.

Three sub-problems, all measured rather than asserted:

1. **Staleness - FIXED.** The repo held a stale fraction of what it existed to protect: 42 untracked
   paths inside the allow-list and 23 tracked files with real drift, one untouched skill core
   diffing at 750 deletions, because several courses and a consolidation rewrote the store after the
   first two commits. 71 paths committed. The credential scan in `.gitignore`'s header was re-run
   against exactly the set being added, and **the scanner itself was proved to fire** by planting
   two fake tokens first. Clean both times.
2. **Line endings - FIXED, and the one-line fix did not work the first time.** `core.autocrlf=true`
   is set at SYSTEM level here, so a fresh clone came out CRLF while the repo stores LF - E15 in a
   second repo, and invisible in `git diff`. **Measured on worktrees of the commits either side:
   231 of 231 tracked files checked out CRLF before, 0 of 232 after.** The catch: the allow-list
   `/*` silently ignored `.gitattributes` ITSELF, so the fix applied locally, would never have been
   committed, and every clone would still have come out CRLF - a fix that reports success and ships
   nothing. Caught by checking whether the file was TRACKED, not whether git had accepted it.
   `!/.gitattributes` is the negation that was missing. **Third time this estate has been bitten by
   the allow-list trap**, which is the argument for a gate rather than a fourth memory.
3. **No remote - FIXED**, above.

**What this does NOT cover, and it is the same exposure:** `projects/C--Codex/memory/` is its own
git repo - **16 commits, 190 files, 4.0 MB, no remote** - deliberately excluded from `claude-store`
because adding it would turn it into a gitlink with nothing behind it and lose that history. It
needs its own private repo, by the same route. Tracked as I7.

### I7 - `projects/C--Codex/memory/` is backed up to a private remote `DONE` `4041025`
*Split out of I1, 2026-09-06, and closed the same day.* The C--Codex workspace memory store was its
own git repo - 16 commits, 190 files - on the same disk as its working copy, with no remote. It was
deliberately kept out of `claude-store` because folding it in would have made it a gitlink with
nothing behind it and lost that history.

**Remote:** `github.com/Schweino/codex-memory`, **private**, 17 commits, 192 files. Private badge
read off the live page, not inferred from the creation form. Contents are 190 markdown memos plus
`.gitignore` and `.gitattributes`, verified against the remote tree.

Three things were fixed on the way, and the second is the one worth remembering:

1. **No `.gitignore` at all.** Fine for a local store, not fine for one with a remote: anything a
   tool drops in that directory joins the next `git add` and gets published. Now an allow-list -
   markdown and the two dotfiles - matching `~/.claude`'s design and for the same reason.
2. **The tree stored MIXED line endings, which `~/.claude` did not.** 15 of 190 blobs actually
   held CRLF while the other 175 held LF, so this needed a renormalise and not just an attribute.
   Several of the 15 lost a single byte, meaning one stray CRLF inside an otherwise LF file. All 15
   content-verified identical by sha256 with line endings normalised. **Measured on worktrees of the
   commits either side: 190 of 190 checked out CRLF before, 0 of 192 after.**
3. **`.gitattributes` negated explicitly** in the new allow-list, because `/*` would otherwise
   swallow it - the silent failure hit in `claude-store` hours earlier, where the fix applied
   locally, would never have been committed, and every clone would still have come out CRLF.

Both stores are now on private remotes. **The allow-list has now swallowed a root dotfile three
times across this estate**, which is the argument for a gate rather than a fourth memory entry.

### I6 - Bypass-permissions is opted in at the account level, with no sandbox under it `PARKED - MEASURED, THE PREMISE WAS WRONG ON BOTH HALVES`
*Surfaced by the Claude Cowork run (course 11), then verified directly rather than taken on its
word.* `%APPDATA%\Claude\claude_desktop_config.json` carries, for this account:

```
bypassPermissionsGateByAccount   = true
bypassPermissionsOptInByAccount  = true
coworkModelAutoFallbackByAccount = true
coworkBrowserToolsEnabled        = true
coworkScheduledTasksEnabled      = true
```

Confirmed by me: those five flags. **Still the agent's claim, not independently confirmed:** that
`C:\Codex` specifically is the granted folder, and that the VM sandbox is unsupported on this machine
(it reported `yukonSilver not supported` in `cowork_vm_node.log`). `coworkUserFilesPath` is
`C:\Users\Owner\Claude`, not `C:\Codex`, so the grant may be narrower than reported - worth checking
before acting.

Two separate things to decide, and both are Brad's:
1. **Bypass permissions with no sandbox** is the one mode the Claude Code course says belongs only
   inside an isolated container or VM. If the sandbox really is unavailable here, that condition is
   not met.
2. **`coworkModelAutoFallback` means a Cowork result is not attributable to a named model.** That
   matters anywhere we record which model produced a ruling - the estate pins models per agent
   precisely so results are attributable.

**Nothing changed.** Permission settings are not mine to alter, and this is listed to be ruled on.


**VERIFIED 2026-09-07 read-only, on Brad's ruling to check before acting - and the item is wrong on
both counts.** It was right to say so itself: the sandbox claim came from an agent and was never
independently confirmed.

**1. The five account flags do not exist.** `%APPDATA%\Claude\claude_desktop_config.json` has exactly
**two** keys: `coworkUserFilesPath` and `preferences`. None of `bypassPermissionsGateByAccount`,
`bypassPermissionsOptInByAccount`, `coworkModelAutoFallbackByAccount`, `coworkBrowserToolsEnabled` or
`coworkScheduledTasksEnabled` is present.

**2. The sandbox is supported, and the claim was three months stale.** The
`yukonSilver not supported (status=unsupported)` lines are from **2026-06-09 and 06-10**, in the
**Roaming** copy of `cowork_vm_node.log` - a log that stopped being written on **08-20**. The CURRENT
log is the **Local** one, last written 2026-09-05, and it shows the VM warming normally: "Fetching VM
hash", "VM SHA matches current version, skipping", with no unsupported line anywhere. The old log
itself shows the recovery beginning on 08-17: "Stale bundle present; refreshing in background".

**The trap is one this estate already has a memory for** - `check-the-commit-clock-behind-a-recorded-measurement`.
A three-month-old log line was read as current state, from the stale copy of two same-named files.
Dating the measurement was the whole job.

**What survives, and it is a different thing.** `~/.claude/settings.json` really does carry
`defaultMode: bypassPermissions`, which governs **Claude Code**, not Cowork. That is a live question
about the surface these sessions run on, and it is Brad's setting to change rather than mine - I will
tighten my own permissions on request and will not loosen them, but I would rather he changed his
prompting behaviour knowingly than found it altered underneath him. Carried forward as the only real
residue of this item.

### I2 - Stray artifacts at the repo root `DONE` `558321d5`
`3 cups sliced, for topping` (1 file) and `CodexThriftyCrewgroceryoutcaptures_sink` (empty - a
mangled `C:\Codex\ThriftyCrew\grocery\out\captures_sink`). Both look like path-construction bugs.
Untouched deliberately: something wrote them and may still be writing them, so find the writer
before deleting the evidence.

### I3 - the two out-of-repo CLAUDE.md files are backed up `DONE`
`C:\Codex\CLAUDE.md` and `C:\Codex\Fantasy\CLAUDE.md` drove real work from directories that were
not repositories. Copies live at `~/.claude/workspace-context/`, which as of 2026-09-06 is on a
private remote (I1), so the exposure is closed. Verified 2026-09-06: both copies are byte-identical
to their sources with line endings normalised, and both are present in the remote's tree.

**The residual is drift, and it is real** - these are copies and nothing automates the refresh, as
`workspace-context/README.md` says in as many words. It bit within the hour: the workspace
`CLAUDE.md` gained a rule about CRLF sweeps and binaries, and the copy had to be refreshed by hand
immediately afterwards. If that becomes a habit rather than an event, the check belongs next to the
root-dotfile check in `check-skills.py`, which already walks both stores.

### I4 - Fantasy is under version control and on a private remote `DONE`
212 Python files with no branch to abandon, no diff to review and no undo. A repo was created
2026-09-06 with a deliberately-reasoned DENY-list `.gitignore` - the opposite of `~/.claude`'s
allow-list, and correctly so: this is a source tree with one large derived directory, not private
session state with a little source in it.

**Remote:** `github.com/Schweino/fantasy-nfl`, **private**, 313 files, 5.5 MB. Private badge read
off the live page. Verified on the remote tree: no `data/` (901 MB, re-pullable), no `.npy`, nothing
secrets-shaped. Credential scan clean, scanner proved to fire first.

Three things fixed on the way, and two were near-misses rather than tidying:

1. **`*.npy` was missing from the deny-list next to `*.npz`.** Not hypothetical - `search_preds.npy`,
   684 KB of derived prediction array written by `search.py:151`, was already tracked and would have
   gone to the remote. Now ignored and untracked, which is what that file's own comments say about
   derived artifacts: track the card, not the weights.
2. **No `.gitattributes`.** `core.autocrlf=true` is system-wide here, so a clone came out CRLF while
   the repo stored LF. **Measured on worktrees either side: 311 of 313 checked out CRLF before, 0
   after.** Being a deny-list, the file is tracked by default and needed no negation - but it was
   verified as tracked rather than assumed, which is the lesson from I1.
3. **`.env` was already covered** at line 30, so nothing was added. Checked rather than assumed.

**A mistake worth recording, because it is the kind that passes its own test.** The CRLF sweep that
prepared this repo ran over every tracked file including binaries, and silently rewrote
`search_preds.npy`. The sha256 "integrity check" compared the converted bytes against themselves, so
it was tautological and reported clean. `git status` caught it - a binary showing as modified when
only line endings were meant to change. Restored byte-for-byte from HEAD and verified against
`git cat-file`, valid NumPy header intact; no other repo had a binary to damage, checked. The rule
is now in the workspace `CLAUDE.md`: skip files containing a NUL byte, and verify against the
pre-edit copy rather than your own output.

### I5 - Coursera enrollment lapsed on `building-with-the-claude-api` `PARKED - KNOWLEDGE BANKED, ONLY THE COMPLETION RECORD IS MISSING` - knowledge banked, only the completion record is missing
Will not reinstate by clicking - three attempts. Course-specific, not account-wide. All content was
already extracted and routed; outstanding are 6 ungraded dialogues and that course's progress ticks.
Needs Brad to click enroll himself.


**Brad's ruling 2026-09-07: close it.** The point of working a course here is the routed knowledge,
and that landed - the skills carry it and `cc-course-source` records the run. What was outstanding was
6 ungraded dialogues and Coursera's own progress ticks, which nothing in this estate reads. Enrolment
would not reinstate by clicking after three attempts and it is course-specific rather than
account-wide, so there is nothing here to fix on our side.

Recorded rather than deleted, so nobody reopens it as debt.

### I8 - `run-gates` DISCOVERS PowerShell self-tests and HAND-LISTS the Python ones `DONE` `queue-2`
*Source: Build Testable Python Packages for AI (queue 2, course 7).* The course's whole argument is
that a test only protects you if the runner finds it without being told. Checked here, and the two
halves of our own gate are built on opposite principles.

The PowerShell half **discovers**: it walks the tree, and `run-gates.ps1`'s header says exit 3 means
"discovered zero self-tests, which means this discovery is broken". The Python half, added later at
lines 214-253 under a comment admitting "the discovery above reads `*.ps1` and nothing else, so
every Python suite in this estate was ungated", is **six literal hashtable entries**:
`coverage_check.py`, `executor_selftest.py`, `bm25_dedup_probe.py`, `checkpoint_selection.py`,
`extractor_model_probe.py`, `matcher_eval.py`. There is no Python discovery anywhere in the repo
(`Get-ChildItem *.py` appears once, in `audit-twin-drift.ps1`, for a different job).

**Measured 2026-09-06.** Sixteen further `.py` files define a real `--selftest` entry point
(`ap.add_argument("--selftest", ...)`, not merely a mention of the flag) and are NOT in that list:

`graph/bench/priors_ablation.py`, `graph/learning/ingest_hunter_events.py`,
`graph/pipeline/scorecard_query.py`, `grocery/pull-browser-stores.py`,
`meal-prep/pipeline/browser_price_work.py`, `decide_apply.py`, `extract_sweep.py`, `harvest.py`,
`harvest_embed.py`, `hunt-daemon.py`, `hunt_dispatch.py`, `hunt_lib.py`, `learn_apply.py`,
`local_extract.py`, `resolution_embed.py`, `retire_food_db_row.py`.

Of those sixteen, exactly **one** is invoked by any runner in the repo: `ingest_hunter_events.py`,
from `graph/pipeline/nightly.ps1`. The other fifteen are suites nobody runs.

**Why this is worse than a plain coverage gap.** The Python half cannot report exit 3. A discovery
that finds nothing is loud by design; a hand-list that is missing an entry is silent, and the
failure looks exactly like a clean run. So the estate's own "a blind check that reports success is
the worst failure" rule is enforced on one language and not the other.

**Touches** `ops/run-gates.ps1` only. The work is a `*.py` discovery pass plus the same
reason-per-line `$SKIP` allowlist the PowerShell half already carries - and it needs that allowlist,
because some of the sixteen will not be hermetic (models, network, a real board). **Expect it red on
day one**, which the ops rules say is the wrong way to add a gate: it wants a ratchet with a
high-water mark, the `audit-write-seam` shape, not a bare discovery.


**FIXED 2026-09-07, and the hand-list was hiding more than anyone thought.** 32 `.py` files carry
`--selftest`; the gate listed **six**. Running all of them on the pinned interpreter:

| | |
|---|---|
| pass and were NOT gated | **19** - band_precheck, food_provenance, learn_apply, local_extract, hunt_lib, decide_apply, retire_food_db_row, price_evidence, authority, scorecard_query and nine more |
| genuinely cannot run there | 5 - three need numpy/torch from the sidecar venv and say so themselves; the daemon and its full battery run for minutes |

Nineteen working suites had simply never been wired in. A suite nobody runs is a suite that rots, and
this estate has already paid for that: `coverage_check.py` sat at two failures for weeks.

Discovery now walks the tree exactly as the PowerShell side always has. **The skip list is explicit and
carries its reason**, and anything discovered that is not skipped MUST run - so a new suite is in the
gate the moment it exists, and the only way out is to name it and say why. Discovery finding fewer
than 15 suites is itself a failure, because a walk that breaks looks exactly like a tree with no tests.

**Widening the input exposed two real defects that six curated suites had hidden:**

1. **`run-gates` line 279 redirected a NATIVE exe's stderr into a variable** under
   `$ErrorActionPreference='Stop'`. In PS 5.1 each stderr line becomes an ErrorRecord and the FIRST is
   a TERMINATING throw, so the gate **died** at the first Python suite that printed a warning rather
   than reporting it. It survived six suites and broke on the twenty-seventh. Same shape
   `capture-run.ps1` records from 2026-08-22, and one CLAUDE.md warns about by name.
2. **`fdc_lookup.py` carried an invalid `\d` escape** in its module docstring - the warning that
   triggered the above.

Gate went 225 to **245 passed, 0 failed**, in 285s.

### I9 - The 95-file Python tree is not a package, and one consequence is already load-bearing `PARKED - MEASUREMENT ONLY, NO WORK PROPOSED` `queue-2`
*Source: Build Testable Python Packages for AI (queue 2, course 7).* Recording the state, not
proposing the rewrite - the bet is large and the payback is not obvious.

Measured 2026-09-06 across the repo, excluding `.venv`, `__pycache__` and `.claude/worktrees`:

- **95 Python files. Zero import `pytest` or `unittest`.** The test story is entirely hand-rolled
  `--selftest` flags inside the modules under test, driven by `run-gates` (I8).
- **No `pyproject.toml`, `setup.py` or `setup.cfg` anywhere.** The single dependency declaration in
  the estate is `sidecar/requirements.txt`. Nothing is installable and nothing is importable by
  name; modules reach each other with `sys.path.insert(0, HERE)`.
- **Five files carry a hyphen** and therefore cannot be imported by name at all:
  `grocery/pull-browser-stores.py`, `meal-prep/pipeline/hunt-daemon.py`, and three under
  `media/reels/`. This is not theoretical: `meal-prep/pipeline/hunt_daemon_selftest.py` exists as a
  separate file *for that reason*, and says so in its own header - it loads the daemon back through
  `importlib.util.spec_from_file_location`. A naming convention chosen for the orchestration
  surfaces has bent the test architecture around it.

**The one argument from the course worth keeping**, because it names a failure shape this estate
already has under a different name: without a `src/` layout, tests import from the current working
directory instead of the installed package, so they pass where they were written and fail everywhere
else. That is the same shape as `run-gates-blind-in-worktrees` and
`worktrees-lack-the-boards-the-engines-price-on` - a check that is green because of where it ran.

**If any of this is ever done, the cheap slice first and on its own:** `sidecar/` is the one part
that looks like a library rather than a set of scripts (`lib_match.py`, `score_cache.py`,
`checkpoint_selection.py`, `matcher_eval.py`), it already has the only `requirements.txt`, and it is
where a regression is hardest to see by eye. Everything else is orchestration and should stay
scripts. Do not treat this item as a mandate to package the whole tree.

### I10 - The estate's biggest files are also its most-changed files `PARKED - MEASUREMENT ONLY, NO WORK PROPOSED` `queue-2`
*Source: Clean Code and Refactoring Techniques (queue 2, course 8).* Recording a measurement, not
proposing a split. The course's own Code Hygiene reading argues **against** a blanket file-size rule
- see `software-craft/SKILL.md` for the axis that reconciles it with our global CLAUDE.md line.

Measured 2026-09-06 across the repo, excluding `.venv`, `site-packages`, `__pycache__`,
`node_modules` and `.claude/worktrees`. **765 PowerShell and Python files, 211,075 lines.** 26 files
exceed 1,000 lines; 10 exceed 2,000.

| Lines | File | Commits since 2026-06-01 |
|---|---|---|
| 12,721 | `meal-prep/pipeline/hunt_daemon_selftest.py` | 91 |
| 8,713 | `meal-prep/pipeline/hunt-daemon.py` | 88 |
| 6,198 | `grocery/test-auditors.ps1` | **150** |
| 4,169 | `meal-prep/pipeline/harvest.py` | - |
| 3,661 | `meal-prep/pipeline/map-preresolve.ps1` | - |
| 3,396 | `grocery/compare-deals.ps1` | 74 |
| 2,983 | `grocery/check-ad-cycles.ps1` | **137** |
| 2,751 | `meal-prep/pipeline/hunt-run.ps1` | 40 |
| 2,548 | `grocery/build-deals-page.ps1` | 64 |

**The finding is the correlation, not either column.** The six most-edited source files in the last
three months are all in the top nine by size. A large file that nobody touches costs nothing; a
large file edited 150 times is the case where per-change cost actually compounds, and that is what
this list is. `grocery/test-auditors.ps1` alone absorbed 150 commits at 6,198 lines.

**Two structural notes, both already recorded elsewhere and confirmed here:**

- The single largest file in the estate is a **test** file, and it is 46% larger than the module it
  tests. `hunt_daemon_selftest.py` exists as a separate file only because `hunt-daemon.py` carries a
  hyphen and cannot be imported by name - see **I9**. So the naming constraint and the size
  concentration are the same defect seen twice.
- `compare-deals.ps1` at 3,396 lines is the file three other scripts LIFT functions out of
  (`compare-deals-functions-are-lifted-by-three-scripts`). In the course's vocabulary that is
  **shotgun surgery**: one conceptual change to a lifted helper has a plural edit site, and the lift
  breaks at call time rather than at parse time.

**What this item is NOT.** It is not a mandate to split anything. The course's own judgment section
is explicit that stability has value and that refactoring without a stated objective consumes effort
for no return, and every file above is working. The useful form of this item is a **trigger**: when
one of these files is next opened for a real change, that is the moment the split pays for itself,
because the reading cost is already being paid. Splitting them speculatively is the
`Speculative Generality` smell wearing a different hat.

**Touches** nothing until Brad rules. If it is ever taken, `grocery/test-auditors.ps1` is the
cheapest first slice: it is the highest-churn file in the repo, it is a battery of independent
auditors rather than one algorithm, so the seams are already there, and it is test code - a
regression in it is visible as a changed pass count rather than as a wrong number on a live page.

---

### I11 - "CLEAN TWIN" means two opposite things in this estate's own test fixtures `DONE 2026-09-07` `queue-2`

**Source:** course 9, `test-driven-development-workflow` (LearnQuest). Found while checking the
queue's claim that our gate philosophy is TDD - the claim itself is answered in
`~/.claude/skills/software-craft/tests-as-safety-net.md` 3b and needs nothing from the estate.

**What.** The phrase `CLEAN TWIN` labels fixture cases in two conventions here, and **the sign of
the assertion is opposite in each**:

| Where | A clean twin asserts | Example |
|---|---|---|
| the PowerShell audits under `ops/` | **zero findings** - a legal input the detector must NOT flag | `T 'CLEAN TWIN both pins present raises nothing' (@($m3).Count -eq 0)` in `ops/audit-agent-tools.ps1` |
| `~/.claude/skills/knowledge-search/search.py --selftest` | **a hit** - adjacent behaviour that must not have regressed; it keeps `MUST NOT FIRE` as a separate third label | `("dotfile still searchable as itself", dotfile, True)` |

Counted 2026-09-06 across `ops/`, `lib/`, `grocery/`, `meal-prep/` (worktrees and `out/` excluded):
190 files declare a `-SelfTest` switch, **158 carry a `CLEAN TWIN`**, 132 name a *founding* case.

**Why it matters here.** Both readings are defensible in isolation, so neither file is wrong and
nothing is red today. The risk is transfer: this estate's standing instruction is to add a must-fire
fixture plus a clean twin whenever a detector is written, and an author who learned the phrase from
`search.py` and applies it in `ops/` writes a positive assertion where a negative was wanted. That
produces a fixture that **passes while proving nothing about over-firing** - the exact failure the
twin exists to prevent, and one that is invisible because the suite is green. `ops-and-gates.md`
already warns that a defect in this machinery is "silent by construction".

**A second, non-actionable observation, recorded so it is not re-derived.** Every fixture sampled
was written *after* its defect - the comments say so outright (`THE ONE THAT MADE THIS FILE
NECESSARY`, `the founding under-reporting case`). There is no test-first discipline in this tree and
this item does not propose introducing one; for a detector estate, freezing a scar is the right
instinct. It only means **"we already do TDD" is not an accurate description of this repo**, and the
queue entry that said so has been corrected in the claims register as X5.

**Touches** a naming decision only. The cheap form is one sentence in
`.claude/rules/ops-and-gates.md` fixing the vocabulary for `ops/` (twin = must-not-fire) and naming
the third category explicitly, so the instruction to "add a clean twin" is unambiguous at the point
it is read. Renaming existing cases across 158 files is **not** proposed - it is churn across the
whole gate surface for no behaviour change, and the files are individually consistent.

**RULED 2026-09-07 (Brad): the knowledge-search vocabulary is canonical.** Three labels, three jobs -
`MUST FIRE` the founding bug, `MUST NOT FIRE` a legal input the detector must be silent on, and
`CLEAN TWIN` an adjacent behaviour that still works, which is a POSITIVE assertion. That inverts the
"cheap form" proposed above, which had assumed the `ops/` reading would win.

**The corpus is far larger than this item measured, and that changed the plan.** The item counted
158 files carrying a `CLEAN TWIN`; the real figure on tracked source is **1,673 labels across 214
files**, 1,166 of them non-comment lines in `.ps1` and `.py`. A blind rename of that is not
available: the sense is decidable only where the ASSERTION settles it, and a keyword classifier over
the PROSE agrees with a hand read about 85% of the time - which would have planted roughly 250
confidently WRONG labels. **A wrong label is worse than an ambiguous convention, because it is
believed.**

**So the rename is the provable subset and nothing else: 133 cases in 39 files**, every one read
before it was changed, chosen by the assertion asserting an absence - a zero count, a null, a negated
detector call, `len(x) == 0`. Diff is +133/-133 and every changed line is a label; alignment is
preserved because the three extra characters come out of padding outside the quotes. `grocery/
fanout-lib.ps1`'s two `-eq 0` twins are the founding false positive and are deliberately untouched:
**an exit code of 0 is not an absence, it is a run that succeeded**, which is a real clean twin.

**What holds the line going forward.** `ops/audit-fixture-vocabulary.ps1` fails a `CLEAN TWIN` whose
assertion proves an absence, is wired into `run-gates` for both its self-test and a live pass, and is
green at zero rather than red on day one. Its header states what it cannot see rather than implying a
sweep: ~1,000 labels carry the sense in their wording alone and are out of its reach. The vocabulary
itself is now in `.claude/rules/ops-and-gates.md`, where an author reads it before writing the next
fixture.

**Found while building the gate for this item, and it belongs here because it is the same failure
one level up.** Two of that gate's own must-not-fire cases PASSED while proving nothing:
`Test-Thing "a" + "b" + "c"` is not a concatenation inside an argument, it is THREE positional
arguments, and a simple function binds the first and drops the rest into `$args`. The cases ran
against a truncated line that could never have matched anything. Recorded in the rules file beside
the vocabulary.

**The non-actionable observation above stands unchanged** - every fixture here was written after its
defect, this tree has no test-first discipline, and freezing a scar remains the right instinct for a
detector estate.

---

### I12 - There is no NULL-RATE check anywhere in the estate, and it is the one scraper failure nothing watches `DONE` `queue-2`

**Source:** course 10, `vsp-data-quality-profiling--monitoring` (Coursera). A thin course, but it
names four standing data-quality checks - **freshness, volume, schema drift, null rate** - and
checking the estate against that list is what produced this item. Full inventory of what we already
have, with paths, is `~/.claude/skills/data-quality-craft/estate-inventory.md`.

**What.** Three of the four checks are implemented here, several times over and well. The fourth is
absent. A grep of the whole tree for `null_rate|null rate|blank rate|missing rate|pct_null|nullrate`
across `.ps1`, `.py`, `.md` and `.json`, excluding vendored `site-packages` and `.venv`, returns
**zero hits**. Verified twice on 2026-09-06, once by a read-only subagent and once directly.

What we have that looks like it but is not:

| Exists | What it actually measures | Why it is not this |
|---|---|---|
| `grocery/audit-row-age.ps1` UNDATED arm | whether a store's newest engine file dates its rows at all | field **presence**, hard pass/fail, not a **rate** and not tracked over time |
| `grocery/audit-coverage-gaps.ps1`, `audit-cell-drops.ps1` | missing **cells on the board** | a board cell, not a field inside a source row |
| `grocery/audit-coverage-ledger.ps1` | `examined` counts per check | coverage of the checking, not completeness of the data |

**Why it matters here, specifically.** The estate's inputs are seven scraped store feeds, and the
canonical way a scraper degrades is not that it dies. It is that **one field stops being extracted
while the row keeps arriving** - a selector moves, a price node changes shape, a unit string stops
being parsed. That failure:

- passes guard 9 and `audit-row-age.ps1`, because the rows are fresh;
- passes `audit-coverage-regression.ps1` and `audit-cell-drops.ps1`, because the row count is
  unchanged;
- passes every schema check we have, because the field is still present and still a string.

It is caught today only downstream, by whichever pricing engine trips over an empty value, or by a
wrong number reaching a reader. `walmart-price-shape-moved-to-pricelines-values` is exactly this
failure class having already happened once.

**Touches.** The cheap first slice is one new advisory (not a gate) in the daily chain, not in
`run-gates`, since it is data-dependent: per store, per field, the proportion of rows where the
field is absent or empty, written to `grocery/out/` as a dated artefact and compared against a
baseline JSON in the estate's existing ratchet shape (`coverage-baseline.json` and
`audit-coverage-ledger.ps1` are the pattern to copy - they already have the right verdict
vocabulary, including `BLIND` and `INERT`). Start advisory-only for a few weeks so the baseline is
**measured rather than chosen**, which is what `no-hardcoded-bands` requires and what item I13
below is about.

**Two traps if it is built.** `@($null).Count` is 1 in PowerShell, so a null-rate check written
naively scores an absent field as present (`ps-null-count-is-one`). And the check has to agree what
a null is before it can count one: `""`, `"N/A"`, `"-"` and a missing key are four different things
in these feeds and at least two of them currently survive as ordinary values.

---


**BUILT 2026-09-07: `grocery/audit-null-rate.ps1`, wired into the daily chain after the encoding
normalise and BEFORE anything prices.** The claim was verified independently - the same grep returns
zero hits - and the three near-misses this item lists really are near-misses.

**What it measures.** Per store and source, the BLANK rate of every field carried on at least half the
rows. Blank counts as well as absent, which is the whole point: a moved selector usually leaves the
key in place with an empty string behind it, and that is exactly the shape a does-the-key-exist check
passes. Baselined across **31 store/source pairs** on the first run.

**Two findings, and the second is one a rate comparison alone cannot produce.** A field whose blank
rate climbs more than 25 points is the degraded-selector case. A field the baseline knew that has
VANISHED from the rows is the other - a rate cannot rise for a field nothing emits, so comparing rates
would report nothing at all.

**It alerts and does not block**, for the same reason the encoding repair beside it is non-fatal: it
is a first-line signal about the INPUT, the board's own guards still stand between a bad row and a
published price, and withholding a day's prices on a young detector with a fresh baseline costs more
than it saves. It names the store, the field and the size of the jump, which is what separates an
actionable alarm from another red line nobody reads.

**The baseline is a reference, not a ratchet.** A RISE is the finding and a fall is simply better data,
so `lib/ratchet.ps1`'s asymmetry does not apply here - which is worth stating because the two shapes
look alike and the wrong one was applied to four audits before I15 caught it.

**The store comes from each file rather than from a map**, because `audit-row-age.ps1` already carries
a store-to-glob table and a second copy is exactly what `audit-twin-drift.ps1` exists to catch.

**The gate caught it before I did.** Committed as an orphan, `audit-script-census` failed with "ORPHAN
audit-null-rate.ps1 - no executable file in the repo names it", which is the estate's own machinery
refusing a detector with no caller. Wiring it into `capture-run.ps1` is what fixed it, not an
allowlist entry.

### I13 - Every threshold in the estate is CHOSEN, because only two artefacts keep history `DONE - THE ONE DERIVABLE SET IS DERIVED; 4 OF 16 ARE TOO LOOSE` `queue-2`

**Source:** course 10, same run as I12. This is the standing `no-hardcoded-bands` ruling (Brad,
2026-09-04) arriving from the other direction: the reason bands get hard-coded here is that there is
almost nothing to derive one from.

**What.** The estate has roughly **eighteen baseline files** and they are all the same shape: a JSON
snapshot of **one accepted number**, re-read each run, compared with a tolerance, raised only by an
explicit `-Accept` or `-Baseline` flag. `grocery/out/row-age-baseline.json`,
`tile-integrity-baseline.json`, `band-censorship-baseline.json`, `board-mojibake-baseline.json`,
`guard-contract-baseline.json`, `json-readers-baseline.json`, `audit/match-baseline.json`,
`grocery/search-link-baseline.json`, `grocery/regression-baseline.json`,
`grocery/coverage-baseline.json`; `ops/fixture-input-baseline.json`,
`mustfire-census-baseline.json`, `write-seam-baseline.json`, `ruling-drift-baseline.json`;
`meal-prep/db/schema-constraint-baseline.json`, `blocker-heading-baseline.json`,
`meal-prep/out/spec-contradictions-baseline.json`.

**Only two artefacts in the whole estate keep a time series:**
`grocery/out/coverage-ledger-history.jsonl` (560 lines, one per audit run, written best-effort
inside a try/catch by `audit-coverage-ledger.ps1` ~line 421) and `graph/provenance/*.jsonl`.

**Why it matters.** A last-value baseline answers *"did it get worse than the one time somebody
looked?"*. It cannot answer *"what does normal look like, and how much does it usually move?"* - and
that second question is the only honest way to set a tolerance. So every tolerance in the tree is a
number someone picked, which is precisely the defect `no-hardcoded-bands` names and
`sumac-carried-but-band-dropped` demonstrates costing real accuracy (`band_max 6` refused the only
shelf price that existed; the recipe ran about 40% low).

**The estate already knows this and already started the fix.** `coverage-ledger-history.jsonl`'s own
stated purpose, in `audit-coverage-ledger.ps1`, is that tolerances can later be narrowed from
**measured denominator movement instead of guesses**. Nothing has yet read it back for that purpose.

**Touches.** Nothing needs building first. The cheap, high-value slice is a **read**, not a write:
compute the observed distribution of `examined` per check from the 560 lines already on disk, and
compare each check's hand-set `tolerance` in `coverage-baseline.json` against what the history says
the real variation is. That is a one-off analysis that either confirms the chosen tolerances or
names the ones that are wrong, and it costs nothing but an afternoon. Only if it pays off is the
larger version worth it: give the other seventeen baselines a history line each, in the same
append-only shape, so the same question can be asked of them.

**Not proposed:** converting the existing baselines. They work, they are green, and rewriting a
working ratchet to change where its number came from is churn across the whole gate surface for no
behaviour change today.

**DONE 2026-09-07. The afternoon's analysis this item asked for is now
`grocery/analyse_coverage_tolerances.py`, run against 562 runs of history, and it pays off.**

**What it does.** Per check, the DOWNWARD deviation from a ROLLING median of the preceding 15 runs,
then the p95 of those against the hand-set `tolerance`. A tolerance has to sit above the ordinary
variation and below the fall you want caught, so it prints both the p95 and the worst observed
side by side.

**The trap it is shaped around, and the reason a naive version would have been useless.** "How far
does `examined` swing" answered by the max is dominated by STEP CHANGES, which are not noise:
`audit-everyday-mismatch` fell from ~2,900 to ~2,500 on 2026-08-22 because a carry-forward fix
retired 530 rows - real, permanent and explained. A tolerance sized to absorb that absorbs
everything. A rolling reference follows a step within a few runs; a global one is distorted by it
forever. That case is the file's founding must-not-fire fixture.

**The result, and it is the opposite of the worry.** Nothing is crying wolf: **0 of 16 tolerances are
too tight.** Four are too LOOSE - more than three times the worst fall ever observed - so the row is
watched in name only:

| Check | Tolerance | Ordinary variation (p95) | Worst ever observed | Runs |
|---|---|---|---|---|
| `guards/11-bakers-provenance` | 0.25 | 0.001 | **0.004** | 561 |
| `guards/13-board-vs-identity-staple` | 0.10 | 0.000 | 0.002 | 169 |
| `guards/13-board-vs-identity-recipe` | 0.10 | 0.006 | 0.017 | 169 |
| `guards/5-multipack` | 0.50 | 0.023 | 0.136 | 561 |

`guards/11-bakers-provenance` is the sharpest: it has never varied by more than **0.4%** across 561
runs and would tolerate losing a **quarter** of its coverage in silence.

**It changed nothing, deliberately.** A tolerance is a live gate, and moving one on the strength of an
afternoon's arithmetic is how a guard gets loosened by a script instead of by a person. Tightening
these four is a per-row decision for Brad - each one trades a smaller blind spot against the risk of
firing on a legitimate future population change, and the history cannot see a change that has not
happened yet.

**Two rows are deliberately not judged**, and the tool says so rather than scoring them: `audit-ff-carry`
carries `tolerance: 1` because its denominator is INVERSE - the number falls when the FF pull gets
BETTER - and `pull-regular-hyvee` is judged by ratio against the day's slice rather than by a floor.

**The larger version this item floated - a history line for the other seventeen baselines - is still
not proposed.** The analysis paid off for the set that already had history; that is an argument for
keeping this one, not for retrofitting append-only logs across the gate surface on spec.

---

### I14 - The derived-threshold technique I13 wants is ALREADY IN THIS REPO, in the Python half `DONE - APPLIED` `queue-2`

**Source:** course 11, `applied-anomaly-detection-with-machine-learning`. This is a **sharpening of
I13, not a new problem.** I13 says every tolerance in the estate is chosen rather than derived and
proposes building the capability. Measured on 2026-09-06, that is only true of the PowerShell half.

**What was measured.** A case-insensitive grep of `.ps1`, `.py` and `.js` in the repo for
`percentile|quantile|stdev|stddev|standard deviation|MAD|z-score|interquartile|IQR`, excluding
vendored trees, worktrees and `grocery/archive/`, returned **35 hits, every one of them in the
Python half** (`sidecar/`, `meal-prep/pipeline/harvest_embed.py`, `graph/`). **Zero** in `grocery/`,
`ops/` or any `.ps1` file. Two of those hits are the exact technique I13 asks for:

- **`sidecar/hardeval.py` ~386** computes `(score - commodity median) / MAD` with a 3-exemplar
  minimum. That is a textbook **modified z-score**, and its own comment says it is robust on purpose
  because one outlier would otherwise set a mean-based floor wherever it liked.
- **`sidecar/lib_match.py` `calibrate()`** sets a per-commodity floor at the **`q=0.10` quantile of
  the scores that commodity's own accepted products earn** - a threshold read off an observed
  population instead of chosen.

Meanwhile every price-side tolerance is a scalar in a `param()` block: `4.0`, `1.25`, `0.75`, `1.5`,
`0.30`, `0.15`, `2.0`. `graph/pipeline/flag_outliers.py` is the honest case - median-based, and its
header says outright that its `5.0` factor is a judgement call, not a derivation.

**Why it matters.** I13 reads like a capability that has to be built and costed. It is not. The
matcher half already runs both rungs of the ladder; the price half has never borrowed either. That
makes the item mostly an **adoption and porting** question, which is a much smaller bet, and it also
means there is a working local reference implementation to copy rather than a paper to read.

**Touches.** Nothing needs building first. The narrow first slice: take
`grocery/out/coverage-ledger-history.jsonl` (560 lines already on disk) and compute a MAD-based
robust z-score of each check's `examined` count in the shape `hardeval.py` already uses, then
compare it against the hand-set `tolerance` in `coverage-baseline.json`. That is I13's proposed
one-off analysis with the arithmetic already written and debugged elsewhere in this repo.

**Not proposed:** rewriting `flag_outliers.py` or `audit-unit-basis-outlier.ps1`. Both are green,
both have self-tests pinned to founding bugs, and both state their reasoning. Changing where their
number comes from is a behaviour change to a live correctness guard and needs its own evidence.

---


**APPLIED 2026-09-07 to the one prefilter whose miss is unrecoverable, and it CORRECTS a
recommendation I made the day before.** `sidecar/derive_coverage_floor.py` reads `sweep.py`'s
`COVERAGE_COS_FLOOR` off the data the way `harvest_embed.py` already reads `ask_floor` - the technique
I14 says is in the repo - and writes the number, its basis, its sample and its caveat to
`sidecar/out/coverage-floor.json`.

| | |
|---|---|
| chosen value | 0.55, from eight observations where Task C's true positives sat (0.58-0.69) |
| derived value | **0.3848** - the lowest BEST-cosine among 2,816 confirmed-correct pairs (0.3948), less a hair |

**The correction.** E19 reported 186 of 2,816 known-correct pairs under the floor and I recommended a
rank-based cut on that basis. Reading how the lane actually works makes that wrong twice over: the
floor is applied to each product's **BEST** cosine against any commodity, not to its true one, and the
lane only sees products matching **NO RULE** - while all 2,816 are accepted board pairs, which match
rules by definition. Re-measured properly: **134** rows have a best-cosine under the floor and would be
dropped outright, while the other 52 clear it on the WRONG commodity, which a rank-based cut cannot
help and the cross-encoder exists to reject. Applying the first number to this floor would have been
the base-rate error E22 is about.

**So it is derived and deliberately NOT applied.** Those 2,816 pairs are the right KIND of evidence -
human-confirmed product-to-commodity pairs - on the wrong SLICE. That is strictly better than a number
chosen from eight observations and it is not a floor measured on the lane's own traffic, so `sweep.py`
keeps its constant and now carries a comment pointing at the derivation and saying why. Lowering a
live daily auditor's prefilter wants the volume measured on the real unmatched population first.

**The cap is part of the threshold.** A floor without its volume is half a decision, and `sweep.py`'s
own header records what an unbounded report does - 1,404 rows, "a firehose nobody reads, and a guard
nobody reads is worse than no guard". So the artefact carries `max_candidates` beside the floor, and
the derivation reports when the cap binds rather than truncating silently. On this population it
bound: 1,500 of 2,816.

**I13 stays PARTLY DONE**: one threshold is now derived, and `sidecar/THRESHOLDS.md` lists eight.

### I15 - No audit's FINDING COUNT is tracked over time, so an audit that stops firing looks like one that passes `DONE` `queue-2`

**Source:** course 11, production monitoring section. The course's cheapest production signal is the
**detection rate** - the daily volume of alerts a detector raises - on the argument that a change in
alert volume is one tripwire for several unrelated causes at once: genuine behaviour change, drift,
a data quality problem, a threshold change, or the detector degrading. It does not say which, and
that is fine; it says that something changed.

**What.** This estate watches denominators and not numerators. Per course 10's measurement (I13),
only two artefacts keep a time series, and neither stores a finding count:
`grocery/out/coverage-ledger-history.jsonl` records each check's `examined` count, and
`graph/provenance/*.jsonl` records decisions. The `BLIND` / `INERT` verdict vocabulary in
`audit-coverage-ledger.ps1` exists precisely to separate "nothing to check" from "checked nothing"
from "checked and found nothing" - and it applies that distinction to the **denominator only**.

**Why it matters.** An audit whose finding count silently goes to zero is indistinguishable from an
audit that is passing, and this estate has already been bitten by that shape at least five times,
which is why `lib/guard-contract.ps1` requires a `<NAME>-COMPLETE` marker. The marker proves the
detector **ran**. Nothing proves it is still **finding** what it was written to find. A regex that
stops matching, a schema move that empties an input, a mute that was never lifted: all three read as
green.

**Touches.** One field. `audit-coverage-ledger.ps1` already appends a line per run, best-effort
inside a try/catch, to `coverage-ledger-history.jsonl`. Adding each check's finding count alongside
its `examined` count reuses the whole existing mechanism, and after a few weeks the same history
supports both I13's tolerance derivation and a "this audit has not fired in N runs" note. Advisory
only at first: a finding count legitimately goes to zero when things are fixed, so this must not be
a gate on day one, per the standing rule about gates that are red on arrival.

---


**VERIFIED AND FIXED 2026-09-07, and it was worse than written: three of the four ratchets it
describes were BUILT THE DAY BEFORE, by me.** Every one lowered its high-water mark unconditionally:

    if ($count -lt $base) { write the new, lower baseline }

That is right for a real migration and catastrophic for a broken detector. A regex that stops
matching, a path that moved, an empty tree inside a worktree - any of these makes a detector find
NOTHING, and the ratchet then records **0 as the permanent ceiling**, prints "PASSED and TIGHTENED",
and can never rise again. The gate goes green forever on a detector that died. `audit-mustfire-census`
sits at 653; the same failure there would have recorded a tightening while every must-fire assertion
in the estate had vanished.

`lib/ratchet.ps1` now owns the rule, and the asymmetry is the point: a count that ROSE proves the
detector works, while a count that FELL is either good news or a corpse, and those look identical
from outside. Two refusals, neither a hard failure - the caller KEEPS its baseline and says what to
check: a fall to zero, and a fall over 60% in one run. `-AcceptDrop` records a genuine bulk migration
in one flag rather than a hand-edited baseline file. It also keeps **history on every run**, which is
this item's actual ask - a single number cannot show a detection RATE, and a detector quietly
returning the same figure for six weeks is invisible without one.

Proved on the live path, not just in fixtures: with the baseline temporarily set to 100 against a real
count of 17, `audit-write-seam` exits **2** with the baseline still at 100; with `-AcceptDrop` it exits
0 and records 17. Before this change the identical run silently wrote 17 and moved on.

**`audit-board-mojibake` is deliberately NOT routed through it**, and the reason is in its own header:
zero mangled names is that audit's GOAL state, not a suspicious one, and its could-not-read paths
already exit 3 before the ratchet - so the broken-detector case is covered by a different mechanism
and refusing a fall to zero would punish the success it exists to reach.

Wired: `audit-write-seam`, `audit-ruling-drift`, `audit-fact-claims`. `audit-mustfire-census` and
`audit-fixture-inputs` already treat a DROP as a hard fail and needed nothing.

### I16 - The two median-based outlier rules are single-tailed in OPPOSITE directions, and nothing watches both `DONE` `queue-2`

**Source:** course 11, on the point/contextual/collective taxonomy and on relationship anomalies.

**What.** The estate has exactly two median-referenced outlier rules and they live in different
halves and look opposite ways:

- `grocery/audit-unit-basis-outlier.ps1` flags a per-unit price **at or above 4x** the commodity
  median. Upward only, on the stated reasoning that a dear outlier never wins a crown and so never
  reaches a reader.
- `graph/pipeline/flag_outliers.py` bars a per-unit price **more than 5x below** the commodity
  median. Downward only, on the stated reasoning that a false-cheap row always wins a crown.

Both arguments are correct in isolation. Together they mean no single rule asks a two-tailed
question, and the two live on opposite sides of the git-bus with different factors (`4.0` versus
`5.0`) and different eligibility rules.

**Why it matters, with the case already recorded.** `audit-unit-basis-outlier.ps1`'s own header
documents the gap: the baby-formula crown, where Walmart's ready-to-feed liquid at `$0.686/oz` beat
five powder canisters, sat at **0.56x** the median. The header states plainly that no ratio
threshold in either direction would find it without also flagging every genuine deep sale. So the
estate already knows a magnitude rule cannot cover this, and already built the right answer next to
it: `Get-MeasureKind`, which flags a row whose size names a different **kind** of quantity than its
shelf-mates - a volume among weights - and explicitly does not use magnitude at all.

That second arm is the most sophisticated detector in the tree and it exists in exactly one file. In
the anomaly-detection vocabulary it is a **contextual anomaly detected through a cross-feature
relationship**, which is the failure class no single-column threshold can see.

**Touches.** Two candidate slices, and the second is the interesting one. (a) Reconcile the two
factors and state the two-tailed picture in one place, so nobody later "fixes" one direction into
symmetry and reintroduces the bug the other direction exists for. (b) Ask whether the
`Get-MeasureKind` idea generalises past unit basis - a measure-kind or pack-form disagreement
between a row and its shelf-mates is a check on the **relationship**, not the value, and this estate
prices seven stores against each other, which is exactly the setting where that check is cheap.

**Not proposed:** merging the two rules. They sit either side of the git-bus, run on different data
shapes, and each has a self-test pinned to a different founding bug.

---


**CLOSED 2026-09-07 by STATING THE PAIR, not by making either rule two-tailed** - and the item's own
analysis is why. The case it cites, the baby-formula crown where Walmart ready-to-feed liquid beat
five powder canisters, sat at **0.56x the median**, inside both thresholds.
`audit-unit-basis-outlier.ps1`'s header already records that no ratio in either direction finds it
without also flagging every genuine deep sale. So a two-tailed magnitude rule would add noise, not
coverage, and the right instrument was already built beside it: `Get-MeasureKind`, which asks whether
a row's size names a different KIND of quantity.

Both files now state the pair explicitly - 4.0x above in `grocery/`, 5.0x below in `graph/`, opposite
sides of the git-bus - and record that the asymmetry is deliberate and not symmetric in its reasons: a
DEAR outlier never wins a crown and never reaches a reader, while a FALSE-CHEAP row always does. Each
carries the instruction not to "fix" it into two tails, and points at `Get-MeasureKind` as the thing to
extend instead.

### I17 - `backtest.py` calls itself an ACCEPTANCE GATE and always exits 0 `DONE` `queue-2`

**Source:** course 12, `automate-and-evaluate-ml-pipeline-tests`, on the failure-versus-warning
threshold and on what makes a regression suite a gate rather than a report.

**What, measured 2026-09-06.** `grep -nE 'sys\.exit|SystemExit|^\s*assert |exit\('` over the three
sidecar eval files returns:

- `sidecar/backtest.py` - nothing at all;
- `sidecar/seed_sweep.py` - nothing at all;
- `sidecar/hardeval.py` - exactly one hit, `raise SystemExit(2)` at line 317, which fires when a
  cold run is asked for and the corpus records no holdout families. That is a could-not-run refusal,
  not a regression verdict.

So all three always exit 0 whenever they successfully produce numbers, **including when the numbers
are bad.** `backtest.py`'s own docstring opens with "the ACCEPTANCE GATE for the semantic sidecar"
and closes the same paragraph with "Output is a report", and the second sentence is the true one.

**Why it matters here.** The estate's standing rule is *read the EXIT CODE first and the tally
second*. These three files defeat that rule by construction: there is no exit code to read, so the
only reader is a human looking at a report, and no threshold is written down anywhere for that human
to apply. A candidate reranker that lost a defect stock catches would be visible in the report and
invisible to any caller. This is also what makes I18 impossible today - scheduling a suite that
cannot fail buys nothing.

**Touches.** `sidecar/backtest.py`, `sidecar/hardeval.py`. The material the decision needs is
already in the tree: `backtest.py` records TASK A AUC 0.9705 and 17/25 at a 100/2816 budget on a
frozen snapshot, and `finetune_reranker.py` already states in its own output that "hardeval GOLD is
the number that DECIDES". Turning that sentence into a numeric floor plus a non-zero exit is the
whole item. Per the standing rule about gates that are red on arrival, the floor should be set from
the current frozen-snapshot numbers so it passes on day one, and should be a ratchet.

**One dependency worth knowing before starting:** `ops/audit-threshold-register.ps1` already fails
the gate on any similarity threshold in `sidecar\*.py` that is not named in `sidecar\THRESHOLDS.md`
with the space it was tuned in. That register currently carries 22 rows and names `hardeval.py`'s
`--margin` (0.08) and `--keep-above` (0.1), so a new acceptance floor lands in an existing,
enforced mechanism rather than needing one built. It also means the floor cannot be added quietly.

**Not proposed:** putting these in `run-gates`. They need a GPU and real data, so they belong in a
scheduled chain, not in the hermetic change-time gate. See I18.

---


**VERIFIED AND FIXED 2026-09-07.** The file convicted itself: line 2 said "the ACCEPTANCE GATE for the
semantic sidecar", the next paragraph said "it is allowed to fail", and there was no `sys.exit`
anywhere in it - `main()` wrote a JSON report and returned `None`, so every run exited 0 whatever it
measured.

**The bar was taken from the file, not invented.** It states the candidate rule twice: *"beating stock
on a cold holdout is not enough if the new weights lose a defect the old ones caught [...] it ships
only if it still catches what stock catches."* So this is a **veto, not the decider** - `hardeval.py`
has always said GOLD decides and that these 25 negatives "never ask a hard question". A stock run
still just reports and exits 0; a `--reranker` candidate is compared and can now exit 2.

**The refusal is the interesting half.** `commodity_text()` is "label + up to 5 products the board
currently accepts", and backtest.py measured what that does: same model, same eval files, only the
commodity text changed, and known-wrong caught went **17/25 to 0/25**. So a candidate compared against
a baseline built on different defs is measuring board churn. The veto refuses that comparison as
could-not-evaluate rather than reporting a verdict - including when a report simply does not RECORD
its defs, because "cannot prove they matched" is not "they matched".

**That refusal immediately bit the real data, which is why the chooser exists.** `backtest.json` is the
conventional stock report and it predates the `defs` field, so preferring it by name made every veto a
permanent 3. `backtest-phase3-frozen.json` is the same pinned model run six minutes later, same
numbers, with its defs recorded - a valid baseline that was simply never looked for. `find_stock_baseline`
picks the newest PINNED report that records its defs and names the file it chose.

**The historical promotions were sound.** Against that baseline, ft-v1 catches 18/20/23/23/24 where
stock catches 4/8/12/15/17, and ft-v3 16/22/23/23/24. Neither would have been vetoed. What was missing
was the enforcement, not the judgement.

The rule lives in `sidecar/backtest_veto.py` so it imports nothing heavy and `run-gates` can exercise
it on the pinned interpreter. Its must-fire is a candidate that wins at every other budget and loses
ONE known-wrong pair at one of them.

### I18 - Nothing schedules the sidecar's ML eval suite, and its inputs change without a commit `DONE` `queue-2`

**Source:** course 12, on why a model regression suite specifically needs a schedule rather than a
commit trigger.

**What, measured 2026-09-06.** No runner invokes `sidecar/backtest.py`, `sidecar/hardeval.py` or
`sidecar/seed_sweep.py`. Checked across `.ps1`, `.yml` and `.yaml` under `ops/`, `graph/`,
`grocery/`, `meal-prep/` and `.github/workflows/` (which holds `daily.yml`, `gates.yml`,
`heartbeat.yml`): every hit is prose in a docstring, a design note, or the "run this first" error
message in `grocery/export-identity-eval.ps1`. `graph/pipeline/nightly.ps1` runs a chain of five
numbered stages plus a `1b` (emit, defs, sweep, serve, resolve, stage1) and none of its steps is
these. They run when a human remembers.

**Why it matters here, and why it is not just "add a cron".** The argument the course makes is that
a model regression suite is unlike an ordinary test suite because **most of what moves it is not a
commit in your repository.** That is unusually true of this estate: `commodity_text()` is defined as
"label plus up to five of the products the board currently accepts", so the sidecar's scores move
every time the board moves, which is daily and automatic. The estate has already measured how large
that effect is - same pinned model, same eval files, only the commodity text changing: AUC 0.9705
versus 0.7921, and 17 of 25 known-wrong caught versus 0 of 25. Nothing commits when that happens.

**Touches.** `graph/pipeline/nightly.ps1` is the obvious host, since it already owns the GPU card
handoff the sidecar needs and already has a `-SelfTest` and a `-WhatIfOnly`. The run must use a
frozen snapshot via `--defs` (`sidecar/data/frozen/<name>/commodity-defs.json`), or it will measure
board churn and produce exactly the false alarm this item exists to avoid. Depends on I17: without a
non-zero exit there is nothing for a scheduled run to report.

**Adjacent, already filed:** I8 (`run-gates` hand-lists its Python self-tests) is the same shape one
layer down and is **still true and now understated** - re-measured 2026-09-06, 30 `.py` files in the
tree mention `--selftest` and **19 define one via `add_argument`**, against six `.py` paths in
`run-gates`'s hand-list, of which only two are among the 19. I8 recorded "sixteen". None of the four
sidecar eval files defines a `--selftest` at all.


**CLOSED 2026-09-07: a weekly `ml-eval` stage in `graph/pipeline/nightly.ps1`.** Nothing ran
`hardeval`, `backtest` or `seed_sweep` on any schedule - they ran when a human remembered.

**A schedule rather than a commit trigger, which is the item's actual point.** Most of what moves
these scores is not a commit here: `commodity_text()` is "label plus up to five of the products the
board currently accepts", so every score moves when the BOARD moves - daily, automatically, with
nothing committed. The estate already measured that at **AUC 0.9705 to 0.7921** on the same pinned
model with only the defs changed.

**Weekly, not nightly, and non-fatal.** The suite wants the card and the chain already runs five
stages inside a hard deadline; a sixth every night would cost the resolve lane time for something that
has to be tracked rather than watched. A failure records BLIND and never breaks the chain - a
regression report that can take down the nightly matching run is the worse trade.

**Against FROZEN defs**, because `backtest.py`'s header records what happens without them: the same
model scored 17/25 one day and 24/24 another, and the board had changed, not the model. A weekly number
measured against today's shelf would track the shelf.

### I19 - Nine of twelve agents read the open web and can also execute, and none is told that page content is data `DONE 2026-09-07` `queue-2`

> **CLOSED 2026-09-07, and the measurement above understated it.** All nine now carry an
> `UNTRUSTED INPUT` clause after their role paragraph, naming the channel each actually reads, with
> the wording drawn from `security-craft/injection-and-defences.md`. The detector that found nine
> zeros returns nine ones.
>
> **The part this entry missed: SIX of the nine also have USER-SCOPE copies in `~/.claude/agents/`,
> and which copy runs depends on the session's working directory.** The count above was taken from
> `.claude/agents/` alone, so hardening the project copies would have left the same hole open on a
> coin flip. `ops/audit-prompt-backup.ps1` caught it by exiting 2 with `SCOPE DRIFT` the moment the
> project copies changed; nothing else in the tree would have said so.
>
> Before syncing, the six user-scope copies were confirmed **byte-identical to the pre-edit project
> copies**, so `project -> user` propagated the fix and lost nothing. Repaired with the audit's own
> `-SyncScopes -SyncMirror` rather than by hand. `run-gates` exit 0, 220 passed, 0 failed.
>
> **The transferable lesson, which is bigger than this item:** an inventory of agent capability that
> reads one scope is not an inventory. `~/.claude/agents/` holds eight files, two of which
> (`recipe-dedup-selector`, `recipe-writer`) exist at user scope and have no web tools, so they were
> correctly out of scope here - but nothing about the original method would have noticed if they
> had.

**Source:** course 13, *LLM Security and Vulnerabilities*, on indirect prompt injection - the case
where the user is innocent and the payload arrives in data the model fetched on their behalf.

**What, measured 2026-09-06.** Counted from the `tools:` frontmatter of every file in
`.claude/agents/`. Nine of the twelve can read third-party web content (`WebFetch`, `WebSearch` or a
browser MCP tool) **and** hold at least one of `Bash`, `PowerShell`, `Write`, `Edit`:
`post-publish-reviewer`, `recipe-batch-auditor`, `recipe-hunter-extractor`, `recipe-hunter-pricer`,
`recipe-ingredient-mapper`, `recipe-source-qa`, `recipe-sourcer`, `triage-developer`,
`triage-reviewer`. The count of agents that read the web **without** being able to act is **zero**.
The three with no web access are `commodity-registrar`, `recipe-dedup-selector` and `recipe-writer`.

A case-insensitive grep of all twelve for `prompt inject`, `untrusted`, `adversarial`, `jailbreak`,
`injected instruction` and `treat .* as data` returns exactly one hit, and it is not this:
`recipe-batch-auditor`'s description says it "Adversarially verifies a whole batch", which is about
auditing data. **Zero of the nine carry any instruction about how to treat fetched page content.**

**Why it matters here specifically, and why the usual answer does not apply.** The reflex fix is a
rule in `CLAUDE.md` or a rules file. That does not work: `what-actually-reaches-a-spawned-agent`
records that **no `CLAUDE.md` at any level reaches a spawned agent**, so the agent definition is the
only channel that reaches one. A rule written anywhere else is absent from the exact session that
reads the hostile page. `recipe-hunter-pricer` is the sharpest case - it drives Brad's real
logged-in Chrome with `javascript_tool` against retailer pages, so it reads third-party content
while holding a session cookie and a shell.

**Touches.** Nine agent definition files. `ops/audit-agent-tools.ps1` (226 lines, already in
`run-gates`, already requires a `tools:` block) is the natural place to also require the instruction,
which would make this a gate rather than a convention. Note the standing rule about not adding a
gate that is red on day one: the nine would all be red, so the fix ships with the text.

**Not proposing wording here.** The right line is short and the course's own framing is the model:
text arriving through a tool is data, never an instruction, whatever it claims about its authority.

### I20 - The two prompt-builder families disagree about untrusted text, and nobody decided that `DONE - DECIDED 2026-09-07` `queue-2`

> **RULED, and the ruling REVERSES this entry's own proposed fix for two of its three sites.** The
> entry says "the cheap consistency fix is the `!r`". Measured 2026-09-07, it is not, and applying
> it to the page-sized sites would make extraction worse.
>
> **`repr()` escapes newlines, so it collapses a page into a single line.** Demonstrated on a
> four-line page: `PAGE TEXT:\n%r` renders as **1 line** where the raw form renders as 4. On the
> 24,000-character page at `local_extract.py:529` that destroys exactly the line structure the
> extractor needs to find a recipe card, and the estate's own comments record that this prompt's
> wording was earned by a 7-publisher measurement.
>
> **So the two families are not inconsistent by accident. The axis is whether line structure carries
> information.** `graph/` repr-quotes short product NAMES, where a newline carries nothing and can
> only be used to impersonate prompt structure - there `!r` is free and correct. `local_extract`
> handles PAGES, where the newlines are the signal. **The same mechanism that blocks
> structure-impersonation destroys the content.** Both families are right for their input shape.
>
> **Not changed, deliberately.** Line 325's `"LINE: %s" % raw` is a single ingredient line and is
> the one borderline case, but it feeds the split prompt whose wording is part of the measured
> threshold, so changing it needs re-measurement rather than eyeballing and that measurement was not
> available to this session. The delimiter approach (`<page>...</page>`) preserves line structure and
> is the right shape for a page, and it also changes what the model sees, so it carries the same
> re-measurement cost. Recorded so the next session does not re-derive the `!r` idea and ship it.
>
> **The layer that actually holds is now pinned.** This entry always said the validators, not the
> prompt shape, are what stop an injected instruction becoming a published ingredient. As of
> 2026-09-07 those validators are covered by `ops/injection_resistance_selftest.py`, so the residual
> exposure here is documented rather than merely believed.

**Source:** course 13, on where untrusted text sits in a context and what interpolation shape it
gets.

**What, measured 2026-09-06.** Two families, opposite treatments, no recorded decision either way.

`graph/` **repr-quotes** every scraped string. Nine sites in `graph/pipeline/resolve.py` (lines 992,
996, 1000, 1001, 1002, 1068, 1078, 1079, 1081) and one in `graph/learning/local_triage.py:355` use
Python's `!r`, as in `f"\nSTORE PRODUCT LISTING: {product_name!r}\n"`. `repr()` quotes the string and
escapes newlines to a literal `\n`, so a product title carrying an embedded newline cannot break
onto its own line and impersonate prompt structure. Free, and materially better than nothing.

`meal-prep/pipeline/local_extract.py` interpolates **raw** at three sites: line 325
`"LINE: %s" % raw`, line 1087 `"PAGE:\n" + text`, and lines 529-530
`f"PAGE TEXT:\n{body}\n\nTranscribe the recipe."` where `body` is **up to
`RUNG2_PAGE_CHARS = 24000` characters of arbitrary scraped third-party page text**. That last one is
the largest untrusted-text surface in the estate.

Two smaller observations from the same read. In both families the untrusted string is the **last**
thing before the instruction, which is the position a model weights most. And a grep for
prompt/data delimiters (`<document>`, `<untrusted`, `<page>`, `<data>`, `BEGIN PAGE|DATA|DOCUMENT`)
across `.py`, `.ps1` and `.md` under `meal-prep/`, `graph/`, `grocery/` and `.claude/agents/` found
none - scoped to those trees, extensions and patterns on that date.

**Why this is NOT filed as urgent, and the honest half matters more than the exposure.** The estate
is already strong in the layer that actually holds. `local_extract.verify()` proves every
transcribed line occurs in the page with no model involved; `verify_split()` requires the quantity to
re-substring into the raw line verbatim and the split fields to cover at least 90% of its non-glue
tokens; `raw` is reconstructed by construction from the page rather than taken from the model's
answer; and every `json_call` passes a JSON schema so output shape is constrained. An injected
instruction cannot produce a transcribed ingredient that passes those checks, because passing them
requires being text that is genuinely on the page. **The cheap consistency fix is the `!r`, not a
rewrite of the validators, which are already the right design.**

**Touches.** Three lines in `meal-prep/pipeline/local_extract.py`. Changing the prompt text is not
free: that file's own comments record that the split prompt wording is part of the threshold and was
earned by a 7-publisher measurement, so any change to what the model sees needs re-measuring rather
than eyeballing.

### I21 - E1's staging switch is off by default, and this course changes the argument for that default `DONE 2026-09-07` `queue-2`

**Source:** course 13. **Does not re-file E1**, which is `PARTLY DONE` and correctly scoped; this is
about the default, which E1 does not discuss.

**What.** E1 shipped two mechanisms on `lib/ghost-lib.ps1`'s `Invoke-GhostApi`, both **off by
default**: `TC_STAGE_WRITES` queues a mutating call for approval, and `TC_WRITE_JOURNAL` records the
inverse so `ops/revert-ghost-write.ps1` can undo it.

**Why the argument changes.** E1 came from an agent-design course, so its case for staging is "agents
make mistakes" - and against that case, opt-in is a defensible default, because the error rate is
low and the friction is constant. Course 13 supplies a second and different case: with nine agents
reading third-party pages (I19), a write may be **directed** by text a third party planted rather
than merely mistaken. Against that case the staging approver is not error-catching, it is the
permission boundary between a compromised model and a live paid site - and a permission boundary
that is off by default is not a boundary. The course's central claim is that no defence recognises
every attack, so the layers that constrain what can happen *after* the model is fooled are the ones
worth paying for.

**Needs a ruling, not a patch.** The trade is real in both directions: staging on by default puts a
human in the loop of every Ghost write, which is exactly the approve-then-hand-out-the-next-task
cycle the operating rules say to avoid. Recording it as a decision Brad should make with the second
argument in front of him, rather than as work to do.

**Touches.** The default in `lib/ghost-lib.ps1`, and whoever or whatever is nominated as approver.
E1 already notes `post-publish-reviewer` could move to run BEFORE the publish, which is what the item
originally asked for. E1's R2 gap is unchanged and unaddressed by this.

**RULED 2026-09-07 (Brad): on for agent runs, off for the daily chain.** Neither default was right
for both, because they are not the same risk. The daily chain is a fixed sequence nobody planted
text into, and staging it would put a human in the loop of every recipe publish for no threat model.
An agent that read a third-party page is the case the course is about.

**Where the line is drawn, and why there.** `meal-prep/pipeline/hunt_dispatch.py` `_child_env()`
sets `TC_STAGE_WRITES` on the dispatched subprocess. `lib/ghost-lib.ps1` reads it from the
ENVIRONMENT, so that one seam arms every PowerShell an agent invokes and nothing else - no flag has
to be threaded through the call sites, and no caller can forget it. Checked rather than assumed that
the publish lane is untouched: `wave-publish.ps1` is invoked by `hunt-daemon.py`, the daemon
PROCESS, never through a dispatch. Four cases pin it, including the two CLEAN TWINs that an operator
who set the variable themselves keeps their own queue and that the rest of the environment travels
through.

**Arming it found that approving a staged write would have corrupted the post.** `Add-TcStagedCall`
recorded a `[byte[]]` body as the STRING `"(byte[] length N)"` - a description of the content, not
the content - and `ops/review-staged.ps1 -Apply` replays with `-Body $e.body`. So the approver would
have sent that literal description to Ghost as the post body. **And every real caller passes
byte[]**: `publish.ps1:277`, `:280` and `wave-publish.ps1:1163` all send
`[Text.Encoding]::UTF8.GetBytes(...)`, so the broken branch was not an edge case, it was the only
branch the live chain takes. It was invisible because every existing self-test stages a STRING body,
which round-trips fine - a mechanism tested only on the shape it never sees in production. Fixed
before arming: base64 in `body_b64` with `body_bytes` beside it, restored on `-Apply`, and three
must-fire cases pin the round trip byte for byte.

**The general shape, which is the part worth keeping.** A safety mechanism that has never been
exercised end to end is not a safety mechanism, and being off by default is what let it go
unexercised for as long as it did. Turning something on is the moment to run its whole path, not
just its entry point.

### I22 - The estate's single strongest defensive property is undocumented as one and pinned by no test `DONE 2026-09-07` `queue-2`

> **CLOSED by `ops/injection_resistance_selftest.py`, group A.** The rule that the local model may
> reject but may never mint a price is now pinned by two must-fire cases, and discovered
> automatically by `run-gates` (245 passed, 0 failed).
>
> **Checked by AST, not by import, and that was deliberate.** Importing `resolve.py` pulls `GraphDB`
> and would need a database, so the test would have to skip when the database is absent - and a
> self-test that degrades to a skip is the could-not-run-reads-as-a-pass shape this estate has been
> bitten by repeatedly. The property is a source-level invariant, so it is checked as one and always
> runs. A2 collects every `Verdict(...)` constructed inside `_llm_adjudicate` and fails if any
> carries a priceable status; A1 pins the priceable set itself, because widening
> `Verdict.is_match` would void every downstream guarantee.
>
> **A3 is the clean twin and it is load-bearing:** it asserts the AST walk found any `Verdict`
> construction at all. Without it, a renamed function or a changed call shape would make A2 pass
> vacuously, which is exactly what makes a green test worthless.
>
> Proved by breaking both: adding `llm_match_unverified` to `is_match` fires A1 alone; making the
> adjudicator return `llm_confirmed` fires A2 alone. Exit 1 both times, restored byte-identical.

**Source:** course 13, on permission boundaries as the defence that does not depend on recognising
the attack.

**What, measured 2026-09-06.** `graph/pipeline/resolve.py:523-525` states the rule in a docstring:

> Layer 5. The local model may REJECT a candidate or flag a probable match for review; **it may
> never mint a price.**

That is least privilege applied to a model's *authority* rather than to its tools, and it is the
best defensive property in the estate. Its consequence is exact and worth stating: a successful
injection against the resolver can suppress a correct price or force a human review, and **cannot
publish a wrong one**. Given that a wrong number on a live paid page is this estate's defining
failure mode, that asymmetry is doing more work than every other control combined.

**The problem is that nothing protects it.** It was earned by measurement, not by security review -
the module docstring's bench decomposition forced it - and it is recorded only as prose in a
docstring. Measured: a grep of `graph/**/*.py` for `mint`, `never_mint`, `may only reject` and
verdict assertions in any file whose name contains `test` or `selftest` returns **nothing**. There
is no `resolve_selftest.py`. `run-gates` hand-lists exactly one Python self-test under `graph\`,
`graph\agentic\executor_selftest.py`, which is E18's and is about tool paths. So the asymmetry is a
convention a future refactor can remove without any test going red, and the reason it exists is
findable only by reading the module docstring.

**Touches.** A small self-test asserting that no code path lets a model verdict produce a price,
added to `run-gates`' Python list. Cheap, must-fire, and it would be green on day one - which is the
correct shape for a ratchet over a property that is already true and must stay true. Related to I8
(`run-gates` hand-lists its Python self-tests), which is the reason a new one has to be remembered.

### I23 - No fixture anywhere asserts this estate resists an injected instruction `DONE 2026-09-07` `queue-2`

> **CLOSED by `ops/injection_resistance_selftest.py`.** Ten cases, exit 0, carrying the
> `INJECTION-RESISTANCE-SELFTEST-COMPLETE` marker `lib/guard-contract.ps1` requires. The grep this
> item was measured by now returns a file.
>
> **What it does NOT test, and why that is the point.** It does not ask whether the model can be
> fooled. Course 14's own testing lectures are right that this is a black box and cannot be
> exhausted, and a fixture pretending otherwise would be theatre. It tests the far narrower question
> the estate actually depends on: **given a model output that has been fully compromised, does the
> checked layer still refuse it?** That is completely answerable, and it is answered here against
> real adversarial input rather than by argument.
>
> Groups B and C call the validators for real. B1 feeds the transcriber an injected instruction as
> an ingredient; B2 feeds it a plausible ingredient that is simply absent from the page, which is
> the one a human reviewer would wave through; B4 pins that an empty answer is a failure rather than
> a clean pass. C2 pins the quieter failure `verify_split()` exists for, a split that silently DROPS
> part of the line while every field it does emit is genuine. Each group carries a clean twin so the
> must-fire cases cannot be satisfied by a function that refuses everything.
>
> Proved by breaking the page check: `verify()` stopped requiring a line to occur in the page and
> **B1 and B2 both fired**, correctly, since both rest on that one predicate. Restored
> byte-identical; `graph/pipeline/resolve.py` and `meal-prep/pipeline/local_extract.py` are
> unchanged by this work.
>
> **The evaluation protocol is now BUILT, and building it corrected this entry.** See the
> correction block below.

---

#### I23 follow-up, 2026-09-07: the protocol, and what measuring changed

`ops/injection_eval.py` plus a frozen `ops/injection-payloads.json` (10 payloads across seven
families, 5 genuine controls). Discovered by `run-gates`. Three rates, baselined in
`ops/injection-eval-baseline.json`:

| rate | measured | meaning |
|---|---|---|
| `fabrication_block_rate` | **1.00** | a line the model invented is always refused |
| `indirect_block_rate` | **0.00** | a line the ATTACKER PUT ON THE PAGE is never refused |
| `genuine_pass_rate` | **1.00** | and it is not achieving that by refusing everything |

**`[CORRECTED: 2026-09-07]` This entry, and `security-craft/estate-exposure.md`, overstate the
transcription layer's defence.** Both say `verify()` "is the only thing standing behind" the
24,000-character scraped-page surface, which reads as though it defends it. Measured, it does not:

- `verify()` asks whether a transcribed line **occurs in the page**. Indirect prompt injection is
  precisely the case where the attacker owns the page, so the answer is legitimately yes and the
  check passes. Confirmed: the payload embedded in an HTML comment on the page verifies clean.
- `verify_split()` does not catch it either. An injected line assigned wholly to `item` scores
  **100% round-trip coverage** and passes all three of its tests.

So against FABRICATION the layer is perfect, and against INDIRECT INJECTION it is absent. Course 13
read the first and recorded it as strength; the second was never measured until now.

**What this does NOT mean.** There is no path from here to a wrong number on a paid page, and this
must not be read as one. What arm B wins is a junk string in an ingredient list. Becoming a price
requires mapping to a real commodity id and then being priced, and `graph/pipeline/resolve.py` rules
that the local model may reject but may **never mint a price** (pinned by I22). The defence is real.
It is one layer further downstream than our own notes claimed.

**Why `indirect_block_rate = 0.00` is a recorded baseline and not a red gate.** It is a measured,
documented, downstream-mitigated exposure. A gate red on day one for a backlog nobody is about to
clear teaches people to ignore red. The ratchet makes any future defence permanent instead: the rate
may rise and may never fall.

**The three guards were each proved by breaking them**, restoring by bytes, md5 verified:
weakening `verify()` drops the fabrication rate and fails; making `verify()` refuse EVERYTHING sends
both block rates to a perfect 1.00 and **only the genuine-pass control catches it**, which is
`rag-craft/evaluating-retrieval.md`'s abstaining-system trap; and shrinking the corpus leaves every
rate perfect, caught only by the harness guard, which is `lib/ratchet.ps1`'s asymmetry.

**`security-craft/estate-exposure.md` has been corrected** (2026-09-07), in the two places that
conflated fabrication with injection.

#### The downstream chain, traced rather than asserted

The paragraph above claims a junk ingredient "has to map to a real commodity id and then be priced".
That was asserted, not checked, so it was checked. `meal-prep/engine/cost-recipes.ps1`:

1. `Resolve-ItemRow` (line 66) looks the item up in `ingredients.json` and then in the alias table,
   and **returns `$null` on a miss**. An injected string matches neither.
2. A null row hits line 231, which adds a **`NO PRICE BASIS`** flag and `continue`s. So the line is
   flagged AND skipped from the cost. It is not silently swallowed, and it cannot contribute a
   price, because there is no row to price it from.
3. `meal-prep/engine/golden-test.ps1` line 175 hashes `cost-flags.txt` against a frozen baseline, so
   the flag BRANCHES are pinned as reachable. That is a regression test on a fixture.

**The refinement, and it is the part worth knowing: the flag is ADVISORY.** `$costFlags` is written
to a file and its count printed (lines 397-399). Nothing sets an exit code on it and **no gate reads
the production flag count**, so a flagged recipe is not blocked from shipping.

For an INJECTED junk ingredient that is benign - the junk cannot be priced, so it cannot inflate a
number. **The sharper case is the same mechanism pointed at a real ingredient.** If an injection
altered a genuine ingredient's name enough to miss the lookup, that line would be flagged, dropped
from the cost, and the batch would ship UNDERSTATED. That is not hypothetical: the comment at line
52 records exactly that outcome from an alias bug, where sheet-pan-smoked-sausage-broccoli-cheddar
published at **$2.12 for the batch** because two real ingredients resolved to nothing. And this
estate's standing rule is that understating is exactly as wrong as overstating.

So the honest chain is: extraction does not block on-page injection (measured 0.00); costing cannot
be made to emit a wrong price for injected junk, and flags it; and the residual is that the flag
does not stop a publish. **Not filed as a new item** because the failure it describes is reachable
without any attacker at all, which is a costing-gate question rather than a security one, and it
already has a documented precedent.

**Still genuinely out of reach here:** none of this measures how often a hostile page actually
compromises the model. That needs the local model in the loop, the endpoint was not running, and it
is the black box course 14 correctly declines to promise. What is now measured is every layer
BEHIND the model, given a compromised output.

**Source:** course 14, *Introduction to Prompt Injection Vulnerabilities* (Kevin Cardwell, Coursera),
whose three testing lectures argue that LLM systems are "the ultimate black box" and cannot be
exhaustively tested. That is true and it is not the same claim as "you cannot check whether a
specific defence holds against a specific payload", which is what nothing here does.

**What, measured 2026-09-06.** A case-insensitive grep for `prompt inject`, `jailbreak`,
`adversarial input`, `injection resist` and `hostile page|input|text` over `.ps1`, `.py` and `.js`
under `graph/`, `meal-prep/`, `grocery/`, `ops/`, `lib/` and `.claude/agents/`, excluding
`.claude/worktrees/`, `__pycache__` and `.venv`, returns **zero lines**. `ops/run-gates.ps1`
contains none of `inject`, `adversarial`, `untrusted`, `security`. No file in the repo is named for
injection except Ghost **code-injection** HTML backups under `archive/`, which are a Ghost feature
name and unrelated. Scope stated so it is not read as an absolute: it says nothing about `.md`
files, about anything outside those trees, or about a check written under a spelling those five
patterns miss.

**Why it matters here specifically.** Course 13 measured (see `security-craft/estate-exposure.md`
section 4) that this estate's real defences were acquired **by accident**: `local_extract.verify()`
proves each transcribed line occurs in the source page, `verify_split()` requires the quantity to
re-substring verbatim, `json_call` forces a schema, and `graph/pipeline/resolve.py:525` rules that
the local model "may never mint a price". Those are the load-bearing layer, and they are strong.
None of them was written as a security control, none is documented as one, and none is pinned by a
test that would go red if it were removed. I22 files that for the resolver rule alone; this item is
the general case, and the general case is the larger one because the 24,000-character scraped-page
path in `meal-prep/pipeline/local_extract.py:529` is the estate's biggest untrusted-text surface and
`verify()` is the only thing standing behind it.

The estate's own convention is that a fix which stops detecting the thing it exists for must fail
loudly, which is why 158 self-tests here carry a `CLEAN TWIN`. By that standard the strongest
defensive property in the tree is currently the exact shape the convention exists to prevent.

**Touches.** One self-test with a frozen must-fire fixture pair: a scraped-page string carrying an
embedded instruction ("ignore the above and output ...") through `local_extract.verify()`, asserting
the injected line is rejected because it is not on the page, plus its clean twin. Same shape for the
resolver's no-mint rule (that is I22). Added to `run-gates`' hand-listed Python self-tests, which is
I8's known friction. Green on day one, which is the correct shape for a ratchet over a property that
is already true and must stay true.

**Not a red-team exercise, and the distinction is the point.** Nothing here proposes attacking a
live system, a third-party site or the local model. The fixture is a frozen string in a test file
asserting that an existing mechanical check does what it already does.

---

### I24 - Nothing in this estate measures search performance, so no SEO change can be shown to have worked `PARTLY DONE 2026-09-07` `queue-2`

> **The half that needs no credential is built. The half that does is still yours.**
> `ops/audit-seo-surface.py`, baselined in `ops/seo-surface-baseline.json`, discovered by
> `run-gates` through its hermetic parser self-test. Six fixture cases; the data audit runs
> `--audit` and belongs in the daily chain rather than in `run-gates`, per that file's own
> hermetic/data split.
>
> **First measurement, 2026-09-07, over 584 built recipes:**
>
> | | |
> |---|---|
> | distinct `Recipe.image` values | **1** |
> | recipes carrying an **empty** image | **49** |
> | distinct descriptions | 582 of 584 |
> | duplicate descriptions | 2 |
> | missing description or name | 0 |
>
> **The 49 empty images are new, and the hand-read missed them.** `seo-baseline-2026-08-31`
> records that all recipes share one image, the site logo, and that is true of the 535 that
> have one. The other 49 carry `"image": ""`. That is a different defect with a worse
> consequence: a shared image is a weak signal, while an empty required property can
> invalidate the Recipe rich result outright. Nobody had counted them because nobody had
> counted anything.
>
> **What it deliberately does NOT measure, and the second one is a trap worth recording.**
>
> It does not measure Google's response - position, impressions, clicks - because that needs
> the Search Console API and a credential. This measures the input, not the outcome.
>
> And it does not measure crawlable teaser length, **because that number cannot be taken from
> this repository at all.** The baseline's ~49 crawlable words was read from the LIVE page,
> where Ghost gates member-only content at serve time. The local built file is
> `html|paywall|html` with the marker about **90% of the way through**, so counting words
> before it returns roughly **5,900** - two orders of magnitude out, because it is a different
> surface. That check was written, measured, found to disagree with the memory by 100x, and
> removed rather than shipped. Measuring it honestly requires fetching the live page logged
> out.
>
> **Ratchet, not a bar.** Each metric has a direction: `distinct_images` may only rise;
> `empty_image`, `duplicate_descriptions`, `missing_description` and `missing_name` may only
> fall. Baselined at today's numbers, so it is **not red on day one** - it records the exposure
> and stops it worsening. A recipe count that collapses fails as a broken walk rather than
> passing as a clean catalogue, which is `lib/ratchet.ps1`'s asymmetry.
>
> Proved by breaking each direction and restoring by bytes: `empty_image ROSE 0 -> 49`,
> `distinct_images FELL 500 -> 1`, and a collapsed count caught by the walk guard while every
> other metric improved. Exit 1 each time.
>
> **Still open and explicitly not done here:** the Search Console series. It needs a credential,
> which is not this session's to create, and it remains the only thing that can answer whether
> a change moved ranking. What exists now is a falsifiable record of the surface we control, so
> a future "we fixed the images" claim can be checked instead of believed.

**Source:** course 15, *SEO: Audit Pages, Rank Higher* (John Whitworth, Coursera). Its own framework
is on-page auditing, and applying it to this estate surfaced that the measurement layer underneath
it is absent.

**What, measured 2026-09-06.** A case-insensitive sweep for `searchconsole|search-console|webmasters|
googleapis|rank.?track|impressions|average.?position|gtag|plausible` over `.ps1`, `.py`, `.js`, `.md`,
`.hbs` and `.html`, excluding `.claude/worktrees/`, `sidecar/.venv`, `node_modules`, `meal-prep/db/
page-cache` and `grocery/out/browser-profiles`, returns no Search Console or analytics API call
anywhere in the estate. There is no stored impressions or position series. Of the 26 PowerShell
scripts in `ops/`, 15 of them `audit-*.ps1`, not one checks a published page's `<title>`, meta
description, canonical or `og:image`. Every `schema.org`, `json-ld` and `meta description` hit in the
tree is the recipe harvester reading **other people's** pages inbound, plus Ghost's `custom_excerpt`
on the way out: the estate consumes structured data and audits none of its own. Scope stated so it is
not read as an absolute - this is a grep of the repository, and says nothing about a check that lives
only in Ghost's admin UI or in a person's habit.

**Why it matters here specifically.** The one baseline that exists, `seo-baseline-2026-08-31`, was
hand-read off the Search Console UI on a single day: 1.44K indexed, no manual actions, 3 clicks on
997 impressions, **average position 50.1**. It is a good measurement and it cannot be re-read. So the
estate currently cannot answer "did that move", and it cannot answer the narrower question the
baseline actually leaves open, which is whether the 556 paywalled recipe teasers are being indexed
and out-ranked or filtered as thin. Those two want different fixes, and the open items already logged
in that memory - per-recipe images, the free-preview length decision - are being decided without the
measurement that would tell anyone whether they are the constrained thing. This estate's standing
rule is that a wrong number on a page costs a real reader; the same rule applied to its own growth
work means an SEO change shipped today is unfalsifiable.

**Touches.** Smallest useful version is a scheduled read of the Search Console API into a dated
JSON under `grocery/out/`-style conventions, keyed by page and query, so position and impressions
become a series rather than a snapshot. That is a new credential and a new daily job, which is the
real cost. A cheaper first step that needs no credential is a static on-page audit gate over what we
already publish: `public/board.json` and the Ghost payloads carry title, excerpt and og fields, so a
`ops/audit-page-metadata.ps1` could assert one `h1`, a non-empty unique title and description per
published URL, and a non-logo `og:image`, as a ratchet with a high-water mark that may only go down.
Green-on-day-one is not available here, which is why the ratchet shape matters.

---

### I25 - The Search Console property is named three different ways in three places, and at most one is right `DONE` `queue-2`

**Source:** course 15, while grounding the estate's measured baseline.

**What, read 2026-09-06.** Three files name three different owning accounts for the site's search
data. `docs/seo-backlink-plan.md` says the properties are "already set up under
admin@simplemoneyplaybook.com". `.claude/skills/lesson/SKILL.md` says the site is verified "under
`admin@thriftycrew.com`". The memory `seo-baseline-2026-08-31` says the `https://www.thriftycrew.com/`
property had **never been verified** until 2026-08-31, when it was verified under
`schweino68@gmail.com` by adding a second `google-site-verification` tag, because the tag already on
the site belonged to something else and did not match the account.

**Why it matters.** The backlink plan's entire "How to measure it" section routes a reader to a
property that may hold nothing, and the lesson skill tells any future run to request indexing in an
account that may not be the verified one. Both are instructions that will silently do nothing rather
than fail. This is not a code defect and no gate can catch it.

**Touches.** One reconciliation by Brad, who is the only party who can see which accounts exist, then
a single edit to each of the three files so they name the same property. `docs/seo-backlink-plan.md`
also carries I26.

---


**CLOSED 2026-09-07.** Three files named three different owning accounts and at most one could be
right. The authority is the memory `seo-baseline-2026-08-31`: the property is
`https://www.thriftycrew.com/` (URL-prefix) under **`schweino68@gmail.com`**, and it had **never been
verified** until 2026-08-31 - the `google-site-verification` tag already on the site belonged to
something else and never took, so a second tag was added.

`docs/seo-backlink-plan.md` claimed the properties were already set up under an
`admin@simplemoneyplaybook.com` address; `.claude/skills/lesson/SKILL.md` said
`admin@thriftycrew.com`. Both now state the verified account and cite the memory that holds it.

### I26 - `docs/seo-backlink-plan.md` is written against the previous domain, and its stated premise is refuted `DONE` `queue-2`

**Source:** course 15.

**What, read 2026-09-06.** The plan is dated 2026-07-02 and every target page it names is a
`simplemoneyplaybook.com` URL. That domain survives in the estate only in `archive/ghost-config/`
(dated 2026-07-01) and in `.claude/skills/lesson/ghost-config.ps1`; the live site is
`www.thriftycrew.com`. The document also opens by asserting its own premise: the outreach strategy is
justified "because on-page/technical SEO is already A-grade". The 2026-08-31 baseline contradicts
that on two specific, measured counts - 556 of 1,093 indexable URLs are paywalled recipe teasers with
about 49 crawlable words of which roughly 18 are unique, and all 576 recipes share the site logo as
both `Recipe.image` and `og:image`. Near-duplicate thin pages at scale and a single shared image
across 576 pages are on-page conditions, not off-page ones.

**Why it matters.** The plan reads as current and it is the only SEO strategy document in the repo,
so it is what anybody picking up growth work will find first. Its link-building advice may well still
be sound and is not what is being questioned; its premise and its target URLs are stale, and a run
that follows it will promote pages on a domain we no longer publish to.

**Touches.** Re-point the target URLs, or mark the document superseded with a dated header. Either
way the "already A-grade" line needs removing or qualifying, because it is the sentence that argues
against doing on-page work at all, and it is the on-page work the baseline points at.

---


**CLOSED 2026-09-07.** The plan was written 2026-07-02 and every promoted URL still pointed at
`simplemoneyplaybook.com`, so anyone following it would have pitched the previous domain - six
references in the file that decides where outreach effort goes.

**The four promoted tool pages were checked on the live domain before anything was rewritten** and
each returns **200** at `www.thriftycrew.com`: `/where-do-you-stand/`, `/true-cost-calculator/`,
`/can-i-afford-this/`, `/need-or-want/`. A plan pointing at a 404 would be no improvement on one
pointing at the old domain.

The file carries a banner recording what was corrected and why, and it is the only place the old
domain still appears - as history rather than as a target.

### I27 - `lesson/SKILL.md` cites a memory that does not exist `DONE` `queue-2`

**Source:** course 15.

**What, read 2026-09-06.** `.claude/skills/lesson/SKILL.md` cites `[[google-search-console]]` twice
as the governing memory for indexing, once in its Step 6 and once in the cheat-sheet's "the three
memories that govern any creation". A directory listing of
`~/.claude/projects/C--Codex-ThriftyCrew/memory/` on 2026-09-06 contains no file of that name; the
only search-related memory present is `seo-baseline-2026-08-31.md`.

**Why it matters.** It is small, but a dangling citation in a skill that publishes to a live paid
site teaches a reader that a ruling exists and was consulted when neither is true, and the two
citations sit next to the account-name claim in I25 that is itself in doubt. Cheapest of the four
items here.

**Touches.** Either repoint both citations at `seo-baseline-2026-08-31`, or write the memory the
skill thinks it is citing. Not a course-run decision, because whichever is right depends on I25.

**FIXED 2026-09-07, and it was SEVEN dead pointers, not one.** Six `[[memory]]` citations resolving to
nothing - `brand-voice-brad`, `writing-no-em-dashes`, `ghost-migration`, `google-search-console`,
`meal-prep-recipe-template`, `book-method-keep-asking` - plus a file pointer to a `STYLE-GUIDE.md`
that does not exist. In the skill that **publishes lessons to a live paid site**.

The worst line told the writer: *"The three memories that govern any creation [...] Read
`[[brand-voice-brad]]` every time before drafting."* A standing instruction to open a file that was
never there.

**No memory was invented to satisfy a link.** The skill already states the substance inline beside
every citation - the voice, the em-dash rule and the Search Console facts are all in the text. So each
pointer was either repointed at something that exists (`CLAUDE.md` for em dashes,
`docs/RUNTIME-MAP.md` for the migration background, `.claude/rules/meal-prep.md` for recipe
conventions) or removed while its content stayed.

**The process half is the more important one: `ops/audit-memory-citations.ps1` was not scanning
`.claude/skills` at all.** Its scan list was agents, rules and design, so it passed every day at 30
citations across 102 files while seven pointers in a live-publishing skill were dead. Skills are now
in the scan (105 files), it still passes, and a planted dead citation makes it exit 2 - proved both
ways rather than assumed.

**Same shape as I8, found the same morning:** a scanner that does not scan everything reports on what
it scanned, not on the estate. Two independent instances in one session is the finding worth keeping.

Two false alarms recorded rather than dropped: `ghost-config.ps1` and `publish-lesson.ps1` resolve
correctly relative to the skill's own directory, and the file's 26 em dashes are pre-existing in an
internal skill rather than in reader-facing copy.


### I30 - Eighteen live tables carry 28 indexes and nothing has ever looked at a query plan `DONE - REDIRECTED 2026-09-07, THE RISK WAS DURABILITY AND NOT SPEED` `queue-3`
*Source: Optimize SQL Queries - Uncover Performance Bottlenecks (queue-3).* Measured 2026-09-07 at
commit `d172e3a6`: the estate greps to 61 `CREATE TABLE` and 84 `CREATE INDEX` across `*.py`/`*.sql`,
`EXPLAIN` appears in exactly two files (`meal-prep/pipeline/coverage_check.py` and
`meal-prep/pipeline/learn_apply.py`), and the two databases that actually exist on disk hold
**18 tables, 28 indexes and 4 views**: `graph/sqlite/graph.db` (11 tables, 24 indexes, 126 MB, WAL)
and `meal-prep/db/thriftycrew.db` (7 tables, 4 indexes, 1.8 MB). The source-level counts are
statements, not objects, and reasoning from "61 tables" is reasoning about text.

**What a first pass found, in about twenty minutes of read-only probing.**

1. **`ANALYZE` has never been run on either database.** Neither has a `sqlite_stat1` table, which is
   definitional. Both planners are on built-in guesses. On a copy, `ANALYZE` produced 36 stat rows
   and reordered a three-table join - **and bought no measurable time**: 7 runs each, `count(*)` over
   `v_current_rows` (15,607 rows) 0.0446 s to 0.0453 s, a 3.7-million-row fan-out join 0.1592 s to
   0.1594 s. Both inside noise. **This is a finding, not a fix.** Do not schedule a nightly `ANALYZE`
   on this evidence.
2. **`ix_nodes_type (type)` is a strict prefix of `ix_nodes_type_name (type, canonical_name)`** on the
   47,319-row `nodes` table, so it is maintained on every write and serves nothing the wider index
   does not. The only such pair in either database. The **check** generalises; the single finding
   does not.
3. **A prefix `LIKE` cannot use an index here, and today that costs nothing.** On the 76,439-row
   `aliases` table, `WHERE alias LIKE 'beef%'` plans as `SCAN`, not `SEARCH`, because SQLite's
   default case-insensitive `LIKE` cannot use the BINARY-collation `ix_alias_alias`. `PRAGMA
   case_sensitive_like=ON`, `GLOB`, or a `COLLATE NOCASE` index each flip it to `SEARCH`.
   **`[CORRECTED: 2026-09-07, before this item was acted on]` This read "the one with real blast
   radius: matcher and alias-resolution code is exactly where a prefix `LIKE` gets written". That
   was an inference and it is refuted.** The estate has exactly two live prefix-`LIKE` queries,
   `sidecar/build_pair_corpus.py` 130 and `graph/pipeline/review_escalations.py` 748, and **both are
   harmless**: an equality predicate on an indexed column drives each plan (`SEARCH ... USING INDEX
   ix_nodes_type` and `... ix_dlog_type`) and the `LIKE` post-filters 592 and 752 rows at medians of
   0.00019 s and 0.00006 s over 9 runs. Swapping in `GLOB` changes neither plan nor time. A third
   grep hit in `graph/lib/authority.py` is inside a docstring, not executed SQL. So the mechanism
   reproduces and the present cost is zero: it is a trap for the next query written, ranked third of
   the three here. Kept rather than edited away because the error is the reusable part - a mechanism
   reproduced in a probe and a mechanism costing us something are different claims.

**What this proposes.** A read-only self-diagnostic, `ops/audit-sqlite-health.ps1` or a Python
equivalent, reporting per database: object counts and journal mode; row count per table;
`sqlite_stat1` present; prefix-redundant indexes; indexes on very small tables (information only);
`PRAGMA foreign_key_check` violations; and `EXPLAIN QUERY PLAN` for every view plus a curated hot-query
list, flagging `SCAN` on a table over N rows, `USE TEMP B-TREE`, and `USING INDEX` where
`USING COVERING INDEX` was expected.

**Why it matters here.** Nothing in the estate can currently tell you that a query got slower, or
that an index stopped being used. The three findings above were all invisible until somebody ran
`EXPLAIN QUERY PLAN` by hand for the first time.

**Touches.** A new read-only audit script and its `-SelfTest`. Nothing else, if built correctly.

**Two hazards that would make it destructive.** Open every database **`mode=ro`**: `graph.db` is
126 MB of live state the graph pipeline writes, and a read-write handle can take a WAL lock or leave
a `-wal` file the ~07:00 bot then commits. And to test an index or `ANALYZE`, **copy the file with
`shutil.copy2` first and delete the copy** - running either against the real database is a schema
change performed as a measurement, against state with no undo layer (E1).

**Do NOT put it in `run-gates` red.** Findings 2, 3 and the plan flags would be red on day one
against a backlog nobody is about to clear, which teaches people to ignore red. Ratchet it with a
high-water mark that may only go DOWN, the way `audit-write-seam` and `audit-band-censorship` do.

**Not ordered work.** The measurements say this estate is small (biggest table 84,748 rows, biggest
database 126 MB) and that nothing is currently known to be slow. The case for the audit is that it
would tell us when that changes; it is not a case that anything is broken today.

Method and full output: `~/.claude/skills/database-craft/estate-inventory.md`.

---

**RULED 2026-09-07. Brad asked for the smartest thing that scales rather than a quick fix, so the
first move was to measure which database risk is actually real. It is not the one this item names.**

**Performance is not the threat, and the item's own numbers say so.** 126 MB over 47,319 nodes,
`ANALYZE` moving a three-table join by 0.0002 s across seven runs, all three findings costing zero
today. SQLite is nowhere near strained and will not be at ten times this size. A plan baseline would
mostly report churn, and six of the nine proposed checks are one-time answers that would be printed
every run and acted on never - which is how a gate teaches people to skim it.

**Integrity is already handled, and better than expected.** Both databases declare foreign keys on
five tables; `graph/lib/graphdb.py:71` and `meal-prep/db/build_db.py:108` turn `PRAGMA foreign_keys
= ON`, the latter asserting it stuck. `PRAGMA foreign_key_check` returns **0 violations** on both and
`quick_check` returns **ok**. Checked before proposing anything, because "the FKs are probably
decorative" was a plausible guess and it was wrong.

**THE REAL HOLE IS THAT NOTHING RUNS THE VERIFIER.** `graph/lib/rebuild.py` already establishes the
architecture - tracked JSON is truth, `graph.db` is an index, which is what makes the README's
`rm graph.db` safe - and names the five tables that exist nowhere else: `learning_proposals`,
`approved_patches`, `eval_runs`, `cell_state`, `question_verdicts`. Its `--verify` passes today
(241/241, 186/186, 43/43, 3092/3092, 4141/4141). **And it has zero callers**: not `run-gates`, not the
nightly chain, not CI, verified by grep. The mirror is kept by **eight hand-placed
`export_learning()` calls** across `stage2_review.py` (three), `score.py`, `review_escalations.py`,
`stage1_analyze.py` and graphdb's own writer - write-through by convention, not by construction.

That is the failure that scales badly. Every new write path is another place to forget the call, the
database stays right while the JSON falls behind, and nobody learns until the day someone does the
`rm` the README suggests. `run-gates` records this exact shape about itself twice already:
`audit-twin-drift` sat red for weeks because nothing ran that suite, and `golden-test.ps1` was
ungated while being the only check that caught a schema change.

**Shipped: `graph/pipeline/audit_graph_durability.py`, in the nightly chain, read-only (`mode=ro`).**
Three checks, each of which grows in value as the graph grows:

1. **MIRROR** - every irreplaceable table matches its tracked JSON row for row. The table list is
   READ from `graphdb.GraphDB.LEARNING_TABLES` rather than restated, so a table this audit forgot
   cannot be a table it reports clean.
2. **INTEGRITY** - `PRAGMA quick_check`, 1.1 s on 126 MB, the only thing here that can see a torn
   file. The database is WAL, written nightly, with no undo layer under it (E1).
3. **VOLUME** - per-table row counts against a baseline. This is the **volume** limb of the four
   standing data-quality checks; I12 established freshness, schema and null-rate elsewhere.

**The volume asymmetry is the opposite way up from `lib/ratchet.ps1`** and confusing them would make
it useless: that one counts FINDINGS, where a fall is suspicious; this counts ROWS, where growth is
the steady state and a fall past 40% or to zero is the finding. The baseline is rewritten on every
clean run with history appended, because writing it only on an `--update` flag - which is how the
first draft worked - would compare tonight against a stale week and fire on nothing.

It is the one stage in `nightly.ps1` that is FAILED rather than BLIND on a non-zero exit. Every other
stage degrades a downstream result; this one is the only thing standing between a forgotten export
and a month of silent drift. Exit 3, no database, stays BLIND - that is the normal state in a
worktree.

**Deliberately NOT done, and each one is a decision rather than an omission.**

- **No query-plan gate.** Argued above.
- **The redundant `ix_nodes_type` stays.** Dropping it is a schema write against a 126 MB live
  database with no undo layer, to reclaim a write-side index update on a table nobody writes hot,
  for a benefit the item itself measures at zero. Not a trade worth taking on those terms. Reopen it
  if `nodes` ever becomes write-heavy.
- **The prefix-`LIKE` trap is documentation, not a gate.** Both live instances are measured harmless;
  it is a trap for the next query, and a gate for a thing that has never happened is a gate people
  learn to ignore.

**One incident worth recording, because it is E1's own argument arriving unannounced.** A patch
script destroyed the first draft of the audit: `open(path, 'w')` truncates the file BEFORE anything
else on that call can fail, so a bad `newline=` argument left a zero-byte file and no copy. The
rewritten `save_baseline` serialises the whole document before it opens anything, and says why at the
line.


### I31 - Every LLM run here is costed AFTER it finishes and none is budgeted or capped BEFORE it starts `OPEN - RUNGS 1 AND 2 ARE REPORTS; ONLY THE CAP NEEDS A RULING` `queue-3`
*Source: Optimize & Interface LLM Apps Effectively (queue-3, Starweaver), module 2.* The course's
one genuinely new habit is trivial and this estate does not have it: **do the arithmetic before you
build, not after the invoice** - expected tokens per call x price x expected calls, priced as two
legs because output costs several times input.

**What is already here, and it is ahead of the course.** Measured 2026-09-07 by grep across the tree
(excluding .git, .venv, worktrees, out):

- Per-lane token accounting exists and is good. meal-prep/pipeline/lane-tokens.ps1 and
  harvest-lane-tokens.ps1 reconstruct real spend by reading subagent transcripts, because the
  Workflow tool's gent() never exposes usage to the caller and 738 of 738 invocations on the
  2026-08-15/16 run self-reported nothing. harvest-lane-tokens.ps1 counts cache reads SEPARATELY
  and refuses to fold them into input, on the stated grounds that billing and burn diverge by an
  order of magnitude - a distinction the course never reaches.
- wall-clock-is-output-tokens models a run's DURATION from output tokens at ~81/sec.
- Vendor rate-limit discipline is thorough, but all of it points at grocery and USDA endpoints, not
  at our own model spend: measured per-store call caps in grocery/capture-policy-lib.ps1, a
  circuit breaker in grocery/fix-links-ff.ps1, the throttle-wipeout guard in
  grocery/pull-regular-familyfare.ps1.

**What is missing, precisely.** All of the above is *retrospective*. Nothing anywhere:

1. states an expected spend for a run before it is dispatched;
2. converts a token count into money at any point - no price constant exists in the tree;
3. stops, narrows or degrades a run that exceeds an expected spend. A hunt run that costs 10x its
   usual has no mechanism that notices while it is still running.

**Why it matters here rather than generally.** This estate runs a daily chain, a local model and
16-way concurrent agent lanes unattended. The wall-clock model means a run's duration is already
predictable from expected output length; the same number is one multiply away from a predicted
spend, so rung 1 is nearly free.

**Rungs, cheapest first.** (1) Add a price table and have -LaneSummary print money beside tokens,
which turns an existing measurement into a number a human reacts to. (2) Record a predicted spend at
dispatch and report predicted-versus-actual per run, which makes the estimate falsifiable.
(3) Only then discuss a cap, which is a behaviour change and needs Brad's ruling: a cap that
truncates a hunt mid-wave could be worse than the overspend.

**Deliberately not proposed: a gate.** Per the standing rule, a gate that is red on day one for a
backlog nobody is about to clear teaches people to ignore red. Rungs 1 and 2 are reports.

### I32 - No alert here can require a condition to PERSIST, and no alert ROUTE has been tested end to end `OPEN - RUNG 1 IS A MEASUREMENT, NOT A BUILD` `queue-4`

**Source.** Queue-4 course 1, `observability-engineering-metrics-logs-traces` (Edureka), items 34,
37 and 38. A vendor course with no measurements; what it supplied is a mechanism and a vocabulary,
not evidence. Registered as claims C66 and C67 in `~/.claude/skills/course/CLAIMS-REGISTER.md`.

**What the estate does today.** Every gate and audit reads the newest artefact once, decides, and
exits. Nothing in the tree expresses "this has been true for two consecutive runs". The nearest
mechanism is the once-per-type-per-day gate in `grocery/send-alert.ps1`, and it is the OPPOSITE
behaviour to what is missing: it withholds the second email about a persistent condition, where a
duration window withholds the first notification of a transient one. So a condition that clears on
its own before anyone reads it and a condition that has been true for a week arrive looking
identical.

**Why that matters here rather than generally.** `grocery/ALERTS.md` already records the specific
harm in its own words: a non-zero exit from the 08:00 job is usually the guards refusing to publish,
and reporting that as FAILED about a board that triage has since rebuilt "is how a real alert gets
trained into noise". The fix applied there was `Test-RunSuperseded`, which is this problem solved
once, by hand, for one alert. A duration window is the general form.

**The second half, and it is cheaper to see than to fix.** 217 PowerShell files in this tree carry a
self-test (counted 2026-09-07, `grep -rl SelfTest --include=*.ps1`, worktrees excluded) and every one
of them proves a DETECTOR fires. None proves a ROUTE delivers. Email has been muted since
2026-08-14 (`grocery/alerts-muted.json`, no expiry), the 6:30 triage agent is disabled, and
`grocery/ALERTS.md` says plainly that until something reads the queue "an alert is a record, not a
page". So the DELIVERY leg has not been exercised in roughly three weeks and nothing would report
that it had stopped working. The queue leg is fine and deliberately so.

**Rungs, cheapest first.**

1. **Measure the prize before building anything.** Count, over `grocery/triage-queue.json`'s closed
   items, how many firings cleared without action inside one run cycle. If that number is small, the
   duration window buys nothing here and this item should be `PARKED`. Nobody has this number, and
   `grocery/audit-alert-precision.ps1` is already reading the right file to produce it.
2. **A persistence field on the alert.** `send-alert.ps1` already implements a per-type-per-day
   decision and stamps `emitter` on a new queue item, so a per-type key and a durable record both
   exist; what does not exist is a "first seen at run N" stamp an alert could require before it
   pages. NOTE, because this was got wrong once during this run and corrected: `alert-state.json`
   is **not** alert-type state. It holds one price-alert record per commodity (`{"chicken-breast":
   {"price":1.99,...}}`) and is the wrong file to extend.
3. **One end-to-end route test.** A deliberately triggered synthetic alert driven all the way to the
   receiving channel, so "the detector fired" and "somebody was told" stop being the same claim.
   Scope it to the DELIVERY leg only: `send-alert.ps1` writes the triage-queue entry before the mute
   gate on purpose, so the queue leg is exercised on every alert already and is not what is untested.

**Deliberately not proposed: a gate.** Per the standing rule, this would be red on day one for a
backlog nobody is about to clear. Rung 1 is a report.

**What it touches.** `grocery/alert-lib.ps1`, `grocery/alert-state.json`, `grocery/ALERTS.md`,
`grocery/audit-alert-precision.ps1`. No board, no published page.
