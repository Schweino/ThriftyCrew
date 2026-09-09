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

## The two sorting fields, and why they are fields (2026-09-08)

The five states say **whose move** an item is. They say nothing about **what it costs to be wrong**,
or **what the first step actually does** - and both of those signals lived in the free text after
the state, where they were miscounted twice. `decision-craft/applies-here.md` 1 has the account: two
careful readers scanning this file for "what is the first rung" got **16 of 33** and **17 of 30**,
and neither had stated its test. That is I11's defect - one label, more than one meaning - two floors
up. So every **not-closed** heading now carries two more backticked tags, and the audit reads them:

| Field | Values | What it means |
|---|---|---|
| reversibility | `2-WAY` / `1-WAY` | of the **FIRST RUNG**, not of the whole item |
| first rung | `RUNG1 READ` `RUNG1 MEASURE` `RUNG1 DOC` `RUNG1 BUILD` `RUNG1 RULING` `RUNG1 BLOCKED` | what the cheapest next step IS |

**`2-WAY`** means the first rung produces a file that can be deleted, and being wrong costs the time
it took. **A `2-WAY` item is never blocked on a ruling** - it waits on somebody having time.
**`1-WAY`** means it spends money or GPU hours, changes a reader-facing page on a live paid site,
makes a remote write, pulls member data, or sets a precedent that gets quoted afterwards.

`READ` reads bytes already on disk or in git. `MEASURE` runs something for a number and writes no
tracked file. `DOC` is text only. `BUILD` ships code. `RULING` means nothing proceeds until Brad
decides. `BLOCKED` waits on another item or an outside party.

**Measured 2026-09-08 after the sort, by `ops/audit-backlog-status.ps1 -Summary`, exit 0,
`items=130 notclosed=68 twoway=56 oneway=12`: 56 of 68 not-closed items are two-way.** The method
that ordered the sort predicted "about half"; the real figure is **82%**, and the gap is itself the
finding - the prose scan that produced "about half" was answering a narrower question (*does the item
SAY its first step is cheap*) than the one that matters (*is the first step actually reversible*).
Sixteen items were declaring it. Fifty-six were it.

A `DONE` or `PARKED` heading owes neither field: the axes exist to sort a queue and a closed item is
not in one. The audit enforces that split rather than demanding a retro-fit over 62 finished items.

## The consequence table (2026-09-08)

Built after the reversibility sort, over what survived it. **Objectives as rows, items as columns** -
the point being that it terminates and an argument does not. Scored `++` strong, `+` some, `.` none,
`-` a cost.

**The objectives, and why these four.** *Reader-facing correctness* outranks everything because this
is a live paid site. *Throughput* is Brad's own bottleneck. *Blast radius* is what a wrong answer
costs to unwind. *Cost to run* is hours on one box.

### The band that reaches a reader, and therefore goes first

| Objective | I44 | I59 | I60 | I64 | I92 |
|---|---|---|---|---|---|
| reader-facing correctness | `++` rich results | `+` unproven | `++` three quantified claims with no quantity | `++` **wrong verdict, live, measured** | `+` via a weaker board |
| throughput | `.` | `.` | `.` | `.` | `+` 15 aliases never learned |
| blast radius if wrong | low | **high** - 125 files | medium - 3 published posts | medium - one tool | low |
| cost to run | waiting | (a) minutes | hours | rung 1 **done** | hours |

**I64 dominates this band and is the only one with a measured live defect.** Rung 1 ran: the page
tells a paying reader `Decent, not instant` when 22 weeks of data say `good buy`. I59 is the one to be
careful with - **its rung (a) costs minutes and may close the item outright**, while its rung (c)
touches 125 published files, so doing (c) before (a) would be the most expensive possible order.

### Test and measurement quality - the band where three items overlap and none is dominated

| Objective | I37 mutation | I39 resolved-count | I65 consistency oracle | I95 near-miss row |
|---|---|---|---|---|
| reader-facing correctness | `+` indirect | `+` indirect | `++` catches real-input drift | `+` |
| throughput | `.` | `.` | `+` before a refactor | `.` |
| blast radius | none - temp copies | none | none - temp checkout | none |
| cost to run | ~1 h for one detector | a scan | ~1 h for one parser | one log line |
| **needs a ruling** | no | no | **no** | no |

**I65 wins on the objectives and it is the one to do first**, which is what I38's own update says: it
needs no ruling, its second version is whatever `git show` returns, and every git-bus stage boundary
is the shape the oracle wants. **Nothing here is dominated** - a `-SelfTest` proves a detector still
fires on one frozen fixture (I37 asks whether the fixtures would notice the detector being wrong), a
resolved count asks whether the assertion ran at all (I39), and the oracle asks whether 4,000 real
rows changed (I65). Three different questions.

**I95 is the one that cannot be backfilled** and so is time-sensitive in the same way I98 is: the
best-scoring candidate that did NOT clear the bar is the only row that can ever show a floor belongs
lower, and it is not being written today.

### Reliability - and the two that are NOT the same item

| Objective | I32 duration window | I35 second observation | I45 stage input assertion | I80 (done) |
|---|---|---|---|---|
| what it filters | a transient real condition | **a broken instrument** | stale input to a stage | a producer that stopped |
| cost to run | rung 1 is a count | rung 1 is a count | rung 1 is a read | shipped |

**I32 and I35 must not be merged, and the table is why**: same observer watched longer, versus a
different observer immediately. An estate whose probes are the thing most likely to be broken needs
the second at least as much as the first. **I45 is the cheapest of the three** and has already bitten
twice - the 08:30 job that ran inside its predecessor's window, and a watchdog named 0930 that fires
at 10:30.

### Deleted as dominated, or priced and found not worth commissioning

**Pass 4 says: before commissioning any measurement, price the answer. If the result would change no
action, that is a legitimate reason to close PARKED, and this file already has precedent.** Three
were closed on that test this session, and each one names its trigger rather than being abandoned:

- **I54** - a quant-format benchmark. **No quant change is proposed and none is pending**, so the
  number changes no decision today; it is also blocked behind I53. PARKED with a trigger.
- **I76** - edges per node over time. Real, cheap, and **has no consumer and no threshold**: nothing
  would act differently at any value it could return. PARKED with a trigger.
- **I84** - the guards as an open control loop. **Names a shape and proposes no rung**, and its
  forward half is now inside I93's ruling. PARKED as absorbed.

**Not deleted, and worth saying why:** I83 (quality attributes) looks like ceremony for a
one-person estate and mostly is - but the one instrument in it that ports is *get two independent
priority lists and diff them*, which is this estate's own case-NAME set diff wearing different
clothes. It stays OPEN on the strength of that one line, not of the method.

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

### E1 - The estate takes irreversible actions with no safety layer `DONE - CLOSED 2026-09-07; R2 HAS NO CALLERS AND BOTH PUBLISHERS ARE TAUGHT` `723be4ad`
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

---

**CLOSED 2026-09-07. Three of the four were answered by looking rather than by building, and the
fourth turned out to have a second half nobody had noticed.**

**1. R2 has no callers to protect.** Grepped every tracked `.ps1` and `.py`: there is exactly one
Cloudflare API call in the estate and it is a **GET** (`ops/audit-cloudflare-estate.ps1:292`, reading
bucket lifecycle). No `PutObject`, no upload, no wrangler, no S3 client. The V3/V4 platform that used
R2 was deleted in Aug 2026 and the buckets outlived the code that wrote them. So "route R2 through
the seam" has nothing to route - and the guard that would catch a NEW one already exists:
`audit-write-seam.ps1` carries `api\.cloudflare` in its owned-surfaces list and a frozen must-fire
fixture for a mutating R2 lifecycle PUT. A new R2 write hard-fails the gate on the day it is added.

**2. Neither mechanism would have caught the 2026-08-29 paywall leak.** Unchanged and still true: that
PUT reported success without taking effect, and only a downstream audit could see it. Recorded as a
limit of this layer, not as work.

**3. Half armed since I21** (Brad's ruling, 2026-09-07): staging is ON for agent dispatches, off for
the daily chain. Arming it immediately found that the approver would have corrupted the post - a
`[byte[]]` body was recorded as the STRING `"(byte[] length N)"` and `-Apply` replayed that
description to Ghost, on the only branch the live chain takes.

**4. `publish.ps1` was already taught - and `wave-publish.ps1` was NOT, which nobody had looked
for.** The estate has two mutating Ghost callers, and the second is the serveability ROLLBACK at
`wave-publish.ps1:1163`, which drafts a post whose card the feed cannot price. With staging armed
that PUT would be queued, the post would stay LIVE, and the code would have added the slug to
`$drafted`, printed "drafted + held" and advanced the run state - **recording a recipe that is still
live and still unpriceable as safely withdrawn, on the one path whose whole job is pulling down
something that is hurting readers.** Now a staged rollback reports **STILL LIVE** and advances
nothing, which is the truthful reading: until somebody applies the queued write, the post IS live.

**The marker has one reading now.** `Test-TcStaged` lives in `lib/ghost-lib.ps1` beside the code that
sets `__tc_staged`, and both publishers ask it instead of spelling out a property test. Three
hand-written copies is how one of them ends up checking a renamed property and silently taking the
not-staged branch. Four fixtures pin it, and the one that matters is `$null`: a real Ghost response
has no such property and neither does a variable left unset by a throw, so both must read NOT staged
- the alternative is a run that sent everything and reported it all queued.

**What remains is not this item.** The journal switch (`TC_WRITE_JOURNAL`) is still off everywhere,
and arming it is a separate decision with a separate argument.

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

### E5 - Validate at source `DONE - THE ENGINE HAD ONE SILENT DROP, NOT 24`
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

~~**Still open:** `compare-deals.ps1` has 24 drop points in the pricing path.~~

**CLOSED 2026-09-07, and READING the 24 rather than counting them changed the job entirely.** They
are not 24 silent drops; they are three different things and only one of them was silent:

| Kind | Where | Was it silent? |
|---|---|---|
| FILE-level refusals | `Test-AdWindowClosed`, the price-mode gate | **No.** Both `Write-Warning` with the store, the reason and the row count. |
| Row-level BUSINESS drop | the expired-sale check | **No.** Increments `$script:ExpiredSaleRows` and lands in `$health` as `expired_sale_rows_dropped`. |
| Row-level FORMAT drop | `if (-not $name) { return }` at the top of `Add-Norm` | **Yes - and this is the only one.** |

That last one is E5's format layer exactly as the item describes it: a row whose name did not parse
vanishes before any business rule runs, so a capture whose name field moved would yield fewer rows
and produce no signal at all. Silent by construction, and one site rather than twenty-four.

**It is now counted PER STORE and reported in `$health` as `nameless_rows_dropped` and
`nameless_rows_by_store`.** Per store because the total is the wrong grain: three nameless rows
across seven stores is feed noise, three from ONE store is that store's capture shape having moved,
which is the event worth seeing.

**Provably inert on pricing, which is why it was safe to do to a live engine without rebuilding a
board to check.** The row is still dropped, on the same condition, at the same place. No branch was
added and none removed, so the engine cannot price differently because of this - it is only no longer
invisible.

**Two traps this file's own scars named, both hit on the way:**

- `Join-String` is a **PowerShell 7** cmdlet and this estate is 5.1. The first draft used it in the
  `$health` block, where `$ErrorActionPreference` is `Stop` - it would have thrown while composing the
  health record on the live chain. `-join` instead.
- The counting was inline in `Add-Norm`, which is defined ~30 lines AFTER `-SelfTest` exits, so
  nothing could ever have asserted it. Lifted to `Add-TcNamelessRow` and `Format-TcNamelessByStore`
  above the self-test block, which is this file's own stated rule: "TWO FUNCTIONS, BOTH PURE, BOTH
  REACHED BY `-SelfTest`". Six fixtures, including the uninitialised-counter case, because a
  `$script:` variable does not travel with a lifted function and three scripts lift from this file
  ([[compare-deals-lifters-need-functions-not-variables]]).

### E19 - No matcher in the estate has a scored test set `DONE - ALL THREE ACCOUNTED FOR, 2026-09-07`
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

~~**Still open:** every other retrieval-shaped component.~~ **CLOSED 2026-09-07, and the three named
components turned out to be two - one of which cannot be scored honestly.**

**The near-name shelf scorer IS the ingredient matcher.** `ingredient-vocab.ps1` says so at its own
line 262: the food DB needed a near-name shelf and "there were two wrong ways to build one: a second
head-noun scorer inside map-preresolve, or a third inside coverage_check.py. These pin that the rows
became an argument and the scorer did not fork." Same `Get-Candidates`, different `-Rows`. Scoring
one scored both, and this item listed them as two things because nobody had looked.

**The ingredient matcher now has a scored set: `meal-prep/pipeline/score_ingredient_mapper.py`,
659 distinct (query, canon) pairs built from 1,525 mapped rows across the whole run corpus**, one row
per case in `meal-prep/db/mapper-eval-cases.jsonl` (E24's shape).

**Getting the QUERY right was the load-bearing decision.** The mapped files carry `source_raw` - the
page's whole line, *"16 ounces cauliflower chopped into macaroni sized pieces"* - and scoring on that
returns `GENUINE-GAP` with zero candidates. But production never hands the matcher a raw line: the
extractor resolves the noun first and the matcher sees *"Cauliflower"*. **Scoring a component on an
input it never receives is E23's bias with the sign flipped** - a falsely terrible number instead of
a falsely good one. So the pairs are built by joining `extracted/` to `mapped/` on the raw line.

| | |
|---|---|
| pairs scored | **659** |
| exact resolve | 215 |
| recall@1 | **0.5751** |
| recall@5 | **0.6874** |
| recall@25 | **0.6874** |
| MRR | 0.6232 |
| abstained (returned nothing) | **88** |

**Two findings, and the first is actionable today.** `recall@5` and `recall@25` are **identical** -
nothing is ever found beyond rank 5. So any future "return more candidates" change is already
answered: it buys nothing, and the shortfall is retrieval, not ranking.

**The second is a number this estate has never had.** On a corpus filtered toward its own successes,
the vocabulary matcher retrieves the eventual canon name for about **69%** of the names it is asked
about. The other 31% were settled by something else - a registrar ruling, a new row, an agent's
judgement. That is not necessarily a defect; it is the first measurement of **how much of the mapping
work the matcher does and how much the agent does**, and every future change to either can now be
scored against it.

**Abstention is in the denominator, never dropped** (E20): 88 names returned nothing, and they lower
MRR rather than vanishing from it - the trick that lets a matcher which gives up on its hard rows
outscore one that attempts everything. And the report states on every run that this is an **upper
bound**, because every pair is a line that WAS mapped (E23).

**Nothing was tuned.** This scores and does not change the matcher, or the measurement would be a
description of a decision already taken.

**`knowledge-search` is NOT scored, and the reason is the item's own argument turned on itself.**
Every gold set available for it is derivable only from the corpus it searches - section headings, the
catalogue, the skills' own `description` frontmatter - and all of that text is IN the BM25 index. A
set built from it would score near-perfectly and mean nothing, which is exactly the flattering
measurement E19 and E23 both warn about. **A weak scorer built to close a ticket is worse than no
scorer**, because the number would be quoted. An honest set needs queries a person actually typed
against answers they knew, collected as they search - which is a habit rather than a build, and is
the same mechanism E23 prescribes. Recorded rather than faked.

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

### E23 - Our test sets are built out of successes `DONE - MEASURED 2026-09-07; 189 OF 6,476 ROWS ARE FAILURES`
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

**DONE 2026-09-07. The item's sharpest line is that the absence is INVISIBLE IN THE SCORE, so the
work was to make it visible rather than to build another corpus.**

`ops/audit_corpus_provenance.py` reads every registered corpus and prints, per corpus, how many cases
came from a recorded FAILURE, how many from a SUCCESS we already handle, and how many from neither -
with the counts beside every share, because a share without its population is what caused this in the
first place.

**What it found, and the second row is the whole item in one line:**

| Corpus | Rows | From a recorded failure | From a success | Neither | Labels |
|---|---|---|---|---|---|
| `graph/gold/gold.jsonl` | 1,968 | 189 | 400 | 1,379 | MATCH 1332, NO_MATCH 633, DIFFERENT 3 |
| `graph/gold/hunter-gold.jsonl` | 281 | **0** | **281** | 0 | **MATCH 281** |
| `graph/gold/escalation-review.jsonl` | 1,411 | 0 | 0 | 1,411 | MATCH 944, NO_MATCH 467 |
| `sidecar/data/eval-positives.json` | 2,816 | — | — | — | **no `source` on any row** |

**189 of 6,476 rows come from a recorded failure.** And `hunter-gold.jsonl` is 281 rows where every
case is a success and every label is MATCH - **a corpus with no negative cases cannot measure
over-firing at all**, which is a fixture with no clean twin wearing a bigger coat.

**An escalation is counted as NEITHER, deliberately.** The automatic path could not settle it and a
reasoner did; that is not the same as a shipped answer being wrong, and folding 1,379 of them into
either column would flatter or damn the corpus by definition.

**It reports and does not judge the mix.** A matcher corpus SHOULD be heavy on adjudicated failures
and an identity corpus should not, and no rule here knows which is which. The one thing it ratchets
is corpora carrying no `source` at all - that number may only go DOWN, because such a corpus cannot
answer this question even in principle.

**One bug in my own ratchet, found before it shipped and worth recording.** `eval-positives.json` is
gitignored, so in a worktree it is simply absent - and "in the baseline, not in this run's findings"
would have read that absence as a REPAIR and dropped it from the list forever, on the strength of a
run that never opened the file. Exactly the shape `lib/ratchet.ps1` exists to refuse. A corpus counts
as repaired only when it was actually READ and now carries provenance; three fixtures pin it.

**The habit half is at the point of read**, in `.claude/rules/measurement.md`: record the case at the
moment it fails, including the ones fixed by hand and moved on from, and give every corpus row a
`source`. A habit is not something a script enforces - but the script now makes the consequence of
skipping it a number somebody can see.

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

### E6 - Fact Check List before we publish `DONE - VERIFY THEM, DO NOT DECLARE THEM 2026-09-07` `a90b2081`
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

---

**WORKED 2026-09-07, and reading the 340 instead of counting them found that they are not 340 of one
thing.** `-All` and `-Json` were added first, because the gate line printed 15 and said "and 325
more": "each one declared or removed lowers the mark" is advice nobody can follow against a list they
cannot see.

| Class | Count | What they are |
|---|---|---|
| `price-compare` | **332** | real, unbacked comparative price assertions |
| `storage` / food safety | **8** | **all eight false positives** |
| `carriage` | **0** | none at all |

**THE FOOD-SAFETY CLASS HAD PRECISION ZERO, and it is the class this audit's own header calls the
most serious** - "a wrong one is a health claim". All eight hits were marinating or cooking steps:
*"Refrigerate at least 4 hours and preferably overnight"*, *"toss in the marinade and refrigerate at
least 2 hours"*, and one where `keeps` meant maintain - *"the lowest heat that KEEPS IT MOVING"* next
to *"3.5 to 4 hours"*. **That is E22 in the flesh:** green on its fixture, and on the live corpus only
ever wrong about the thing that matters most. A detector like that trains people to skim exactly the
class they should read.

**The fix is a principle, not a patch for those eight.** A food-safety claim is an **UPPER** bound -
how long the finished food is still good for, *"keeps 5 days"*, *"freezes up to 3 months"*. A
marinating instruction is a **LOWER** bound - how long to leave it before cooking. **A floor says
nothing about when food stops being safe**, so it cannot be the claim this class exists to catch.
Marinating prose, "at least"/"minimum" durations, and keep-as-maintain are excluded; the upper-bound
must-fire still fires, and the three live shapes are frozen as must-not-fire cases. Ratchet
**tightened 340 -> 332**.

**Zero carriage claims is worth stating rather than passing over.** That is the class where the
estate has the strongest system of record - `grocery/carriage.json`, which already refuses to publish
a recipe whose ingredient has no store evidence - and no card is routing around it in prose.

**STILL OPEN, and it is a RULING rather than a defect list.** The 332 are real: *"Ground turkey
usually undercuts ground beef by a couple dollars a pound"*, *"the same green salsa in a taller jar
is routinely half the price"*, *"frozen broccoli is cheaper than fresh"*. They are qualitative
comparative claims made in the writer's voice across **274 of 584 live cards**, and clearing them
means an editorial decision on each: verify against the board and declare, soften the wording, or
rule that generic culinary comparison is acceptable house voice and narrow the class.

**Not a code task, and not one to decide unilaterally on a live paid site.** The gate holds the line
against NEW ones either way, which is what it was built for. `-All` and `-Json` are there so the 332
can actually be worked when the ruling is made.

---

**RULED 2026-09-07. Brad asked for the LONG TERM solution rather than a choice between narrowings,
and measuring the residual produced a better answer than any of the three options offered.**

**The 332 contain nothing demonstrably false.** Eleven carry a number or a ratio - the only ones that
can be flatly wrong - and all eleven were checked against the 2026-09-07 board. None is contradicted.
*"Ground turkey undercuts ground beef by a couple dollars a pound"* is true and UNDERSTATES it
($2.663 against $6.170, a $3.51 gap). *"Chicken thigh is cheaper than breast"*: $0.98 against $1.99.
The pork loin claim - *"about two dollars a pound, roughly half the price of tenderloin"* - is
consistent with the board once you read the ordinary shelf prices ($3.59 Aldi, $3.88 Hy-Vee, $3.97
Walmart, $3.99 Fareway) rather than Sam's $2.98 membership price, which is what I anchored on first
and had to correct.

**THE PART A DECLARATION CANNOT DO IS THE PART THAT MATTERS: THESE CLAIMS DECAY.** Ground turkey
undercuts 93/7 beef today. If beef falls to $3.00 in November that sentence on a live paid page
becomes false, and **nothing in this estate would notice**. A declaration is a one-time act; the
board is rebuilt every day. No quantity of declaring reaches that failure, and it is the only one
here that costs a reader money.

**So the declaration became the INPUT to a check rather than an echo of the prose.**
`meal-prep/pipeline/audit-price-claims.ps1` reads a structured entry -

    "price_claims": [ { "cheaper": "ground-turkey", "dearer": "ground-beef-93-7",
                        "basis": "per lb", "says": "..." } ]

- resolves both ids against the newest board and asks whether the claim is **still** true. It runs
daily from `check-ad-cycles`, alerting rather than blocking, because a contradicted claim is a prose
fix and not a reason to withhold a correct board. `fact_claims` finally earns its keep: it is
machine-readable input to something that can answer.

**Verdicts are `supported`, `tie`, `CONTRADICTED`, `unpriceable`, and the middle two are what keep it
credible.** Two commodities within 5% are a tie, not a refutation - reporting a tie as a contradiction
is how a check like this gets switched off. A commodity the board does not price is `unpriceable`
and says in words that this is NOT evidence the claim holds.

**Proved in both directions.** The first real declaration - the ground turkey claim, on
`baked-ziti-with-ground-turkey-and-ricotta` - reports `supported: ground-turkey 2.663 vs
ground-beef-93-7 6.170 (56.8% cheaper)`. Against a copy of the board with turkey moved to $9.99 it
reports `CONTRADICTED ... the claim is now BACKWARDS by 61.9%` and exits 2.

**And declaring it turned up a latent defect that had been waiting since E6 shipped.** `Get-SpecHash`
hashes the whole spec, so adding `price_claims` marked the card dirty and the next `propagate` would
have **republished it** - a Ghost write on a live paid site for a field no builder renders.
**`fact_claims` has had the identical problem all along** and never bit only because no spec had ever
declared one: the day anybody started clearing the 332 by declaring them, every card they touched
would have republished. Both are masked now, in a SEPARATE list from `MACHINE_FIELD_PATTERNS` -
that list is pinned verbatim against `reanchor-machine-fields.ps1` because those are fields reanchor
REWRITES daily, and the source pin correctly refused the first attempt to fold two meanings under one
name. Three fixtures, including the clean twin that a prose edit beside a declaration still dirties.

**What is NOT proposed: back-declaring the other 331.** They are qualitative - buy whole not pre-cut,
buy frozen not fresh, buy in bulk - and that is the site's editorial substance rather than unbacked
pricing. Two separate attempts to split them mechanically were wrong, which is itself the finding.
The gate still counts them and the mark can only fall; what changed is that the ones worth declaring
now buy something real when they are.

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

### E9 - Model choice is pinned per agent, but MATE's M is per call `DONE - THE SWAP IS REFUSED AND THE COMPARISON IS BUILT, 2026-09-07`
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

**BUILT 2026-09-07: `meal-prep/pipeline/audit_transcription_fidelity.py`, wired into
`wave-preaudit.ps1` as `p9-transcription-fidelity`** - which is the correct side of the publish, E1's
whole point. It fetches each transcription's `source_url`, reads the page's own JSON-LD
`recipeIngredient` list, and compares.

**Numbers and units strictly, prose loosely, which is the opposite of a text diff.** A dropped
adjective is a fidelity nit; a quantity that moved is a price on a live paid page. Findings are
ranked by what they cost: `quantity-moved`, `unit-moved`, `invented`, `dropped`.

**The calibration is the whole thing.** The extractor is not verbatim ON PURPOSE - it folds unicode
fractions and strips parentheticals ([[extractor-raw-is-not-verbatim]]) - so a checker that did not
know that would flag every line on every page and be switched off inside a day. Both transformations
are normalised on both sides before anything is compared, and four must-not-fire fixtures pin exactly
that.

**Three defects my own fixtures caught before it shipped, and the first is the one that mattered:**

1. **A UNIT SWAP WAS INVISIBLE.** "1 cup smoked sausage" against "1 pound smoked sausage" paired on
   prose and agreed on every digit, so nothing fired - and that is the single most expensive drift
   there is. Units are now compared as strictly as numbers.
2. **A quantity change was mislabelled.** Pairing scored the whole line, so numbers and units - the
   very things that may have drifted - pushed a changed line below the pairing floor and it came back
   as an invention plus a drop. Pairing now scores PROSE ONLY: what a line IS decides the pairing,
   what it SAYS decides the finding.
3. **NFKC ran before the fraction map and glued the digits.** "1half" became "11/2" = 5.5 rather than
   1.5, so the calibration case this file depends on reported a quantity that had not moved.

**Measured on real pages, both directions, because a green on nothing proves nothing.** 31 of 31
transcriptions across two runs were read and agreed - 5 of 5 on `hunt-2026-09-04-five`, 26 of 26 on
`hunt-2026-08-27-highprotein` - so the extractor is faithful and the checker does not cry wolf. Then a
real transcription was corrupted on a temp copy and it fired correctly at exit 2, catching both the
quantity change and the invented line. **An agreeing number that has never been shown to disagree is
not evidence.**

**A page it cannot read is never counted as agreement.** No JSON-LD, a 403, a paywall - each is
CANNOT-CHECK against its own count, and the pass line prints "N page(s) could not be read and are NOT
counted as agreement". p9 passes on cannot-check and fails only on a real finding, which diverges
from `p8-feed-liveness` beside it on purpose: p8 is false-on-skip because a wave must never ship
without knowing the feed is up, whereas a source page that 403s is not something anybody here can
clear, and a wave blocked by somebody else's server is a gate that gets `-SkipLive` added to every
call within a week.

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

### I24 - Nothing in this estate measures search performance, so no SEO change can be shown to have worked `DONE - THE SERIES IS LIVE 2026-09-07` `queue-2`

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

**CLOSED 2026-09-07. Brad created the service account and added it to the property; the series is
live.** `ops/seo_search_console.py` signs an RS256 service-account JWT, trades it for a token and
queries `searchAnalytics` - no new dependencies, because `cryptography` and `requests` are already
here and `google-auth` is not. It runs daily from `check-ad-cycles`, report-only. The key is
gitignored at `ops/.gsc-key.json`; the series it writes is TRACKED, because being checkable is the
whole point of the item.

**First real measurement, window 2026-08-08 .. 2026-09-04:**

| | |
|---|---|
| impressions | **292** |
| clicks | **1** |
| CTR | **0.34%** |
| impression-weighted position | **40.33** |

**Impressions are falling, and that is the headline.** Per day: ~15-22 through mid-August, 3-6 by the
26th, and **2, 2, 1, 2** on 1-4 September. Roughly an 90% decline across the window. The numbers are
small enough that a single day means nothing; the shape across three weeks is not nothing.

**Zero clicks at positions that should convert.** `/chicken-tikka-masala-burrito/` took 39
impressions at average position 18.97 and its query "chicken tikka masala burrito" sits at **position
9.0 over 27 impressions with no clicks at all**. `/omaha-grocery-prices/` is at **position 7.47** over
17 impressions, also zero. One click in 292 impressions is the kind of CTR that points at the result
LOOKING wrong rather than at ranking - which is exactly what 584 recipes sharing one image, 49 of
them empty, would produce. **That is a hypothesis this now makes testable, not a conclusion.**

**Three defects the first real pull exposed in code written an hour earlier**, each invisible until
something real came back:

1. **"Top 25" was the first 25 ALPHABETICALLY.** The API returns rows in key order, so `rowLimit: 25`
   recorded about, almond-milk, avocados, balance-transfer and silently dropped the actual top pages.
   A field named "top" that is not top is worse than no field, because it is the one that gets quoted.
2. **A false claim inside an honest-refusal message.** The file said the series "cannot be longer than
   the days since verification" on 2026-08-31. It can, and the first pull proved it: 28 days back to
   2026-08-08. **Google serves history for a URL-prefix property from before it was verified**,
   because the data belongs to the URL rather than to the verification. Corrected in place.
3. **Two pulls in one day counted as two days**, which would have moved the 14-pull bar closer with no
   new data. Records are folded by window end date now. Nearly caused it while fixing defect 1.

**What the fixtures pin, and two are the errors this metric invites.** The window ends **three days
back**, because Search Console finalises late and asking for yesterday returns a hole that reads
exactly like a collapse. Average position is **impression-weighted**, not a mean of means. And
**position is a RANK** - falling from 50 to 45 is an improvement, and reading it the other way is the
classic mistake.

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


### I31 - Every LLM run here is costed AFTER it finishes and none is budgeted or capped BEFORE it starts `DONE - RUNG 1 SHIPPED; THE CAP IS STILL BRAD'S` `queue-3` `2-WAY` `RUNG1 BUILD`

**`[RUNG 1 CLOSED 2026-09-09. No gate was added, per the item's own instruction.]`**

`meal-prep/pipeline/lane-tokens.ps1` now prints money beside tokens: a per-lane USD column, a per-recipe
dollar figure, and the model mix behind both.

**The price table is read, not remembered.** Rates come from the `claude-api` skill's model table
(cached there 2026-06-24, read 2026-09-09). They are Anthropic first-party list prices and the header
says so, because a run dispatched through Bedrock or Vertex is priced differently and **this script
cannot detect that**.

**The finding that made this more than a multiplication.** `Get-UsageFromLine` folded fresh input,
cache reads and cache writes into one `in` number. That is right for tokens and wrong for money by
close to an order of magnitude: a cache read costs a **tenth** of fresh input and a cache write costs a
**quarter more**, and this estate's transcripts are overwhelmingly cache reads - a sampled session ran
**40,153 cache-read tokens against 2 fresh input tokens**. Pricing the collapsed `in` at the input rate
would have overstated the bill roughly 10x and made repeated context look like the dominant cost when
it is not. The three buckets are now priced separately; `in` is unchanged, so the token report did not
move.

**Priced per line against that line's own model**, because the roster is deliberately mixed - some
agents are Fable-pinned and some Opus-pinned, a 2x difference in input rate - so one assumed model for
a whole run would be wrong for most of it. Every usage line in a transcript carries its own `model`,
verified over 172 usage records in a real session file.

**An unknown model is NAMED, never billed at zero.** `Get-CostUsd` returns `priced=$false`, the lane is
flagged, the model is listed, and the report says in words that **the total is a floor, not a bill**. A
silent zero here is the agreeing-zero shape: the report would read as complete while omitting a whole
model's spend.

**Verified:** self-test 20 of 20, exit 0, `LANE-TOKENS-COMPLETE`. Driven on a synthetic transcript
directory and the output READ, not just tallied - which caught a stray backtick rendering literally in
the FLOOR warning (a single-quoted PowerShell string does not consume one), now fixed.
Worked example from that run: an Opus-5 price lane at 254,801 tokens is **$0.36**, a Fable-5.1 write
lane at 99,010 tokens is **$0.29** - a lane a quarter the size costing four fifths as much, which is
exactly the comparison a token-only report could never show.

**NOT run against a real hunt, and it cannot be yet:** there are no `agent-*.jsonl` transcripts on disk
anywhere in the tree. The first real run produces the first real number.

**Still open and still Brad's: rung 3, the cap.** A budget that refuses to dispatch is a policy
decision about what a run is allowed to spend, not a report, and nothing here pre-empts it.
*Source: Optimize & Interface LLM Apps Effectively (queue-3, Starweaver), module 2.* The course's
one genuinely new habit is trivial and this estate does not have it: **do the arithmetic before you
build, not after the invoice** - expected tokens per call x price x expected calls, priced as two
legs because output costs several times input.

**What is already here, and it is ahead of the course.** Measured 2026-09-07 by grep across the tree
(excluding .git, .venv, worktrees, out):

- Per-lane token accounting exists and is good. meal-prep/pipeline/lane-tokens.ps1 and
  harvest-lane-tokens.ps1 reconstruct real spend by reading subagent transcripts, because the
  Workflow tool's \agent() never exposes usage to the caller and 738 of 738 invocations on the
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

### I32 - No alert here can require a condition to PERSIST, and no alert ROUTE has been tested end to end `PARKED - MEASURED 2026-09-09: 7 OF 136, SO THE DURATION WINDOW BUYS ALMOST NOTHING HERE` `queue-4`

**`[CLOSED PARKED 2026-09-09, by the item's own instruction: "If that number is small, the duration
window buys nothing here and this item should be PARKED."]`**

**Measured over `grocery/triage-queue.json`, 139 closed items:**

| | |
|---|---|
| items with both a raised and a resolved timestamp | 136 of 139 (3 unusable, **not scored, not counted as fast**) |
| median time raised to resolved | **5.1 h** |
| resolved inside one run cycle (<=24 h) | 101 of 136 |
| resolved with **no recorded action** in the notes | 8 of 136 |
| **BOTH - what a duration window would have suppressed** | **7 of 136 (5%)** |

**Five per cent.** A duration window withholds the first notification of a transient condition; on
this history it would have withheld seven alerts in the queue's whole life, and the other 129 needed
somebody to do something. **That is not worth a mechanism.**

**The half of the item that was NOT about duration is where the value turned out to be**, and it has
moved to I35: the queue's own notes record that alerts are frequently wrong on their FIRST
observation, which is a different fix (a second observer) and is sized up rather than down.

**Unchanged and still true:** the estate's nearest mechanism is the once-per-type-per-day gate in
`send-alert.ps1`, and it is the OPPOSITE behaviour - it withholds the SECOND email about a persistent
condition. And the DELIVERY leg is still untested end to end; 22 of 139 items fired more than once,
so the queue leg demonstrably works. Email was unmuted 2026-08-31 and the log shows 73 sends, the
most recent 2026-09-08, so delivery is evidently working even though nothing asserts it.

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
page". So the DELIVERY leg has not been exercised and nothing would report that it had stopped
working. The queue leg is fine and deliberately so.

**CORRECTED 2026-09-07 by queue-4 course 2, which read the file.** The sentence above said email
"has been muted since 2026-08-14 ... no expiry". **It was unmuted on 2026-08-31.**
`grocery/alerts-muted.json` reads `"muted": false`, `"unmuted": "2026-08-31"`, with the reason that
the mute had run 17 days and two queue items sat unseen; `send-alert.ps1 -SelfTest` asserts
`muted:false -> not muted (in-place off switch)`. The mute MECHANISM is still expiry-less, which is
the separate true point the `force-bypasses-the-daily-gate-not-the-mute` memory records. **The rung
this item proposes is unaffected**, because the untested thing is the delivery leg and it is still
untested whether muted or not. Logged as X7 in the claims register.

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

### I33 - The estate has 15 days of latency history in git and has never read it `PARKED - RUNG 1 IS DONE AND RUNG 4 APPLIES: NO VARIANCE WORTH ACTING ON`

**`[CLOSED PARKED 2026-09-08, by the item's own rung 4, which said to record this outcome so it does
not become a standing invitation to build observability machinery for a one-box estate.]`**

Rung 1 was re-run rather than quoted, over `git log` for
`grocery/out/logs/graph-nightly-status.json`. **16 commits, all 16 parsed, 16 distinct nights,
2026-08-23 to 2026-09-08:**

| | item, as filed | re-read 2026-09-08 |
|---|---|---|
| observations | 15 | **16** |
| range | 118-199 s | **118-223 s** |
| mean / median | 161.7 / 161 s | **165.6 / 162 s** |
| trend | none visible | **still none** |

The range widened because 2026-09-08 ran 223 s, the slowest night on record. **One point is not a
trend** and the median barely moved, so the verdict stands: nothing here varies enough to act on, and
rung 2 (a band) should not be built. 16 points is thin, `no-hardcoded-bands` applies, and there is no
decision a band would change.

**A defect in the reader is worth recording, because it would have produced a confident wrong zero.**
The committed file carries a **UTF-8 BOM**, so `json.loads` failed on **every one of the 16
revisions** and the first run reported 0 parsed. A less careful reader would have printed "no history"
and closed the item on an absence that was entirely the instrument -
`[[a-negative-search-result-must-prove-itself]]`.

**The per-STAGE half of this file was never the same question and it is now answered separately: see
I43, which found the bottleneck.** That is the value that was actually sitting unread here.

**Source.** Queue-4 course 2, `site-reliability-engineering-principles` (Edureka), items 7 to 12, 18,
19, 23 and 44. Vendor course, no measurements; claims C69 to C72 in
`~/.claude/skills/course/CLAIMS-REGISTER.md`. The concepts are routed to `reliability-craft`; this
item is only what the estate measurement found.

**Measured 2026-09-07, main checkout, worktrees and `sidecar/.venv` excluded.** 28 scripts under
`ops/`, 56 `grocery/audit-*.ps1`, and 217 `.ps1` files containing `SelfTest`; the sets overlap and
the **distinct union is 243**. (`QUEUE-4.md`'s "249 gates" was not reproduced and is not used here.)
**242 of them answer a boolean and record nothing about how long they took.** A text sweep for `SLO`,
`error budget`, `burn rate`, `golden signal` and `blameless` across all tracked `.ps1`, `.py` and
`.md` returned **zero files for each** - measured before this item was written. **Re-running it now
returns one file for all five: this one.** Exclude `design/BACKLOG-course-findings.md` when you
re-measure. `toil` is still zero. `runbook` returns seven, all prose, none with escalation timings or
resolution criteria; `postmortem` returns two, both naming the V4 postmortem document rather than a
practice.

**The exception, and a correction to this item's own first draft.** `graph/pipeline/nightly.ps1`
times each stage (line 324) and writes per-stage timings plus a total `elapsed_sec` (line 675) to
`grocery/out/logs/graph-nightly-status.json`. **This item first said that file is gitignored and
overwritten with no history. That was wrong**, and wrong in exactly the shape the
`check-ignore-directory-form-lies` memory names: the assumption came from `grocery/out/` being an
ignored directory and was never checked against the file path.

Checked properly: `git check-ignore -v` on the file path **exits 1 (not ignored)** and
`git ls-files --error-unmatch` succeeds. It is **tracked and committed daily**, 15 commits from
2026-08-23 to 2026-09-07 with one gap on 2026-08-24. Reconstructed from `git show` per commit:

| | |
|---|---|
| observations | 15 daily totals of the graph nightly chain |
| range | **118 s to 199 s** |
| mean / median | **161.7 s / 161 s** |
| trend | none visible by eye over 15 points |

**So the finding is not "we do not measure". It is "we measure one thing, keep it properly, and have
never once looked at it."** In roughly three weeks nothing has read that series: no script consumes
the file, no band exists around it, and producing the five numbers above meant walking git history by
hand. That is why nobody has.

**Rungs, cheapest first.**

1. **Read what is already there.** A short script that walks
   `git log -- grocery/out/logs/graph-nightly-status.json`, extracts `elapsed_sec` and the per-stage
   timings, and prints the series. This is a read of committed data, changes nothing, and is the only
   rung that should happen without a further ruling. Its output is the input every later rung needs.
2. **Then decide whether a band is worth it**, using `data-quality-craft/checks-and-thresholds.md` 2
   on band-versus-ratchet-versus-budget and `detecting-anomalies.md` 3 on deriving a cutoff rather
   than choosing one. 15 points is thin; `experiment-craft` should rule on whether it can support a
   band at all before one is written. **Do not hard-code a number** - the `no-hardcoded-bands` ruling
   applies here as much as to prices.
3. **Only then consider widening coverage** to the daily grocery chain or the capture lanes. Adding a
   second uninspected timing series before anyone has read the first one buys nothing.
4. **PARKED if rung 1 shows no variance worth acting on.** Recorded so this does not become a
   standing invitation to build observability machinery for a one-box estate.

**What it would touch.** Rung 1 is a new read-only script under `ops/` and nothing else. No gate
changes, no agent changes, no data writes.

---

### I34 - The estate wrote one exemplary postmortem and never wrote a second `DONE - THE TEMPLATE EXISTS AND IT PROMPTS FOR ALL THREE, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08. Rung 1 only, which is what the item asked for.]`**
`docs/INCIDENT-TEMPLATE.md` ships with the three-way corrective-action split as its central section -
**preventive** (stops the cause recurring), **detective** (finds it faster next time), **responsive**
(responds better to this shape) - one row each, with the instruction that an empty row is written
*"none needed, because ..."* rather than deleted, since an absent row and a considered nothing are
indistinguishable afterwards.

**The structural reason the template is needed is written into it**, because it is the whole finding:
a must-fire fixture is a **preventive** artefact by construction, so a test philosophy built entirely
out of them keeps prompting for prevention and never prompts for *would we notice this faster*. That
is why the estate's one excellent postmortem
(`grocery/INCIDENT-2026-07-23-walmart-flood.md`) contributed its preventive half to `CLAUDE.md` and
lost the other two.

It points at that incident as the standard rather than restating it, and carries the sections that
earned their place there: the timeline gap between broke and noticed, *the class (this has happened
before)*, `Verified:` on every action, accepted risks with bounds, and the independent re-review that
corrected the original RCA's own attribution.

**Rungs 2 and 3 are NOT done and rung 3 may well end PARKED**, which the item already argues: one
incident in the repository's whole life, written two weeks in, six weeks of silence since. On that
base rate a standing postmortem PROCESS is ceremony. The template is not - it cost nothing to keep.

**Source.** Queue-4 course 3, `foundations-of-site-reliability-engineering-training` (Simplilearn).
The transferable piece is its three-way split of postmortem corrective actions - **preventive**
(stop the cause recurring), **detective** (find it faster next time), **responsive** (respond better
to this shape) - recorded in `reliability-craft/rca-and-chaos.md` 2.

**What was actually found, which is not what the course predicted.** The check was expected to show
the estate has no RCA practice. It shows the opposite and something more useful:
`grocery/INCIDENT-2026-07-23-walmart-flood.md` is a **complete, high-quality incident postmortem** -
severity in the header, a timestamped timeline, a `## Root cause (the five whys)` section, a
`## The class (this has happened before)` section that refuses to stop at the single cause, what
worked and what did not, four fixes each with a *Verified:* line, tracked follow-ups, three accepted
risks with stated bounds, and an independent re-review that corrected the RCA's own attribution and
found two further gaps. It contains all three kinds of corrective action.

**And it is the only one.** `find . -name "INCIDENT*"` returns exactly that file. The practice
produced one artefact and did not become a practice.

**Why that matters here.** The half of that incident's answer that survived into standing policy is
the **preventive** half - `CLAUDE.md`'s *"when a defect recurs, the durable fix is a memory, a gate
or a command, not just the repair"*. The detective and responsive halves did not. There is a
structural reason to expect that drift rather than treat it as an oversight: a must-fire fixture is
a preventive artefact by construction, so a test philosophy built entirely out of them (164 files
carry a `CLEAN TWIN` as of 2026-09-07) will keep prompting for prevention and will never prompt for "would we notice this faster next time".

The one detective artefact in the estate, `grocery/audit-walmart-fullpull.ps1`, exists because that
incident's re-review explicitly asked the detective question and found a blind spot the preventive
fixes had just created. That is the case for asking it routinely.

**Rungs, cheapest first.**

1. **A template, not a process.** Add the three-way action split to whatever is used when an incident
   record next gets written, so the author is prompted for all three rather than only prevention.
   This is text, changes no code, and is the only rung that should happen without a further ruling.
2. **Then ask the detective question against the existing backlog**, once, retrospectively: for the
   defects already fixed here, how many would be noticed faster today than they were then. That is a
   read, and its answer decides whether rung 3 is worth anything.
3. **Only then consider a second incident record.** Note the honest counter-argument, and note that
   it cuts both ways: the repo's first commit is **2026-07-08**, the incident is **2026-07-23**, and
   today is 2026-09-07. So the record covers **one incident in the whole two-month life of the
   repository**, written two weeks in - and **six weeks have passed since with no second one.** On a
   base rate that thin, a standing postmortem process is ceremony, and the right outcome of rung 2
   may well be `PARKED`. What is NOT thin is the template: it cost nothing to keep and the next
   incident, whenever it lands, should not be written from scratch.

**What it would touch.** Rung 1 is one markdown file. Rungs 2 and 3 are reads. No gate changes, no
agent changes, no data writes.

**Explicitly NOT proposed: chaos engineering.** The same course names inadequate monitoring as the
disqualifying precondition for fault injection, and this estate has telemetry on 1 of 243 gates
(item I33). It also already does deliberate fault injection one layer down: `grocery/test-guards.ps1` breaks each
guard invariant on purpose, asserts the gate exits 2, restores and asserts exit 0 again - 16 mutation
windows with a crash-safe restore. That is the chaos loop against the gate layer, where a steady
state is observable. Reasoning recorded in `reliability-craft/estate-inventory.md` so it is not
re-derived as an open gap.

### I35 - Every failure verdict here is reached on ONE observation, and synthetic monitoring's standard answer is to take a second `DONE - THE SECOND OBSERVATION IS BUILT, AND IT IS A PRE-CONDITION RATHER THAN A RE-PROBE` `queue-4` `2-WAY` `RUNG1 MEASURE`

**`[RUNG 2 BUILT 2026-09-09, in the form rung 1 argued for rather than the form the item proposed.]`**

**The item proposed a second INDEPENDENT observation** - a different search term, a different session.
Rung 1 showed that would have caught none of it: the reversals were not the store being misread, they
were **this auditor's own blind spots**. So what shipped is the check triage did by hand on 2026-09-01
and wrote down: *"every candidate lives in `walmart-regular-2026-08-31.json`, the file that fed the
board"*.

**THE ASYMMETRY THAT MANUFACTURED THE FALSE CLAIMS.** `audit-coverage-gaps.ps1` selected the **newest**
regular capture per store; the board was built from whichever was newest **at build time**. Any capture
landing after the board contains products the engine never saw, and every one of them then read as
*"the store carries it and a too-strict regex dropped it"* - **a rule finding raised for a row no rule
was ever offered.** The capture set is bounded by the board's own date now, and skipped files are
NAMED in the output, because an exclusion nobody can see is its own blind spot - which is the mistake
this whole change is about.

**It is a pre-condition on one alert, not a general mechanism**, and it touches no store and costs no
75-minute pull - which is why it is affordable where the re-probe the item costed was not.

**HONEST RESULT: it changed nothing today, and that is the correct behaviour rather than a
disappointment.** Before and after are identical on the live board - 21 gaps, 0 actionable, 21
explained by the engine's own basis and band gates - because no regular capture is currently newer
than the board. **A guard that fires on a healthy day is a guard that gets ignored.**

**So it was proved by CONSTRUCTING the condition instead:** a capture dated after the board made the
audit print *"SKIPPED 1 regular capture(s) NEWER than the board (2026-09-08) - the engine never read
them"*, and removing it returned the audit to silence on that line. **Unproven against a live false
alarm**, and it will stay that way until a day when a capture lands late - which is exactly the
2026-09-01 shape.

**The prize this defends, unchanged:** 16 of 23 individual claims across three dated firings were not
what the alert said they were, and this alert type has SENT four times - 4 of the 73 alerts ever sent,
all the same shape, all reaching a real inbox.

**`[RUNG 1 RAN 2026-09-09. This is the opposite of I32's result and the two items were right not to
be merged.]`**

*"Count how many store-cold, zero-row and carry-expiry verdicts were reached on exactly one
observation, and how many of those were later reversed. That number is the size of the prize and
nobody has it."*

**The prize, from the queue's own closing notes - verbatim, not paraphrased:**

| firing | what the alert claimed | what triage found |
|---|---|---|
| 2026-08-22 | 15 stores dropped from a commodity | *"**Nine of fifteen were capture-rotation artifacts already gone.**"* |
| 2026-09-06 | 3 too-strict includes | *"**Two of three ... were false** ... the audit read 'not ingested' as 'no rule can see it'."* |
| 2026-09-07 | 5 too-strict includes | *"**False alarm as phrased - no include was too strict in any of the five.** Four were the auditor's own blind spots."* |

**16 of 23 individual claims across three dated firings were not what the alert said they were.** And
`grocery/alert-log.txt` shows this alert type SENT on 09-01, 09-02, 09-06 and 09-07 - **4 of the 73
alerts ever sent**, all the same shape, all reaching a real inbox.

**53 of 139 closed items carry a reversal or supersede in their notes.**

## The finding is SHARPER than the item's framing, and this matters for what gets built

The item proposed a **second INDEPENDENT observation** - a different search term, a different
session. But these reversals were not the store being misread. They were **the auditor's own blind
spots**: rotation artifacts already gone, an expired ad file the engine had correctly refused, rows a
reasoner had already ruled that the auditor could not see.

**So the second observation that would have caught them is not a re-probe of the store.** It is
exactly what triage did BY HAND on 2026-09-01 and wrote down: *"Not a capture-depth artifact (tested
first: every candidate lives in `walmart-regular-2026-08-31.json`, the file that fed the board)"*.
**The cheap second observer is a check against the capture file that fed the board, inside the
auditor, before it raises.** That is a pre-condition on one alert, not a general mechanism - and it is
far cheaper than the re-probe the item costed, because it touches no store and no 75-minute pull.

**Not built here.** It changes what `audit-coverage-gaps.ps1` will raise, on a live daily alert that
reaches a real inbox, and the right moment to make that change is with a day's board in front of you.
The estate has already been narrowing it the right way on its own: that auditor has learned the
NOT-INGESTED verdict, to skip expired deals files, and to read `known-wrong.json`.

**I32 was PARKED at 5% on the same data. This is not that item**, and the table above is why: a
duration window filters a transient real condition; this filters a broken instrument.

**Source.** `monitoring-and-observability-for-development-and-devops` (IBM/Coursera), item 15. The
synthetic check loop it describes does not alert on a failing probe. When a checkpoint reports an
error the system **immediately re-runs the same check from a DIFFERENT checkpoint**, and only when
the second one reports the same error is it declared *confirmed* and an alert sent. Routed to
`reliability-craft/telemetry-signals.md` 5, registered as claim C76.

**Why it matters here.** This estate's capture layer is synthetic monitoring in everything but name:
scripted transactions replayed on a schedule against seven store front-ends we do not control. And
it fails in the field the way synthetic checks do - a bot wall, a lazy-load that did not scroll, a
session that expired. The memory `bot-wall-verdict-discards-its-evidence` already records that a
"store is cold" verdict was reached on one probe and was wrong, and its remedy is written as
advice - *re-probe one term before calling a store cold* - rather than as a mechanism anything
enforces. `fareway-capture-defects` is the same shape: a repeated exact 9 is an unscrolled page, not
a shelf with nine items on it.

**This is NOT item I32 and the two should not be merged.** I32 is about a condition having to
PERSIST - the same observer, watched for longer, which is a duration window. This is a **second
INDEPENDENT observation** - a different observer, immediately. They catch different things: duration
filters a transient real condition, a second observer filters a broken instrument. An estate whose
probes are the thing most likely to be broken needs the second one at least as much as the first.

**Three rungs, and only the first should happen without a ruling.**

1. **Count what a second observation would have changed.** Read the alert history and the capture
   logs and count how many store-cold, zero-row and carry-expiry verdicts were reached on exactly
   one observation, and how many of those were later reversed. That number is the size of the prize
   and nobody has it. This is a read.
2. **Then decide whether the second observation is affordable.** For a store pull it is not free -
   Walmart's full pull is ~75 minutes - so the honest form is probably a re-probe of ONE term rather
   than a re-run of the pull, which is exactly what the bot-wall memory already advises by hand.
3. **Only then, mechanise it** for the verdicts rung 1 says were worth it. Note the precondition:
   the estate has one checkpoint, so "a different checkpoint" is not literally available. The
   available second observers are a different search term, a different session, or a different
   store's agreement - not a different location.

**What it would touch.** Rung 1 reads `grocery/alert-log.txt`, `grocery/out/capture-cursor-log.jsonl`
and the coverage ledger. Rungs 2 and 3 would touch the capture verdict paths and `send-alert.ps1`.
No gate weakens either way: this makes a verdict harder to reach, not easier.

### I36 - Nothing in this repo has a stated log retention, and the logs are committed, so they grow forever `DONE - THE POLICY IS WRITTEN: KEEP FOREVER, DELIBERATELY, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08.]`** `docs/RUNTIME-MAP.md` now carries a **Log retention, stated** section
naming all four committed logs, their measured sizes, why each is kept, and the answer: **keep
forever, deliberately.**

That is what the item asked for and the reasoning is recorded rather than asserted. **The dimension
that computes rather than asserts is discovery-and-resolution time, and it sets a FLOOR:** retention
must exceed how long this estate takes to notice a defect, and several here were found weeks later, so
the floor is months. Cost-effectiveness is the only dimension pulling the other way and at roughly a
megabyte in total it pulls very weakly.

**Re-measured 2026-09-08 rather than copied from the item**, because the item's figures were two days
old: `ad-cycle-log.txt` **862,179 B / 7,324 lines** (the item said 747,309), `coverage-ledger-history.jsonl`
**263,741 B** (said 253,363), `capture-cursor-log.jsonl` **18,075 B**, `alert-log.txt` **9,726 B**.
Growth is real but slow.

**A trigger is recorded so "forever" does not become unexamined again**: any of these passing ~10 MB,
or a new appender that writes per-ROW rather than per-run. At that point the question is rotation, not
deletion.

**Explicitly NOT built: a pruning job.** Nothing here is close to big enough to justify code that
deletes evidence, and deletion is the one direction that cannot be undone. **A stated forever is a
policy; an unstated forever is an accident that looks identical** until something starts appending a
megabyte a run.

**Source.** Same course, item 38, which sets a retention period from six analytical dimensions
rather than one number: criticality, security, system maturity, run frequency, cost-effectiveness,
and your own discovery-and-resolution time. Routed to
`reliability-craft/logging-and-tracing.md` 3, registered as claim C74.

**Measured 2026-09-07 in this checkout.** The only retention policy that exists anywhere in this
estate is on the **R2 buckets**, declared in `ops/cloudflare-estate.json` and guarded by
`ops/audit-cloudflare-estate.ps1`, which correctly treats a shortened retention as the dangerous
direction. A `grep` for retention, rotation or pruning across `ops/` and `grocery/*.ps1` returns
that audit and nothing else. Meanwhile, in git and growing without bound:

| File | Size |
|---|---|
| `grocery/ad-cycle-log.txt` | 747,309 B |
| `grocery/out/coverage-ledger-history.jsonl` | 253,363 B |
| `grocery/out/capture-cursor-log.jsonl` | 16,688 B |
| `grocery/alert-log.txt` | 9,073 B |

These are appended by the daily chain and committed by the ~07:00 bot, so every byte is permanent
and is carried by every clone and every worktree forever. That is not automatically wrong - it is
cheap, and history has repeatedly been the thing that settled an argument here - but **it is a
policy nobody has stated**, which means nobody can say whether the current answer is right.

**What the six dimensions say about these specifically**, so the ruling has something to rule on:

- **Criticality and security** argue for keeping `alert-log.txt` and the capture logs: they are the
  only record of what the automated chain decided while nobody was watching.
- **Discovery and resolution** is the dimension that computes rather than asserts, and it sets a
  FLOOR: retention must exceed the time this estate typically takes to notice and fix a defect.
  Several defects here were found weeks after they started, so the floor is months, not days.
- **Cost-effectiveness** is the only one pulling down, and at three quarters of a megabyte it is
  currently pulling very weakly. **This is the honest reason the item may end `PARKED`.**

**Not to be confused with I33.** That item found a 15-day latency series sitting in git and concluded
that *"the real gap is not retention, it is that nothing has ever read this"* - which is true and is
a different question. I33 is about a series nobody consumes; this is about a policy nobody has
written. A file can be read regularly and still have no stated lifetime.

**The rung.** Write the answer down, per file, wherever the file is described - even if the answer
is "keep forever, deliberately, because it is small and it is evidence". A stated forever is a
policy; an unstated forever is an accident that looks identical until the day something starts
appending a megabyte a run. **Explicitly NOT proposed: a pruning job.** Nothing here is big enough
to justify code that deletes evidence, and deletion is the direction that cannot be undone.

**What it would touch.** One paragraph in `docs/RUNTIME-MAP.md` or beside each writer. No code.

---

### I37 - 217 self-test files, and nothing has ever asked whether their cases would notice the detector being wrong `DONE - THE PROBE RAN, FOUND A REAL GAP, AND THE GAP IS CLOSED, 2026-09-09` `queue-4`

**`[CLOSED 2026-09-09. The cheap experiment ran and it paid, which is the outcome the item asked
for and did not assume.]`**

*"Do the cheap experiment before proposing the tool. Mutate ONE real detector and run its self-test.
A red result shrinks this item; a green one sizes it."*

**Eight single, compiling mutations across three detectors** - operators taken from this estate's own
recorded scars, which read almost as a mutation table: an off-by-one comparison, a lost regex anchor,
a count that loses its guard, an equality flipped.

| detector | mutation | verdict |
|---|---|---|
| `audit-backlog-status` | `-gt 1` becomes `-ge 1` | KILLED |
| `audit-backlog-status` | `-eq 0` becomes `-lt 0` | KILLED |
| `audit-backlog-status` | reversibility 'exactly one' guard loosened | KILLED |
| **`audit-backlog-status`** | **heading regex loses its `^` anchor** | **SURVIVED** |
| `audit-python-pins` | pin equality flipped | KILLED |
| `audit-python-pins` | normaliser stops collapsing `-_.` | KILLED |
| `consistency-oracle` | case-sensitivity dropped | KILLED |
| `consistency-oracle` | differing-field test inverted | KILLED |

**7 of 8 killed. The survivor is the whole value of the item.**

## What the survivor was, and it is not hypothetical

Dropping the `^` from `'^###\s+([A-Z][0-9]+)\s+-\s'` left **the entire suite green**. No case asserted
that a `###` has to start the LINE - and **this ledger quotes item headings inline and inside fenced
code blocks constantly.** Every one of those would have been parsed as a real item: the board count
inflated, and a quoted heading reported as *declaring no state*, which is a hard finding. The suite
had twenty-one cases and not one of them looked at the left-hand edge of the line.

**Two must-not-fire cases now cover it** - a heading quoted mid-line, and an indented code-block line.
**Re-ran the probe: 8 of 8 killed, 0 survived.** The suite's own tally line was corrected from 8
must-not-fire to 10 in the same change, because a stale count is the defect this estate has a rule
about.

## Why this closes rather than becoming a tool

The item asked whether the fixture suites would notice the detector being wrong. **On this sample they
notice 7 times in 8**, and the eighth was found and fixed in the same hour. That is a high kill rate,
which the item said would shrink it - and building a general mutation runner to keep re-confirming a
7-in-8 result is the tool that costs more than the finding.

**Both prohibitions were honoured.** It is NOT a gate and nothing was wired into `run-gates` - a
mutation score that has to stay above a number would be a ratchet nobody asked for. And **it never
edited a tracked file**: every mutant ran from a temp mirror carrying `ops\` and `lib\`, and all three
originals were verified byte-identical by md5 afterwards. The mirror also runs the UNMUTATED file
first and refuses to score a detector whose baseline fails there, so a broken harness cannot be
reported as a killed mutant.

**THE TRIGGER: run it again against a detector whose logic you have just rewritten.** That is when a
survivor is most likely and cheapest to act on. `scratchpad/i37.py` is the throwaway; the method is
four lines of `re.subn` and a temp mirror.

**Source.** `introduction-software-testing` (queue-4 course 5, worked 2026-09-07), items 30 and 28.
Routed to `software-craft/test-design-and-oracles.md` 6 and cross-linked from
`tests-as-safety-net.md` 3b. Registered as claim C81, which says plainly that the value HERE is an
inference and not a measurement.

**The gap, stated exactly.** Measured in the main tree on 2026-09-07: **217** `.ps1` files carry a
`-SelfTest`, and the three fixture labels occur **1,375** (`MUST FIRE`), **211** (`MUST NOT FIRE`)
and **1,076** (`CLEAN TWIN`) times. Every one of those cases was written by someone who already knew
what the bug was - `tests-as-safety-net.md` 3b calls this discipline *fixture-after* and records that
the estate says so in its own comments, in the form `CLEAN TWIN - THE ONE THAT MADE THIS FILE
NECESSARY`. That is a good discipline and it has a hard ceiling: **the suite's reach is bounded by
what has already gone wrong.**

Mutation testing asks the complementary question. Take a detector, make one small compiling change
to it - a `-gt` that should be `-ge`, a regex that loses a `\b`, two same-typed variables swapped -
and run its own self-test. If the suite stays green, that mutant *survived*, and it names the exact
line where a case is missing. The estate's recorded scars are almost a list of the mutation
operators: off-by-one comparisons, a norm regex without a word boundary that turned `Garlic` into
`arlic`, `@($null).Count` being 1.

**What it would touch.** Nothing in production. The cheapest useful version is a one-off script that,
for a named `.ps1`, applies a small operator table to the source, writes the mutant to a temp copy,
runs `-SelfTest`, and records killed-or-survived. Run it against five or six `ops/` detectors first.

**Do the cheap experiment before proposing the tool.** Mutate ONE real detector by hand and run its
self-test. A red result shrinks this item; a green one sizes it. That is an hour, and it is what C81
asks for.

**Two things it must not become.** It is not a new gate - a mutation score that has to stay above a
number on every push is a ratchet nobody asked for, red on day one, which
`.claude/rules/ops-and-gates.md` already forbids. And it never edits a tracked file: mutants are
written to temp copies and the original is restored by hash, per the estate's own
`neuter-numbers-get-predicted-not-measured` rule.

---

### I38 - Every parser here has only ever seen inputs a person wrote, and randomness is refused estate-wide on reproducibility grounds that do not apply to it `DONE - RULED IN, BUILT FOR ONE PARSER, AND IT FOUND TWELVE` `queue-4` `1-WAY` `RUNG1 RULING`

**`[CLOSED 2026-09-09. Brad ruled: the refusals do not extend to a seeded generator. Build it for one parser.]`**

**The ruling is recorded in `.claude/rules/ops-and-gates.md`** so the next session is not blocked by
the same ambiguity: the three `Get-Random` refusals cover **work selection**, not test input, because a
seeded generator is reproducible by construction.

**Shipped: `ops/probe-hostile-input.ps1`**, pointed at `Import-CaptureCsv` - the first target because
**every builder reads captures through it** and a capture is the input we author least.

**IT FOUND REAL DAMAGE ON THE FIRST RUN. 60 seeded cases: 17 refused, 31 survived, and 12 ACCEPTED
CORRUPT INPUT** (seed 20260909, replayable). Two classes:

| what got through | cases |
|---|---|
| a **NUL byte** surviving into a parsed field | 3 |
| a **20,000-character** field passing through intact | 9 |

**`ACCEPTED-CORRUPT` is the outcome the vocabulary was missing.** Refusing is fine and surviving is
fine. Returning rows that carry damage looks exactly like success to every builder downstream, and
those rows get priced.

**A THIRD RESULT WORTH READING, which the probe does NOT flag:** `number-to-text` **survived with 3
rows** - replacing a price with `not-a-price` parses cleanly, because validating a price is not this
parser's job. That is arguably the most dangerous of the three for a pricing estate, and it is a
finding about where the validation boundary sits rather than a defect in `Import-CaptureCsv`.

**THE PROBE FOUND A DEFECT IN ITSELF FIRST, and it is the better finding.** Its own must-fire
(*"every malformation kind actually changes the input"*) failed at 10 of 12. Both apparent no-ops had
one cause: **PowerShell's `-ne` on strings is culture-sensitive, and culture-sensitive comparison
IGNORES NUL characters.** `('Bana' + [char]0 + 'nas') -ne 'Bananas'` evaluates to **`$false`** despite
a length difference. **The default operator is blind to precisely the corruption class the probe exists
to find.** Every comparison in the file is `[StringComparison]::Ordinal` now, both cases are fixtures,
and the trap is written into the rules file beside the `[StringComparer]::Ordinal` hashtable trap it
rhymes with.

**A REPORT, NOT A GATE**, per the standing rule and per the ruling: it exits 0 and only exits 2 under
`-Strict`. Twelve findings on day one is exactly the backlog a red gate would train people to ignore.

**Verified:** self-test **10 of 10**, exit 0, led by the two must-fires above and a clean twin that an
unmodified capture still parses to 3 rows **through the real parser**. `run-gates` exit 0.

**SCOPE OF A CLEAN REPORT: UNSOUND, emphatically.** It tries the malformations it knows how to make,
against **one** parser of the 255 files that mention `ConvertFrom-Json`. A clean report is not evidence
of robustness.

**NOT DONE, and it is a separate decision: hardening `Import-CaptureCsv` itself.** Refusing a NUL or a
20,000-character field changes what **every builder** accepts, so it could drop rows that pass today.
That is a change to the shared capture path and wants its own ruling.

**Source.** Same course, items 4 and 8, plus the queue-4 entry that chose it. Routed to
`software-craft/test-design-and-oracles.md` 5, and recorded in that file's section 11 as a gap the
course names but does not fill.

**Why this estate in particular.** It parses text it did not author all day - scraped store HTML,
vendor JSON feeds, Walmart payloads whose price shape has already moved twice, ad PDFs, LLM
returns. Measured 2026-09-07 in the main tree, worktrees and `archive/` excluded: **255 `.ps1` files
mention `ConvertFrom-Json`**, over **819 matching lines** (lines, not verified call sites - some are
comments). A `grep` for self-test cases whose `MUST FIRE` line mentions malformed, truncated,
corrupt, empty or invalid input returns **6**. That 6 is a **lower bound from one narrow pattern**,
not a census: a case could test hostile input while wording its label differently. The order of
magnitude is what the item rests on, and it does not change if the true figure is 20.

**The blocker is a ruling, not a tool, and this is the part worth reading.** `Get-Random` appears in
exactly **three** files in the tree and **all three are refusals**:

| File | What it says |
|---|---|
| `grocery/build-verification-sample.ps1` | "DETERMINISTIC, NOT RANDOM. No Get-Random anywhere" |
| `grocery/test-auditors.ps1` | "Get-Random would silently make every past worklist unreproducible" |
| `lib/ghost-lib.ps1` | uses the attempt index as jitter instead |

**Each of those is correct for what it refuses**, which is unreproducible *work selection* - a
verification sample or a retry schedule that cannot be replayed. None of them is an argument against
generated test input, because **a seeded generator is reproducible**: record the seed beside the
failure and the case replays byte for byte, which is exactly what the deterministic-sample rule was
protecting. The risk is that three strongly-worded refusals get read as one estate-wide ban on
`Get-Random`, and the ruling this item needs is simply that they do not extend to a seeded test-input
generator.

**What it would touch, if Brad rules it in.** One helper that generates hostile variants of a known-
good fixture (truncate at a random offset, flip a byte, empty the file, nest deeper, swap a number
for a string, insert a lone `"`), a seed printed on every run and re-fed on failure, and the verdict
being *crash-or-hang* rather than a compared output - which is the one oracle that needs no expected
value and is what would have caught the Zune loop in the course's own worked example. Scope it to
the JSON and HTML entry points, not to the whole tree.

**The honest counter-argument.** Most of these parse points read files this estate itself wrote one
stage earlier over the git-bus, where the input is not adversarial and a fuzzer would find nothing.
The value is concentrated at the boundary where outside bytes first arrive - the capture lanes and
the feed readers - and an item that fuzzes everything would spend its budget on the wrong 200 files.

**UPDATED 2026-09-08, by `automated-analysis` (queue-4 entry 20, raided). The ruling this item needs
has not changed; three things about its COST have.** The source that filed this item named fuzzing
and did not teach it. The next course in the same specialization does, and it makes the item
cheaper in three specific ways. Full material: `software-craft/test-design-and-oracles.md` 5.

1. **Crash-or-hang is the entire oracle at the boundary this item is scoped to.** The objection
   "generated inputs need generated expected outputs" does not apply to a parser being fed hostile
   bytes: an error is a pass, an assertion violation is a pass, and only a crash or a hang is a
   finding. So the build is a generator and a `try/catch`, not a test suite.
2. **A property-based test can pass having run nothing, and that is this estate's own worst shape.**
   Guard clauses that reject out-of-envelope draws are mandatory, and under a random generator they
   can reject nearly every draw while the run still reports success. **Whatever gets built must
   print the number of draws that REACHED the assertion**, exactly as `lib/guard-contract.ps1`'s
   `<NAME>-COMPLETE` marker exists so that "no findings" and "died halfway" are distinguishable.
3. **There is a cheaper adjacent item that needs no ruling at all**, because it involves no
   randomness whatsoever: the consistency oracle, filed below as **I65**. If the objection to this
   item is the `Get-Random` question, I65 sidesteps it entirely and should go first.

**Still not answered by the new course:** shrinking a failing input to a minimal one, which is the
thing that makes a fuzz finding actionable rather than a 40 KB blob. Neither course teaches it.
And no fuzzing or property-based tool exists for PowerShell here. **Checked 2026-09-08 and worth
recording because the grep is misleading**: `hypothesis` matches under
`sidecar/.venv/Lib/site-packages/` only inside numpy's and anyio's own vendored test files, which
import it conditionally. There is no `hypothesis` package installed.

---

### I39 - 217 self-test files assert on a target set none of them prints, so a vacuous pass is invisible `PARKED - RUNG 1 RAN 2026-09-09 AND THE NUMBER IS HIGH: 151 OF 180 ALREADY REPORT` `queue-4`

**`[CLOSED PARKED 2026-09-09. "Do not build anything until that number exists." It exists, and it is
high, which the item said would shrink it.]`**

**Measured over the whole tree, worktrees and `archive/` excluded. 180 `.ps1` carry an actual
`if ($SelfTest)` BRANCH** - not the 217 the item quotes, which counted files merely *mentioning*
`SelfTest`. Different test, said out loud, because a count with no stated test cannot be checked.

| | |
|---|---|
| self-tests that PRINT a resolved/case count a reader could compare | **151 of 180 (84%)** |
| printing nothing comparable | 29 of 180 |
| Python suites carrying `--selftest` | 43, of which **42 print a case count** |

**And the item's own counter-argument measured, which is the sharper half.** A detector whose target
set is a LITERAL LIST in the same file cannot resolve empty, so the risk lives only where the target
set is DISCOVERED - a glob, a recurse, a query:

| | |
|---|---|
| suites whose target set IS discovered | 143 of 180 |
| **of those, printing no resolved count - the population that actually matters** | **23 of 143** |

**Twenty-three files, named.** Among them `grocery/send-alert.ps1`, `grocery/set-board-cell.ps1`,
`grocery/publish-deals-page.ps1`, `meal-prep/pipeline/build-card2.ps1`. That is a nameable list, not
an estate-wide programme.

**Why it parks rather than becoming rung 2.** At 84% already compliant the general build is
re-confirming what is mostly true, and the item is explicit that **a threshold on resolved counts must
not become a gate** - it would be red on day one, which the ops rules forbid. The 23 are worth a line
each *when someone is already editing them*, not a sweep.

**THE FORWARD RULE, which is the durable half and is now in `.claude/rules/ops-and-gates.md`:** a
suite whose target set is DISCOVERED prints what it resolved. "No findings" and "the glob matched
nothing" are the same bytes otherwise, and that shape has bitten this estate at least five separate
times.

**Unchanged and still right:** the daemon suite solved this properly for one suite with
`--names-out`/`--names-diff` and exit 2 on a removed case. It compares CASES rather than reporting a
resolved count, so it still cannot see a lost flag inside a case that runs.

**Source.** `chaos-engineering` (KodeKloud, Nasia Ullas, queue-4 course 6, worked 2026-09-07), items
15 to 17. Routed to `reliability-craft/rca-and-chaos.md` 3.2 and 3.3, and cross-linked from
`reliability-craft/estate-inventory.md`. Registered as claim C82.

**Where it comes from.** The course's most instructive moment is an experiment that never ran. The
hypothesis was that terminating 50% of the instances behind an auto-scaling group would not affect
the application; the targeting resolved to an empty set and the run aborted, because the group was
running a single instance and 50% of 1 is 0. The tempting reading is a targeting bug. The correct
reading is that the empty target set WAS the finding - the group's desired and minimum capacity were
both 1, so the redundancy the hypothesis assumed did not exist, and a real termination would have
caused downtime. The tool offers two controls against this and both are free: **preview the resolved
target set before running**, and **read the resolved count in the output afterwards.**

**The estate's exposure, stated exactly.** This is the estate's single most-repeated failure shape
under a new name. `lib/guard-contract.ps1` exists because "no findings" and "died halfway" are
indistinguishable without a `<NAME>-COMPLETE` marker, and the notes say that shape has bitten at
least five separate times. `@($null).Count` is 1, so an absent field scores 1 and a naive "did it
grow?" check passes when nothing happened. `exit-code-first-tally-second` exists because deleting a
case left exit 0. A candidate pool that legitimately pops nothing looks the same as a broken query.
Every one of these is the same defect: **an assertion ran against a set nobody counted.**

**What already exists, so this is not started from zero.** The daemon self-test solved it for one
suite - `--names-out` / `--names-diff`, exit 2 on a removed case. That is exactly the right control.
It is one suite out of 217, and it compares CASES rather than reporting a resolved count, so it
cannot see a lost flag inside a case that still runs.

**Rung 1 is a measurement and it is cheap.** For each `.ps1` carrying a `-SelfTest`, count the
fixture cases it declares and check whether the run prints that count anywhere a reader could
compare. The output of rung 1 is one number: how many of the 217 report what they resolved. Do not
build anything until that number exists - if it is high the item shrinks, and if it is low it sizes
the work.

**What rung 2 would touch, if the number justifies it.** A line in each self-test harness printing
the resolved case count alongside the pass/fail tally, and the existing `<NAME>-COMPLETE` convention
extended to carry it. **Not a new gate.** A threshold on resolved counts would be red on day one for
a backlog nobody is about to clear, which `.claude/rules/ops-and-gates.md` already forbids; the
ratchet shape with a high-water mark that may only go down is the only acceptable form if it ever
becomes enforced at all.

**The honest counter-argument.** A detector whose target set is a literal list in the same file
cannot resolve empty, and a good fraction of the 217 are that shape. The value is concentrated where
the target set is DISCOVERED - a glob over the tree, a filter over a board, a query against a pool -
which is a much smaller set than 217 and is what rung 1 should really be counting.

----

### I40 - the git-bus is an untyped producer/consumer contract with no schema and no version `PARKED - RUNG 1 RAN 2026-09-09 AND SHRANK IT: THE BUS IS NAME-ADDRESSED` `queue-4`

**`[CLOSED PARKED 2026-09-09. The item's own honest counter-argument was right, and the read is what
settled it.]`**

Rung 1 asked for one table: for each producer/consumer contract, does the consumer read fields **by
NAME or by POSITION**? That split is the whole risk ranking - an added key is harmless to a
name-addressed reader and **silently shifts every value** for a position-addressed one.

**Measured 2026-09-09 over 635 first-party files (525 `.ps1`, 110 `.py`), worktrees, `archive/`,
`.venv` and `out/` excluded. 505 of them parse a structured input at all:**

| | |
|---|---|
| NAME-addressed only | **378 of 505** |
| both shapes in one file | 88 of 505 |
| **POSITION-addressed only** | **39 of 505 (7.7%)** |

**And the 39 are not the bus.** Almost all of them are under `.claude/skills/lesson/` - Ghost API
helpers splitting a response line - not the grocery capture-to-board chain the item was worried
about. **The git-bus itself reads by name**, through `ConvertFrom-Json` and `Read-JsonFile`.

So the item's own counter-argument holds exactly as written: *"if almost everything is
name-addressed the item shrinks to a handful of files"*. It does, and they are the wrong handful to
build a schema registry for. **A declared shape per bus file, checked at write time, would be a
large build against a risk the read cannot find.**

**THE TRIGGER THAT REOPENS THIS:** a positional reader appearing in the capture-to-board chain, or a
feed changing to a delimited format. Neither is true today.

**One number corrected on the way:** the item quotes **27,154** JSON files acting as data. It is now
**28,226**. That growth is real and it is not an argument for the item - the count includes every
cached artefact under `out/`, most of which is written and read by the same script, which is not a
contract at all. The item said so itself.

**Source.** `automate-data-pipelines-schema-evolution` (Coursera, content credited to Jason Rand,
queue-4 course 7, worked 2026-09-07), items 6 to 9. Routed to
`database-craft/changing-a-schema.md` and `data-quality-craft/checks-and-thresholds.md` 3.

**Where it comes from.** The course's whole subject is that a structure change arriving unannounced
at a consumer is the leading cause of silent pipeline failure, and that the fix is a declared
contract plus a check that fires when reality leaves it. `docs/RUNTIME-MAP.md` documents the
git-bus: one runtime writes a file that another runtime reads through the repo. That is a
producer/consumer interface with **no declared schema, no version field and no compatibility rule**,
across roughly 27,154 JSON files acting as data. Neither side can tell whether the other changed.

**Why it matters here specifically.** The estate already knows this shape hurts. Its own record of
it is `graph/pipeline/audit_graph_durability.py`, which notes that `golden-test.ps1` "was ungated
while being the only thing that caught a schema change" - a single unscheduled test was the whole
detection surface. And several engines here read the newest COMMITTED artifact, so a producer's
shape change reaches a consumer through a commit, with no handshake anywhere in between.

**What rung 1 would be, and it is a measurement rather than a build.** Count the distinct
producer/consumer file contracts on the bus and, for each, whether the consumer reads fields **by
name or by position**. The name/position split is the whole risk ranking: an added key is harmless
to a name-addressed reader and silently shifts every value for a position-addressed one. Output is
one table. Do not build a schema registry before that table exists - if almost everything is
name-addressed the item shrinks to a handful of files.

**What rung 2 would touch, if the number justifies it.** A declared shape per bus file, checked at
write time by the producer rather than at read time by the consumer, because the producer is the
only party that knows the change was intentional. **Not a new gate on day one** - a shape assertion
across 27,154 files would be red immediately for a backlog nobody is about to clear, which
`.claude/rules/ops-and-gates.md` forbids. The ratchet shape is the only acceptable enforced form.

**The honest counter-argument.** Most of those 27,154 files are written and read by the same script,
which is not a contract at all, and the real bus is much narrower than the file count suggests. That
is exactly what rung 1 is for.

----

### I41 - a `graph.db` schema change today has no recorded procedure, and no rollback `DONE - RULED: RECORD PLUS DETECTOR, AND NOT A MIGRATION CAPABILITY` `queue-4` `1-WAY` `RUNG1 RULING`

**`[CLOSED 2026-09-09. Brad ruled: a written record plus a schema detector. NOT staged migration.]`**

**A COUNT IN THIS ITEM WAS WRONG AND IS CORRECTED HERE.** It says *"the 18 live SQLite tables"*.
Measured 2026-09-09 from `sqlite_master` on the live database, and cross-checked against
`graph/sqlite/schema.sql`: **11 tables, 4 views, 24 authored indexes** (36 total indexes less 12
SQLite `sqlite_autoindex` entries, which are not authored schema). `schema.sql` declares the same 11
by name, so the two agree and there is no third source. **18 reproduces from nothing.**

**Shipped: `graph/audit_schema_change.py`**, live half on `capture-watchdog` check 5a3b, `--selftest`
discovered by `run-gates`. Founding baseline recorded at fingerprint `014da3370767862b`.

**THE DETECTOR IS WHAT MAKES THE RECORD REAL, and that is the whole design.** A written procedure
nobody is forced to follow is an intention, and **an intention has no exit code**. So the only way to
clear the detector is `--accept`, and **`--accept` is the call that appends to
`docs/SCHEMA-CHANGES.md`**. The record cannot be skipped, because skipping it leaves the check red.

**Two refusals on the accept path, both verified:** `--accept` without `--note` refuses; `--accept`
without either `--backup <path>` or `--no-backup-reason "..."` refuses. `graph.db` has no undo layer,
so **skipping the pre-change copy has to be a stated decision rather than an omission**.

**The baseline is a FILE, not a `schema_version` table, deliberately.** Adding a version table to the
live 127 MB database is itself a schema change against the thing with no undo, which is the exact risk
this item is about.

**Verified by making it fire against a real database, not a fixture:** `graph.db` was copied to a
scratch path, `ALTER TABLE nodes ADD COLUMN retired_at TEXT` applied **to the copy**, and the audit
exited **2** naming `table:nodes`. The live database was opened read-only throughout and its
fingerprint is unchanged. Self-test **9 of 9**, led by a must-fire on an added column and a must-not-fire
that a pure reformat is **not** a schema change - whitespace is collapsed on purpose so it cannot cry
wolf over layout. `run-gates` exit 0, `pass=288 fail=0`.

**WHAT IS DELIBERATELY ABSENT: staged migration.** No expand-contract, no backfill, no rollback. All
four terms are absent from this estate and from 819 sections of the skill store, and building a
capability nobody here knows how to do would have been the larger bet the item warned about. **This
records what changed and why. It does not help you undo it**, and the file says so in its own header.

**Source.** Same course, sections 4 to 9 of `database-craft/changing-a-schema.md`. Registered as
claims C84 and C85.

**What was verified, and how.** Grepped 2026-09-07 across `ops/`, `graph/`, `lib/` and `docs/` for
`migrat`, `ALTER TABLE`, `schema.change` and `schema.version`. The 18 live SQLite tables have **no
migration script, no schema-version table and no change record**. What exists is one narrow gate
(`graph/pipeline/state.py --verify`, called a "migration gate" in `graph/README.md`, comparing state
coverage against the live board across one derivation change) and the accident noted in I40.

**Why it matters here specifically.** `graph.db` is 126 MB of live state, written nightly under WAL,
committed by the ~07:00 bot, with **no undo layer** (E1). A schema mistake made against it today has
no defined way back. The only recovery mechanism the estate currently has is
`database-craft/SKILL.md` section 8's rule to copy the file before running anything experimental.

**The ruling needed.** The course teaches the change-management wrapper and **none of the mechanics**
- it covers no expand-contract/parallel-change, no backfill and no rollback, and all four terms are
absent from our whole skill store as well (`--files` over 819 sections, 2026-09-07). So the question
is which of two things this estate wants: a lightweight written record per schema change (cheap,
proposed in `changing-a-schema.md` 4, uncorroborated as C84), or an actual staged-migration
capability, which nothing here currently knows how to do and which would want its own course first.
Recommending neither until Brad rules, because the second is much the larger bet.

----

### I42 - the estate runs ETL in `grocery/` and ELT in `graph/`, has never named which is which, and so never asks whether a transform's input is still obtainable `PARKED - RUNG 1 RAN 2026-09-08 AND THE ANSWER IS 'MOSTLY YES', SO THIS IS A DOCUMENTATION ITEM` `queue-4`

**`[RUNG 1 RAN 2026-09-08 on Brad's instruction - 'just do the free read'. Read-only; nothing was
written.]`** The item predicted the answer might be *"mostly yes, by accident"*, which would shrink it
to a documentation item. **It is, and it does.**

**Does the raw source response survive the transform? 11 of 11 lanes: YES. 8 of 11 are also in git.**

| lane | files | newest | in git |
|---|---|---|---|
| Hy-Vee | 57 | 2026-09-08 | yes |
| Family Fare | 55 | 2026-09-08 | yes |
| Baker's | 55 | 2026-09-08 | yes |
| **Aldi** | 24 | 2026-09-08 | **NO - gitignored** |
| **Walmart** | 30 | 2026-09-08 | **NO - gitignored** |
| Sam's Club | 54 | 2026-09-08 | yes |
| Fareway | 59 | 2026-09-08 | yes |
| ads (all stores) | 24 | 2026-09-08 | yes |
| **raw capture sink** | **1** | **2026-07-23** | **NO - gitignored** |
| url-inputs | 19 | 2026-09-08 | NO - gitignored |
| throttled / partial | 26 | 2026-09-08 | yes |

**404 files across the eleven lanes.** So the ETL lane is not destroying evidence the way the item
feared - the transform is re-run daily AND the inputs are kept.

**The narrower finding that survives, and it is the actionable half.** **Aldi and Walmart raw survives
ON DISK ONLY.** A machine loss, a `git clean`, or a fresh checkout takes them and they are **not
re-acquirable at any price** - a shop's shelf price on a given morning is gone. Those are also the two
stores whose pulls are hardest to repeat: Walmart's full pull is ~75 minutes and Aldi throws bot
walls. And `grocery/out/captures/`, which the name says is the raw sink, **holds one file dated
2026-07-23** - so whatever that directory was for, it is not carrying today's raw.

**That is a real exposure and it is NOT being fixed here**, because it is a retention decision about
disk in a repo the ~07:00 bot commits whole, and I36 just set the standing policy for exactly that
class (keep forever, deliberately, with a ~10 MB trigger). **The question is now decidable in one
line: should Aldi and Walmart's regular pulls be tracked like the other five?** Recorded here rather
than opened as a new id.

**HONEST LIMIT OF THIS READ, stated so the table is not over-claimed.** It establishes that a file of
the right SHAPE exists and how fresh it is. **It does NOT prove the file is the store's response
verbatim** rather than a normalised row this estate composed - `[[extractor-raw-is-not-verbatim]]`
records exactly that trap on the recipe side. Proving verbatim-ness needs one file opened per lane
against its pull script, and that was not done.

**The ETL/ELT naming half stands as filed and is the documentation this item now is:** `grocery/` is
ETL (transform re-run daily rather than the raw being kept - which is why `known-wrong.json` exists),
`graph/` is ELT-ish (events ingested as they arrived, derivations computed from them, so a derivation
change can be re-run over history). Neither word appears in any first-party file. **The axis worth
keeping is neither: it is whether the source is RE-ACQUIRABLE**, and for a shelf price it is not.

**Source.** `etl-and-data-pipelines-shell-airflow-kafka` (Coursera, IBM, Yan Luo, queue-4 course 8,
worked 2026-09-07), module 1. Routed to `data-quality-craft/moving-data-in-flight.md` sections 1, 3
and 7. Claims C87 and C88.

**Measured 2026-09-07**, main checkout, worktrees and `sidecar/.venv` excluded. Neither `ETL` nor
`ELT` appears in any first-party file in this repo. The only hits are third-party packages under
`sidecar/.venv`.

**What is actually true, and it is a real split rather than an inconsistency.**

| Lane | Shape | The bargain it takes |
|---|---|---|
| `grocery/` capture to board | **ETL** - pull, normalise, write `comparison-*.json` | transform is re-run daily instead of the raw being kept. `known-wrong.json` exists because of this |
| `graph/` | **ELT-ish** - events ingested as they arrived, derivations computed from them | a derivation change can be re-run over history, which is only possible because the raw survived |

**Why it matters here specifically.** The course's one careful teaching is that an ETL transform is
a one-way door **unless the raw is stored**, and the axis it never names is whether the source is
re-acquirable. A shop's shelf price on a given morning **is not re-acquirable at any price**. So
every point in the capture lane where a raw response is parsed and discarded is a place where
evidence is destroyed and nobody decided to destroy it.

**What rung 1 would be, and it is a read rather than a build.** For each capture lane, answer one
question: after the transform, does the raw source response still exist anywhere on disk or in git?
One table, one row per store. `grocery/out/` already holds a lot of intermediate JSON, so the answer
may be "mostly yes, by accident", which would shrink this to a documentation item.

**The ruling needed.** If the answer is "no" for any lane, the question is whether raw retention is
worth its disk cost against a repo the ~07:00 bot commits whole and I36's unbounded log growth. That
is a trade Brad decides, not one a course run decides.

----

### I43 - the estate records per-stage latency for one chain, commits it daily, and has never read it to name a bottleneck `DONE - THE BOTTLENECK IS NAMED: `sweep`, 80.2% OF THE NIGHT, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08. Rung 1 ran and it answered both of the questions it was supposed to.]`**

The `stages` array in `grocery/out/logs/graph-nightly-status.json` had never been read. Walked over
**16 committed nights, 2026-08-23 to 2026-09-08**, denominators being nights that RECORDED each stage
rather than nights (a stage absent from a night is absent, not zero):

| stage | nights | median s | share of the 162 s median night | cv |
|---|---|---|---|---|
| **sweep** | 16/16 | **130.0** | **80.2%** | **0.14** |
| ml-eval | 1/16 | 41.0 | - | - |
| stage1 | 12/16 | 24.5 | 15.1% | 0.17 |
| serve | 16/16 | 8.0 | 4.9% | 0.57 |
| resolve | 12/16 | 2.0 | 1.2% | 0.13 |
| emit | 16/16 | 2.0 | 1.2% | 0.20 |
| defs | 16/16 | 1.0 | 0.6% | 0.88 |
| stop / hunter / durability | 16, 14, 1 of 16 | 0.0 | 0.0% | - |

**`sweep` IS the chain.** It is four fifths of a median night and everything else together is a
rounding error - `stage1`, the second-largest, is a sixth of it. A staged pipeline's latency is owned
by its slowest stage, so any work on this chain that is not `sweep` cannot move the total.

**And the second question is answered too, which is what makes this more than a ranking.** `sweep`'s
**cv is 0.14** - consistently slow, not erratic. That makes it a **parallelisation candidate, not a
buffering candidate** (claim C90's split). The variable stages are `defs` (cv 0.88) and `serve`
(0.57), and both have medians of 1 and 8 seconds, so their variance is worth nothing.

**Two things stated rather than glossed.** `ml-eval` appears on **1 night of 16** at 41 s and
`durability` on 1 - neither is part of the nightly shape and neither is scored as if it were. And the
stage medians sum to **208 s against a 162 s median total**, which is not an error: medians do not
add, and the stages that are absent on some nights inflate the sum. The share column is against the
median total and is the honest figure.

**Rung 2 is NOT started and should not be.** The `grocery/` capture lanes and the 243 gates record no
duration at all, and adding a second uninspected timing series before anything acts on this one buys
nothing - which is the exact mistake I33 recorded. **Nothing is proposed for `sweep` either**: naming
a bottleneck is not the same as having a reason to make the nightly chain faster, and nobody has said
the 162 s is a problem. This item asked which stage owns the latency. It is `sweep`.

**Source.** Same course, module 2 lectures 20 and 21. Routed to
`reliability-craft/pipeline-throughput.md`. Claim C90.

**This is the per-STAGE sibling of I33, which read the same file's TOTALS.** I33 established that
`grocery/out/logs/graph-nightly-status.json` is tracked and committed daily with 15 days of history,
and read `elapsed_sec` from it: 118 s to 199 s, mean 161.7 s, no visible trend. **What it did not
read is the `stages` array in the same file**, which carries `{stage, state, detail, sec}` per stage,
written by `graph/pipeline/nightly.ps1` (timing at line 324, emission at line 675). Verified
2026-09-07 by reading the file.

**Why it matters.** The course's operative rule is that a staged pipeline's latency is owned by its
**slowest stage**, so an end-to-end number says the chain is slow and only a per-stage number says
what to fix. We have the per-stage number, in git, for every night, and have never looked at it.
That is the cheapest unread measurement in the estate.

**What rung 1 is.** `git log` the file, pull the `stages` array per commit, and produce one table:
stage, median seconds, share of total, variance across the 15 days. The output answers two questions
at once - which stage is the bottleneck, and whether it is *consistently* slow (a parallelisation
candidate) or *variable* (a buffering candidate), which is the split recorded as claim C90.

**What is genuinely absent, stated separately so this item is not read as bigger than it is.** The
`grocery/` capture lanes and the 243 gates and audits record **no** duration at all. Extending the
timing to them is a rung 2 and should not be started before rung 1 says a bottleneck read is worth
having.

### I44 - The Recipe rich result went from ~40 valid to 1, and the paywall claim is on the wrong node `PARTLY DONE - THE FIX IS SHIPPED AND VERIFIED LIVE 2026-09-07; ONLY GOOGLE'S RE-CRAWL VERDICT IS OUTSTANDING` `b3a35c7cf` `be797a371` `seo` `2-WAY` `RUNG1 BLOCKED`

**Found 2026-09-07 while chasing the impression decline I24 measured.** Read from Search Console
directly, not inferred.

**What the numbers say.**

| | |
|---|---|
| pages indexed | **1,330** |
| pages NOT indexed | 311 (redirects 161, canonicals 76, 404 28, noindex 4, discovered-not-indexed 37, crawled-not-indexed 5) |
| URLs offered in the sitemap | 1,098 |
| pages receiving ANY impression in 28 days | **25** |
| **Recipe rich results: VALID** | **1** |
| Recipe rich results: INVALID | 0 |

**Indexing is not the problem and images are not the problem.** The site is fully indexed. What
collapsed is the Recipe rich result: Google recognised roughly **40** valid recipe items from mid
July, and that fell to **1** between about 18 and 30 August - the same window and the same shape as
the impression decline.

**The mechanism, measured on a live page** (`/chicken-tikka-masala-burrito/`, fetched with a Googlebot
user agent):

- the page is paywalled - `gh-post-upgrade` and Subscribe markers are present
- its `Recipe` JSON-LD carries **4 full `recipeInstructions` steps**
- the last step's text is **NOT present in the visible body** Googlebot receives
- `isAccessibleForFree`: **ABSENT** from the Recipe node
- `hasPart`: **ABSENT** from the Recipe node

That is structured data asserting content the page does not show, with no paywall declaration on the
node making the assertion - the configuration Google's own paywalled-content guidance exists to
prevent being read as cloaking.

**The paywall claim EXISTS and is attached to the wrong node.** `build-card2.ps1` emits it as a
SEPARATE `Article` node (`isAccessibleForFree=false`, `hasPart` with `cssSelector='.gh-content'`),
conditional on the recipe being paid. Google reads the **Recipe** node for a recipe rich result, and
an Article node beside it does not attach a paywall to the Recipe.

**Why this is a ruling and not just a patch.** The fix is two fields on the Recipe node, but
`sync-paywall-schema.ps1` is the other half: it ADDS and REMOVES the claim as a recipe moves in and
out of the free rotation, and its `$PAYWALL_RX` is written to match only the one-line Article block -
its own comment says "The Recipe node in the same field has no such key, so it can never be caught by
this." Put the claim on the Recipe node without teaching the syncer, and a recipe that is freed keeps
telling Google it is paywalled. **That is exactly the bug 2026-08-31 already fixed once**, where all
20 free-rotation recipes claimed a paywall while serving to everyone.

So it is: two fields in `build-card2.ps1`, a matching add/remove in `sync-paywall-schema.ps1`, fixtures
for both directions, and a rebuild+propagate. Not large, but it touches the live publish path and it
has a known way of going wrong.

**Stated as a hypothesis, because it is one.** The mismatch is measured and the timeline fits. That it
CAUSED the decline is the best available explanation and not a proven one - Google does not say why it
stopped honouring markup. The cheapest confirmation is to fix one recipe, request indexing, and watch
whether it returns to valid.

**Also fixed today, separately:** 49 specs carried `head.image = ""`, which invalidates the Recipe rich
result outright regardless of the above. They now carry the same image the other 535 use - strictly
better than empty, and no photography. It does NOT address the 584-share-one-image weakness, which
remains genuinely blocked on being able to photograph the food.


**CONFIRMED 2026-09-07 by an independent read, after the fix had shipped.** The diagnosis this item
asked to confirm is correct, the two-field fix is in `build-card2.ps1` (`b3a35c7cf`) and the syncer
handles both nodes (`be797a371`), and it is LIVE. Measured rather than assumed:

| what was checked | result |
|---|---|
| paid pages fetched as Googlebot carrying `isAccessibleForFree=false` **and** `hasPart` on the **Recipe** node | **5 of 5 sampled** |
| a free-rotation page as the control, which must claim nothing | correct: claim ABSENT on the Recipe node |
| built heads under `db/built` carrying the Recipe claim | **142 of 584**, and every one of them written after the 12:23 fix |
| built heads WITHOUT it that were written after the fix | 6, and all 6 are `visibility: public` in `recipes-db.json`, so claiming nothing is correct |

**The stale built heads are not a regression, and that was checked rather than assumed.** 442 built
heads still carry the pre-fix shape because they have not been rebuilt since. They cannot ship it:
`propagate-recipes.ps1` runs `build-cards` at step 4 and `publish` at step 5, so any card that
publishes is re-rendered from the fixed builder first. The live pages were corrected by the syncer,
not by a rebuild, which is why live is ahead of `db/built` rather than behind it.

**What is still open is only Google's verdict**, and it is not ours to compute: the item's own
cheapest confirmation is to request indexing on one recipe and watch whether Recipe rich results
return to valid. That is an action on Brad's Search Console account.

**READ FROM SEARCH CONSOLE 2026-09-07, and it weakens the hypothesis this item is built on.**
Brad's own property, `https://www.thriftycrew.com/`, inspected in his browser:

| what Search Console says | value |
|---|---|
| Recipes enhancement, site-wide | **1 valid, 0 invalid** (the number this item was opened on) |
| Breadcrumbs enhancement, site-wide | 23 valid, 0 invalid, against 1,331 indexed pages |
| `cheeseburger-pasta` (paid), URL Inspection | indexed; **Recipes: 1 valid item detected**; last crawl **Jul 10, 2026** |
| `bbq-chicken-rice-bowls` (paid), URL Inspection | indexed; **Recipes: 1 valid item detected**; last crawl **Aug 2, 2026** |

**Two of two sampled pages hold a VALID Recipe item in Google's own index.** The site-wide count of
1 is therefore not a count of pages whose markup is currently broken; it does not agree with the
per-page truth on either page sampled, and the honest reading is that the enhancement report counts
what Google has recently re-processed rather than what it holds.

**And Google is barely re-crawling this site.** The two pages were last crawled 10 July and 2
August, five to eight weeks ago. The Recipe collapse this item measured is dated 18 to 30 August,
AFTER both of those crawls, so neither page's indexed copy has ever contained the defect the item
diagnosed, and neither can show the fix until Google returns. Nothing about today's change can
appear in this report on its own schedule.

**What that does and does not do to the diagnosis.** The measured facts stand: the Recipe node did
lack `isAccessibleForFree` and `hasPart` while the page withheld a step, and putting the claim on
the node Google reads is correct whether or not it caused anything. What is now doubtful is the
CAUSAL half - that the mismatch is why valid results fell to 1 - because the pages sampled were not
crawled during the window in which they fell. A crawl-rate or site-quality explanation fits the
evidence at least as well, and 3 web-search clicks in 28 days over 1,331 indexed pages points the
same way. Treat the fix as correct-and-cheap, not as the known cause.

**THE CONFIRMATION WAS SUBMITTED 2026-09-07, on Brad's authorisation, and this is the record to
check it against.** Request Indexing was clicked on five paid recipes, each of which had already
been verified as serving the Recipe-node paywall claim live. Google returned "Indexing requested,
URL was added to a priority crawl queue" on all five.

| recipe requested | last crawl BEFORE the request | Recipes in the index at that crawl |
|---|---|---|
| `cheeseburger-pasta` | Jul 10, 2026 | 1 valid item detected |
| `bbq-chicken-rice-bowls` | Aug 2, 2026 | 1 valid item detected |
| `fajita-chicken-rice-bowl` | not read | 1 valid item detected |
| `beef-burrito-bowls` | not read | 1 valid item detected |
| `italian-sausage-penne` | not read | 1 valid item detected |

Five were requested rather than one deliberately: a single page's result cannot separate "the fix
worked" from "that page was re-crawled anyway".

**WHAT WOULD SETTLE IT, WRITTEN BEFORE THE ANSWER ARRIVES so the reading cannot be fitted to
whatever turns up.** Re-inspect these five in a few days and read the site-wide Recipes count:

- **The fix mattered.** All five re-crawl, each still shows a valid Recipe item, and the site-wide
  valid count rises from 1 toward the number of pages re-crawled. The paywall declaration is then
  the thing that changed and the hypothesis is supported.
- **The fix was correct but was not the cause.** All five re-crawl and still show valid per page,
  and the site-wide count stays at 1. Then the enhancement report is measuring something other than
  per-page validity, and the collapse needs a different explanation - crawl rate is the standing
  candidate.
- **Something else is wrong.** A re-crawled page reports its Recipe item INVALID, which would be a
  new defect and not this one; read the reason it gives before touching anything.
- **No verdict yet.** The pages have not been re-crawled. That is not evidence either way, and the
  honest move is to wait rather than to read the unchanged number as a result.

The site-wide baseline on the day of the request: **Recipes 1 valid, 0 invalid; Breadcrumbs 23
valid, 0 invalid; 1,331 pages indexed; 3 web-search clicks in 28 days.**

**ONE ADJACENT OBSERVATION, stated as an open question and not a finding.** On both a paid and a
free page fetched as Googlebot, **none of the six declared `recipeInstructions` steps appears
anywhere outside a `<script>` tag** - the text is in the JSON-LD and in the card widget's data
island, and the rendered steps a reader sees are produced by JavaScript. For the paid pages that is
now declared, which is the whole point of this item. For the FREE pages nothing is declared and
nothing needs to be, but it does mean the rich result depends on Google rendering the page rather
than reading it. The first instrument used here said "0 of 6 steps visible" on a stripped copy of
the HTML and that was the instrument being wrong, not the page - the text IS in the served bytes.
Settling whether Google sees the rendered steps needs the URL Inspection tool's rendered HTML, on
the same account as the confirmation above. Worth doing in the same sitting; not worth guessing at.

---

### I45 - no scheduled stage asserts its inputs; the 08:30 bug is one XML file away from returning `PARTLY DONE - THE ASSERTION EXISTS AND ONE STAGE USES IT; THE CAPTURE ENTRY POINTS WANT A WATCHED RUN` `queue-4` `2-WAY` `RUNG1 READ`

**`[RUNG 2 BUILT 2026-09-09, at the size rung 1 narrowed it to - five entry points, not 172 files.]`**

**Shipped: `lib/input-assert.ps1`.** THREE OUTCOMES, and collapsing any two of them is the bug it
exists to prevent:

| | |
|---|---|
| `FRESH` | exists and inside its window. Proceed. |
| `STALE` | exists and older than its window - **the producer ran and then stopped, or failed quietly** |
| `MISSING` | absent. **Not the same as stale, and never the same as fresh.** A worktree has no board, so this is routinely could-not-evaluate rather than a fault |

**It returns 3, never 1.** A stage that cannot verify its input has not failed and has not passed. The
window is passed by the caller and derived from the schedule, never invented at the call site.

**Wired into `capture-watchdog` (check 5a2b), and the choice of first stage is deliberate.** It is the
one scheduled stage whose entire job is REPORTING, so a could-not-evaluate there costs a line in a
report rather than a board that never gets built. **Verified green on the live tree today: the capture
status file is 21.8 h old against its 26 h window.**

**A defect in my own library, caught by its own must-not-fire on the first run.** `Assert-TcInputs`
used `Write-Output` for its report lines, so **the report became part of the function's return value**
and the exit code arrived buried at the end of it - `$rc -eq 0` was false while every input was fresh.
It uses `Write-Host` now, which still lands in stdout when a scheduled stage is redirected to a log,
so nothing is lost. **The estate has a memory for exactly this shape** and it still caught me. Two
fixtures now hold it: the return value is asserted to be an `[int]`.

**Verified:** self-test **13 of 13**, led by the three-way distinction and by the window boundary
tested in *both* directions - exactly at 26 h is FRESH, one second past is STALE - because a boundary
asserted on one side only is half a test. `run-gates` exit 0, `pass=295 fail=0`.

**WHAT IS DELIBERATELY NOT DONE: the two capture entry points.** Asserting inside `capture-run.ps1`
means a wrong window **stops the day's capture on a live paid site**, and the item itself said that
wants somebody watching the next run. The library is ready and the pattern is one call; adding it is a
five-line change whenever there is a window to watch it. Doing it blind would not have been thorough,
it would have been reckless.

**`[RUNG 1 RAN 2026-09-09, which is exactly what the item asked for before any code.]`**

*"List which scheduled stage consumes which other stage's output, and check how many of those edges
are currently defended by anything at all. Do that before proposing code."*

**The five scheduled entry points, all `CalendarTrigger`:**

| task | fires | runs |
|---|---|---|
| Ad Pulls | 07:00 | `grocery/capture-run.ps1 -Kind ad` |
| Daily Capture | 08:00 | `grocery/capture-run.ps1` + the downstream chain |
| Capture Watchdog | **10:30** | `grocery/capture-watchdog.ps1` |
| Graph Nightly | 21:30 | `graph/pipeline/nightly.ps1` |
| Recipe Harvest | 18:00 | `meal-prep/pipeline/harvest-crawl.ps1` |

**And the edges. 172 first-party `.ps1` consume another stage's output file. 75 of 172 (44%) contain
any freshness, supersede or mutex defence at all. 97 do not.**

**That number does NOT justify the build the item proposed**, and saying so is the point of running
rung 1 first. An input assertion added to 97 consumers would be a large change across the whole
estate for a risk that has fired twice, and a gate over it would be red on day one - which
`.claude/rules/ops-and-gates.md` forbids.

**WHAT THE READ ACTUALLY NARROWS IT TO.** The scars are both on the SCHEDULED chain, not on the 172:
the 08:30 stage that ran inside its predecessor's 08:12-08:43 window, and a watchdog named 0930 that
fires at 10:30. **The defensible build is an input assertion on the handful of stages the five tasks
invoke directly - five entry points, not 172 files** - and it should exit 3 (could-not-evaluate) on a
stale input rather than proceeding. That is a much smaller, rankable job than the item as filed.

**Not started, and deliberately.** It touches the live daily chain, and the estate already has the
vocabulary (`lib/guard-contract.ps1`) and the freshness machinery (`audit-row-age`,
`audit-asof-evidence`) to do it properly when someone has a window to watch the next run.

**What already exists and what it does not buy, unchanged:** `chain-idle.ps1` takes a named mutex and
prints FREE or HELD - *"a fixed clock gap is an assumption while the mutex is a fact"*. It prevents
**overlap**. It does not sequence, and it cannot tell "stage one failed" from "stage one has not
run".

**Source.** `source-systems-data-ingestion-and-pipelines` (Coursera, DeepLearning.AI with AWS, Joe
Reis and Morgan Willis, queue-4 course 9, worked 2026-09-07), module 4 items 82 to 84. Routed to
`reliability-craft/pipeline-throughput.md` 6 and `reliability-craft/applies-here.md`.

**Where it comes from.** The course's opening argument about orchestration is that a chain of
clock-scheduled jobs encodes every dependency as **a guess about how long the previous stage takes**,
and that nothing checks the guess: when a stage overruns, the next one starts anyway, consumes stale
or half-written input, and **the chain reports success while the output is wrong.**

**This estate is that chain, and it has the scars.** Five Windows scheduled tasks, all
`CalendarTrigger`/`StartBoundary`, defined in `ops/scheduled-tasks/*.xml`. Two recorded instances:

1. `grocery/chain-idle.ps1`'s own header: *"Measured 2026-08-22: the 0800 task's downstream chain ran
   08:12-08:43, 31 minutes. Stage two was originally scheduled at 08:30 - squarely inside it - and
   was moved to 09:00 because of this."*
2. `TC Grocery Capture Watchdog 0930` fires at **10:30**. `ops/install-grocery-tasks.ps1` carries a
   `-FixName` switch and deliberately refuses to move the time.

**What exists already, and what it does not buy.** `chain-idle.ps1` takes a named mutex and prints
FREE or HELD, with the right principle in its header - *"a fixed clock gap is an assumption while the
mutex is a fact."* It prevents **overlap**. It does not sequence, it does not distinguish "stage one
failed" from "stage one has not run", and a stage two that runs after a crashed stage one reads stale
input and reports success.

**The proposal, and it is deliberately not an orchestrator.** Adopting Airflow or Step Functions
would add a fifth runtime to a box whose runtime count is already why `docs/RUNTIME-MAP.md` exists.
The cheap version is **an input assertion per consuming stage**: before a stage reads a file another
stage writes, assert that file's mtime is inside this run's window, and exit 3 (could-not-evaluate)
rather than proceeding on a stale one. The estate already has the vocabulary
(`lib/guard-contract.ps1`) and the freshness machinery (`grocery/audit-row-age.ps1`,
`grocery/audit-asof-evidence.ps1`); this is applying it at a stage boundary rather than at the board.

**What it would touch.** The consuming stages in `grocery/capture-run.ps1`'s downstream chain and
`graph/pipeline/nightly.ps1`. Rung 1 is a **read**, not a build: list which scheduled stage consumes
which other stage's output, and check how many of those edges are currently defended by anything at
all. Do that before proposing code.

**Related.** I43 (per-stage latency already recorded and never read) is the measurement that would
say how close each gap actually is; I40 is the same contract problem one layer down, on the git-bus.

### I46 - every check reports on a whole artefact, so a failure names the file and never the slice `PARKED - MEASURED 2026-09-09: EVERY FINDING ALREADY NAMES ITS SLICE` `queue-4`

**`[CLOSED PARKED 2026-09-09. The premise does not hold.]`**

Rung 1: *"take the last 30 days of `grocery/out/` audit outputs and count how many findings a reader
had to open the artefact to attribute. If the answer is small, this is not worth building."*

**Measured over 710 report JSONs under `grocery/out/` and `grocery/out/audit/`. 123 carry a
findings-shaped list. Of those:**

| | |
|---|---|
| findings that DO name a slice key (`store`, `commodity`, `id`, `week_of`, `as_of`, `item`) | **123 of 123** |
| findings that name only the file | **0 of 123** |

**Not one.** The natural slices this estate would need to attribute a failure to - store, week,
commodity - are already on the finding rows. The batch key the item wanted to port from Great
Expectations is, in effect, already there; it is carried per row rather than declared per suite, and
for a reader chasing a failure that is the same thing.

**Stated honestly: 586 of the 710 files carry no findings-shaped list at all** and were NOT scored.
They are stamps, cursors and caches rather than reports. Counting them as clean would have been the
vacuous pass this estate has a rule about, so they are reported as unscored.

**What the item got right and is worth keeping:** a tolerance breach that is one store's whole feed
and one that is a thin smear across all seven are different defects with different owners. That is
true. It is just not currently invisible.

**Source.** Same course, module 3 items 71 and 72 (Great Expectations). Routed to
`data-quality-craft/checks-and-thresholds.md` 6a and `data-quality-craft/applies-here.md`.

**Where it comes from.** Great Expectations splits a data asset into **batches** - by date part, or
by a column value such as a store id - and runs the same expectation suite per batch. The failing
batch is named. That is the one component of its model this estate has no equivalent of.

**What the estate has.** `grocery/coverage-baseline.json` holds 16 declared checks with
`examined` / `tolerance` / `max_age_days` / `min_ratio` / `phase` / `why`, interpreted generically by
`grocery/audit-coverage-ledger.ps1`. `meal-prep/pipeline/audit-schema-constraints.ps1` declares PK,
FK, type and cross-file constraints over eight live JSON files. Both run whole-artefact.

**Why it matters here specifically.** The natural slices in this estate are exactly the ones a
failure needs attributing to: **store** (seven of them, with genuinely different feed shapes),
**week** (the ad cycle), and **commodity**. A tolerance breach that is one store's whole feed and one
that is a thin smear across all seven are different defects with different owners, and today they
produce the same finding.

**What rung 1 is.** A read, not a build: take the last 30 days of `grocery/out/` audit outputs and
count how many findings a reader had to open the artefact to attribute. If the answer is small, this
is not worth building.

**What it is not.** Not a proposal to adopt Great Expectations - it is a Python package over a Python
data stack, and these checks are PowerShell over JSON. The component that ports is the batch key.

### I47 - a recorded measurement can be voided later, and nothing in the estate re-checks one `DONE - THE CONVENTION IS ENFORCED BY A RATCHET, NOT LEFT AS AN INTENTION` `queue-4` `2-WAY` `RUNG1 READ`

**`[RUNG 2 SHIPPED 2026-09-09: `ops/audit-measurement-provenance.ps1`, in `run-gates`, ratchet at 8.]`**

The convention went into `.claude/rules/measurement.md` on 2026-09-09. **A convention with no detector
is an intention, and an intention has no exit code** - the same principle I41 turned on - so this is
what notices when a new recorded measurement does not say what it was measured through.

**A RATCHET, NEVER A GATE.** The item was explicit that retro-filling the existing nine was not asked
for, and a bar over them would be red on day one against almost all of them. The high-water mark may
only go DOWN: a new document without provenance raises it and fails; filling one in lowers it.

**Live: 10 documents, 2 compliant, 8 not.** Baseline armed at 8.

**THE AUDIT'S FIRST RUN FAILED THE ONE DOCUMENT WRITTEN TO THE CONVENTION, and it was right to.**
`EVAL-alert-retention-2026-09-09.md` named its harness and then said *"the commit that introduced both
is the one carrying this file"* - **because a document cannot contain the hash of the commit that adds
it.** The convention as first written was unsatisfiable for the introducing commit. It accepts a
harness plus **a commit hash OR an ISO date** now, since `git log --before=<date> -- <harness>` answers
the same question, and the hash is backfilled once it exists - which that document now carries
(`60e944660`). **That is a real design hole found by building the detector rather than by reasoning
about it.**

**Both half-done shapes are must-fires, because each looks finished:** a harness named with no commit
(which is exactly where all nine already were - you know which file to look at and still cannot tell
whether it moved), and a date with no harness (**every one of the nine carries a date**, so if a date
sufficed this audit would have gone green on day one having changed nothing).

**Verified by making it fire:** a provenance-free probe document took it to 9 and the audit exited **2**
naming both numbers; removing it returned exit 0. Self-test **9 of 9**. `run-gates` exit 0,
`pass=297 fail=0`.

**SCOPE OF A CLEAN REPORT: UNSOUND.** It checks that the question was ANSWERED, never that the answer
is true - a document naming a harness it did not use counts as compliant.

**`[RUNG 1 RAN 2026-09-09. The answer is not "nothing has moved", so the item does not close.]`**

*"Walk the `design/EVAL-*.md` and `MEASURE-*.md` files, and for each recorded verdict still being
obeyed, write down what harness it was measured through and whether that harness has changed since.
If the answer is 'nothing has moved', this is not worth building."*

**Nine recorded-measurement documents. For each, the scripts it names were checked against their own
last-commit date:**

| document | written | harness that moved SINCE |
|---|---|---|
| `EVAL-dedup-shortlist-2026-09-04` | 09-04 | `harvest_embed.py` 09-05, `hunt-daemon.py` 09-07, `hunt-run.ps1` 09-05 |
| `EVAL-hunter-repeat-work-2026-09-04` | 09-04 | `update-recipes-db.ps1` 09-05, `hunt-daemon.py` 09-07, `hunt_dispatch.py` 09-07 |
| `EVAL-latency-cold-read-2026-08-25` | 08-25 | `fdc_lookup.py` 09-07 |
| `EVAL-latency-lf1-drill-2026-08-25` | 08-25 | `hunt-run.ps1` 09-05, `ingredient-queue.ps1` 09-05, `wave-preaudit.ps1` 09-07 |
| `EVAL-map-lane-latency-m1-drill-2026-08-25` | 08-25 | `hunt-run.ps1` 09-05, `map-preresolve.ps1` 09-07 |
| `EVAL-registrar-batch-2026-08-25` | 08-25 | `hunt-daemon.py` 09-07, `ingredient-vocab.ps1` 09-07 |
| `MEASURE-cheapest-selection` | 08-15 | `measure-cheapest-selection.ps1` 09-05 |
| `MEASURE-local-finetune-feasibility-2026-08-22` | 08-22 | `serve.ps1` 09-08 |
| `EVAL-hunter-wall-clock-2026-09-04` | 09-08 | -- none -- |

**8 of 9.** And the ninth is an artefact of the instrument, which has to be said: `EVAL-hunter-wall-
clock` reads as current only because **I edited it yesterday** for I51. Its measurement is still from
2026-09-04. So the honest figure is closer to **9 of 9 than 8 of 9**, and the instrument's own
contamination is exactly the shape it is measuring.

**A MOVED HARNESS IS NOT A WRONG VERDICT.** It means the verdict is **unqualified** until somebody
re-reads it, which is all the item ever claimed. The two recorded cases stand:
`check-ad-cycles.ps1`'s *"THE MEASUREMENT WAS CONFOUNDED"* block, where a 30.9-vs-41.7-minute verdict
reverted a working parallel path and the parallel arm turned out to be running through a wrapper
measured an hour later at 3.8 minutes per call; and `EVAL-hunter-wall-clock` 46's *"arithmetically
true and causally wrong"*. **Both were caught by a human re-reading the commit clock months later, by
luck.**

**The cheap fix the item proposes is a CONVENTION, not a gate, and it is not built here:** every
recorded measurement names its harness and the commit it ran at, so the question is answerable
without archaeology. Retro-fitting the nine is not proposed; the ask is that the next one carries it.
**A gate over `design/EVAL-*.md` would be red on day one against all nine**, which is the shape the
estate forbids.

**Source.** `crash-course-in-causality` (UPenn, Roy), queue-4 course 10. Routed to
`experiment-craft/is-the-difference-caused.md` 18-25 and `experiment-craft/applies-here.md` 1.

**Where it comes from.** A difference can be real, reproducible and significant, and still be caused
by something that differed between the arms and was not the intervention. The course's whole subject
is that this is a *design* defect, not a precision one, and that more data makes it worse rather than
better.

**What the estate has, and it has already paid.** `grocery/check-ad-cycles.ps1` carries a block
comment headed "THE MEASUREMENT WAS CONFOUNDED": a 2026-08-22 verdict of serial 30.9 min vs parallel
41.7 min caused a working parallel path to be **reverted**, and `design/PLAN-use-the-cores-2026-08-23.md`
218 shows the parallel arm ran through `Invoke-Bounded`, measured an hour later at 3.8 minutes per
call for a 1-second script. `design/EVAL-hunter-wall-clock-2026-09-04.md` 46 is the second case and
says it plainly: "arithmetically true and causally wrong". Both were caught by a human re-reading the
commit clock, months later, by luck.

**Why it matters here specifically.** Both defects have the same shape - a number was recorded, a
decision was made on it, and the machinery it was measured through changed underneath it. Nothing
re-opens a recorded measurement when that happens. `ops/run-gates.ps1` checks source properties and
hermetic self-tests; there is no audit over `design/EVAL-*.md` or `design/MEASURE-*.md` at all.

**What rung 1 is.** A read, not a build. Walk the `design/EVAL-*.md` and `design/MEASURE-*.md` files,
and for each recorded verdict still being obeyed, write down what harness it was measured through and
whether that harness has changed since. If the answer is "nothing has moved", this is not worth
building.

**What it would touch.** Nothing yet. If rung 2 is ever ordered, the cheapest form is a convention
rather than a gate: every recorded measurement names its harness and the commit it ran at, so the
question is answerable without archaeology.

**What it is not.** Not a proposal to adopt propensity scores or IPTW. This estate mostly compares
two configurations it controls, where the repair is a paired design (I48), not an adjustment.

### I48 - comparisons here are between-runs when a within-pairs design is available and cheaper `OPEN - BLOCKED ON A RUN, NOT ON A DECISION` `queue-4` `2-WAY` `RUNG1 MEASURE`

**`[NOT REACHED 2026-09-09, and the reason is stated rather than implied.]`** Rung 1 is the
`EVAL-dedup-shortlist` experiment: the same candidate dossiers ruled **twice**, with and without the
neighbour block, two decider calls on identical inputs. That needs live decider calls over a real
dossier batch - a dispatched run, not a script I can execute and read in a session. Nothing about it is
undecided; it is waiting on the run. **No part of it was faked or estimated.**

**Source.** Same course. Routed to `experiment-craft/is-the-difference-caused.md` 22a and
`experiment-craft/applies-here.md` 4 and 7.

**Where it comes from.** Matching and paired analysis exist to make two arms the same population. When
you control both arms you do not need to *reconstruct* that - you can run the same units through both,
which removes the confounding by construction instead of modelling it away.

**What the estate has.** It already knows this and has written it down once:
`design/EVAL-dedup-shortlist-2026-09-04.md` 387 found that "output tokens per candidate ruled" was
confounded because the run selects its own denominator - the duplicate mix moved 32% to 53% when the
band moved - and named the fix as "the SAME candidates ruled twice, once with the neighbour block and
once without - a within-pairs design, not a between-runs one". **That experiment was never run.**
`meal-prep/pipeline/extractor_model_probe.py` 18 is the estate's one worked example of the design,
and its docstring gives the reason: scoring against stored August transcriptions "would confound a
model difference with a page edit".

**Why it matters here specifically.** Every model, prompt, effort-level and threshold comparison in
this estate is a candidate, and the paired form is usually *cheaper* as well as more valid, because it
needs fewer cases for the same power (`experiment-craft/effect-size-and-power.md` 9).

**What rung 1 is.** Run the experiment `EVAL-dedup-shortlist` already specified: the same candidate
dossiers ruled twice, with and without the neighbour block. Two decider calls on identical inputs.

**What it would touch.** `sidecar/` and the decider prompt only; no board, no published page.

**Related.** I47 is the same subject from the other end - I47 asks whether an old number is still
valid, I48 asks how to take the next one so the question does not arise.

### I49 - one global similarity floor is a claim about the shape of a space nobody has ever grouped `DONE - MEASURED, AND THE SHAPE HOLDS` `queue-4` `2-WAY` `RUNG1 MEASURE`

**`[CLOSED 2026-09-09 with a measurement instead of an opinion, which is what the item asked for.]`**

`sidecar/probe_distance_concentration.py`. The question was never whether 0.55 is the right value - it
was whether a SINGLE GLOBAL value is the right shape of answer, which in high dimension can fail
silently through distance concentration: nearest and furthest neighbours drift toward the same
distance, the ordering under a fixed cut becomes close to noise, and the floor keeps returning
confident numbers throughout.

**THE BAR WAS WRITTEN ABOVE THE RUN, in the metric's own units:** median relative contrast
(`d_far / d_near`, cosine) **>= 1.50 SOUND**, **< 1.20 CONCENTRATED**, in between reported as
**AMBIGUOUS** rather than rounded toward a verdict.

**Measured over 2,000 of 16,839 product vectors (11.9%), dimension 1,024:**

| | |
|---|---|
| median relative contrast | **2.702** |
| p10 | **1.928** |
| p90 | 6.551 |
| points below the concentration bar | **0 of 2,000 (0.0%)** |

**VERDICT: SOUND.** Not marginally - the **tenth percentile** is 1.928, well clear of the 1.50 bar, so
this is not a healthy median hiding a concentrated region. A single global cut is the right instrument
for this space.

**What that does and does not settle.** It settles the SHAPE and closes this item. It says nothing
about the VALUE: `derive_coverage_floor.py` already showed the hand-chosen 0.55 is too high, with 186
correct pairs beneath it, and that finding is untouched by this one. **Rung 2 as filed (cluster the
space, compute recall lost per cluster) was conditional on the space being concentrated. It is not, so
rung 2 is not owed** - if the 186 lost pairs concentrate anywhere, it is not because the metric has
stopped discriminating.

**Verified:** self-test 8 of 8, exit 0, led by two must-fires - a clustered space scores above 5 and is
called SOUND, and **uniform 1,024-dimensional noise concentrates and is refused**, which is the failure
this probe exists to be able to see. A duplicate nearest neighbour makes RC undefined and those rows are
**excluded, not clipped**, because clipping would inflate the median toward the answer one would prefer.
One row per sampled point is written to `sidecar/out/distance-concentration.jsonl` with the input
fingerprint and seed, so the totals derive from the file and the run can be re-asked without re-running.

**Source.** Queue-4 course 11, CU Boulder "Introduction to Machine Learning: Unsupervised Learning",
worked 2026-09-07. Routed to `rag-craft/grouping-a-vector-space.md` 33, 35 and 38, and
`rag-craft/applies-here.md` 1.

**Where it comes from.** Similarity search answers "what is near this". It cannot answer whether the
space has dense regions and empty ones, and a single cosine floor assumes the gap between a true pair
and a false pair means the same thing everywhere in the space. That is an assumption about density,
and it has never been tested here.

**What the estate has.** `sidecar/sweep.py` line 62 sets `COVERAGE_COS_FLOOR = 0.55` for the whole
corpus. `sidecar/derive_coverage_floor.py` already derives it from labelled data rather than choosing
it, and `sidecar/matcher_eval.py` already measures recall@25 against a `RETRIEVAL_BAR` of 0.99. The
memory `matcher-prefilter-drops-correct-pairs` records 186 of 2,816 correct pairs lost under that
floor. Both existing tools ask where the known-good pairs sit; neither asks whether one number can be
right across the whole space. A first-party grep over `sidecar`, `graph`, `meal-prep`, `grocery`,
`ops` and `lib` finds **zero** clustering code of any kind - no k-means, no silhouette, no sklearn.

**What rung 1 is, and it is cheap.** Not a clustering project. For a sample of product vectors,
compute the ratio of the furthest to the nearest neighbour distance. If that ratio sits near 1, the
ordering under the floor is close to noise and a single global cut is the wrong instrument; if it is
comfortably above 1, the current design is sound and this item closes with a measurement instead of
an opinion. Everything needed is already installed in `sidecar/.venv`.

**What rung 2 would be.** Cluster the product embedding space, then compute the recall lost under the
0.55 floor **per cluster** rather than in aggregate. If the 186 lost pairs concentrate in one region,
the repair is a per-region floor, not a lower global one - and lowering the global floor costs
cross-encoder calls, which `derive_coverage_floor.py` already prices.

**What it would touch.** `sidecar/` only. No board, no published page, no gate.

**What it is not.** Not a proposal to change 0.55. The point is that the number is currently
unqualified in a dimension nobody has looked at, and the look is an afternoon.

### I50 - `serve.ps1`'s per-slot guard says it is set by the LARGEST caller, and it is not `DONE - THE COMMENT NOW TELLS THE TRUTH; THE CONSTANT IS DELIBERATELY UNCHANGED, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08.]`** `tools/local-llm/serve.ps1`'s floor block now records that the rule it
states - *the floor is set by the LARGEST caller* - stopped being true when a caller grew past it:
`meal-prep/pipeline/local_extract.py`'s `RUNG2_MIN_SLOT_CTX` is **11,465** against this file's
**3,300**, and at the defaults (`-Context 16384 -Slots 4` = 4,096/slot) a server that reports READY is
not usable by the extract lane.

**The constant was NOT touched, and the comment says why.** Bumping 3,300 to 11,465 hard-codes the
identical failure one level up - the next caller to grow outruns it silently again - and it would make
the default invocation throw on a server Brad starts by hand. The repair is to DERIVE the floor from
the largest declared caller, which is a behaviour change to a file the queue's group-H rule keeps off
limits. Filed in the comment, not made.

The reflex I52 asked for is written: `[[per-slot-context-is-context-over-slots]]`.

**Verified:** `run-gates` exit 0, `pass=276 fail=0`. No behaviour changed, which is the point.

**Source.** Queue-4 course 12, Coursera / Board Infinity "Deploying Deep Learning: Quantization,
Serving, and Edge AI", worked 2026-09-07. Found while measuring the course's serving claims against
what the estate runs; the course did not cause it.

**What it is.** `tools/local-llm/serve.ps1` refuses to start when the per-slot context falls below a
floor, and its comment states the rule plainly: *"The floor is set by the LARGEST caller, not the
smallest."* The floor in the code is **3,300** tokens/slot, justified against Learning Stage 1's
~1,000-token prompt plus 2,200 requested. But `meal-prep/pipeline/local_extract.py` sets
`RUNG2_MIN_SLOT_CTX = int(4096 + 24000/3.5 + 512)` = **11,465**, and rung 2 is a larger caller than
Learning Stage 1 by a factor of three and a half.

**The arithmetic, verified 2026-09-07.** At the defaults `-Context 16384 -Slots 4`, per-slot is
`16384/4 = 4096`. That clears `serve.ps1`'s 3,300 floor, so the server starts and reports READY.
It does not clear 11,465, so the extract lane refuses.

**Why it is not a live bug, and why it is still worth an item.** `local_extract.py` does the right
thing: `slot_context()` reads the running server's real per-slot `n_ctx` from `/props` rather than
assuming it, and a slot that is too small is a **named BLOCK, exit 2**, never a short read - the
comment there explains that a truncated page would substring-verify cleanly and pass a recipe
missing its last five ingredients. Its self-test even asserts the mismatch directly ("rung 2's slot
requirement exceeds a 4-slot split of serve.ps1's default -c 16384"). So the failure is loud and
already guarded.

**What is actually wrong** is that `serve.ps1` carries a rule it no longer obeys. A reader who
trusts that comment concludes a READY server is usable by every caller, which is false. The
comment and the constant were correct when written and a caller grew past them.

**What it would touch.** `tools/local-llm/serve.ps1` only - the floor constant and the comment
around it. The obvious repair is to make the floor derive from the largest declared caller rather
than restate it, so the next caller to grow cannot silently outrun it. **Do not just bump 3,300 to
11,465**: that hard-codes the same failure one level up, and it would also make the default
invocation throw, which is a behaviour change on a server Brad starts by hand.

**Constraint acknowledged.** The queue's group-H rule forbids a course run from changing
`serve.ps1`. Nothing was changed; this is the ledger entry the rule asks for.

### I51 - two unrelated ~81 tok/s numbers, and nothing says which machine either is about `DONE - BOTH FILES NOW NAME THEIR MACHINE, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08.]`** Two throughput figures rounded to the same number and described
different machines, in two files that never mentioned each other:
`design/EVAL-hunter-wall-clock-2026-09-04.md`'s **~81 tok/s** is CLOUD API agent output (Opus, over
the network, across 148,111 output tokens), and `tools/local-llm/serve.ps1`'s **80.4 tok/s** is the
local llama-server at 8 slots on the RTX 5070 Ti. Both now say so, beside the number, with the
failure named: speed up the local server, see a rate near 81, and conclude the hunter's wall clock
will move - it will not, because the hunter's wall clock is Opus output and the local server is not
in that path. `[[an-agreeing-number-escapes-scrutiny]]` with two sources instead of one.

**Verified:** both edits read back; `run-gates` exit 0, `pass=276 fail=0`.

**Source.** Same course. Routed to `model-finetuning-craft/applies-here.md` 2.

**What it is.** The estate records two throughput figures that round to the same number and describe
different machines:

- `design/EVAL-hunter-wall-clock-2026-09-04.md` 2b: **~81 output tokens/sec**, measured over 148,111
  output tokens of **cloud API agent** calls. This is what the memory `wall-clock-is-output-tokens`
  is about and what the standing `MAP_BATCH = 2` ruling rests on.
- `tools/local-llm/serve.ps1`: **80.4 tok/s aggregate** from the **local llama-server** at 8 slots
  on the RTX 5070 Ti (up from 36.6 at one slot).

**Why it matters.** Neither file mentions the other. The failure this sets up is an agreeing number:
someone speeds up the local server, sees a rate near 81, and concludes the hunter's wall clock will
move. It will not - the hunter's wall clock is Opus output over the API, and the local server is not
in that path. This is the `an-agreeing-number-escapes-scrutiny` shape with two sources instead of
one.

**What it would touch.** One clarifying sentence in each of the two files naming the machine, and
ideally the same in the memory `wall-clock-is-output-tokens`. No code, no gate, no board.

### I52 - a reflex candidate this run could not write: the per-slot context floor `DONE - THE REFLEX IS WRITTEN, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08.]`** `[[per-slot-context-is-context-over-slots]]`, indexed in `MEMORY.md`.
It carries I50's arithmetic - `-c` is the TOTAL KV budget and llama.cpp divides it by `--parallel`,
so the number that decides whether a caller works is `Context / Slots`, and the extract lane needs
11,465 of it - plus the reason not to simply raise the constant.

The item was filed as an item rather than written directly because a course run may not write outside
the repo. This session can, so it did.

**Source.** Same course, raised under procedure step 4.0 (can this finding be a reflex?).

**What it is.** The cue is typed and rare: a session editing `-Slots`, `--parallel` or `-Context` in
`tools/local-llm/serve.ps1`, or starting llama-server by hand with non-default values. The rule it
would fire is I50's arithmetic - **`-c` is the TOTAL KV budget and llama.cpp divides it by
`--parallel`, so the number that matters is `Context / Slots`, and the extract lane needs 11,465 of
it.** MUST FIRE: a diff touching `-Slots` or `--parallel` in that file. MUST NOT FIRE: any other
llama-server mention, or a read of the file without an edit.

**Why it is an item rather than a row.** Writing a reflex means writing under
`~/.claude/projects/C--Codex-ThriftyCrew/memory/`, which is outside the repo and outside a course
run's write scope. The candidate is recorded here so the between-courses pass can rule on it.

**What it would touch.** One memory file plus its `MEMORY.md` index line. Nothing in the repo.

### I53 - the local model's "decode" bar measures the whole round trip `DONE - RELABELLED; THE BAR IS DELIBERATELY UNCHANGED` `queue-4` `2-WAY` `RUNG1 MEASURE`

**`[CLOSED 2026-09-09 as a relabel. The re-derivation it invites is a separate decision.]`**

`elapsed_s` is a client-side stopwatch around the whole `/chat/completions` POST, so prefill, queueing
behind other slots, HTTP and JSON parsing are all charged to what the bench printed as **decode**.

Three files now say what the number is: `graph/lib/llm.py`'s `tokens_per_s` docstring, `graph/bench/bench.py`
(the row reads `median round-trip`, with four lines under the verdict explaining the bias), and a note in
`graph/prompts/model-selection.md` marking **every historical `median decode` row in that file as a
round-trip rate**.

**The bias is downward and it is NOT constant - it grows with prompt length**, so the same server scores
differently for a ~312-token `resolve` call than for a caller asking 4,096 out. Two consequences are
written down beside the number: these figures are **not comparable** to `tools/local-llm/serve.ps1`'s
36.6-to-80.4 slot sweep or to any published decode figure; and **a change that speeds up prefill only
would appear here as a decode improvement**, which is the shape that gets banked without being
investigated.

**THE BAR IS LEFT AT 15.0 ON PURPOSE.** It gated real model choices against a consistent, if
mislabelled, measure. Re-deriving it means re-benchmarking every candidate, which is a decision for
Brad, not a side effect of fixing a label. Moving it quietly would also have been the exact error
`measurement.md` names: a threshold chosen after seeing the number.

**What was NOT done, and it is one request.** A true decode rate needs the server's own timings object.
llama.cpp's OpenAI route may return one and `LLMResult.raw` already keeps the full response, so nobody
has to instrument anything - **nobody has looked**. Port 8080 refused during the course run and was
still refusing on 2026-09-09, so this could not be probed today.

**Source.** Coursera, *Optimize AI Inference Speed & Accuracy* (Starweaver), queue-4 H2, module 1.
Routed to `reliability-craft/pipeline-throughput.md` 7.5 and `reliability-craft/applies-here.md`
2026-09-07 entry 1.

**What it is.** `graph/lib/llm.py` lines 56-59 defines

    tokens_per_s = completion_tokens / elapsed_s

where `elapsed_s` (lines 176-178) is a client-side stopwatch around the entire
`/chat/completions` POST. `graph/bench/bench.py` consumes it at lines 125 and 270, gates on it at
line 275 (`BARS["tok_s"] = 15.0`), prints it at line 341 as **"median decode ... tok/s"**, and writes
it into `graph/prompts/model-selection.md` under the same label. The recorded 46.1 / 45.5 / 42.3
tok/s per candidate model are therefore round-trip rates, not decode rates: prefill, queueing behind
other slots, HTTP and JSON parsing are all charged to decode.

**Why it matters.** The bias is downward and it is **not constant** - it grows with prompt length,
so the same server scores differently for `resolve` (~312 tokens in) than for
`meal-prep/pipeline/local_extract.py` (asking 4096 out). Two consequences: the figures are not
comparable to `tools/local-llm/serve.ps1`'s 36.6 to 80.4 slot sweep or to any published decode
number, and a future change that speeds up prefill only would show up as a "decode" improvement.
Separately, `graph/bench/bench.py` has no warm-up discard (`warm`, `steady`, `discard` and
`first call` return zero hits in the file); the median over N absorbs one slow first call but never
measures the cold-start cost, which on this box means loading 12.2 GiB of weights.

**The cheap part of the fix.** `LLMResult` already keeps the full response as `raw=data`
(`graph/lib/llm.py` line 187), so if the llama.cpp OpenAI route returns a timings object the
per-stage numbers are already in memory and merely unread. **This was not verified** - port 8080
refused during the course run, so nobody looked at a live response. First step is one probe.

**What it would touch.** `graph/lib/llm.py` (add prefill/decode properties beside the existing one,
do not change it), `graph/bench/bench.py` (label the existing bar honestly, and add TTFT), and a
note in `graph/prompts/model-selection.md` that the historical rows are round-trip.
**Do NOT lower the 15 tok/s bar.** It gated real model choices against a consistent, if mislabelled,
measure; re-deriving the bar means re-benchmarking every candidate, and that is a decision for Brad.

**Constraint acknowledged.** Group H forbids a course run from changing `serve.ps1`, a sidecar
threshold or a model artefact. Nothing was changed. `graph/lib/llm.py` and `graph/bench/bench.py`
are outside that list but were left alone anyway, because a measurement change is exactly the thing
a run that just read a course about measurement should not make unsupervised.

### I54 - the quant format's dequantisation cost is named as a ceiling and never compared `PARKED - PRICED 2026-09-08: NO QUANT CHANGE IS PROPOSED, SO THE NUMBER CHANGES NO DECISION` `queue-4`

**`[PARKED 2026-09-08 under Pass 4 - price the measurement before commissioning it.]`**

The finding is correct and stands: `serve.ps1` records that aggregate throughput goes 36.6 to 80.4
tok/s from 1 to 8 slots and then **goes flat because Q3_K dequantisation compute becomes the
ceiling** - a real measurement, better than any course supplied - and **no file in this estate
benchmarks two quant formats against each other on this card.**

**What the measurement would cost, and what it would change.** Fetching an alternative GGUF and
benchmarking both is a real block of GPU time on the one box. **No quant change is proposed and none
is pending.** So the number would be recorded and nothing would be decided differently by it. That is
the legitimate reason to park a measurement rather than run it.

It is also **blocked behind I53**: running it before the decode bar means what it says would produce
two ROUND-TRIP numbers and label them decode, which is worse than having no comparison.

**THE TRIGGER THAT REOPENS THIS, written now so the requirement is not rediscovered later:** anyone
proposing a quant change. At that moment the standing rule (from H1) is *state the free-VRAM number
you expect to be left with*, and this item adds the second column that the flat-past-8-slots
measurement already implies - **a smaller file that dequantises more slowly can LOSE throughput while
gaining headroom.** Until then, any quant proposal is arguing about file size and guessing about
speed, and this item is the note saying so.

**Source.** Same course, module 3. Routed to
`model-finetuning-craft/publishing-and-automation.md` 11.3 and that domain's `applies-here.md`.

**What it is.** `tools/local-llm/serve.ps1` lines 45-67 record that aggregate throughput goes
36.6 to 80.4 tok/s from 1 to 8 slots and then **goes flat, because once the weight reads are
amortised Q3_K dequantisation compute becomes the ceiling**. That is a real measurement and it is
better than anything the course supplies. What does not exist anywhere is a comparison: no file in
this estate benchmarks two quant formats against each other on this card.
`graph/prompts/model-selection.md` records per-MODEL decode figures for a fixed format, never
per-FORMAT figures for a fixed model.

**Why it matters.** The standing rule for a quant change here (from H1) is "state the free-VRAM
number you expect to be left with". H2 adds a second column that the flat-past-8-slots measurement
already implies: **a smaller file that dequantises more slowly can lose throughput while gaining
headroom.** With no format-versus-format number on this box, any future quant proposal is arguing
about file size and guessing about speed.

**What it would touch.** A benchmark run only, no code change: fetch one alternative GGUF with
`tools/local-llm/fetch-model.ps1`, run `graph/bench/bench.py` against each, record both in
`graph/prompts/model-selection.md`. **Blocked behind I53** - running it before the decode bar means
what it says would produce two round-trip numbers and call them decode.

**Constraint acknowledged.** Nothing in `serve.ps1`, `sidecar/` or any model artefact was changed.

### I55 - two courses ruled "no motive for LoRA here" against the reranker, while a measured QLoRA plan for the local 27B sat unread `PARTLY DONE - THE QUESTION IS ANSWERABLE NOW; THE SPEND DECISION IS STILL BRAD'S` `queue-4` `1-WAY` `RUNG1 RULING`

**`[2026-09-09. Brad ruled: build the holdout and the eval first, decide after. No GPU time was spent.]`**

**Why that was the right order, and it is the sharpest fact in this item:** the feasibility doc's own
section 10 says the holdout split does not exist. Without it a training run **cannot be scored** -
per-example loss during training is noise, not a learning signal - so committing 17 to 25 hours of GPU
today would have bought an answer to a different question.

**Shipped, both pure and both GPU-free:**

- **`tools/local-llm/finetune-probe/split_holdout.py`** - the split. **The unit is the whole COMMODITY,
  never the row**, so a held-out commodity is cold by construction. Live over the real corpus:
  **101 holdout commodities of 505 (20.0%), 704 rows of 3,305 (21.3%)**, seeded and reproducible.
- **`tools/local-llm/finetune-probe/eval_holdout.py`** - the scorer that did not exist, with the bar
  **written above any run**: false-MATCH at or below **20%** against the stock-27B **29%** baseline
  earns the hours; between 20% and 29% is reported as **"MOVED, NOT EARNED"**; and it refuses to score
  at all under 100 cases. Abstention is counted, so a model that answers UNSURE on everything hard
  cannot post a flattering rate.

**THE FEASIBILITY DOC SAID "SPLIT BY COMMODITY FAMILY" AND THERE IS NO FAMILY TAXONOMY HERE.** The 516
gold commodity ids are slugs and every cheap heuristic is wrong somewhere: first-token grouping pairs
`laundry-detergent` with `laundry-pods` correctly and then files `zero-sugar-soda-2l` under `zero`;
last-token grouping separates the laundry pair. Rather than invent one, the split does the
unambiguous, strictly stronger thing and then **measures the residual risk instead of asserting it
away**.

**And the residual risk is large, which is exactly why measuring it mattered:**

| leak test | result |
|---|---|
| holdout commodities sharing a slug token with a training one (loose) | **73 of 101** |
| **containment pairs** - one slug is a superset of the other (tight) | **42** |

Containment is the one worth acting on: `asparagus` in training against `canned-asparagus` held out,
`milk` against `chocolate-milk` and `evaporated-milk`, `bread` against `bread-crumbs`. **A holdout
number computed today would be optimistic**, and now that is a printed figure rather than a hope. Token
sharing is deliberately over-cautious and says so (`black-pepper` shares `black` with `black-olives`
and that is not a leak).

**Verified:** `split_holdout` self-test 9 of 9 led by the must-fire that no commodity may appear on both
sides; `eval_holdout` 10 of 10 led by the must-fire that false-MATCH is scored over gold NON-match rows
only, and that a model abstaining on everything is UNSCOREABLE rather than a winner. `run-gates` exit 0,
`pass=291 fail=0`, both discovered. The corpora are gitignored, per the doc's reproducible-from-script
rule.

**STILL BRAD'S, and unchanged by any of this: whether to spend the hours.** 17 to 25 h of local GPU
across nights, or roughly 1 h and about $10 on a cloud A100. What changed is that the result would now
be scoreable, and that the 42 containment pairs should be read before trusting it. Section 7's standing
rulings are untouched: detached LoRA adapter, never a merged GGUF; reject-only kept afterward; thermal
watchdog on any local run.

**Source.** Coursera, *Fine-tuning Text Models with PEFT*, queue-4 group H entry H3, modules 1 and
2. Routed to `model-finetuning-craft/publishing-and-automation.md` 10.7 and 10.8, and that domain's
`applies-here.md` entry 1.

**What it is.** H1 and H2 each asked "does this change what `finetune_reranker.py` should do?",
answered no on sound reasoning, and recorded the verdict as if it covered the estate. It does not.
`design/MEASURE-local-finetune-feasibility-2026-08-22.md` is a **measured** QLoRA study of the local
27B on this box, with working probes in `tools/local-llm/finetune-probe/`: 57.3 tok/s, 8.31 h per
epoch, peak 15.59 of 15.92 GiB, 58.4M trainable params at r=8, and a corpus builder that emits 3,198
rows from `graph/gold/gold.jsonl`. Three separate course runs have now discussed LoRA in this estate
and none of them cited it.

**Why it matters.** The motive the two previous runs could not find is written down and quantified:
26.9B parameters against a 15.92 GiB card, where PEFT is not a preference but the only arrangement
that fits. The feasibility doc's section 10 also states plainly that **the work is unfinished** - the
commodity-family holdout split does not exist, and without it a training run cannot report a
cold-start false-MATCH rate against the stock-27B 29% baseline, which is the entire point of the
exercise.

**What needs a ruling, not a build.** Whether the 27B adjudication fine-tune is still wanted at all.
It was costed at 17-25 h of continuous local GPU across nights (or ~1 h and ~$10 on a cloud A100),
and it cannot overlap the 07:00 semantic sweep. That is a scheduling and money decision, not an
engineering one.

**What it would touch if ruled in.** `tools/local-llm/finetune-probe/build_corpus.py` (add the
family holdout), a new eval that reports holdout false-MATCH against the 29% baseline, and the
training venv `C:\Codex\llm\.venv-train` - deliberately not `sidecar/.venv`, which runs the sweep.
Section 7's rulings stand and are not up for revisiting here: detached LoRA adapter never a merged
GGUF, holdout by commodity family, reject-only kept afterward, and the thermal watchdog on any local
run.

**Constraint acknowledged.** Nothing in `serve.ps1`, `sidecar/` or any model artefact was changed,
and no probe was run. This is a reading of files already in the repo.

### I56 - no rank, alpha or target-module set has ever been compared here, and the two probes disagree with each other `OPEN - SMALL, AND IT IS A PREREQUISITE FOR I55` `queue-4` `2-WAY` `RUNG1 BLOCKED`

**Source.** Same course, modules 1 and 3. Routed to
`model-finetuning-craft/training-and-evaluation.md` 11 and `publishing-and-automation.md` 10.7.

**What it is.** `tools/local-llm/finetune-probe/step_probe.py:43` attaches LoRA at `r=16,
lora_alpha=32` across twelve target modules; `train_probe2.py:23`, the arrangement that actually
fits, defaults `R=8` with `lora_alpha=2*R`. Neither was chosen by comparison and the two were never scored against each other -
`step_probe.py` is kept explicitly as documentation of an arrangement that does NOT fit, so the
r=16 figure is not a rejected candidate, it is an untested one. Register claim C111 records the
same gap in the store: the `q_proj/v_proj` default is copied everywhere and nobody has ablated it.

**Why it matters.** Rank is the knob that decides how much VRAM is left for batch size, and this box
has **0.33 GiB** of headroom. Picking r=8 because a probe used it is the same class of error as
importing a threshold from a course reading - a number standing where a derived one belongs, in a
codebase whose `sidecar/THRESHOLDS.md` derives every other threshold it has.

**What it would touch.** Nothing in production. Short arms at r=8, 16 and 32 on a slice of the
corpus, scored on the same frozen holdout, with the acceptance margin stated first the way
`sidecar/checkpoint_selection.py` states its 0.0033. **Blocked behind I55's ruling** - there is no
point sweeping a rank for a run nobody has decided to make.

**Constraint acknowledged.** Nothing changed; no GPU work was done.

### I57 - Jaccard runs in three first-party files, and none of them says which of its two properties it is buying `DONE - ALL THREE SITES NAME THE PROPERTY THEY BUY, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08.]`** One tailored comment at each of the three first-party Jaccard uses,
naming which of the metric's two consequences it is buying and, for the two that rank, why the
no-gradient hazard cannot fire there:

- `grocery/ad-match-lib.ps1:180` - presence over frequency, as the THIRD tie-break. The hazard cannot
  fire because `$overlap -lt 1 -> continue` guarantees every surviving candidate shares a token and
  the overlap COUNT has already ranked them. **This use is correct rather than lucky, and the comment
  now says which.**
- `grocery/resolve-hyvee-links.ps1:187` - presence over frequency over SETS, which is what makes it
  symmetric and is why a long candidate pays for its extra words.
- `sidecar/sweep.py:178` - the no-gradient half named as a PROPERTY OF THE METRIC rather than as a bug
  in `prior_rulings`. Every pair sharing no token scores identically, so Jaccard cannot rank
  non-overlapping candidates at all - which is disqualifying for a RETRIEVER and is why the
  replacement there is embeddings rather than a better Jaccard.

**The point is not documentation.** It is that a future scorer written by imitation would have copied
the standalone-retriever shape, which is the failure `teach with examples` warns about: existing code
is an instruction nobody wrote on purpose.

**Rung 2 is NOT done and needs a ruling** - whether `$bestJac` earns a row in
`sidecar/THRESHOLDS.md`. It is a tie-break never compared against a bar, so it is arguably not a score
space at all. Left open deliberately rather than decided here; `ops/audit-threshold-register.ps1`
cannot see a number it was never told about, so silence is the status quo either way.

**Verified:** `run-gates` exit 0, `pass=276 fail=0`.

**Source.** Queue-4 course 12, IBM "Unsupervised Machine Learning", worked 2026-09-07 as a partial
run. Routed to `rag-craft/vector-space-foundations.md` 21a and `rag-craft/applies-here.md` 12.

**Where it comes from.** Jaccard distance is `1 - |A intersect B| / |A union B|` on SETS, so it
discards repetition and length before it counts anything. That has two consequences and they pull in
opposite directions. Presence over frequency is often exactly right for short names. But **every
pair sharing no token scores exactly 1**, so Jaccard has no gradient across non-overlapping
candidates and cannot rank them at all.

**What the estate has.** Three first-party uses, all verified 2026-09-07:

- `grocery/ad-match-lib.ps1:166` computes it, and `:180` uses it as the third-rank tie-break behind
  a price match and a raw shared-token count. **This use is correct** and the no-gradient hazard
  cannot fire, because an overlap count has already ranked the candidates.
- `grocery/resolve-hyvee-links.ps1:187`, as symmetric overlap so extra words in a candidate cost
  something.
- `sidecar/sweep.py:178` documents that `Resolver.prior_rulings` ranks precedent by bag-of-words
  Jaccard over `[a-z]{3,}`, per commodity, **and records the no-gradient failure from the field**:
  it retrieves nothing when the words do not overlap, the coconut-oil against Epsom-salt case where
  two listings share no word and are the same mistake. That is the set-theoretic property observed
  as a bug, and the fix already chosen for it is embeddings.

So the estate hit both halves and wrote down neither as a property of the metric. `sidecar/THRESHOLDS.md`
also has no row for a Jaccard space, although `ad-match-lib.ps1` compares its output against a
`$bestJac`.

**What rung 1 is.** A comment, not a rewrite. Beside each of the three, one line saying which
property it is buying - presence over frequency, or frequency as evidence - and, for the two that
rank, that the no-gradient case is handled by the overlap count in front of it. This is the cheapest
possible fix and it is the one that stops a future scorer being written as a standalone Jaccard
retriever by imitation, which is the failure mode `teach with examples` warns about: existing code
is an instruction nobody wrote on purpose.

**What rung 2 would be, and it needs a ruling.** Whether `$bestJac` earns a row in
`sidecar/THRESHOLDS.md`. The register's stated subject is score spaces that do not share a scale,
and a tie-break that is never compared against a bar is arguably not one. Ruling either way is
better than the current silence, because `ops/audit-threshold-register.ps1` cannot see a number it
was never told about.

**What it would touch.** Comments in two `grocery/` scripts and one `sidecar/` docstring at rung 1.
No behaviour, no board, no gate. Rung 2 touches `THRESHOLDS.md` and possibly its audit.

**Constraint acknowledged.** Nothing was changed. This is a reading of files already in the repo.

### I58 - `sidecar/requirements.txt` is wrong about two of its five pinned packages, and nothing in the estate compares it to the venv `DONE - THE CHECK EXISTS, THE DECLARATION IS CORRECTED AND DATED, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08. The item's own recommendation was taken.]`**

**The drift reproduced exactly as filed**, read off the filesystem: `sentence-transformers` declared
**5.1.2** against an installed **5.6.1**, `fastapi` declared **0.121.2** against **0.141.1**; `torch`,
`transformers` and `uvicorn` match. 5 pins, 49 installed distributions.

**`ops/audit-python-pins.ps1`** parses the `==` pins out of `sidecar/requirements.txt`, reads the
version out of each matching `*.dist-info` directory, and fails on a mismatch.
**`sidecar/requirements.txt` is corrected to 5.6.1 and 0.141.1, with the correction DATED in a
comment** so a later reader can see the declaration was retro-fitted to the install and not the other
way round - and carrying the honest consequence the item asked for: **no AUC or threshold recorded
before 2026-09-08 can be attributed to a specific `sentence-transformers` version, because the only
written record of it was wrong.**

**IT IS IN THE WATCHDOG, NOT IN `run-gates`, AND THE ITEM'S PLACEMENT WAS WRONG.** The item called
the check hermetic and put it in `run-gates`. The SELF-TEST is hermetic - it drives pure functions
with synthetic fixtures and run-gates discovers it like any other. **The LIVE run is hermetic only
where `sidecar/.venv` exists**, and a CI runner, a worktree and a fresh checkout have none. It
correctly reports BLIND at exit 3 there, and `run-gates` treats every nonzero exit from a `$static`
entry as a FAIL - so registering it would have painted the gate red for a condition nobody can clear,
which is the red-on-day-one shape wearing a different coat. It runs as watchdog check **5a2**, beside
`audit-ad-forecast`, which already distinguishes exit 3 as could-not-evaluate.

**And that placement was found by a gate, not by reasoning.** The first version had no caller and
`audit-script-census` flagged it `DEAD: a detector that NOTHING in production calls`.

**Verified, all three paths OBSERVED rather than assumed:** self-test exit 0 over 9 cases (led by a
must-not-fire on the `dist-info` UNDERSCORE normalisation, without which every pin reads NOT INSTALLED
and the whole check is vacuous); live run **exit 2** before the correction naming both drifted
packages; live run **exit 0** after it; and a synthetic repo with no venv returning **exit 3 BLIND**.
`run-gates` exit 0, `pass=277 fail=0`.

**The item's other conclusion stands and is worth keeping:** this is NOT the problem containers solve.
The drift is between a declaration and an install on one box, and an image rebuild would have carried
it forward unchanged. What catches it is a comparison, not a runtime.

**Source.** Queue-4 group E, worked 2026-09-07. **Both courses were dropped on outline evidence**
without reading a lecture, so this finding is not routed course material - it comes from the estate
check the run did instead. The standing containerise-or-not verdict is in
`model-finetuning-craft/applies-here.md`, dated the same day.

**What it is.** `sidecar/requirements.txt` declares seven packages, five of them with `==` pins.
Measured against `sidecar/.venv/Lib/site-packages/*.dist-info` on 2026-09-07:

| Declared | Installed | |
|---|---|---|
| `sentence-transformers==5.1.2` | **5.6.1** | DRIFTED |
| `fastapi==0.121.2` | **0.141.1** | DRIFTED |
| `torch==2.11.0+cu128` | 2.11.0+cu128 | matches |
| `transformers==5.14.1` | 5.14.1 | matches |
| `uvicorn==0.52.0` | 0.52.0 | matches |

Nothing reads the file. Its only two references anywhere in the estate are prose: `sidecar/README.md`
line 62 quotes the `uv pip install -r requirements.txt` command, and this backlog names it at lines
1942 and 1959 as the estate's only requirements file. `grep -rn requirements ops/` exits 1 - no gate,
audit or self-test touches it. There is no lockfile of any kind in the repo (`uv.lock`,
`requirements.lock`, `poetry.lock`, `Pipfile.lock` all absent).

**Why it matters.** `sentence-transformers` is the library the matcher's whole score space is built
on: `sidecar/lib_match.py` line 41 imports `SentenceTransformer` and `CrossEncoder` from it and line
99 constructs the embedder, and that is the only import of it in the tree, so every bi-encoder and
cross-encoder number this estate produces comes through it. `sidecar/THRESHOLDS.md` registers three
score spaces and `sidecar/freeze_eval.py` exists
because a changed input moved holdout AUC from 0.9705 to 0.7921 - this estate already knows that the
embedding side is the sensitive one. A minor-version move across `sentence-transformers` 5.1 to 5.6
is exactly the kind of change that shifts a score space without shifting a number anybody watches,
and every eval this estate has recorded since the drift was produced on 5.6.1 while the file on disk
says 5.1.2. The wrong half is the DECLARATION, not necessarily the install: nobody can currently say
which version any recorded AUC was measured on, because the only written record is wrong.

This is also the answer to the question group E was queued to ask. The queue entry proposed
`sidecar/` as "exactly the reproducibility problem containers exist for". It is not: the drift is
between the declaration and the install on ONE box, and an image rebuild would have carried it
forward unchanged. What catches it is a comparison, not a runtime.

**What rung 1 is.** A hermetic self-test - it reads two files on disk and needs no board, so it
belongs in `ops/run-gates.ps1` rather than the daily chain. Parse the `==` pins out of
`sidecar/requirements.txt`, read the version out of each matching `*.dist-info` directory name under
`sidecar/.venv/Lib/site-packages`, and fail on any mismatch. Its `MUST FIRE` fixture is the current
state (a declared 5.1.2 against an installed 5.6.1); its `MUST NOT FIRE` is a pin that matches; its
`CLEAN TWIN` is an unpinned line such as `numpy`, which must be skipped rather than flagged. It owes
a `<NAME>-COMPLETE` marker as its last line per `lib/guard-contract.ps1`.

**The ruling it needs first, and it is the whole decision.** Which side is authoritative. Either
`requirements.txt` is corrected to 5.6.1 and 0.141.1 - cheap, and it makes the file true - or the
venv is rolled back to the declared versions, which is not cheap and would need the frozen eval
re-run to show the score space did not move. **Correcting the file is the recommendation**, with the
correction dated in a comment so a later reader can see the declaration was retro-fitted to the
install rather than the other way round, and with the honest note that no recorded AUC can be
attributed to a specific `sentence-transformers` version before that date.

**What it would touch.** One new `-SelfTest` under `ops/`, its registration in `run-gates.ps1`, and
one edit to `sidecar/requirements.txt`. No board, no page, no published number, no GPU work.

**Constraint acknowledged.** Nothing was changed. Both versions above were read off the filesystem;
no package was installed, upgraded or removed.

### I59 - the standing "no em dashes" rule has no gate, and 3,151 em dashes sit in the lesson and Substack source `PARKED - C128 IS SETTLED BY MEASUREMENT: NO PUBLISHED BODY CARRIES AN EM DASH` `queue-4`

**`[CLOSED PARKED 2026-09-08. Option (a) was the recommendation, it cost minutes, and it closed the
item outright exactly as the item predicted it might.]`**

The open question was C128: *source markdown is not published output, and nobody has ever read a
published lesson body.* Read now, through the Ghost Admin API, which returns the post's own HTML -
the body a paying member is served.

**Measured 2026-09-08 over EVERY published post, not a sample:**

| set | bodies read | with an em dash |
|---|---|---|
| the 52-week lessons | **52 of 52** | **0** |
| every other published post | **1,013 of 1,013** | **0** |
| **total** | **1,065** | **0** |

No body was skipped, and a post with no HTML would have been counted as skipped rather than scored 0.

**VERDICT: the 3,151 em dashes in 125 source files DO NOT REACH A READER.** The standing rule is
unbroken where it matters, and the item's own expensive option (c) - sweeping 125 content files and
republishing each - **would be a real risk to live pages for no reader-facing gain. Do not do it.**
Option (b), a ratcheted detector over reader-facing source, is also not worth building: it would
guard a corpus that demonstrably does not ship the character.

**A defect in the reading, recorded because it produced a confident wrong zero first.** The first
attempt used `limit=all` and got back **exactly 100 posts**, none of which was a lesson, and reported
*"published lessons matching ^week-N: 0"*. `limit=all` is CAPPED at 100 here; the real total is
**1,565 posts, 1,065 published, over 16 pages**. A round 100 that answers a question is the shape
`[[a-negative-search-result-must-prove-itself]]` exists for, and only the pagination meta showed it.

**One observation, not a finding:** 8 of the 52 lessons and 4 of the 1,013 other posts contain an EN
dash. The standing rule names the em dash specifically, so this is not a violation and nothing is
proposed. Recorded so the next reader does not re-derive it.

**Also unchanged:** nothing mechanical enforces the em-dash rule, which is still carried only inside
five agent prompts and one archived `DeDash` helper that does not run. That remains true and is now
known to be costing nothing.
*Source: queue-4 group F, technical writing (2026-09-08).* `CLAUDE.md` line 57 states **"No em
dashes"** under "Standing rules for anything that ships", and the workspace `CLAUDE.md` repeats it.
Nothing mechanical enforces it. The rule is carried only inside five agent prompts
(`.claude/agents/post-publish-reviewer.md` line 42, `recipe-batch-auditor.md` 89, `recipe-writer.md`
38, `triage-developer.md` 147, `recipe-ingredient-mapper.md` 194) and by one `DeDash` helper in
`archive/ghost-config/voice-rewrite/publish-rewrites.ps1` line 33, which is **archived and does not
run**. A grep across `ops/`, `site/`, `meal-prep/` and `grocery/` finds no live stripper and no gate.

**Measured 2026-09-08:** 3,151 em dashes in 125 files under `content/`, of which 1,038 sit in 54 of
the 55 `content/lessons/*.md` and the rest in `content/substack/posts/`. `site/` and `public/` hold
**zero**.

**What is NOT established, and it decides the size of this item.** Source markdown is not published
output. The Week-N lessons live at `https://www.thriftycrew.com/week-<n>-<slug>/` and their bodies
are behind the paywall, so an anonymous fetch returns only the teaser; the one em dash visible there
belongs to Ghost's own date-and-read-time byline, not to our copy. **Nobody has read a published
lesson body.** So this item is not "the live site breaks the rule", it is "the rule is unchecked and
the source corpus is full of the character". Claims-register row C128 holds the open question.

**The ruling it needs.** Almost certainly the rule wants a stated regime rather than a corpus sweep.
The 52-week series was written before the rule and there is no evidence a reader has ever seen a
violation. Three options, cheapest first: (a) settle C128 by reading one lesson body as a subscriber,
which costs minutes and may close the item outright; (b) add a detector over reader-facing SOURCE
with a ratchet high-water mark that may only go down, per the estate's own do-not-add-a-red-gate rule;
(c) sweep the corpus, which touches 125 published files and is the expensive answer to a question
nobody has confirmed is a problem. **Recommend (a), then decide.**

**What it would touch.** (a) nothing. (b) one new `ops/audit-em-dashes.ps1` with a must-fire and a
must-not-fire fixture, its registration in `run-gates.ps1`, and a high-water file. (c) 125 content
files and a republish of each, which is a real risk to live pages and should not be done casually.

**Constraint acknowledged.** Nothing was changed. Every figure above was read off the filesystem or
off a public page.

### I60 - three finance lessons make a quantified claim and give no quantity `PARTLY DONE - SOURCE FIXED AND VERIFIED; THE LIVE POSTS ARE NOT REPUBLISHED` `queue-4` `1-WAY` `RUNG1 BUILD`

**`[2026-09-09. Brad ruled: worked example with stated assumptions.]`**

**All four claims are fixed in `content/lessons/` and mirrored into `content/substack/posts/`.**

**Lesson 31 was the clear case and it now finishes its own sum.** Two savers, $3,000 a year, 7%
average annual return, both stopping at 65: the one who starts at 22 reaches about **$743,000**, the
one who starts at 32 about **$357,000**. **She contributed $30,000 more over her life and ended with
$386,000 more.** The paragraph names every assumption inline and says plainly that a steady 7% every
year is not what a real market does.

**Lesson 30 needed an external fact, so it was verified externally rather than written from memory:**
large-company U.S. stocks have returned **about 10% a year on average since 1928 with dividends
reinvested, closer to 7% after inflation**. The rewrite also says what the average hides - **about a
third of the 98 calendar years since 1928 finished down** - because a bare 10% on a paid finance page
is its own kind of overstatement.

**Lesson 37 gets the arithmetic the claim was gesturing at:** $27,000 at 6.5% left unpaid through four
years of school starts repayment at roughly **$34,700**, and at $300 a month that is about **15 years
versus 10 years 4 months**, nearly five years shorter and about **$17,700 less paid in total**, bought
with $4,800 of interest payments during school.

**The fourth claim was NOT given a number, deliberately.** *"Scholarships, grants, community college
... can all dramatically reduce the total borrowed"* has no arithmetic implied anywhere on the page,
and inventing tuition figures to finish it would be the exact fabrication the standing rule forbids.
The magnitude word is cut and the sentence now tells the reader to price their own combination.

**Re-measured after the edit: sentences pairing a magnitude word with no digit fell from 16 across 14
files to 10 across 10 files.** All ten survivors were read and every one is behavioural rather than
financial (*"teens are much more likely to buy into a system they helped shape"*), which confirms the
original triage rather than assuming it.

**`run-gates` exit 0, `pass=288 fail=0`.**

**WHAT IS NOT DONE: the three live Ghost posts are unchanged.** The repo and the live site now
disagree on these three lessons. Republishing is an outward-facing change to paid content and is
Brad's call, not a side effect of a copy fix.

**Noticed in passing, not acted on:** the sentences I rewrote sit among em dashes, which the standing
rule forbids in anything that reaches a reader. My new text uses hyphens; the rest of those files
still carry em dashes from before that rule, and sweeping them is its own item.
*Source: queue-4 group F, Rice `engineering-writing`, the vague-to-specific ladder (2026-09-08).*
On a paid finance site, a magnitude claim with no number is the defect that course teaches against,
and it is a sharper instance of the estate's own "no fabricated numbers, and understating is exactly
as wrong as overstating".

Measured over all 55 `content/lessons/*.md`: 16 sentences pair a magnitude word (`dramatically`,
`significantly`, `substantially`, `much more`, `a lot more`) with **no digit anywhere in the
sentence**, across 14 files. Most are rhetorical and correct as written ("teens are much more likely
to buy into a system they helped shape"). **Three are quantifiable financial claims:**

- `content/lessons/lesson-30-boring-wins-index-funds-101.md` - "stocks as a group have grown
  significantly over long time periods".
- `content/lessons/lesson-31-the-401k-and-free-money.md` line 51 - the early starter "can end up
  with dramatically more money", in a lesson whose entire point is the size of that gap.
- `content/lessons/lesson-37-student-loans-without-the-panic.md` - "can all dramatically reduce the
  total borrowed", and separately "the payoff timeline shrinks dramatically".

**The fix is not to invent a figure.** It is to show the arithmetic already implied, or to name the
assumption and its source, or to cut the magnitude word. Lesson 31 is the clear case: it already sets
up two savers ten years apart and then declines to finish the sum.

**What it would touch.** Three lesson files and their three published Ghost posts, plus the mirrored
`content/substack/posts/substack-week-30|31|37.md`. No board, no pricing engine, no gate.

**Constraint acknowledged.** Nothing was changed.

### I61 - the local LLM server is a four-slot queue whose service time has only ever been measured as a mean `PARTLY DONE - INSTRUMENTED; THE RUN NEEDS A SERVER THAT IS DOWN` `queue-4` `2-WAY` `RUNG1 MEASURE`

**`[2026-09-09. The half that does not need the GPU is shipped. The half that does is blocked, and the block is real.]`**

**The premise is confirmed, not assumed.** `graph/pipeline/resolve.py:1213` writes exactly one
`elapsed_sec` for a whole run and nothing per request. There is no per-request timing anywhere on disk
to compute percentiles from, so this could not be answered out of history.

**SHIPPED: `graph/lib/service_time.py`, and the timing it needs was already being thrown away.**
`LLMResult.elapsed_s` is measured on every call and discarded; both `resolve.py` call sites
(`resolve-adjudicate` and `resolve-challenge`) now record one row per request with wall time and both
token counts. Nothing new is timed and no extra call is made.

**THE BAR IS WRITTEN BEFORE ANY DATA EXISTS**, which is the only time it can honestly be written. For an
exponential distribution the coefficient of variation is exactly 1, so: **CV <= 1.20 near-exponential**
(an M/M/c model is a fair description, no build owed); **CV > 1.20 heavy-tailed** (the wait is dominated
by a minority of slow requests and rung 2, a **bounded wait rather than a timeout**, is owed).

**`record()` swallows every one of its own failures on purpose.** A measurement that can break the
pipeline it measures gets deleted the first time it does, and then the pipeline is unmeasured again.

**Verified:** self-test 11 of 11, exit 0. The founding case is a fixture: **one request 50x slower than
the other fifty is HEAVY-TAILED while the mean stays near 2 seconds** - which is precisely the tail a
mean hides. A deterministic exponential sample is a must-not-fire, so the bar cannot simply call
everything heavy. `--report` with no rows exits **3 and says BLIND**, never 0.

**BLOCKED, and this is the honest part: no numbers yet.** Port 8080 refused on 2026-09-09 and no
`llama-server` process is running, so not one request has been recorded. **There are no percentiles in
this note because there is no data, and a percentile I could not observe is not one I will write down.**
The instrument is in place; the first `resolve.py` run against a live server fills it, and
`python graph/lib/service_time.py --report` then answers the item in one command.
*Source: Simulation Models for Decision Making (course 18, Minnesota Carlson, Gupta).*

Queueing writes a system as `arrival / service / servers`. `tools/local-llm/serve.ps1` line 107 sets
`-Slots 4`, so the server half is `n = 4`; `graph/pipeline/resolve.py` line 1295 sets `--jobs 4`, so
the arrival half is deliberately coupled to it. The header at `serve.ps1` 61-66 already states both
consequences correctly - *"more jobs than slots just queues inside the server and burns client
timeouts"* and *"a sequential client against eight slots is exactly as fast as one slot"*.

**What is missing is a distribution.** Everything recorded about service time here is a mean: 0.99
q/s at 4 slots against 1.08 at 8 (`serve.ps1` 100-106), and the two ~81 tok/s figures I51 is already
about. The course's strongest demonstration is that the mean does not predict the queue. Three runs,
same arrival rate, one server: exponential service at 3.0 min queued 30-40 and climbing; exponential
at 2.5 min queued 1 to 3; and an **empirical** service distribution whose mean was 2.9 - *better* than
the first - queued **around 240**. Only the shape changed. So the estate cannot currently say what a
burst does to it, and the failure mode the header names is a **client timeout**, which is the "drop"
policy - the one that loses work silently.

**Why it matters here.** The coupling `--jobs == -Slots` is the equal-rates case, which is not
break-even; it is only safe because the caller is a closed loop that waits. The moment a second
caller holds slots at the same time - a second agent, a browser-pull lane, a manual probe - nothing
bounds arrivals and the drop policy is what catches it.

**Rung 1, and it writes nothing.** Log per-request wall time for one existing `resolve.py` run, print
the percentiles, and say whether the distribution is anywhere near exponential. That is a report.
Only if the tail is heavy is there a build, and the build is a bounded wait rather than a timeout.

**What it would touch.** Rung 1: nothing, one log file under `graph/out/`. A later rung would touch
`resolve.py`'s client and `serve.ps1`'s guidance comment, not the board or any gate.

**Constraint acknowledged.** Nothing was changed. Standing context is
`~/.claude/skills/reliability-craft/applies-here.md` entry 4; the method is `pipeline-throughput.md` 8.

### I62 - `MIN_SCORE`'s on-topic and off-topic score distributions now overlap completely, so the calibrator's suggested threshold cannot be right `DONE - THE CALIBRATOR NOW PRINTS THE OVERLAP INSTEAD OF LETTING A MARGIN STAND IN FOR IT, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08, and half of it was already closed before this session started.]`**

The item proposed that the calibrator stop printing a *suggested MIN_SCORE* derived from a separation
that no longer exists. **That print is already gone** - `recall-hook-calibrate.py` now mentions it
only in its header, as the historical error it caused. What remained was the second half of the
item's ask, and it is the half that still had teeth: the VERDICT line prints a **margin**, and a
margin is one number standing in for two distributions.

So the calibrator now prints, in its own output, whether the two sets separate at all - and says
plainly what follows when they do not. **Run live 2026-09-08, exit 0:**

```
DO THE TWO SETS SEPARATE? on-topic 8.54-69.26 over 159 probe(s); off-topic 0.00-11.68 over 13.
THEY OVERLAP: 5 of 13 off-topic prompt(s) score at or above the LOWEST on-topic probe.
NO CUTOFF SEPARATES THESE SETS, so no suggested MIN_SCORE is meaningful and none is printed.
```

**The overlap is worse than the item measured** - 5 of 13 off-topic prompts sit at or above the
lowest on-topic probe, against the 4 of 13 recorded when the item was filed. The 2026-09-06
suggestion to raise `MIN_SCORE` from 9.0 to 11.2 rested on a margin of 0.79 between one pair of
extremes; **11.2 would now sit above a great many on-topic probes.**

**And where two sets overlap everywhere the question changes**, which the output now says: not *which
cutoff separates them* but *which error is cheaper* - and that is already answered in the code.
`recall-hook.py` calls the floor *deliberately permissive* and a wrong hit costs about 40 bytes of
injected pointer. **A written asymmetric cost outranks an unwritten margin.**

**NO THRESHOLD WAS CHANGED**, which the item required and which matters here for a second reason:
`MIN_SCORE` governs the recall offers that feed a course run's own dedup, so a run proposing to move
it is the interested party. This changes what the calibrator SAYS, never what the hook does.

**Verified:** the calibrator ran to exit 0 with the new block, read off its real corpus of 159 probes.
*Source: Decision Making (course 17) and Simulation Models (course 18).*

`~/.claude/skills/course/LEDGER.md` 4310 records a deliberate refusal: `recall-hook-calibrate.py`
suggested raising `recall-hook.py`'s `MIN_SCORE` from 9.0 to 11.2, and it was declined because the
suggestion rested on **a margin of 0.79** - lowest on-topic 11.59 against highest off-topic 10.80 -
over a handful of probes. The refusal was correct. **Re-running the calibrator on 2026-09-08 shows it
was correct for a stronger reason than was recorded, and that the suggestion's premise has since
inverted.**

Live numbers, from that run: corpus 1,064 sections, **148 probes** (140 harvested from `SKILL.md`
trigger clauses plus 8 hand-written), floor now **8.5**, not the 9.0 the ledger entry was written
against. Lowest clearing on-topic probe **8.54** (`claude-code-automation`, *"checking work from an
unsupervised run"*). Highest off-topic prompt **11.00** (*"rename this variable to total_count"*), with
**4 of 13** off-topic prompts clearing the floor and **3** on-topic probes baselined below it.

**The two sets no longer separate at any cutoff.** A threshold of 11.2 would sit above almost every
on-topic probe in the store. The single margin between one pair of extremes was never evidence about
where a cutoff belongs, because it is one number standing in for two overlapping distributions -
which is course 18's central point and course 17's sensitivity test in one: a recommendation that
flips inside the spread of its own inputs has not been made.

**Where they overlap everywhere, the question changes from "which cutoff separates them" to "which
error is cheaper", and that is already answered in the code.** `recall-hook.py` 41 calls the floor
*"deliberately permissive"*, and the calibrator's own off-topic block says a wrong hit costs about 40
bytes of injected pointer. A written asymmetric cost outranks an unwritten margin.

**What is proposed, and it is small.** The calibrator prints a "suggested `MIN_SCORE`" figure derived
from a separation that no longer exists. Either it stops printing a single suggested value and prints
the two distributions with their overlap, or its output says in one line that a suggestion is only
meaningful while the sets separate. **No threshold is changed by this item.**

**Explicitly out of scope for a course run.** `MIN_SCORE` governs the recall offers that feed a course
run's own dedup, so a run proposing to move it is the interested party. `course/procedure.md` step 8's
first hard exception covers exactly this, and it is why the measurement is reported and nothing is
touched.

**What it would touch.** `~/.claude/skills/recall-hook-calibrate.py`, its summary block only. Outside
the repo, like I1 and I3.

**Constraint acknowledged.** Nothing was changed. The calibrator run exited **3**, not 0: its
recognition-floor half could not compare corpora from that cwd. The probe half ran and printed, and
only the probe numbers are quoted here.

### I63 - the backlog records whose move an item is and never how reversible it is, so 17 items that write nothing queue behind 3 that need a policy `DONE - THE TWO AXES ARE FIELDS AND THE AUDIT READS THEM, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08, and the closing measurement contradicts the item's own headline number, which is the more useful half.]`**

This item proposed **one** column. Two shipped, because reversibility alone does not say what the
cheapest next step *is*, and that was the other half of the signal living in prose. Every not-closed
heading now carries `2-WAY`/`1-WAY` and `RUNG1 <READ|MEASURE|DOC|BUILD|RULING|BLOCKED>`; the legend
is at the head of this file; `ops/audit-backlog-status.ps1` parses both, fails a not-closed heading
missing either, and prints the split with its denominator. Ten new frozen fixtures, including the
must-fire for the founding shape (an `OPEN` item with no reversibility) and the two must-not-fires
that keep `DONE` and `PARKED` exempt.

**What the sort actually found.** This item said *"17 items that write nothing queue behind 3 that
need a policy"*, from a prose scan. Measured against fields instead, exit 0,
`items=130 notclosed=68 twoway=56 oneway=12`: **56 of 68 not-closed items are two-way, 82%.** The
method that ordered the sort predicted about half. Both earlier numbers were low for the same
reason - **they counted items that DECLARED their first rung was cheap, not items whose first rung
IS cheap.** Sixteen were declaring it; fifty-six were it. A count with no stated test cannot be
checked, which is I82's finding arriving on the instrument that was supposed to settle I82.

**And the sort found two items that were not on the board at all.** `I71` and `I72` were filed with
headings of the shape `### I71 [ID ALLOCATED ...]` - no title, no state - which matched neither half
of the audit's item pattern, so it skipped them as prose. Every board count taken since they merged
said 128 items and 66 not closed. **It is 130 and 68.** Both headings were rewritten to the item
shape and their allocation notes moved into their bodies. This is the exact defect the item was
filed about, one level lower: a signal that lives in a shape nobody validates gets miscounted, and
the miscount is invisible because the missing rows look like rows that were never written.

**Verified:** `ops/audit-backlog-status.ps1 -SelfTest` exit 0, 21 cases; live run exit 0,
`BACKLOG-STATUS-COMPLETE items=130 malformed=0`; `ops/run-gates.ps1` exit 0, `pass=275 fail=0`.

**The MAP half of this item is NOT done and was not proposed as work.** It says so itself: nobody
should build a scoring rubric until Brad decides he wants one. The eight `NEEDS A RULING` items are
written up for him in `design/RULINGS-2026-09-08.md` in the shape MAP asks for - criteria first,
assessments separately, global judgement last - which is that idea used once rather than installed.
*Source: Decision Making (course 17, Nardy), lecture "When decisions are experiments" and the MAP
lesson.*

This file's five states answer **whose move it is** - `NEEDS A RULING` is Brad's, `OPEN` is mine. They
say nothing about **what it costs to be wrong**, and that is the axis the course adds. Bezos's split,
quoted in the course: a **type 1** decision is a one-way door, made slowly with consultation; a
**type 2** decision is a two-way door, and *"can and should be made quickly"*. The named failure is
organisations applying the type 1 process to type 2 decisions as they grow, which reads as caution and
costs throughput.

**Measured on this file, 2026-09-08**, by `ops/audit-backlog-status.ps1` before these three items were
added: **90 items** - 50 `DONE`, 10 `PARKED`, 3 `NEEDS A RULING`, 1 `PARTLY DONE`, 26 `OPEN`, exit 0.
Of the 30 that are not closed, **17 already say in their own free text
that the first step writes nothing or is small**: I31, I32, I33, I34, I35, I36, I39, I40, I43, I45,
I46, I47, I56, I57, I58, I59, I60 - *"RUNG 1 IS A READ"*, *"RUNG 1 IS A MEASUREMENT, NOT A BUILD"*,
*"RUNGS 1 AND 2 ARE REPORTS"*, *"SMALL, AND IT IS A COMMENT, NOT A REWRITE"*. Every one of those is a
two-way door: it produces a file that can be deleted, and being wrong costs the time it took.

**They are listed identically to the ones that are not.** I38 (whether randomness may enter the
parsers) and I55 (whether to spend on a QLoRA run) change what the estate is tested against and what
it spends; those are one-way enough to want a ruling. Reading the list, the two kinds are
indistinguishable, and the effect is that a read nobody needs to authorise waits in the same line as a
policy that genuinely does.

**What is proposed, and it is one column.** Add a reversibility marker to each non-closed heading -
two values, `2-WAY` and `1-WAY` - and state the standing rule that a `2-WAY` item does not wait on a
ruling. The information is already in the free text; nothing new has to be judged to fill it in. The
state vocabulary is unchanged, so `ops/audit-backlog-status.ps1` is unaffected unless someone chooses
to make it count the new column too.

**The second half, for the items that really are one-way.** The course's MAP (Mediating Assessment
Protocol; Kahneman, Sibony and Lovallo, 2019) is the process for those: break the decision into
independent intermediary assessments, fix fact-based criteria for each **before** the decision meeting,
score each one on its own, and only then form a global judgement - deal-breakers first. This file
already writes each item as *what, why, and what it would touch*, which is most of an assessment
skeleton. What it does not do is score them separately before Brad forms a view on the whole item.
**Proposed as a shape, not as work**: nobody should build a scoring rubric until Brad decides he
wants one.

**What it would touch.** `design/BACKLOG-course-findings.md` headings only, and the paragraph above
the state table. No script, no gate.

**Constraint acknowledged.** No heading was re-labelled by this run; the counts above are a read.

### I64 - the Freezer Math tool decides a several-hundred-dollar purchase from three means, and its verdict flips inside their error bars `DONE - REFRESHED AND THE FLIP POINT IS ON THE PAGE, RULED BY BRAD 2026-09-08` `queue-4`

**`[RUNG 2 SHIPPED 2026-09-08 on Brad's ruling: refresh AND flip point together, never the refresh
alone.]`**

**What a reader saw before, and sees now**, at the page's own defaults ($120/month, a $200 freezer):

| | before (`weeks:5`, 2026-07-10) | now (`weeks:22`, 2026-09-08) |
|---|---|---|
| combined spread | 23.31% | **35.91%** |
| net saving | $12.78/mo | **$21.86/mo** |
| payback | 16 months | **10 months** |
| verdict | `Decent, not instant` | **`good buy`** |

The live page was **understating**, and this estate treats that as exactly as wrong as overstating.

**The DATA block is the generator's own paste-ready output**, not hand-typed arithmetic:
`grocery/build-freezer-data.ps1` re-run against the 22-week history, and
`grocery/out/freezer-data.json` regenerated in the same pass so the artefact and the page cannot
disagree (`weeks=22 stockup=0.1334 bulk=0.2257` on both sides, checked).

**THE FLIP POINT IS COMPUTED PER READER, not stated as a constant.** `flipSpend` is the monthly spend
at which THAT reader's verdict would change, and it renders in the same register as the rest:

> *"At your numbers this is a good buy. Under a year to break even, then it just prints grocery
> savings. **It stays a good buy down to about $96 a month of freezable spending; below that the
> payback stretches past a year.**"*

The `Decent, not instant` band gets the mirror sentence - *it would tip into "good buy" at about $X* -
so the reader is always told how close they are to the line rather than only which side of it they are
on. **That is the whole finding: the verdict flips inside the error bars of three means, so a point
estimate alone was the wrong thing to publish.**

**A SECOND DEFECT THE REFRESH CREATED AND THE LOOK CAUGHT.** The receipts caption is generated, and it
hard-coded the words *"Five weeks is a short window"* - which, beside a freshly-updated *"based on 22
weeks of history so far"*, was a contradiction on a live paid page. It is now conditional on
`DATA.weeks`, and above 12 weeks it says the thing that is actually true and is this item's own second
finding: **a short window UNDERSTATES these spreads, because an item we have not yet caught on sale
looks like an item that never goes on sale.** That defect existed only because the numbers changed,
and it was found by reading the rendered words rather than by checking the arithmetic -
`[[a-measurement-is-not-a-look]]`.

**The item's downward-bias prediction is confirmed exactly: zero stock-up spreads went 3 of 9 to 0 of
9** (sub-0.5%: 4 of 9 to 1 of 9). Every one of the nine freezables has now been seen on sale.

**Verified:** 375px mobile check done and READ, not just measured - **no horizontal scroll**
(`scrollWidth` never exceeded `clientWidth`), the nine-row receipts table fits inside its own
`overflow-x:auto` wrapper without needing to scroll, nothing crushed, and the verdict text was read
off the rendered page at mobile width. Live values read back from the DOM: `10 months`, `$21.86`,
`combined 35.9% (13.3% stock-up + 22.6% bulk)`. `run-gates` exit 0, `pass=277 fail=0`.

**Scope unchanged and still honest:** only this tool was examined. The other nine under `site/tools/`
were NOT audited for the same `quantity x mean` shape, and the absence of findings there is an
absence of looking.

**`[RUNG 1 RAN 2026-09-08 AND THE ANSWER IS NOT MARGINAL.]`** `grocery/build-freezer-data.ps1`
re-run read-only against the current history. **Nothing was written to the page.**

| | live page (`weeks:5`, `updated:'2026-07-10'`) | re-run (**22 weeks**, 2026-09-08) |
|---|---|---|
| stock-up spread | 6.12% | **13.34%** |
| bulk spread | 17.19% | **22.57%** |
| **combined** | **23.31%** | **35.91%** |
| net saving at the page defaults | $12.78/mo | **$21.86/mo** |
| payback | 16 months | **10 months** |
| **verdict a reader sees** | **`Decent, not instant`** | **`good buy`** |

**The flip point, computed rather than asserted:** at the page's defaults ($120/month, a $200
freezer, `SHIFT` 0.60, $4/month electricity) the verdict becomes `good buy` at a combined spread of
**28.70%**. The live page is at 23.31%, below it. The current data is at 35.91%, **well above it.**
So this is not a rounding difference - **the live tool is giving a paying reader the wrong verdict
about a several-hundred-dollar purchase, and it is wrong in the UNDERSTATING direction**, which this
estate treats as exactly as wrong as overstating.

**The item's second defect is confirmed exactly.** It argued that a stock-up spread of `0` over a
five-week window means *we have not seen a sale yet*, not *this item never goes on sale*. **Zero
spreads went from 3 of 9 to 0 of 9** (and sub-0.5% from 4 of 9 to 1 of 9). Every one of the nine
freezables has now been seen on sale. The mean was biased downward for the reason predicted.

**RUNG 2 IS NOT SHIPPED, AND THIS IS A DELIBERATE STOP RATHER THAN AN OMISSION.** Refreshing the
`DATA` block is mechanical - the generator prints the paste-ready constants - but it changes what a
live paid page tells a reader to DO, in the direction of spending $200+. Three things make it Brad's:

1. The verdict flips **inside the error bars of its own inputs**, which is the finding. Shipping the
   refresh WITHOUT the flip-point sentence would make the page newly wrong in the opposite direction -
   a confident `good buy` built on `quantity x mean`, with no range, from a mean over 22 weeks.
2. The flip-point sentence is authored reader-facing copy in Brad's voice, not a regeneration.
3. `[[build-deals-page-clobbers-public-artifacts]]` and the publish path make this a live-site change,
   not a file edit.

**Recommendation: refresh the DATA and add the flip point IN THE SAME CHANGE, never the refresh
alone.** The numbers above are everything that decision needs.

**Scope stated honestly, unchanged from the item:** only this tool was examined. The other nine files
under `site/tools/` were NOT audited for the same `quantity x mean` shape, and the absence of findings
there is an absence of looking.
*Source: Simulation Models for Decision Making (course 18, Gupta), module 3, models 1 versus 2; and
Decision Making (course 17, Nardy), module 3 sensitivity analysis. Routed to
`~/.claude/skills/decision-craft/decide-under-uncertainty.md` 6 and 8.*

`site\tools\freezer-math-tool.html` is a live, reader-facing tool that answers *"should I buy a chest
freezer"*. Its whole arithmetic is one line, 148:

    gross = spend * SHIFT * (DATA.stockup + DATA.bulk)

Three constants, all of them means: `stockup` **0.0612** (mean across nine freezables of the gap
between the mean weekly cheapest price and the record low), `bulk` **0.1719** (mean across the same
nine of the Sam's Club spread against the mean regular-store price), and `SHIFT` **0.60**, a flat
assumption about how much of a reader's buying actually moves. Generated by
`grocery\build-freezer-data.ps1` from `grocery\price-history.json`. The page then reads a **verdict**
off that product - `Skip it`, `good buy`, `Decent, not instant`, `not a slam dunk` - with a payback
month count, a year-1 and a year-5 figure. It states a point estimate and never a range.

**Two defects, and they compound.**

**1. The verdict flips inside the error bars of its own inputs.** At the page's own defaults ($120 a
month, a $200 freezer) net is $12.78/month and the verdict is `Decent, not instant` at 16 months. It
becomes `good buy` at $148 of monthly spend, or equivalently if the combined spread rises from 23.3%
to about 28.7%, or if `SHIFT` rises from 0.60 to about 0.74. **A 23% move in a mean estimated over
five weeks changes what we tell a paying reader to do.** Nardy's rule is that the number to report is
the breaking point, not the estimate.

**2. The mean is biased downward, in the direction we call exactly as wrong as overstating.** Three
of the nine stock-up spreads are exactly `0` (chicken thighs, pork chops, butter) and a fourth is
`0.0030`. A zero there means the record low equals the mean, which over a five-week window means *we
have not seen a sale yet*, not *this item never goes on sale*. Gupta's models 1 and 2 are the general
form: a figure built as `quantity x mean` reads low in the bottom half of the distribution and high in
the top half, and the error lands on the number the decision is made from.

**And the data is stale.** The page is frozen at `weeks:5, updated:'2026-07-10'`.
`grocery\price-history.json` carried **21 weeks** when this was measured on 2026-09-08. The generator
was written to be re-run and its output pasted in; that has not happened in two months.

**Rung 1 is a computation and writes nothing.** Re-run `grocery\build-freezer-data.ps1` against the
21-week history and print, without editing the page: the new blended spreads, how many of the nine
freezables still have a zero stock-up spread, and the spend at which each verdict band flips under
both the old and the new numbers. That says how far the live page is out and whether the verdict a
reader sees today is the one they should see. It is a two-way door.

**Rung 2, only if rung 1 says the page is out**, is the refresh plus one sentence of flip point on
the page beside the verdict, in the same register as the assumptions already listed there.

**What it would touch.** `grocery\build-freezer-data.ps1` (a read at rung 1), then
`site\tools\freezer-math-tool.html`'s `DATA` block and one note. No gate, no engine.

**Scope stated honestly.** Only this tool was examined. The other nine files under `site\tools\` were
not audited for the same `quantity x mean` shape, and the absence of findings there is an absence of
looking.

---

### I65 - every parser here has a previous version one `git show` away, and nothing has ever run old and new over the same input `DONE - RUNG 1 RAN AND RUNG 2 SHIPPED BECAUSE THE RESULT JUSTIFIED IT, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08. The item said a zero sizes it down and a non-zero sizes it up. It is a
non-zero, every difference is accounted for, and the headline is the one nobody could previously
state.]`**

**SUBJECT:** `grocery/build-walmart-deals.ps1` - a pure file-to-file transform with ten commits since
2026-08-21, several touching parse and price behaviour. Old revision `d81391efa` (2026-08-21) against
HEAD, both over the same real capture, `walmart-capture-2026-09-08.csv`, 488 raw rows.

**NOT `sidecar/lib_match.py`'s `clean_product`, which was the item's own first suggestion.** Its
`_UNIT_TAIL` regex and function body are **byte-identical across all three of its revisions**, so a
run there returns a guaranteed zero that proves nothing about the parser and everything about the
choice of subject - a vacuous pass, which is I39's shape. Recorded because the next person will reach
for the same file.

## THE HEADLINE: 0 of 190 price fields moved

`ad_price`, `current_price`, `price`, `per_unit`, `unit_price` - **not one differs on any row both
arms emitted.** Ten commits of parser churn changed no price. **Nobody could make that claim before,
and no `-SelfTest` in the estate could have produced it**, because they prove a detector still fires
on its own frozen fixture and say nothing about the 4,000 real rows nobody froze.

## The full diff, and every part of it is intended

| | HEAD | old |
|---|---|---|
| rows emitted | **193** | **198** |
| in both | 193 | |
| only in old | | **5** |

| field | rows moved | what it is |
|---|---|---|
| `seller` | 193 of 193 | **new field**, old side empty. Additive. |
| `fulfillment` | 191 of 193 | **new field**. Additive. |
| `ad_basis` | 14 of 193 | **prose only** - the explanation string gained *"(the capture's as_of)"*. No semantic change. |
| `qty_basis` | 11 of 193 | **prose only** - gained *"; a pack count in the name explains the multiple"*. |
| `ad_from` / `ad_to` | 6 of 193 | **a real, intended behaviour change** |

**The `ad_from`/`ad_to` change is the rollback TTL being anchored to FIRST DETECTION rather than to
the capture date.** Old: `2026-09-08 -> 2026-10-08` for everything. New: `2026-08-31 -> 2026-09-30`,
and Monster Energy at `2026-08-22 -> 2026-09-21`. The new windows **expire sooner**, so the change
makes the board more conservative about promo prices - the safe direction.

## THE FIVE ROWS HEAD DROPS, AND THIS IS THE PART WORTH READING

They are not a filter tightening on brand or seller. HEAD added a **REFUSED** reject class that did
not exist at the old revision, and it catches rows where **Walmart's own stated unit price
contradicts the pack size in its own product name**:

| row | line price | Walmart's unit price | the contradiction |
|---|---|---|---|
| Great Value Black Beans, 4 lb | $4.98 | **$1.25/oz** | name says 64 oz, Walmart's own arithmetic derives **3.984 oz** |
| Kirkland Signature Chicken Breast, 12.5 Oz, 6 Ct | $24.99 | **$416.50/lb** | derives **0.06 lb** |
| (2 pack) La Preferida Black Beans, 30 oz | $3.50 | 3.5 c/oz | derives **100 oz** |
| GOYA Black Beans, 7.5 oz Bag | $8.00 | 57.1 c/oz | derives **14.011 oz** |
| Bob's Red Mill Yellow Cake Mix 15.5 oz | $5.69 | $5.99/oz | derives **0.95 oz** |

**The old pipeline PUBLISHED all five.** Each would have carried a per-unit price wrong by one to
three orders of magnitude onto a live board. The reject tallies confirm it: old `314 priced, 184
rejected` with no REFUSED class at all; HEAD `307 priced, 189 rejected` including **7x REFUSED**.

**So the oracle's first real run independently verified a fix rather than finding a regression**, and
it did it without anybody authoring a single expected value.

## A SECOND FINDING, from an arm that could not run

Pinning **only the script** and leaving its libraries at HEAD **failed outright**:
`Get-TcWholePurchaseTokens : The term ... is not recognized`. The old `build-walmart-deals` lifts a
**hand-maintained list of function names** out of `compare-deals.ps1`, and against today's
`compare-deals` it lifted a function whose callee did not exist at that revision. That is exactly the
run-time failure `build-walmart-deals.ps1`'s own comment warns about, and it is **I82's coupling
measured from the outside**: a component whose provided interface is its source text cannot be run
against a different version of what it lifts from. Recorded in the tool, which tells you to switch
modes when it happens.

## Rung 2 shipped, because rung 1 justified it

`ops/consistency-oracle.ps1` - takes a script, a commit-ish, an input and an output key, runs both
arms in **their own temp sandboxes** and reports the keyed diff. Sandboxes are not optional: this
subject writes its output, a rejects file **and mutates the rollback ledger**, so running an old
revision in place would have written all three to tracked paths.

**It is NOT a gate and the header says so twice.** Output is MEANT to change when a fix lands; a
consistency check that must be green on every push is a ratchet nobody asked for, red on day one.
Run it deliberately, before a refactor lands.

**A real defect its own fixtures caught before it shipped:** a bare `@{}` in PowerShell is a
**case-insensitive** hashtable, so `"Great Value BLACK BEANS"` and `"Great Value Black Beans"` would
collide into one key and a name that changed **only in case would read as the same row** - the oracle
silently missing the exact class of string change it exists to catch, and the family the estate
already paid for when a norm regex turned "Garlic" into "arlic". Both sides are `StringComparer::Ordinal`
now, pinned by a composite-key clean twin.

**Verified:** self-test exit 0 over 8 cases - led by the must-fire that keeps an emitted-versus-dropped
row APART from a changed value, because folding them together is how a filter change hides inside a
value change. The shipped tool reproduces the founding run exactly (193 / 198 / 5, same field
tallies). `run-gates` exit 0, `pass=279 fail=0`. **Nothing tracked was written by any arm.**

**Scope stated honestly:** ONE parser, ONE input, ONE revision pair. It says nothing about the other
transformation stages, and the item's own caution stands - the oracle is only valid where output is
MEANT to be identical, so it must never be pointed at boards that rebuild daily or at `reanchor`,
which rewrites every spec.

**Source.** `automated-analysis` (University of Minnesota; queue-4 entry 20, raided 2026-09-08),
item 37. Routed to `software-craft/test-design-and-oracles.md` 5.3. Registered as claim C139.

**The idea, and it is one sentence.** Where behaviour is meant to be UNCHANGED, you do not need to
write an oracle, because you already have one: **the previous version of the program**. Run both
over the same inputs and require identical output. The course calls this the *consistency oracle*
and rates it the strongest of the four that scale, precisely because nobody authors it.

**Why this estate in particular, and why it is filed separately from I38.** I38 is blocked on a
ruling about `Get-Random`. **This item involves no randomness at all** and therefore needs no
ruling. Its inputs are files this estate already has on disk: the captures, the boards, the feeds,
the specs. Its second version is whatever `git show` returns. The estate's whole architecture is a
git-bus in which one runtime writes a file another reads, which means every stage boundary is a
pure-ish function with a version history - the exact shape this oracle wants.

**What it would catch that the current suite cannot.** A `-SelfTest` proves a detector still fires
on the one frozen fixture it was written for. It says nothing about whether a refactor changed the
output of the 4,000 real rows nobody froze. The estate has been bitten by exactly this: the price
formatter had five copies, `compare-deals` functions are lifted by three scripts and a lifted
`$script:` constant does not travel, and a norm regex without a word boundary turned "Garlic" into
"arlic". Every one of those is a behaviour change on real input that a fixture suite did not see.

**Rung 1 is a measurement and writes nothing.** Pick ONE parser with a recent commit - the
suggestion is a `grocery/` capture reader or `sidecar/`'s normaliser - check out the previous
revision to a temp path, run both over the same real input directory, and diff the outputs. Report
three numbers: rows processed, rows differing, and whether any difference was intended. **A zero
sizes the item down and a non-zero sizes it up**, and either answer is worth the hour.

**What rung 2 would touch, if rung 1 justifies it.** A small runner that takes a script path, a
commit-ish and an input directory, and reports a diff. **Not a gate.** A consistency check that has
to be green on every push is a ratchet nobody asked for and would be red on day one, which
`.claude/rules/ops-and-gates.md` forbids. It is a thing you run deliberately before a refactor
lands. It must also never write to a tracked path: the old version runs from a temp checkout, per
the estate's own `neuter-numbers-get-predicted-not-measured` rule.

**The honest counter-argument.** The oracle is only valid where output is MEANT to be identical, and
much of this estate is deliberately not: boards rebuild daily, prices move, `reanchor` rewrites every
spec. Scope it to the transformation stages, not to anything that reads live data.

---

### I66 - every static detector in `ops/` is unsound, none of them says so, and their clean reports are written as though they were proofs `DONE - ALL 22 ops DETECTORS STATE WHAT A CLEAN REPORT MEANS, 2026-09-08` `queue-4`

**`[CLOSED 2026-09-08. Rung 1's number is better than the item predicted, and the work was done
anyway.]`**

**Rung 1, the count:** of 22 `ops/audit-*.ps1`, **7 already stated their own scope in their headers**
- `audit-arg-binding`, `audit-fixture-vocabulary`, `audit-run-log-claims`, `audit-source-comment-strip`,
`audit-source-control-bytes`, `audit-threshold-register`, `audit-write-only-reports`. The item expected
the honesty to be a lone exception; it was already a third of them. **15 read as proofs.**

All 15 now carry a `SCOPE OF A CLEAN REPORT:` line, **each written for its own file**. A boilerplate
line repeated fifteen times would have been the thing this estate warns about - a copied disclaimer
teaches a reader to skip it. The lines split three ways, and the split is the useful part:

- **UNSOUND** (a clean report proves nothing beyond a spelling list): `audit-agent-tools`,
  `audit-capture-ingest-reporting`, `audit-fixture-inputs`, `audit-git-sweepers`,
  `audit-mustfire-census`, `audit-ruling-drift`, `audit-twin-drift`, `audit-write-seam`.
- **SOUND OVER A DECLARED UNIVERSE** (clean means everything DECLARED agrees, and an undeclared thing
  cannot be a finding): `audit-cloudflare-estate`, `audit-task-registry`, `audit-stray-root-artifacts`.
- **SOUND ABOUT ONE PROPERTY, SILENT ABOUT ANOTHER**: `audit-memory-backup` and `audit-prompt-backup`
  prove a backup is CURRENT and say nothing about whether its contents are right.

**`audit-backlog-status.ps1`'s own line is the one that earned itself.** It says the check is sound
over the heading LINE and blind to a heading that is not of that shape - *which is not hypothetical*,
because I71 and I72 sat outside the pattern from the day they were filed and were absent from every
board count until this session found them.

**Nothing's logic changed.** It changes what a report CLAIMS, not what it checks, exactly as the item
required. The forward rule is in `.claude/rules/ops-and-gates.md`: a new detector owes that line the
way it owes its `<NAME>-COMPLETE` marker.

**Verified:** `run-gates` exit 0, `pass=276 fail=0`. (An earlier pass of this edit landed the block
mid-sentence in the six files whose title wraps over two lines; that was caught by reading all 15
diffs, reverted with `git checkout`, and redone anchored on the end of the title paragraph.)

**Source.** `automated-analysis` (queue-4 entry 20, raided 2026-09-08), items 3, 28, 31 and 45.
Routed to `software-craft/test-design-and-oracles.md` 5b.

**The distinction the estate is missing a word for.** A static analysis must approximate, because
non-trivial semantic properties are undecidable. The direction of the approximation decides what its
verdicts MEAN. A **sound** (over-approximating) analyser never misses a real defect but raises false
alarms, so a clean report is trustworthy. An **unsound** (under-approximating) one stays quiet, so a
reported defect is real and **a clean report proves nothing**. Most real tools are deliberately
unsound, because an analyser that buries findings under false alarms gets ignored - which is the
same argument this estate already makes about gates that are red on day one.

**Where it bites here.** `ops/run-gates.ps1`'s own header says it runs "the static-analysis
detectors that read source rather than data". Every one of those detectors is a **pattern matcher
over source text**, and therefore unsound by construction: it finds the spellings it knows and is
blind to the same defect written differently. The estate has already been burned by exactly this and
has a memory about it - `a-negative-search-result-must-prove-itself`. One detector already states
its own unsoundness: `ops/audit-fixture-vocabulary.ps1` line 31 says it "stops the shape a new
author actually writes, and it does not pretend to have swept the estate" (verified verbatim
2026-09-08). **That honesty is the exception, not the pattern**, and rung 1 is to find out how far
the exception extends.

**Why it is worth an item rather than a shrug.** A clean report from an unsound detector is evidence
about a spelling list. Read as a proof, it closes a question that is still open, and the estate's
whole verification story rests on those reports. This is not a defect in any detector; it is a
defect in how their output is worded and therefore read.

**Rung 1, and it is small.** For each static detector in `ops/`, decide in one line whether its
clean verdict means "this class of defect is absent" or "none of the patterns I carry matched", and
put that line in the detector's header beside the `<NAME>-COMPLETE` convention. The output of rung 1
is a count: how many detectors already state their scope, and how many read as proofs.

**What it must not become.** Not a new gate, not a schema, and not a rewrite of any detector's
logic. **It changes what a report claims, not what it checks.**

---

### I67 - the backlink plan is refuted a second time on a new axis, and the one instrument this estate could actually use has never been read `OPEN - RUNG 1 IS A READ, NOT A BUILD` `queue-4` `2-WAY` `RUNG1 BLOCKED`

**Source.** `seo-fundamentals` module 2 (UC Davis; queue-4 entry 21, raided 2026-09-08). Routed to
`growth-craft/search-position-diagnosis.md` 4. Registered as claims C141 to C143.

**What is new.** `docs/seo-backlink-plan.md` is already marked `[REFUTED: 2026-08-31]` because its
premise was wrong and it still targets the site's former domain. It is now wrong a second way, on an
axis that would survive fixing the domain: **links are scored by the traffic they actually carry**
(C141), so a plan whose target is a COUNT of acquired links is aimed at the wrong quantity. A link
nobody clicks is worth close to nothing. The plan cannot be repaired by updating its URLs.

**The honest scoping, and it is most of this item's value.** The off-page material splits about
evenly into work a one-person site can do and work it cannot, and pretending otherwise is how an SEO
plan becomes a list nobody executes. **Agency-scale, and the right answer is to decline:** digital
PR, journalist relationships, editorial-calendar targeting, guest blogging at volume, syndication,
and competitor backlink analysis behind a paid tool. **Executable alone:** reading brand queries in
Search Console, a Google Alert on the brand name, reclaiming broken links that already pointed here,
and converting unlinked brand mentions into links one email at a time.

**Rung 1 is a read and it writes nothing.** In Search Console, sort queries for brand terms and
answer one question: **is anyone searching for this brand at all, and with what wording?** The
2026-08-31 baseline is 1,331 indexed pages drawing 3 web-search clicks in 28 days at average
position 50.1, and a brand-query read has never been taken. It says whether there is any brand
signal to build on or whether the honest answer is that off-page work is premature and the
constrained layer is still crawl and content.

**What rung 2 would touch, if rung 1 justifies it.** Retire or rewrite `docs/seo-backlink-plan.md`
so it stops standing as a refuted plan, replacing it with the reclamation shortlist. No engine, no
gate, no page change.

**The prohibition, stated so it is not re-derived.** Buying links or using a brokerage is
manipulation, link velocity and index-tier scoring exist to catch it, and the downside lands on a
live paid site. Not a trade worth making at any price.

---

### I68 - the ad period is known, written down in seven places, and used by nothing that looks at a price `PARKED - MEASURED AGAINST A BAR SET BEFORE THE RUN; THE WEEKDAY COMPONENT IS NOT THERE` `queue-5`

**`[CLOSED PARKED 2026-09-08. The item said 'if it does not, this item closes'. It does not.]`**

**The bar was written before the run** (E21, in the metric's own units): a check shows a day-of-week
component if pooling its runs by weekday removes at least 20% of its spread (pooled within-weekday sd
<= 0.80 x overall sd); a check is TESTABLE only with >= 14 runs over >= 4 weekdays, three of them
carrying more than one run; and **the item is supported only if a MAJORITY of testable checks show
it.**

**`examined` is a DICT of per-check counts, not a scalar** - `guards/10-store-charges` runs ~29,542
while `guards/6-collapse` runs ~6 - so summing them would have answered a question about the biggest
check and called it an answer about the estate. The test runs **per check**.

**Measured over `grocery/out/coverage-ledger-history.jsonl`: 582 runs, 39 distinct dates,
2026-08-01 to 2026-09-08, 16 checks, all 16 testable, none excluded.**

**2 of 16 (12%) clear the bar.** Against a majority. And both are weak on inspection:
`guards/6-collapse` has an overall sd of **0.2** on a value of about 6, so its 0.633 ratio is noise
about a near-constant; `build-rescue-worklist` is **0.794** against a bar of 0.800. The other fourteen
sit between 0.805 and 0.940 - i.e. pooling by weekday removes 6% to 20% of the spread, which is what
random grouping of 39 dates into 7 buckets does anyway.

**VERDICT: NOT SUPPORTED.** Claim C148 - that `grocery/analyse_coverage_tolerances.py` is averaging a
removable weekly effect into its 15-run rolling p95 - was *a prediction with a mechanism*, and this is
the measurement that does not back it. **The tolerance work in I13 is unaffected**, which the item
said would be the consequence.

**THE ONE RESULT THAT STANDS WHATEVER THE VERDICT, and it is kept:** a multiplicative seasonal
structure puts real autocorrelation at lags `s-1` and `s+1`, not only at `s` (C149, derived rather
than asserted). On a 7-day cycle that is Sunday and Tuesday for a Monday rule. **Any comparison this
estate ever writes that pins itself to "the same day last week" must look at the neighbouring days
too**, or it will read a genuinely seasonal series as clean. That is a rule about a check nobody has
written yet, so it is recorded here rather than in a file it does not apply to.

**Also unchanged, and it was the item's other half:** `grocery/check-ad-cycles.ps1` detects no cycle -
it reads each store's declared window and schedules the next pull. The period is a hand-written
`cadence_days`. Nothing here proposes deriving it; see I69, which closes that question separately.

**Source.** `practical-time-series-analysis` (SUNY Poly, Sadigov and Thistleton; queue-5 entry 1,
worked 2026-09-08). Routed to `data-quality-craft/modelling-a-time-series.md`, with the estate half in
that domain's `applies-here.md`. Registered as claims C146 to C149.

**What is new, and it is a correction to how we describe our own code.** `grocery/check-ad-cycles.ps1`
gets called the cycle detector. It detects no cycle. It reads each store's declared ad window out of
that store's own feed and schedules the next pull for the day after the window expires. The period
itself is a hand-written constant: `cadence_days` in `grocery/ad-schedule.json`, `7` for Hy-Vee,
Aldi, Family Fare, Baker's and Fareway and `null` for Sam's Club and Walmart. It is read by
`grocery/audit-ad-status.ps1`, `grocery/capture-policy-lib.ps1` line 171, `graph/import/importers.py`
and `graph/agentic/verifier.py`, and **every one of those reads it as a schedule. None tests it
against a price.**

**Why that is worth an item.** Knowing the period is the expensive half of seasonal modelling and we
have it for free. What a schedule cannot do is say what a number *should* be. A seasonal expectation
can, at every slot, with an interval, which is the only form a check can subtract. Today every price
band treats the weekly structure as noise, which is `data-quality-craft/detecting-anomalies.md` 4
arriving on our own board.

**Rung 1 is a read of data already on disk and it writes nothing.**
`grocery/out/coverage-ledger-history.jsonl` has carried one dated line per run since 2026-08-01.
Group the `examined` counts by weekday and compare the within-weekday spread to the overall spread.
That answers one question: **does this estate's daily history actually carry a day-of-week
component, or does it not?** If it does not, this item closes and the tolerance work in I13 is
unaffected. If it does, `grocery/analyse_coverage_tolerances.py` is currently averaging that
structure into its 15-run rolling reference rather than removing it, and its p95 is inflated by a
known, removable effect. **This is claim C148 and it is a prediction with a mechanism, not a
finding.** Nobody has looked.

**The one result that should change a check whatever rung 1 says.** A multiplicative seasonal
structure puts real autocorrelation at lags `s - 1` and `s + 1`, not only at `s` - derived, not
asserted (C149). On a 7-day cycle that is Sunday and Tuesday for a Monday rule. So **any comparison
we ever write that pins itself to "the same day last week" must look at the neighbouring days too**,
or it will read a genuinely seasonal series as clean.

**What it must not become.** Not a forecasting engine, and not a new gate. Nothing here should ship
a predicted price to a reader: the course produces 80% and 95% intervals for every forecast and
**never scores one against held-back data anywhere in its 118 items** (`RMSE`, `MAPE`, `backtest`,
`cross-validation` and `held-out` all count zero across its 375,521 characters of transcript). A
forecast with no out-of-sample error estimate is a fabricated number, which the project's standing
rules already forbid. If a fitted expectation is ever used here it is used to judge an observation
we already have, never to publish one we do not.
### I69 - the only forecast this estate makes has its answer stored next to it and has never been scored `DONE - THE SCORER SHIPPED AND THE CADENCE HALF IS CLOSED BY MEASUREMENT, NOT LEFT OPEN` `queue-5`

**`[CLOSED 2026-09-08.]`** The scorer half shipped as `grocery/audit-ad-forecast.ps1` under an
inverted ratchet with twelve frozen fixtures. **The cadence half is closed too, and it is closed by
the queue-6 read already recorded in this item rather than by new work:**

- **Three time-series courses in, neither the store nor any of them holds a period-DISCOVERY method.**
  Prophet's seasonality periods are the calendar ones and its `'auto'` decides only whether to
  *enable* a period, never what the period is; SARIMA's `s` is declared the same way. A periodogram
  and an ACF peak scan are clean no-matches store-wide.
- **The cadence you may infer must be coarser than your observation interval**, so 9 to 12 history
  pairs per store can support "7, or not 7" and nothing finer - which is exactly what
  `audit-ad-forecast.ps1` already tests.
- **The forward rule stands and is the disposition:** `cadence_days` is a hard-coded constant under a
  `no-hardcoded-bands` estate, and its exemption is that the audit FAILS when observation contradicts
  it. Keep that check. **Do not replace the constant with a fitted one until something can score
  both** - and I70 has now built the arm that would do the scoring.

So nothing is proposed and nothing is blocked: `DONE` rather than `PARTLY DONE`, because the state
records what is left and the answer is nothing.

**And I70 changed what this item's own headline means.** I69 reported 37 of 47 exact. I70 added the
naive baseline through the same scorer and it scores **40 of 48** against the live rule's **37 of
48** - so the `to`+1 rule is LOSING to a plain calendar, entirely at Fareway. That does not reopen
this item; it is why I70 existed.

**SHIPPED, same day.** `grocery/audit-ad-forecast.ps1` scores the prediction against the outcome and
runs as watchdog check 5a. It is an INVERTED ratchet: a full-cycle miss is history and can never
legitimately fall, so the count may only stay the same and any rise is a newly skipped cycle, failing
the day it is detected. The two misses on record are the baseline and are silent, which is how the
check exists without being red on day one. `-AcceptMiss` acknowledges a new one after the cause is
dealt with, dated in the baseline file, because without it the gate would have been permanently red
for something nobody can undo. Twelve frozen fixtures ship as its self-test.

**Deliberately NOT built:** a second staleness alarm. `audit-ad-status.ps1` already owns that
question, exits 1 on a closed ad, runs in the same watchdog, and was green on all seven stores.

**What remains open** is the cadence half: `cadence_days` is a hand-set 7 for every store and the
audit now flags an observed cadence that contradicts it, but nothing yet DERIVES the constant from
history. Hy-Vee predicting consistently early (bias -0.29) is the case that would benefit.

**`[CHECKED 2026-09-08 against queue-6 group A entry 1, the Prophet course, which was queued partly
for this. It does NOT close the cadence half, and it says why.]`** Prophet's seasonality periods are
the **calendar** ones - 7 for weekly, 365.25 for yearly - and its `'auto'` setting decides only
whether to *enable* a period, never what the period is. SARIMA's `s` is declared the same way. **Three
time-series courses in, neither the store nor any of them holds a period-DISCOVERY method**; the
honest candidates, a periodogram or an ACF peak scan, are clean no-matches store-wide. **Stop queueing
forecasting courses against this half.** Two things the course does give it: the reframing that a
skipped cycle is a **dated changepoint** rather than a permanently wrong constant, which is what Aldi
and Baker's actually did; and the constraint that **the cadence you may infer must be coarser than
your observation interval**, so 9 to 12 history pairs per store can support "7, or not 7" and nothing
finer - which is exactly what `audit-ad-forecast.ps1` already tests. **The forward rule: `cadence_days`
is a hard-coded constant living under a no-hard-coded-bands estate, and its exemption is that the
audit fails when observation contradicts it. Keep that check; do not replace the constant with a
fitted one until something can score both.** The other half of I69 - the missing baseline - is now
**I70**.

**Source.** `demand-prediction-using-time-series` (LearnQuest; queue-5 entry 2, worked 2026-09-08).
Routed to `data-quality-craft/modelling-a-time-series.md` sections 3a, 7a and 7b, with the estate half
in that domain's `applies-here.md`. Registered as claims C155 to C157. Sibling of I68, which is about
the period; this one is about whether anything we predict is ever checked.

**What is new.** `grocery/ad-schedule.json` writes `next_pull` = the current window's `to` plus one
day. That is a **dated prediction of when the next ad drops, recorded before the event**. The next
`history` entry's `from` is the **observed answer**, read out of the store's own feed. Prediction and
outcome have been sitting in the same file, one line apart, since 2026-06-29. **Nothing reads them
together.** `history` under `grocery/*.ps1` resolves only to appends; `backtest` in first-party code
returns two files and both are the identity matcher; `out.of.sample`, `walk.forward`,
`rolling.origin` and `one.step.ahead` return nothing.

**Scored during the course run, read-only, nothing written.** Differencing `history[i].to + 1` against
`history[i+1].from` over every consecutive pair: **47 paired cases across the 5 stores that have an ad
cycle** (Sam's and Walmart carry `cadence_days: null` and are excluded rather than scored zero).
**37 of 47 exact (79%), MAE 0.47 days, bias +0.30.**

| store | pairs | exact | MAE | range |
|---|---|---|---|---|
| Family Fare | 9 | 9 of 9 (100%) | 0.00 d | 0..0 |
| Aldi | 8 | 7 of 8 (88%) | 0.88 d | 0..**+7** |
| Baker's | 8 | 7 of 8 (88%) | 0.88 d | 0..**+7** |
| Hy-Vee | 14 | 10 of 14 (71%) | 0.29 d | **-1**..0 |
| Fareway | 8 | 4 of 8 (50%) | 0.50 d | 0..+1 |

**Why that is worth an item, and it is not the headline number.** The errors are two populations. Two
cases are a **full +7 days** - Aldi and Baker's each skipped an entire cycle, which on a weekly ad is
a total miss, and an MAE of 0.47 hides both inside a reassuring decimal. **Fareway is the worst store
at 50% exact while every one of its errors is small**, which is the opposite defect and is equally
invisible. Hy-Vee is the only store that predicts **early** (bias -0.29), i.e. it schedules a pull for
a drop that has not happened. Three different failure modes, one summary statistic, none of them
surfaced anywhere today.

**And the misses are not even logged as misses.** `check-ad-cycles.ps1`'s header documents an
`AWAITING` state for "past its `to` but not reposted" - a forecast miss, in flight. The string
`AWAITING` appears **0 times in the 6,346 lines of `grocery/ad-cycle-log.txt`**. Either the state is
never reached under the wording the log uses, or it is reached and not written; both are worth one
grep before anyone builds on the log.

**Rung 1 is a read of data already on disk and it writes nothing.** Re-run the pairing above on a
schedule and print `exact / pairs` plus the count of full-cycle misses per store. That answers one
question: **is the ad schedule drifting, and at which store?** A store whose exact rate falls is a
store whose feed or cadence changed, which today is only noticed when a board cell goes stale.

**The rule it sets whatever rung 1 says, and this one is cheap and general.** *Any* prediction this
estate writes down gets its outcome written beside it, in the same record, at the moment the outcome
is known - and a date prediction is scored as **fraction exact plus count of full-cycle misses**,
never as a mean error alone. `ad-schedule.json` got the first half right by accident and that accident
is the only reason a score existed at all.

**What it must not become.** Not a forecasting engine and not a new gate. I68's constraint stands
unchanged: nothing here ships a predicted number to a reader. This item only asks that a prediction we
already make gets marked against the answer we already store.

### I70 - the ad forecast is scored and never baselined, so 37 of 47 is not yet a verdict `DONE - THE BASELINE SHIPPED AND IT BEATS THE LIVE RULE, 2026-09-08` `queue-6`

**`[CLOSED 2026-09-08, and the answer is the one the item said was possible and did not expect.]`**

`grocery/audit-ad-forecast.ps1` now scores the naive predictor - *the next ad drops `cadence_days`
after the last one DID* - beside the live rule, through the same `Get-ForecastScore` function, over
the same pairs. One column changes; nothing else can drift.

**Measured live, 2026-09-08, exit 0, `AD-FORECAST-COMPLETE pairs=48 exact=37 full=2 baseline=2`:**

| arm | exact |
|---|---|
| live (`to` + 1 day) | **37 of 48** |
| naive (`from` + `cadence_days`) | **40 of 48** |

**The live rule is not beating a plain calendar. It is losing to one.** The item named that as one of
two possible outcomes and called it *"a real finding about five stores' feeds, not a defect"* - it is
sharper than that, because the whole difference is **one store**: Fareway scores **4 of 8** live
against **7 of 8** naive, and every other store's two arms are identical. So the estate's headline
"37 of 47" was never evidence that the close-plus-one rule buys anything; on the one store where the
two rules disagree, it is the worse of the two. The report says so in its own output rather than
leaving the reader to compare two numbers.

(The denominator is **48**, not the 47 the item quotes. History gained a pair since it was filed.
Said rather than quietly corrected, because a freshly-dated wrong number reads as verified - I88's
finding.)

**What this does NOT do, on purpose.** It adds a reported figure, not a failure condition. The
inverted ratchet, the exit codes and the `-AcceptMiss` path are untouched, so it cannot turn the
check red on day one. And it does not change `cadence_days`: that is I69's cadence half, which is
closed separately and explicitly says not to replace the constant with a fitted one.

**Verified:** self-test 17 of 17 (up from 12), including a must-fire that the report SAYS SO when the
arms tie or the live rule loses, and a must-not-fire that an empty error list scores 0 of 0 rather
than 1 of 1. `run-gates` exit 0, `pass=276 fail=0`.

**The general rule this sets stands and is not yet applied elsewhere:** any estate number of the form
"N of M correct" should ship with the same N of M for the dumbest predictor that could have produced
it, through the same code path. `grocery/audit-alert-precision.ps1` and the matcher scorers are the
named candidates and **neither was checked on this run.**

**Source.** `packt-time-series-forecasting-with-facebook-prophet-in-python-7sw5w` (Packt, "the Lazy
Programmer"; queue-6 group A entry 1, worked 2026-09-08). Routed to
`data-quality-craft/modelling-a-time-series.md` sections 9 and 10, with the estate half in that
domain's `applies-here.md`. Registered as claims C158 to C161. Direct sibling of I69, which shipped
the scorer this item proposes to complete.

**What is new.** The course's opening argument is that **an error number with no baseline beside it
means nothing**, and its worked demonstration is the naive forecast - copy the last known value
forward. It reports (uncounted, `[SINGLE-SOURCED]`) that every popular LSTM stock-prediction course
and blog fails to beat it, and gives the checkable mechanism: they scored in sample. The theorem
underneath is the part that transfers - on a random walk the naive forecast is **provably optimal**,
so "we beat the naive forecast out of sample" is the only claim a forecaster can make that is worth
anything.

**Where the estate stands.** `grocery/audit-ad-forecast.ps1` shipped 2026-09-08 under I69 and scores
`ad-schedule.json`'s `next_pull` against the following `history[].from`: **37 of 47 exact, MAE 0.47
days, bias +0.30**, two full-cycle misses counted separately under an inverted ratchet against
`grocery/ad-forecast-baseline.json`. Counting the full-cycle misses apart from the mean is better
practice than the course teaches and should not change.

**What is missing is one number.** Nothing says what the trivial predictor scores on the same 47
pairs. The naive predictor here is exact, free, and already in the file: **"the next ad drops
`cadence_days` after the last one did"**, derived from `history[i].from` rather than from
`history[i].to` plus one day. Two outcomes and both are worth having:

- it also scores about 37 of 47, and the current `to + 1` rule is buying **nothing** over a plain
  calendar - which would be a real finding about five stores' feeds, not a defect;
- it scores worse, and the 37 is finally a verdict rather than a number.

**How, in one block.** The course's method is worth copying exactly: build the baseline as a **copy
of the scored frame with the prediction column replaced**, so both arms run through the identical
scoring code and cannot differ by accident. Same loop, same exact/MAE/bias/full-miss logic, one extra
column in the report and in `-Json`.

**What it would touch.** `grocery/audit-ad-forecast.ps1` only - a read-only script. No schema change,
no new file, no new gate. The ratchet and the exit codes are untouched: this adds a reported figure,
it does not add a failure condition, so it **cannot turn the check red on day one**. Its twelve
frozen fixtures need one more assertion each.

**Deliberately NOT proposed:** replacing `cadence_days` with a fitted period. See I69's cadence half,
which this course does not close and which the note below explains it cannot.

**The general rule this sets, and it is bigger than this script.** Any estate number of the form
"N of M correct" should ship with the same N of M for the dumbest predictor that could have produced
it, through the same code path. `grocery/audit-alert-precision.ps1` and the matcher scorers are the
other candidates; nobody has checked whether they carry a baseline.

---

### I71 - per-store pacing is a static constant, and a closed loop on observed latency has never been costed `PARKED - MEASURED 2026-09-08: THE WALLS ARE NOT A RENDERING PROBLEM AND THE COST IS PACING, SO ADAPTIVE RATE CONTROL IS THE WRONG LEVER` `queue-6`

**`[CLOSED PARKED 2026-09-08. The item said: 'if the estate's walls are quota walls rather than load
walls, this item should be closed as WONTFIX rather than built. The measurement that settles it is
cheap and does not exist.' It exists now.]`**

This was run as the split-out I72 asked for - *is any of the four browser-required stores
browser-required only because nobody has looked at its Network tab?* - and it answered I71 on the
way, because both rest on the same premise.

## 1. The Instacart stores are genuinely client-rendered. Nobody missed an endpoint.

Measured live in a browser on the Aldi/Instacart storefront, running **the exact same-origin fetch
and the exact regex `pull-aldi-instore.js` and `pull-fareway-instore.js` use**:

| | |
|---|---|
| HTTP | **200** |
| response | **498,331 bytes** in 1,356 ms |
| `"priceString"` | **0** |
| `"viewSection"` | **0** |
| `__NEXT_DATA__` | **0** |
| `__APOLLO_STATE__` | **0** |
| rows the agents' regex matches | **0** |

That is a half-megabyte shell with **no product JSON in it at all** - and it extends to **Aldi** the
condition `pull-fareway-instore.js` already documents for Fareway. So the browser is not there out of
habit or ignorance; the storefront genuinely does not ship the catalog in its HTML.

## 2. There IS a JSON API, and it is not the free win the item hoped for

Instacart is a **GraphQL app using PERSISTED QUERIES**: every data call is
`GET /graphql?operationName=<Op>&variables=<json>&extensions={"persistedQuery":{"version":1,"sha256Hash":"<hash>"}}`.
The live parameters were captured (`retailerId` 12 = Aldi, `retailerSlug` aldi, `shopId` 43147,
`postalCode` 68144, `zoneId` 917).

**Using it means pinning an operation name AND a sha256 hash per query, both of which the vendor
rotates on deploy.** That is a standing maintenance cost against a shape that breaks silently - the
exact class this estate keeps paying for - traded for a page fetch that already works. **Not
recommended**, and the reason is now written down rather than left to be re-litigated.

## 3. WALMART WAS NEVER A RENDERING PROBLEM, AND THE 75 MINUTES IS PACING

`pull-walmart-instore.js` fetches `/search?q=<term>` and parses `<script id="__NEXT_DATA__">` out of
the response. **It has always been an API pull wearing a browser.** The browser is there for
`credentials: 'include'` - the session - not for rendering.

So what costs 75 minutes? `stores.json` -> Walmart -> `pull_profile`: **`delay_ms` 3500, `jitter_ms`
2000**, a mean of **4.5 s of deliberate waiting per term**:

| terms | pacing alone |
|---|---|
| 100 | 7.5 min |
| 300 | 22.5 min |
| **596** | **44.7 min** |

**Roughly 45 of the ~75 minutes is the estate choosing to wait.** No JSON endpoint can retire that,
because it is not request time. **This is the item's own honest counter-argument, confirmed:**
`claude-api-craft/rate-limits-retries-and-cost.md` 11 already concluded that under a quota the fix is
**fewer requests per window - shard the term list across the day - not slower requests.** AutoThrottle
is a rate controller, not a quota controller. **So: WONTFIX, as the item itself prescribed.**

## 4. THE FINDING THAT IS WORTH MORE THAN THE ITEM WAS, and it is in the config's own words

Walmart's `pull_profile.evidence` reads:

> *"2026-08-15: hit a Robot or human? wall during the weekly refresh. **THE RATE THAT TRIGGERED IT WAS
> NEVER RECORDED** - the sweep was an ad-hoc snippet with no instrumentation, so there is no
> before-number to compare against."*

**So the most expensive constant in the estate - 45 minutes a pull - was set from a trigger rate
nobody measured.** That is `I94`'s rule (a tuning constant records what else was tried) landing on the
single place it costs the most.

**And the estate already knows how to do better, at another store.** Sam's Club's evidence is
*measured*: two full 388-term sweeps back to back at 2600+/-1400 ms with **zero walls**,
`observedMeanIntervalMs` 5430 and 5198, `timing.verdict CLEAN` both times. Sam's records its observed
interval. **Walmart does not.** Fareway is explicit that a 144-term sweep saw no wall but that
*never-observed is not measured-safe*.

**THE ONE THING WORTH DOING, and it is not this item:** give the Walmart sweep the instrumentation
Sam's already has - record the observed interval and the per-request latency - so the next wall has a
before-number. Until then nobody can say whether 3500 ms is twice what is needed or half.

**Scope stated honestly.** Sam's Club and Walmart were NOT probed live in this session: Sam's is
CAPTCHA-walled and Walmart bot-walls a fresh browser, and driving Brad's own Chrome is the 09:00
agent's job, not this session's. Their halves rest on reading `pull-walmart-instore.js`,
`pull-sams-instore.js` and `stores.json`, which is enough for the rendering question and for the
arithmetic, and is not enough to claim anything about their live wall behaviour today.

*[ID ALLOCATED 2026-09-08 by `ops/merge-backlog-inbox.ps1`'s allocator, which is now the only writer of this file's ids. It was I-WS1, an explicitly unallocated placeholder, because four course agents ran concurrently and the I-series had no lock. HEADING REWRITTEN 2026-09-08 to the `### <ID> - <title>` shape: as filed it matched neither the id nor the state pattern, so `ops/audit-backlog-status.ps1` skipped it as prose and this item was absent from every board count taken since.]*

**OPEN.** Source: `packt-web-scraping-tutorial-with-scrapy-and-python-for-beginners-0edsw` (Packt,
Coursera), worked 2026-09-08.

**Per-store pacing here is a static constant. The alternative is a closed loop on observed latency,
and nobody has costed it.**

`grocery/stores.json` carries a fixed `delay_ms` per store: three stores at `null`, two at 900, one
at 2600, one at 3500. `grocery/audit-pull-profiles.ps1` gates those numbers well: a pacing number
with no `evidence` string fails, a server-fed store with no pacing is a legal input, and the header
records that the 207-of-595 throttle incident happened because "the pacing that would have prevented
it existed nowhere, not in a file, not in a script, only in whatever number was typed that day."
That is a genuinely good design and this item does not propose weakening it.

What it is not is adaptive. Scrapy's AutoThrottle extension (module 17 of this course) is a
**feedback controller**: it measures the server's own response latency per request and treats a
rising latency as evidence the server is loaded, then lengthens the delay; when latency falls it
shortens it again. Its knobs are a start delay (5s default), a max delay (60s), a target concurrency
and a debug flag, and it ships **disabled by default**. The mechanism, not the Scrapy
implementation, is the finding: **the server tells you how hard you are allowed to push, and the
signal is free because you are already timing the request.**

**Why it matters here specifically.** A static 3500 ms is simultaneously too slow on a quiet morning
and too fast on the day the store's own infrastructure is struggling, and only the second case
produces a bot wall. The estate has recorded bot-wall incidents and a documented case
(`design/PLAN-use-the-cores-2-2026-08-23.md`) of a fresh headless profile with no pacing walling a
store. One store's pull already takes about 75 minutes, so a controller that speeds up when the
server is healthy has real upside as well as the safety downside.

**What it would touch.** `grocery/stores.json` (a new optional `pacing_mode` beside `delay_ms`,
defaulting to the current static behaviour), the per-store pull scripts that currently sleep a
constant, and `grocery/audit-pull-profiles.ps1`, whose evidence rule would need to say what evidence
an adaptive profile owes. Nothing about this makes an existing check red on day one: an adaptive
profile is opt-in per store and the static path stays the default.

**The honest counter-argument, which should be settled before building.** `claude-api-craft/rate-limits-retries-and-cost.md`
section 11 already records this estate's own measured conclusion that under a hard per-window quota
the fix is **fewer requests per window (shard the term list across the day), not slower requests**,
and that a "3 retries + backoff" Family Fare pull once ran ~45 minutes under a throttle and returned
a partial catalogue. AutoThrottle is a rate controller, not a quota controller, so it addresses the
politeness/overload case and does **nothing** for the quota case. If the estate's walls are quota
walls rather than load walls, this item should be closed as WONTFIX rather than built. **The
measurement that settles it is cheap and does not exist:** record the observed per-request latency
alongside each pull and check whether latency rises before a wall. If it does not, close this.

---

### I72 - a 200 with a correct selector and zero rows has four causes, and the estate's vocabulary names two `DONE - `unrendered` AND `unsettled` ARE NAMED WHERE THE VERDICT IS MADE, 2026-09-08` `queue-6`

**`[CLOSED 2026-09-08. Rung 1 - the vocabulary - which the item says is the whole of the cheap
half.]`**

The two missing causes are now named in both places a capture verdict is actually reached:
`.claude/rules/grocery.md` and `.claude/agents/recipe-hunter-pricer.md`, immediately after the
standing *UNCHECKED IS NEVER NOT-CARRIED* block, with the rule that **both are PENDING, never
`not-carried`** - you did not look, the page did.

- **`unrendered`** - 200, markup present, selector right, content injected by JavaScript nothing
  executed. It reads as a selector bug and attracts a selector fix, which can never work.
- **`unsettled`** - the element exists but was still filling. **This is the worse one: it returns a
  PARTIAL result rather than an empty one, so it looks like a success.** Not hypothetical -
  `[[fareway-capture-defects]]`'s repeated exact 9 is this shape, diagnosed by hand after the fact.

**The mechanism shipped with the vocabulary, because the vocabulary alone would not have changed a
single capture:** after a scroll, WAIT ON A COUNT-BASED SELECTOR - an element that can only exist if
the scroll produced more rows. The assertion that the load worked is built INTO the wait rather than
bolted on after, and a fixed `Start-Sleep` can never do it: a sleep cannot tell *the page finished and
there were only 10* from *page 2 never loaded*.

Backed by `[[empty-result-has-four-causes-not-two]]`, indexed in `MEMORY.md`, so it reaches sessions
that load neither file.

**SPLIT OUT AND NOT DONE, exactly as the item asked**: whether any of the four browser-required
stores is browser-required only because nobody has opened its Network tab. Three of seven feeds are
already server-side JSON. That check is about an hour per store and **could retire the 75-minute
Walmart pull**, which makes it the highest-value unstarted read in this whole backlog. It is recorded
in the rules file and in the memory; it has NOT been opened as its own id, because nobody has
confirmed it is worth an id and the pointer is where a session would look.

**Verified:** `run-gates` exit 0, `pass=276 fail=0`, after refreshing `ops/prompt-backup` -
`audit-prompt-backup` correctly went red on the edited agent prompt, which is the gate working.

*[ID ALLOCATED 2026-09-08, was I-WS2. HEADING REWRITTEN 2026-09-08 for the same reason as I71: it was invisible to the audit.]*

**OPEN.** Same source course, worked 2026-09-08.

**A 200 with a correct selector and zero rows has three causes, and the estate's vocabulary names
only two of them.**

The estate is already strong here by comparison with the course. `blocked` versus `not-carried` is a
first-class distinction enforced in `.claude/agents/recipe-hunter-pricer.md` ("UNCHECKED IS NEVER
NOT-CARRIED"; a bot wall, timeout, wrong-store session or unreached store leaves the ingredient
PENDING), and the memory `a-could-not-look-must-not-settle-the-question` holds the rule. This item
does not propose changing any of that.

The gap is a **third** cause the course names and the estate's vocabulary does not: the page returned
HTTP 200, the markup is genuinely present and correct, the selector is genuinely right, and the rows
are still absent **because the content is injected by JavaScript that nothing executed**. Module 14
item 68 is the worked case: a correct CSS selector returns nothing against a 200 response, and the
diagnostic is that the data is sitting inside a `<script>` block waiting for a browser. A second
shape in module 15 item 77: the element is present but **empty**, because it is populated after a
loading screen the scraper did not wait for.

So the honest taxonomy for an empty result is four-way, not three-way:

1. **blocked** - a wall, a CAPTCHA, a challenge page. Already named.
2. **genuinely absent** - the store does not carry it. Already named (`not-carried`).
3. **unrendered** - 200, right selector, JS never ran. **Not named.**
4. **unsettled** - the element exists but was still filling. **Not named**, and this is the one that
   produces a *partial* result rather than an empty one, which is worse because it looks like a
   success.

Cause 4 is not hypothetical here: `fareway-capture-defects` records that a repeated exact 9 means
unscrolled lazy-load, which is exactly this shape, and it was diagnosed by hand after the fact.

**The mechanism the course supplies, and it is the useful half.** For an infinite-scroll page, do
not sleep and hope. Issue the scroll, then **wait on a count-based selector** for an element that can
only exist if the scroll actually produced more rows: the course uses
`div.quote:nth-child(11)` when a page starts with 10. If the eleventh never appears the wait fails
loudly, instead of the scrape quietly returning the first 10. **The assertion that the load worked is
built into the wait condition rather than bolted on afterwards**, and that is the whole idea. A fixed
`Start-Sleep` cannot do this: it cannot tell "the page finished and there were only 10" from "the
page never loaded page 2".

**What it would touch.** The browser-driven captures (the four stores that need a real Chrome), which
would gain a per-store "expected next element" wait predicate instead of, or in front of, a fixed
sleep. And an `unrendered` disposition beside `blocked` and `not-carried`, so that the wrong repair
is not applied: a 200-with-no-rows currently reads as a selector bug and gets a selector fix, when
the actual repair is to render the page or to find the underlying JSON call.

**The cheaper repair the course also supplies, and it may make half of this moot.** Module 16: open
the browser Network tab, filter to Fetch/XHR, and read the URL the page's own JavaScript calls. That
call usually returns the data as JSON directly, with no browser needed. The course measures the same
data at **about 9 seconds via the API call against about 19 seconds through a rendered browser** on
its example. Three of the seven feeds here are already server-side JSON; the open question nobody has
written down is **whether any of the four browser-required stores is browser-required only because
nobody has looked at its Network tab**. That check costs one person one hour per store and could
retire the 75-minute pull. It should be an item in its own right if this one is split.


### I73 - the identity graph has 205 nodes joined to nothing and seven two-node islands, and no check looks `DONE - THE FIRST GRAPH CHECK EXISTS AND IT IS A RATCHET, 2026-09-09` `queue-6`

**`[CLOSED 2026-09-09.]`** `graph/audit_graph_shape.py` answers I73, I75 and I76 in one read-only
pass over `graph.db`, and runs from `capture-watchdog` as check 5a3.

**Why it was the right FIRST graph check, unchanged: it has no threshold to argue about.** The correct
value is zero or an explanation, which makes it ratchet-shaped rather than a gate red on day one.

**Measured live: 48,138 nodes, 86,054 edges.**

| | |
|---|---|
| nodes at degree 0 | **205** |
| weakly connected components | **213** |
| largest component | 47,919 of 48,138 (**99.5%**) |
| components of 2+ apart from the largest | **7, every one of size 2** |

That reproduces the item's figures. **But the orphan breakdown is new, and it changes what the number
means:**

| orphan node type | count |
|---|---|
| `CategoryExclude` | **199** |
| `IngredientMapping` | 4 |
| `Commodity` | **2** |

**199 of the 205 are exclusion rules, which join nothing BY CONSTRUCTION** - an exclude is a
statement about what must not match, not a thing with edges. So *"205 nodes joined to nothing"* is
mostly a category error, and the genuinely unexplained orphans are **six**: four ingredient mappings
and **two commodities**. Two orphaned Commodity nodes is a small, real, nameable thing; 205 was not.

**Verified:** self-test exit 0 over 8 cases - led by the must-fire that a node touched by no edge
scores 0 rather than being absent from the table, and including a 5,000-node chain that proves the
flood fill is iterative (a recursive one blows the stack at this size, and finding that out from a
RecursionError inside a gate is a worse way to learn it). Ratchet proved by lowering the baseline to
force a rise: **exit 2, naming both counts**, then restored and green again. `run-gates` exit 0,
`pass=281 fail=0` - the self-test is discovered.

**BLIND, never clean, without a database:** a worktree and a CI runner have no `graph.db` and get exit
3, which is why the live half runs from the watchdog rather than from `run-gates`.

**Merged from `design\backlog-inbox\lane-graphs-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** `big-data-graph-analytics` (UC San Diego, Amarnath Gupta), queue-6 group I entry 15,
worked 2026-09-08. Routed to `rag-craft/graph-analytics.md`; estate half in that domain's
`applies-here.md` entries 12 to 17.

**Measured read-only against `graph\sqlite\graph.db` on 2026-09-08, and verified independently by
the orchestrator: 48,043 nodes and 85,891 edges.** Degree histogram: **205 nodes at degree 0**,
12,479 at 1, 31,168 at exactly 2, thinning to a maximum of 20,133 at `store:walmart`. **213 weakly
connected components**, the largest holding 47,824 nodes, which is 99.5%; seven of the rest are two
nodes.

**Why no existing check can see it.** Nothing is wrong with any of those rows individually, so every
row-level `data-quality-craft` check passes. A degree-0 node is only visible as a property of the
graph, and no first-party code computes one: a grep for `networkx|centrality|betweenness|connected
component|shortest path|in-degree|adjacency` over the tree returns no graph analytics at all. The
`traversal` hits are directory-traversal security checks; `graph/learning/lint_adjacency.py` lints
exclude patterns, not adjacency.

**Why it is the right FIRST graph check.** It has no threshold to argue about. The correct value is
zero or an explanation, which makes it ratchet-shaped rather than a gate that is red on day one -
the standing rule this estate already applies to `audit-write-seam` and `audit-fact-claims`.

### I74 - the nodes table has no cached degree, so every fan-out question is a full scan of 85,891 edges `DONE - THE PREMISE IS REFUTED; THE USEFUL HALF SHIPPED WITHOUT A CACHE` `queue-6` `1-WAY` `RUNG1 BUILD`

**`[CLOSED 2026-09-09. The remedy was DECLINED after measuring, and the measurement is the finding.]`**

**THE PREMISE DOES NOT HOLD, on both of its claims.** Measured against the live database before
building anything:

```
select count(*) from edges where source_id = ?  -> SEARCH edges USING COVERING INDEX ix_edges_src
select count(*) from edges where target_id = ?  -> SEARCH edges USING COVERING INDEX ix_edges_tgt
```

| question | measured |
|---|---|
| worst case, `store:walmart` at 20,146 edges | **0.365 ms** |
| a SKU's degree | 0.003 ms |
| the whole graph's degree table, grouped | 0.004 ms |

**It is not a full scan** - `ix_edges_src` and `ix_edges_tgt` already exist and are COVERING for this
question - **and it is not slow.** A cached degree column would buy roughly nothing and would add a
**staleness hazard**: a denormalised count that silently diverges from the edges as they are written.
In an estate whose whole discipline is that a confident wrong number is worse than a slow right one,
that is a bad trade. **So the proposed remedy was declined, and 1-WAY it may have been, but the
irreversible change is the one that did not happen.**

**AND THE DIRECTION IS BACKWARDS, which matters more than the speed claim.** The item says a query
"from `store:walmart`" returns 20,133 rows outward. Measured: **`store:walmart` has out-degree 0 and
in-degree 20,146.** Edges run SKU -> store via `sold_at`, so a store is a TARGET and never a source.
**The highest out-degree in the entire graph is 4.** A guard written against out-degree, as the item
implies, would have watched the one direction that is always cheap and missed the only expensive one.

| widest IN-degree (the expensive direction) | |
|---|---|
| `store:walmart` | 20,146 |
| `store:bakers` | 7,832 |
| `store:family-fare` | 5,641 |
| `store:hyvee` | 3,875 |
| `store:aldi` | 3,819 |

**What shipped instead: `graph/lib/fanout.py`** - the pre-flight check the item actually wanted, with
nothing to go stale. `fanout()` reports both directions and which one is wide; **`assert_cheap_entry()`
is the forward rule as CODE rather than as prose in a comment.** *"Enter from the SKU, or from a
Commodity down through `instance_of`; never from a Store outward"* had been written down twice and
enforced zero times. It now raises, naming the direction and the count so the caller learns why.

**Verified:** self-test **10 of 10**, hermetic against an in-memory graph shaped like the real one, so
it needs no `graph.db` and runs anywhere. Led by the must-fire that a store's cost is its IN-degree
with out-degree 0 - the case that would have caught the item's inversion - and a clean twin asserting
the query **still uses the index**, because that is the fact the no-cache decision rests on and it
should fail loudly if it ever stops being true.

**Merged from `design\backlog-inbox\lane-graphs-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** As above.

**What is missing.** `nodes` carries no degree column, so answering "how many edges touch this node"
means scanning the edge table. The course's own remedy is one pass that stores the degree back onto
the node, which is section 50.4's standard move for exactly this.

**Why it matters beyond speed, and this is the real point.** `sold_at` is 46,708 of 85,891 edges,
54% of the graph, and it is **directional in cost**: from a SKU it returns one row, from
`store:walmart` it returns 20,133. Any query, join or expansion that enters at a `Store` and follows
`sold_at` outward fans out twenty thousand ways. With no cached degree there is no cheap way to
notice that before running it. **Forward rule: enter from the SKU, or from a Commodity down through
`instance_of`; never from a Store outward.**

### I75 - retiring a commodity id is a graph cut, and both gates that guard it reason about names `DONE - THE CUT IS MEASURED AND THE FORWARD RULE IS IN THE AUDIT, 2026-09-09` `queue-6`

**`[CLOSED 2026-09-09, in `graph/audit_graph_shape.py` alongside I73.]`**

**Retiring a commodity id is a GRAPH CUT, and both gates that guard it reason about NAMES:**
`meal-prep/pipeline/retire_food_db_row.py` greps zero for `edges|graph.db|degree|connect`, and the
`commodity-registrar` agent rules on names and duplicates. **Neither counts what an id actually
joins.**

**Measured live, and it states the estate's cross-store pricing premise as a property rather than a
belief:**

| remove | components go from | to |
|---|---|---|
| the **7** `Store` nodes | 213 | **12,382** |
| the **708** `Commodity` nodes | 213 | **575** |

**Connectivity rests on 715 rows out of 48,138.** The audit prints this every run, so the next person
proposing to retire a commodity id sees what it joins before they do it, which is the thing neither
guard could tell them.

**The forward rule ships in the audit's own output, because it is free and it is the half that
prevents a slow query rather than diagnosing one:** *enter from the SKU, or from a Commodity down
through `instance_of`; never from a Store outward.* `sold_at` is 54% of the graph and fans out
20,133 ways from `store:walmart`.

**What is NOT done:** the retirement gates themselves still reason about names. Teaching
`retire_food_db_row.py` to refuse a cut that would orphan nodes is a change to a gated merge path,
and the audit now gives it the number it would need. That is a follow-on, not this item.

**Merged from `design\backlog-inbox\lane-graphs-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** As above.

**The measurement that makes it concrete.** Remove the seven `Store` nodes and the graph shatters
into **12,343 components**. Remove the 708 `Commodity` nodes and the top seven surviving pieces are
one per store. **Connectivity therefore rests on two node types totalling 715 rows**, and that states
the estate's entire cross-store pricing premise as a measurable graph property rather than a belief.

**What guards it today.** `meal-prep/pipeline/retire_food_db_row.py` greps zero for
`edges|graph.db|degree|connect`, and the `commodity-registrar` agent rules on names and duplicates.
Neither counts what an id actually joins. The second-largest component in this graph is currently
two nodes, so a cut is not hypothetical.

### I76 - valence is rising and every check here counts rows `PARKED - PRICED 2026-09-08: A REAL MEASUREMENT WITH NO CONSUMER AND NO THRESHOLD` `queue-6`

**`[PARKED 2026-09-08 under Pass 4.]`** The measurement is real and stands:
`database-craft/applies-here.md` recorded 84,748 edges over 47,319 nodes and on 2026-09-08 it is
**85,891 over 48,043** - **+1,143 edges against +724 nodes**, so edges accumulate about **1.6 times
faster than nodes**. That is rising valence, and it means the average distance between any two nodes
is falling. Every freshness and volume check in the estate counts ROWS and none of them can see a
query getting slower because a region densified rather than grew.

**Priced: the query is one line and the answer changes no action.** There is no consumer for the
series, no threshold anyone would set on it, and no decision that would go differently at any value
it could return. Tracking edges-per-node over time would produce a second uninspected timing series -
which is precisely the mistake I33 recorded about the FIRST one, and it would be worse to repeat it
knowingly.

**THE TRIGGER: a graph query that is measurably slower than it was, or the first cached-degree work
(I74).** At that point edges-per-node is the number that says whether the cause was growth or
densification, and the two have different fixes. **The forward rule from I74 is the cheap half and it
is already recorded there: enter from the SKU, or from a Commodity down through `instance_of`, never
from a Store outward** - `sold_at` is 54% of the graph and fans out 20,133 ways from `store:walmart`.

**Merged from `design\backlog-inbox\lane-graphs-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** As above.

**Measured.** `database-craft/applies-here.md` recorded 84,748 edges over 47,319 nodes. On
2026-09-08 it is **85,891 over 48,043**: **+1,143 edges against +724 nodes**, so edges are
accumulating about 1.6 times faster than nodes. That is rising valence, and it means the average
distance between any two nodes is falling.

**Why nothing would notice.** Every freshness and volume check in the estate counts rows. None of
them can see a query getting slower because a region densified rather than because it grew. One
query answers it: edges per node, tracked over time.

### I77 - the one-hop memory expansion experiment now has a design and, more importantly, a control group `OPEN - BLOCKED ON A RUN, NOT ON A DECISION` `queue-6` `2-WAY` `RUNG1 MEASURE`

**`[NOT REACHED 2026-09-09.]`** The design and its control group are the valuable half and they are
already written here. Executing it needs live recall runs across both arms, which is a dispatched
experiment rather than a session task. **Nothing was estimated in place of running it.**

**Merged from `design\backlog-inbox\lane-graphs-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** As above, plus `rag-craft/applies-here.md` 15.

**What was measured.** The memory store holds **228 `[[links]]` inside it across 87 distinct
targets with 3 dangling**, and **270** counting the six `.claude/rules` files. `[CORRECTED
2026-09-08: the orchestrator's brief said 252, which does not reproduce at either scope. The target
and dangling counts DID reproduce, so the error was scope rather than counting.]`

**The finding that changes the experiment.** In-degree histogram: **53 of 137 files, 39%, are cited
by nothing**, six are isolated entirely, and the three most-cited are
`an-agreeing-number-escapes-scrutiny` (16), `green-fixture-is-not-production-coverage` (12) and
`rerun-gates-after-a-spawned-build` (9). **All three are general rules.** So in-degree here measures
GENERALITY, not relevance - which means **one-hop expansion is the right experiment and centrality
re-ranking is the wrong one**, and the reason is now written down instead of assumed.

**What would settle it.** `graph-retrieval.md` 28's mechanism, scored per
`evaluating-retrieval.md`: recall@k, a frozen case set, one row per case per arm. **The 53
zero-in-degree files are the control that makes it honest** - a case set drawn only from the linked
61% would overstate the gain by construction.

### I78 - the recall hooks are absent from the watch list that detects a silently dead automation `DONE - BOTH RECALL HOOKS ARE ON THE SILENT-DEATH WATCH, 2026-09-08` `queue-6`

**`[CLOSED 2026-09-08.]`** `grocery/expected-automations.json` gained an `external_files` array
with one row per hook - `recall-log.jsonl` and `recall-reflex-log.jsonl` - and
`grocery/health-heartbeat.ps1` reads it.

**It is a separate array rather than two more `output_files` rows, and that is not tidiness.** Every
other row is resolved with `Join-Path $repo`, and `Join-Path` against an absolute second argument
produces `C:\repo\C:\Users\...` - a path that never matches. The rows would have read as a permanent
MISSING, and a check that is red every day is a check that gets muted inside a week. These resolve
with `ExpandEnvironmentVariables` and are used as given.

**They are deliberately NOT counted in `$declared`.** That counter exists to refuse to grade an empty
exam, and the exam it protects is the repo's own chain; a registry that lost `windows_tasks` but kept
these must still report BLIND rather than checking two log files and calling the estate healthy.

**72 hours, not the 30 every other row uses.** The hook only writes when a session runs and Brad does
not work every day, so a 30-hour window would page every quiet weekend - which is the
red-on-day-one failure in its detective form.

**Two hooks watched separately** rather than trusting one to prove the other: they are different
hooks on different events, and this estate has already paid for assuming one signal covers two loops.

**Verified, and the must-fire was OBSERVED rather than assumed.** Live run: exit 0, both rows
`ok ... fresh`, `HEALTHY: 13 automation(s)/output(s)`. Then a third row pointing at a deliberately
absent path was added, the run went to **exit 2** with `EXTERNAL OUTPUT MISSING`, and the registry was
restored and confirmed identical by MD5 (`690E8363F89433C1AB1F8972EB6FC6D1` before and after), per the
estate's own neuter-numbers rule. `run-gates` exit 0, `pass=276 fail=0`.

**Merged from `design\backlog-inbox\lane-observability-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** `observability-engineering-metrics-logs-traces` (Edureka), queue-6 entry 18, worked
2026-09-08. Routed to `reliability-craft/metrics-storage-and-queries.md`; estate half in that
domain's `applies-here.md` section 1.

**The distinction that makes this a defect rather than a nice-to-have.** A **heartbeat** is written
by the watched thing. It can separate "found nothing" from "died", but it cannot separate either
from "never invoked", because an absent heartbeat row and absent traffic are the same bytes. A
**liveness signal** is written by the watcher on the watcher's own schedule, and that is the only
shape that can say *this should have run and did not*.

**The estate already owns the second half and never pointed it at its newest loop.**
`grocery/health-heartbeat.ps1` is a silent-death detector, run from `grocery/capture-watchdog.ps1`
against `grocery/expected-automations.json`. **The recall hooks appear nowhere in that watch list**,
verified 2026-09-08. So the whole recall loop can stop firing and nothing anywhere goes red.

**The cheapest fix, and it is small.** One row per hook in `expected-automations.json` naming its log
file and a staleness bound. Nothing new needs building.

### I79 - the recall log has the wrong join key, so a subagent's rows fold into its parent's and look like a busy session `DONE - EVERY RECALL ROW CARRIES `agent` NOW, 2026-09-09` `queue-6`

**`[CLOSED 2026-09-09, in the same change as I95 because it is the same row.]`**

`recall-log.jsonl` rows carried `ev, heading, path, q, score, sid, t`. `recall-reflex-log.jsonl` rows
carried `acted, agent, chash, id, kind, sid, t, tool, waived`. **The reflex log had `agent`; the
recall log did not.**

**Why `sid` alone cannot be the key:** a subagent's hook calls carry the parent's `session_id` **byte
for byte** - established over 46 measured payloads - so a join across the two logs on `sid` silently
folds a subagent's rows into its parent's, and the result **looks like a busy session rather than
like a bug**. That is the worst failure shape this estate has a name for.

Every row `recall-hook.py` writes - offers and near misses alike - now carries `agent` beside `sid`.
**There is no call stack in a hook to carry context implicitly**, so it goes in the row deliberately
or it is not there at all.

**Verified by driving the hook with an explicit `agent_id` and reading the rows back:** both `sid`
and `agent` present on every row written.

**Not backfilled, and it cannot be.** Rows written before today carry no `agent`, so any join over
historic data still has the old ambiguity - a reader must treat pre-2026-09-09 rows as
session-level only.

**Merged from `design\backlog-inbox\lane-observability-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** As above, `applies-here.md` section 4.

**Measured 2026-09-08 by reading the last row of each file.** `recall-log.jsonl` rows carry
`ev, heading, path, q, score, sid, t`. `recall-reflex-log.jsonl` rows carry
`acted, agent, chash, id, kind, sid, t, tool, waived`. **The reflex log has `agent`; the recall log
does not.**

**Why `sid` alone cannot be the key.** `automatic-recall.md` already establishes, over 46 measured
payloads, that a subagent's hook calls carry the parent's `session_id` byte for byte. So a join
across the two logs on `sid` **silently folds a subagent's rows into its parent's**, and the result
looks like a busy session rather than like a bug. That is the worst failure shape this estate has a
name for: an agreeing number.

**Fix.** Every log this loop writes carries `sid` **plus** `agent`, the same composite the dedup
already uses, and any new log starts with both. There is no call stack in a hook to carry context
implicitly, so it goes in the row deliberately or it is not there at all.

### I80 - every threshold in the estate is an upper bound, so not one of them can fire on nothing happening `DONE - THE FORWARD RULE IS IN THE RULES FILE, 2026-09-08` `queue-6`

**`[CLOSED 2026-09-08.]`** `.claude/rules/ops-and-gates.md` now carries the rule: **when adding
any threshold, write down what the number does when the PRODUCER STOPS.** If the answer is *goes
quiet, and the alert cannot fire*, add the floor in the same change.

The measurement stands as filed: every alert condition here is staleness or a band breach, every
`ops/` ratchet is a high-water mark that may only go DOWN, `run-gates` answers a boolean, and the only
two checks watching for absence (`health-heartbeat.ps1`, `heartbeat.yml`) watch **scheduled tasks**,
never throughput. No file records a lower-bound alert on a rate.

**The boundary against the volume check is stated in the rule rather than left to be re-derived**,
because it is exactly the distinction that would get folded away: the volume check asks whether the
expected ROWS arrived, this asks whether the STAGE is still running at its expected rate. **A stage
that runs and emits nothing fails the first and passes the second.** Keep both.

**No floor was added to anything on this run, and that is deliberate.** Choosing a rate floor is
deriving a threshold, `no-hardcoded-bands` applies, and picking one here would be the thing the rule
itself forbids. What shipped is the rule that stops the next threshold being written blind - which is
what the item proposed.

**Merged from `design\backlog-inbox\lane-observability-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** As above, `applies-here.md` section 3.

**Measured.** The alert conditions in `grocery/` are staleness and band breaches. The ratchets in
`ops/` carry a high-water mark that may only go DOWN. `ops/run-gates.ps1` answers a boolean. The only
two that watch for absence are `grocery/health-heartbeat.ps1` and the cloud `heartbeat.yml`, and both
watch **scheduled tasks**, never throughput. **No file in the estate records a lower-bound alert on a
rate.**

**Not the same as the volume check, and the boundary matters.** The standing volume check asks
whether the expected ROWS arrived. This asks whether the STAGE is still running at its expected rate.
A stage that runs and emits nothing fails the first and passes the second. A stage that stopped fails
both, and only the second says which. Add the floor here and keep the row count there; do not fold
one into the other.

**Forward rule.** When adding any threshold, write down what the number does when the producer stops.
If the answer is "goes quiet, and the alert cannot fire", add the floor in the same change. A floor
on a rate is detective by construction, and a preventive gate cannot substitute for it, because the
failure it catches is one where nothing ran to be gated.

### I81 - if a hook ever records its own duration it must record the RAW value, and that has to be decided before any data exists `DONE - INSTRUMENTED, AND THE FIRST NUMBER IS 3.2 SECONDS` `queue-6` `1-WAY` `RUNG1 RULING`

**`[CLOSED 2026-09-09. Brad ruled: yes, raw value on every row.]`**

`~/.claude/skills/recall-hook.py` writes one `ev: "timing"` row per invocation carrying a raw `ms`,
the return code, and `sid` + `agent` beside them.

**The ruling was taken before the data existed, which is the only time it could be.** Raw value per
row, never a mean and never a pre-bucketed histogram: a histogram's resolution is fixed by its bucket
boundaries **at instrumentation time** and cannot be improved afterwards, and a mean is the one shape
that cannot be un-aggregated. This is the estate's one-row-per-case rule wearing a different coat.

**IT IS A WRAPPER AROUND EVERY RETURN PATH, and that is not a detail.** There are five returns, and
the offer rows are only written when something was picked - so hanging the duration off them would
have recorded time only for turns that already succeeded. **That is precisely the censored sample
backlog I95 exists to fix, reproduced inside the fix for something else.** A turn that offered nothing
still spent the time, and a slow empty turn is the row most worth having.

**THE FIRST MEASUREMENT, and it is bigger than anyone assumed:**

| path | wall time |
|---|---|
| a real prompt, full search | **3,186 ms** (and 3,201 ms on a second run) |
| an empty prompt, early return before the search | **9 ms** |

**So process start, payload read and state save cost about 9 ms, and the search leg costs about 3.2
seconds.** That refines the standing memory *"the recall hook pays for numpy, not the search - 66 ms
import against a 0.3 ms cosine pass"*: that memory is about the **semantic** leg, and it does not
account for this. The 3.18 seconds sits somewhere in the retrieval path, most likely the lexical index
build over the skills tree.

**Stated honestly: this is TWO observations on one machine, and nothing has been attributed yet.** It
is enough to say the number is large and worth chasing; it is not enough to name the cause, and I have
not. The instrument now exists to answer it, which is what the ruling bought.

**Verified:** hook self-test **15 of 15**; driven twice through a real payload file and the rows read
back, carrying `sid` and `agent`.

**A defect in my own verification, not in the code, worth recording because it wastes a session every
time:** the first test piped JSON to the hook through PowerShell, which **strips double quotes for a
native exe**, so `read_payload` fell back to treating the whole string as the prompt and the rows came
back with no `sid`. The instrumentation was correct and the harness was lying. The payload goes
through a file.

**The other two numbers the item named need no instrumentation** and remain derivable from the log
stream as it stands: offers per turn, and consulted over offered.

**Merged from `design\backlog-inbox\lane-observability-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** As above, `applies-here.md` section 2.

**The state of things.** Every field in both hook logs is a fact or an identifier and **not one is a
duration**, so "the estate has no metric with a unit" is a true description of the system rather than
a gap in its reporting. Two of the three numbers worth having need no new instrumentation at all -
offers per turn, and consulted over offered - because a rate can be derived from a log stream that is
already being written. Only hook wall time needs a new field.

**Why it needs a ruling before it needs code.** A histogram's resolution is fixed by its bucket
boundaries **at instrumentation time**, and cannot be improved afterwards. In a per-event `.jsonl`
there is no reason to pre-bucket, so the ruling is simply: **record the raw duration per row, never a
mean.** A mean is the one shape that cannot be un-aggregated, which is the estate's own one-row-per-
case rule wearing a different coat.

**What is being asked.** Whether to add the duration field at all. It is cheap, but it is the only
one of the three that touches the hot path of every tool call.

### I82 - seventeen files read compare-deals.ps1's SOURCE and twelve of them execute it, and both the rules file and the memory say three `PARTLY DONE - THE FAILURE MODE IS GATED; THE REFACTOR IS PLANNED, NOT BUILT` `queue-6` `2-WAY` `RUNG1 BUILD`

**`[2026-09-09. What shipped, and what deliberately did not.]`**

**SHIPPED: `ops/audit-lift-completeness.ps1`, in `run-gates`, green at 0 findings over 3 lifting
scripts and 31 engine functions.** The hand-maintained lift lists have exactly one failure mode and it
is recorded in `build-walmart-deals.ps1`'s own comment: the day `Test-NameOffersTwoSizes` was added and
`Get-UnitPrice` began calling it, the lift produced a function whose callee did not exist and it failed
at **run** time as "not recognized as the name of a cmdlet". The audit extracts each list's functions
with the same regex the lifters use and reports any call to an engine function the list did not bring.

**Verified by reproducing that incident against the real engine, not a fixture:** deleting
`Test-NameOffersTwoSizes` from `build-walmart-deals.ps1`'s live list made the audit exit **2** and name
the function, and restoring it returned exit 0. Self-test 9 of 9.

**It was red on day one and that was MY defect, caught by looking rather than by trusting it.** The
first sweep reported 6 findings across three builders that have been building daily for months. Both
"callees" - `Add-Norm` and `Get-MatchTexts` - are **prose inside `Get-UnitPrice`'s own explanatory
comments**. A name in a comment is not a call. It strips comments now, **block comments first and line
comments second**, because reducing PowerShell by line comments alone leaves a `<#` header readable as
code, which this estate has a separate audit about. Both cases are now fixtures.

**NOT SHIPPED: the provided interface itself. Planned in
`design/PLAN-compare-deals-interface-2026-09-09.md`.**

**The root cause is named in the code** and it is not that anyone was lazy:
`build-walmart-deals.ps1:82` says *"it runs a pipeline on load, so we can't dot-source it."* A 3,566
line file mixes pure pricing math, a data constant and a board build that executes on import, so the
only reachable interface was the source text.

**There are TWO lifted interfaces, not one**, which the item did not separate: the pricing functions
(regex-extracted bodies, driven by a hand-maintained name list) and **`$GLOBAL_EXCLUDE`**, whose array
literal is regex-lifted and `Invoke-Expression`d by 5+ files. **`compare-deals.ps1` lifts from itself**
at lines 1653 and 2076, because its self-test block runs before those definitions exist.

**Why it was not attempted in this session, stated plainly rather than implied.** It is one atomic
change across 13+ files on the code that decides what a shopper is told a thing costs, and it cannot be
staged: the moment the functions leave the file, every lifter's regex finds nothing. The evidence that
would justify shipping it is **a board rebuilt after the change being byte-identical to one rebuilt
before**, and a passing test suite is not a substitute for that. Scaling that down to fit a session was
not mine to decide.

**Merged from `design\backlog-inbox\lane-software-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** `software-architecture` (queue-6 entry 6), worked 2026-09-08. Routed to
`software-craft/architectural-styles.md` and `evaluating-an-architecture.md`; estate half in that
domain's `applies-here.md`.

**Measured 2026-09-08** by grep over `grocery/`, `ops/`, `meal-prep/`, `lib/` and `graph/` for
`*.ps1`, worktrees excluded: **17 files read `compare-deals.ps1`'s own text with `Get-Content`, and
12 of those 17 also call `Invoke-Expression`**, so they execute code lifted out of it by regex.
Confirmed lifters include `grocery/build-walmart-deals.ps1:87`, `grocery/build-sams-deals.ps1:60`,
`grocery/audit-match-contested.ps1:18` and `grocery/audit-household-in-food.ps1:16`.

`[CORRECTED 2026-09-08, and the correction is the more useful half.]`

**The premise as filed was already stale, and my own numbers did not reproduce.** The item said
`.claude/rules/grocery.md` claims three lifters. It had said MANY since commit `ae6c4caf9` earlier
that same day, and the memory had been renamed to
`compare-deals-functions-are-lifted-by-many-scripts`. I merged a course agent's finding without
checking whether the estate had moved underneath it, which is this estate's own rule about verifying
against a moving main, applied to a backlog item instead of a branch.

**Then four counts of the same quantity turned out to disagree, and none of them had stated its
test:**

| Source | Read | Execute |
|---|---|---|
| the course agent, 2026-09-08 | 17 | 12 |
| `.claude/rules/grocery.md` as it then stood | 17 | 14 |
| the command that file itself gave | 53 name it | 13 |
| `Get-Content` pointed AT the file | 18 (15 outside `grocery\out\`) | 12 |

**The 12 reproduces on two independent tests, so the EXECUTE count is solid.** The read count is 15,
17, 18 or 53 depending entirely on whether "reads it" means names the filename or applies
`Get-Content` to it, and on whether one-off scratch scripts count. Nobody said which.

**So the finding is sharper than filed, not weaker.** The problem was never that the number was 3
rather than 17. It is that **a count with no stated test cannot be checked, cannot be reproduced and
cannot notice the next caller arriving** - and a rule that says "count it, never quote it" while
quoting a number its own command does not produce teaches the opposite of what it says. The rules
file now carries its test, a command whose output is the stated number, and the date. The remaining
work is the architectural half below, which is untouched by any of this.

**What it is architecturally.** `compare-deals.ps1` is a component with a required interface and no
provided one, so the socket has been jammed onto the source file. The estate already has the right
shape elsewhere: `grocery/match-lib.ps1`, `grocery/known-wrong-lib.ps1` and `grocery/identity-lib.ps1`
are dot-sourced libraries that work. This is not a new pattern to invent, it is an existing one
`compare-deals.ps1` never got.

**Forward rule.** Before adding a consumer to an existing script, ask what its provided interface is.
If the answer is "read its source", that is the finding. And any claim about how many things depend
on X is measured with a grep and a date, never carried in prose or a filename.

### I83 - no quality attribute is stated anywhere in the estate, so nothing can be evaluated against one `DONE - THE UTILITY TREE EXISTS; THE MEETING DOES NOT` `queue-6` `2-WAY` `RUNG1 DOC`

**`[CLOSED 2026-09-09 in docs/QUALITY-ATTRIBUTES.md.]`**

**The gap was real and it was checked before it was filled:** `ATAM`, `architecture tradeoff`,
`utility tree`, `quality attribute`, `Kruchten` and `Conway` return **zero matches** across every
`.ps1`, `.py` and `.md` in the repo, and are a clean no-match over 1,251 sections of the skills store.
`docs/RUNTIME-MAP.md` maps the runtimes and the git-bus well but states **no attribute, no priority and
no scenario**, so every design argument had to be re-derived from taste.

**What ported is the utility tree; what did not port is the meeting.** There is one person here and no
stakeholder groups to convene, so a nine-step ATAM is theatre. Attributes are stated per subsystem with
two letters: importance to the business, then difficulty here.

**One attribute outranks the rest and is written as the constraint the others optimise inside:**
correctness of a published number, `H/H`, where understating is exactly as wrong as overstating.

**The document earns its place by naming two things nobody had written down.** First, a tradeoff:
refusal-under-uncertainty is **bought with throughput** - every BLIND verdict is a cell that stays empty
until someone looks, and the estate has consistently chosen the empty cell. That is the right call and
it should stay a conscious one. Second, the weakest seam: **modifiability of the pricing math is `M/H`
and nothing holds it up** - a helper added to the lifted `compare-deals` functions breaks 12 executing
scripts at call time. That is backlog I82, and this is the first document that says so as a property of
the architecture rather than as an incident.

**Deliberately not a design authority.** `RUNTIME-MAP.md` still outranks it on what actually runs. The
file's own closing rule is the one that keeps it honest: **a priority no scenario supports is a priority
nobody has tested, and should be deleted rather than defended.**

**Merged from `design\backlog-inbox\lane-software-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** As above.

**Measured 2026-09-08.** A grep for `ATAM`, `architecture tradeoff`, `utility tree`,
`quality attribute`, `Kruchten` and `Conway` over every `*.ps1`, `*.py` and `*.md` under the repo,
with `.venv` and `site-packages` excluded, returns **zero matches**. The same six terms are a clean
no-match over 1,251 sections of the skills store. There is also **no architecture diagram of any
kind**: `UML`, `component-diagram`, `viewpoint`, `reference-architecture` and `4+1` in the
architectural sense are absent from both.

**What exists and why it is not this.** `docs/RUNTIME-MAP.md` is good and maps the runtimes and the
git-bus, but it states no quality attribute, no priority and no scenario. `ops/run-gates.ps1`
enforces correctness properties and says nothing about availability, modifiability, testability or
performance **as requirements carrying targets**.

**What to actually do, and what NOT to.** Do not open a nine-step ATAM here: there is one person and
no stakeholder groups to convene. What ports is the **utility tree** - quality attributes, refined,
with priorities, per subsystem. What does not port is the meeting.

**The one method piece worth stealing outright.** When two parties both have priorities, get both
lists independently and diff them. That is the same instrument as this estate's case-NAME set diff:
two independent lists compared, where either alone looks complete.

### I84 - the guards are an open control loop, and capture-watchdog exists because of it `PARKED - ABSORBED INTO I93'S RULING; IT NAMES A SHAPE AND PROPOSES NO RUNG` `queue-6`

**`[PARKED 2026-09-08.]`** The analysis is good and is kept: `grocery/guards.ps1` and
`lib/guard-contract.ps1` have the sensor and the controller and the **actuator is missing** - a guard
senses, compares to a set point, reports the error, and nothing closes the loop. That is open-loop
control, whose named cost is the one that bites here: **an open loop cannot check itself to see
whether it is succeeding.** And `grocery/capture-watchdog.ps1` exists precisely because of that gap,
which is the estate independently inventing a **second** loop rather than closing the first - the more
expensive of the two ways out, taken without the tradeoff ever being stated.

**It is parked because it proposes no rung.** There is no measurement, no build and no ruling in it;
it is a name for something already built and already working. Naming it was the value and the name is
now recorded.

**Its live half has moved to where a decision can be made about it: I93**, which asks whether *a
control constant that may only move one way needs a rate limit and a plausibility bar* is a shape
worth naming, and which has the one instance with a real cost sitting under it (I92's fifteen
permanently held aliases). Written up in `design/RULINGS-2026-09-08.md`.

**The Conway reading is kept because it is the part nobody would re-derive:** one person plus many
spawned agents produced 273 scripts, 32 of them uncalled, with the largest reuse mechanism being
source-text LIFTING rather than a library boundary - even though the library shape exists here and
works (`match-lib`, `known-wrong-lib`, `identity-lib`). **A single-writer organisation has no
interface negotiation to force one.** That is I82's territory and I82 stays OPEN.

**Merged from `design\backlog-inbox\lane-software-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** As above.

**The shape.** `grocery/guards.ps1` and `lib/guard-contract.ps1` have the sensor and the controller
present and the **actuator missing**. A guard senses, compares to a set point and reports the error.
Nothing closes the loop. That is textbook open-loop control, and the named cost is exactly the one
that bites here: an open loop cannot check itself to see whether it is succeeding.

**The evidence that this already cost something.** `grocery/capture-watchdog.ps1` exists precisely
because of that gap. That is the estate independently inventing a **second** loop rather than closing
the first, which is the more expensive of the two ways out and the one that was taken without the
tradeoff ever being stated.

**Related, and the same root.** Seven stores share one board pipeline with per-store
`build-*-deals.ps1` scripts. That is domain engineering plus seven application engineerings, unnamed.
The source-lifting item above is what a product line looks like with no declared reference
architecture. Reading Conway's Law here is unusual but clean: one person plus many spawned agents
produced 273 scripts, 32 of them uncalled, with the largest reuse mechanism being source-text lifting
rather than a library boundary, even though the library shape exists and works. A single-writer
organisation has no interface negotiation to force one.


### I85 - the orphan census only ever examined grocery, and 72 scripts elsewhere have never been checked by anything `DONE - THE POPULATION IS THE WHOLE REPO NOW, ON A TWO-TIER DESIGN` `queue-6` `2-WAY` `RUNG1 BUILD`

**`[CLOSED 2026-09-09. Rung 2 done: the re-keying, the widening and the ratchet.]`**

**The blocker the item named is cleared.** `$KNOWN`'s 52 keys were relative to `$Root`, so widening
the population made every one of them stop matching and come back as a false orphan. They are
**repo-relative now** (`grocery\<name>`), and the uncalled list is keyed off `$ScanRoot` rather than
`$Root`, so **the same `$KNOWN` line means the same file whatever the population is set to.**

**TWO TIERS, and the split is the whole design.** `grocery\` keeps the hard rule it has always had -
a new unrecorded orphan there is a FAIL. Everything outside it is a **ratchet** whose high-water mark
may only go DOWN. Neither tier can be satisfied by looking away: widening it as a plain gate would
have landed 74 findings on day one, and leaving it out is what hid them.

**Measured after widening: population 273 -> 530 scripts (plus 38 under `out\`), against 640
executable files. 106 uncalled, of which 74 sit outside `grocery\`.** The item predicted 72; it is 74.

**Verified by making the ratchet fire, not by trusting it:** a one-line script dropped under `ops\`
took the count to 75 and the census exited **2** naming both numbers; `-WideBaseline` then **REFUSED**
to raise the mark; removing the probe returned exit 0. Recording `ops\merge-backlog-inbox.ps1` as a
deliberate lowered the mark 74 -> 73, which is the ratchet working in the direction it is supposed to.

**`ops\merge-backlog-inbox.ps1` now has somewhere to be recorded**, which the item listed as
unresolved - it is uncalled on purpose because id allocation is a one-writer operation and the merge
is a judgement. **It is also the script whose orphan status could not be recorded anywhere, which is
how this item was found in the first place.**

**A regression I caused and caught in the same run, worth recording because the shape recurs.**
Widening `$Root` silently broke two things that were correct only while `$Root` was `grocery\`:
the `out\` exclusion was anchored at `^out\`, so 38 one-off scripts under `grocery\out\` stopped
matching and came back as ORPHANs - **a day-one wall of red produced entirely by the widening**; and
the frozen `OutBaseline` of 38 briefly counted every `out\` directory in the repo and failed at 39.
**A number moving because its definition moved is the one way a baseline can lie**, so the population
test is now `(^|\)out\` anywhere while the baseline check stays scoped to `grocery\out\`.

**Not a regression, checked before assuming: the "20 recorded entries are no longer uncalled" note
predates this change** - the last committed run reported 52 recorded against 32 uncalled, which is the
same 20. `run-gates` exit 0, `pass=294 fail=0`.

**`[HALF SHIPPED 2026-09-08.]`** `grocery/audit-script-census.ps1` now opens every run with a
SCOPE line naming both trees, and says out loud when they differ:

```
script-census SCOPE: population = *.ps1 under C:\Codex\ThriftyCrew\grocery  |  source side = executable files under C:\Codex\ThriftyCrew   <- NOT THE SAME TREE. Scripts outside the population are NOT censused by this run.
script-census: 273 script(s) + 38 under out\, read against 633 executable file(s); 32 uncalled, 52 recorded as deliberate
```

That is the half the item said mattered most - a reader could previously see "273 scripts read against
632 executable files" and take both totals for estate-wide, when only the source side is. **A rate
prints with its denominator; so does a census.**

**Verified:** live run exit 0, scope line read off the actual output rather than inferred.
`run-gates` exit 0, `pass=276 fail=0`.

**What is still open, and it is the larger half.** The 72 uncalled scripts under `.claude\`,
`meal-prep\`, `site\`, `ops\`, `media\`, `sidecar\` and the repo root are still examined by nothing.
The item is explicit about the shape - a ratchet seeded at 72 with a high-water mark that may only go
DOWN, never a default `$Root` change that lands 72 findings on day one - and about the blocker: the
`$KNOWN` register's keys are relative to `$Root`, so widening the population makes grocery's own 69
recorded deliberates stop matching and come back as false orphans. **That re-keying is the actual
work and it was not done here.** Also unresolved, and named in the item: `ops\merge-backlog-inbox.ps1`
is uncalled on purpose and there is still nowhere to record that.

**Merged from `design\backlog-inbox\lane-orchestrator-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Found 2026-09-08 by the orchestrator**, while trying to answer a much smaller question: does the
new `ops\merge-backlog-inbox.ps1` get flagged as an orphan? It ran clean, and the reason it ran clean
is the finding.

**What the census actually covers.** `grocery/audit-script-census.ps1` defaults `$Root` to
`$PSScriptRoot`, which is `grocery\`. So its POPULATION is the scripts in `grocery\` and nothing
else. Its source side is wider, `Split-Path -Parent $Root`, so it reads the whole repo when deciding
whether a grocery script has a caller. **That asymmetry is why the blind spot is invisible from the
output**: the run reports "273 script(s) ... read against 632 executable file(s)" and both numbers
look estate-wide. Only one of them is.

**Sized 2026-09-08** by re-running it with `-Root` and `-ScanRoot` both set to the repo. It reports
141 orphans. **That 141 is NOT the answer** and must not be quoted as one: the `$KNOWN` register's
keys are relative to `$Root`, so at the repo root the 52 recorded deliberates stop matching and
grocery's own 69 come back as false orphans. The honest number is the other side of the split:

| Directory | Uncalled scripts no orphan check has ever examined |
|---|---|
| `.claude\` | 37 |
| `meal-prep\` | 15 |
| `site\` | 12 |
| `ops\` | 4 |
| `media\` | 2 |
| `sidecar\` | 1 |
| repo root | 1 |
| **total** | **72** |

Some of those 72 are certainly deliberate, run by hand or named only in a `.md` (`ops\seed-worktree.ps1`
is one, cited in `CLAUDE.md`, and `.md` is not in the census's source extension list). **That is
exactly the point.** The register that records "uncalled on purpose, and here is why" exists, works
well, and covers one directory out of seven.

**Why this is the shape the estate keeps paying for.** The census is a good gate with a scope nobody
declared, and its own output states two totals that read as estate-wide. A count whose denominator is
narrower than it looks is this estate's most expensive recurring defect, and the standing rule is
that a rate prints with its denominator. **The gate should say which tree it examined, in its
completion line, every run.**

**What NOT to do, and this matters more than the fix.** Do not change the default `$Root` to the repo
and land 72 findings on day one. The estate's own rule is that a gate red on day one for a backlog
nobody is about to clear teaches people to ignore red. The shape that fits is the one already used by
`audit-write-seam` and `audit-fact-claims`: a ratchet with a high-water mark that may only go DOWN,
seeded at today's 72, plus the scope line in the output so the next reader is not misled the way this
one was.

**Immediate consequence, unresolved.** `ops\merge-backlog-inbox.ps1` is run by hand by the
orchestrator at the end of a parallel course run, and it is now documented as such in
`skills\course\orchestration.md`. There is nowhere to record that fact as a deliberate, because
`$KNOWN` only holds `grocery\` entries. It is uncalled, on purpose, and unrecordable.


### I86 - The guard-completion contract is a convention at 793 call sites, and PowerShell can make it structural `PARTLY DONE - 295 OF 410 SITES SWEPT; 115 SHAPES REMAIN` `queue-6` `1-WAY` `RUNG1 RULING`

**`[2026-09-09. Brad ruled: sweep it - the long-term structure is worth more than the cheap win.]`**

**THE MEASUREMENT IN THIS ITEM DOES NOT REPRODUCE.** It says 793 call sites across 119 files.
Measured 2026-09-09 over 530 first-party `.ps1` (worktrees, `archive/`, `grocery/out` excluded):
**410 call sites across 126 files.** 793 counted something broader, most likely every mention
including comments and multi-line continuations.

**Shipped in `lib/guard-contract.ps1`: `Exit-Guard` and `Invoke-Guard`.**

**The design turns on one measured fact, and getting it wrong would have been silent.** `exit` inside
a scriptblock **does** run an enclosing `finally`, but it does **not** run the statements after the
call. So the obvious wrapper - invoke the body, then write the marker - **would have dropped the
marker for every guard that exits with a finding**, which is most of them. It was checked with a
three-way probe before a line of the sweep was written. **The marker therefore travels WITH the
exit**: `Exit-Guard -Name x -Summary s -Code n` writes it and exits in one call, so the two cannot be
separated.

**Three paths, fixtured OUT OF PROCESS** because the behaviour under test is process exit and cannot
be observed from inside the suite that would die with it:

| body | marker | exit code |
|---|---|---|
| returns normally | written, from its return value | 0 |
| calls `Exit-Guard` | written **once**, not twice | preserved |
| **throws** | **none, deliberately** | 1 |

A crash writing no marker is the entire point: **a crash must never look complete.** A raw `exit N`
also writes none, which is left loud on purpose - the guard-contract audit then reports an unfinished
guard, a visible failure rather than a silent one.

**Swept: 295 sites across 86 files**, converted mechanically from `Write-GuardComplete ...` + `exit N`
to a single `Exit-Guard`. **115 sites are other shapes** - `; exit 0` on one line, conditional exits,
computed exit codes - and were left untouched because each needs reading. The converter refused
anything with unbalanced quotes or parens and reported what it skipped.

**THE GATE CAUGHT TWO REAL REGRESSIONS FROM THE SWEEP, and both were fixed at the cause:**

1. `meal-prep/pipeline/audit-paid-not-public.ps1` greps **its own source** for `exit 3` to prove the
   no-key path is could-not-evaluate. The claim was still true, spelled `-Code 3`. The fixture now
   accepts both spellings and still asserts three-and-never-zero.
2. `grocery/audit-guard-contract.ps1` decides coverage by grepping for `Write-GuardComplete`, so it
   read **11 files as having LOST their marker**. It knows `Exit-Guard` now, with its own fixture,
   because **a detector that cannot separate its marker from its exit is more strongly covered, not
   less** - and leaving it untaught would have made the safer construction look like a regression.

**And the pre-commit bulk-edit gate blocked the commit over BOM state**, correctly: reading with
`utf-8-sig` strips a BOM and writing back as `utf-8` does not restore it, so **10 files silently lost
theirs**. Restored byte-for-byte against HEAD before the commit landed. That gate paid for itself here.

**Verified:** `guard-contract -SelfTest` all cases including the four new out-of-process ones;
`run-gates` exit 0, `pass=291 fail=0`.

**NOT DONE: the 115 remaining shapes, and wrapping bodies in `Invoke-Guard`.** `Invoke-Guard` exists
and is fixtured but nothing uses it yet: wrapping a whole script body means running it through `&`,
which is a **child scope**, and a guard that relies on script-scope state would change behaviour
silently. That needs per-file reading, not a sweep.

**Merged from `design\backlog-inbox\lane-design-patterns-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**What is measured.** `lib/guard-contract.ps1` requires a detector's last line of stdout to be
`<NAME>-COMPLETE <summary>`, because "no findings" and "died halfway" are otherwise identical - its
own header records **five separate incidents** of that shape (ff-carry throwing on its report line
for weeks, the cloud gate standing down 13 days reporting SUCCESS, reanchor-all crashing between
halves, store-integrity and batch-ledger crashes indistinguishable from clean).

Measured 2026-09-08 over `*.ps1` under `C:\Codex\ThriftyCrew`, worktrees excluded:

- **793 `Write-GuardComplete` call sites** across **119 files** (counting lines that begin with the
  call; 124 files mention the name at all).
- `grep -rn "function Invoke-Guard\|function Invoke-Detector" --include=*.ps1` returns **zero**.

So the completion guarantee is a **convention honoured independently at 793 sites**, backed by an
audit that catches a violator after it has already shipped a silent detector.

**What the course adds.** This is textbook Chain of Responsibility, and its named failure is exactly
the estate's: a link that neither handles nor forwards ends the chain silently, and the symptom
surfaces far from the cause. The prescribed fix is **not** a marker and an audit - it is to put the
whole obligation in a **`final` template method** on the abstract handler, so a subclass structurally
*cannot* write a link that drops it. The estate converted a silent failure into a detectable one;
the pattern makes it unwritable.

**PowerShell has the same move**, without `final` or abstract classes: a wrapper taking a
`[scriptblock]`, running the guard's body, and emitting the marker itself on the normal path.
Roughly:

    function Invoke-Guard { param([string]$Name,[scriptblock]$Body)
      $r = & $Body            # body returns its summary; exceptions propagate unmarked
      Write-GuardComplete $Name $r
    }

**Why this is a ruling and not a task.** Three things need deciding and none of them is mine:

1. **Is 793 sites worth touching at all?** The current design works and is audited. This is
   `refactoring-judgment.md` 5's four-way call - refactor now, defer, leave alone, or communicate
   the debt - and "leave alone" is a legitimate answer for a convention that has held.
2. **A wrapper changes the failure mode rather than removing it.** A guard that forgets to *use*
   `Invoke-Guard` is the same silent hole one level up, so the audit is still needed. The gain is
   that the obligation moves from 793 sites to 119.
3. **`Write-GuardComplete` must never fire inside a `-SelfTest` branch or before the work is done**,
   and that file already documents a PS 5.1 dot-sourcing trap (`param()` running in the caller's
   scope) that a wrapper would have to be checked against. A partial migration is worse than none.

**A cheap first step if the answer is yes:** wrap the handful of guards that have actually thrown
mid-run, leave the rest, and measure whether the wrapper survives contact with the self-test paths
before proposing a sweep.

---

### I87 - `isReversible` is unnecessary today and becomes load-bearing at the SECOND remote write type `PARKED` `queue-6`

**Merged from `design\backlog-inbox\lane-design-patterns-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Trigger: a second irreversible remote write is hooked.** Until then there is nothing to do, and
this item should stay parked rather than being worked.

**What is measured.** Backlog E1 (`DONE - CLOSED 2026-09-07`) resolved the irreversible-write
exposure correctly and for the right reason: every named local target is git-tracked, so *"git is
already the undo log there and a second one would only have obscured it"*. What shipped hooks
`lib/ghost-lib.ps1`'s **`Invoke-GhostApi`**, a single choke point every remote write passes through.

`ls ops/revert-*.ps1 ops/undo-*.ps1` on 2026-09-08 returns **exactly one file**,
`ops/revert-ghost-write.ps1`.

**What the course adds.** `Invoke-GhostApi` is the Command pattern's **invoker** and
`revert-ghost-write` is its `unexecute`, arrived at independently and without the vocabulary. The
pattern's third method is **`isReversible`**, and it exists because *some commands genuinely cannot
be undone* - you cannot unsave. Today the estate needs no such field: one command type, one inverse,
reversibility is a constant.

**The failure it prevents, stated now because it is silent when it arrives.** Add a second remote
write type with no per-action reversibility verdict and the revert facility starts promising a
rollback it cannot perform - **and a revert that finds no inverse looks exactly like a revert that
had nothing to undo.** That is the same shape as the guard-completion hole in the item above:
absence of an effect and absence of a cause, indistinguishable from outside.

**What it would touch when the trigger fires:** whatever record `Invoke-GhostApi`'s hook writes, plus
whatever dispatches `ops/revert-*.ps1`. It is a field and a lookup, not a redesign - which is the
argument for writing the trigger down now rather than rediscovering the requirement later.

---

### I88 - the compare-deals lifter count moved out of prose into a script `DONE` `queue-6`

**`[CLOSED 2026-09-08, the same day it was filed, and the resolution went further than the item
asked.]` This item was filed against a state that no longer existed when it merged.** The lane read
`.claude/rules/grocery.md` before that day's afternoon correction landed, so its quotation of
"17 read and 14 execute" was accurate when read and stale when filed.

**Then its own re-measurement produced a SEVENTH answer.** 54 / 17 / 12 over five named
directories, differing from the sixth answer only in scope. Seven writers, seven numbers, one
quantity, and not a single disagreement about the code - every one was about which test the writer
meant, and no two used the same test.

**So the number is not in prose any more, in either file.** `ops/count-source-lifters.ps1` defines
and prints the three tests - NAMES, READS, EXECUTES - splits one-off scratch under `grocery\out\`
into its own column, names the executing files, and carries ten frozen fixtures including the ones
that keep the tests nested and stop a comment counting as a read. `run-gates` discovers it.
Measured there over 562 scanned files, whole repo, worktrees and archive excluded:
**54 name it, 18 read its source (15 outside `grocery\out\`), 12 execute what they lifted.**

Both `.claude/rules/grocery.md` and `software-craft/code-smells.md` now cite the script and carry
no digit. The estate's own rule was already "count it, never quote it" - this is the first version
of that rule with something to run.

**What the item got right and is worth keeping:** a freshly-dated wrong number is worse than an old
one, because the date reads as verification.

<!-- original heading: `.claude/rules/grocery.md` says 14 scripts execute what they lift from compare-deals; the number is 12 -->

**Merged from `design\backlog-inbox\lane-design-patterns-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Small, and filed because the rules file was JUST corrected and the correction carries a wrong
digit** - which is worse than the original error, since a freshly-dated number reads as verified.

`.claude/rules/grocery.md` currently reads:

> **MANY scripts LIFT its functions - 17 read its source and 14 execute what they lifted, measured
> 2026-09-08, against a `three` that stood in this file for months.**

It then gives the command to re-run - `grep -rl "compare-deals\.ps1" --include=*.ps1 grocery ops
meal-prep lib graph` - and tells the reader to count it rather than quote it, which is the right
instruction.

**Re-measured 2026-09-08, same five directories, `*.ps1`, worktrees excluded:**

| Test | Count |
|---|---|
| files that reference `compare-deals.ps1` at all (the command the rules file gives) | **54** |
| of those, files that read its SOURCE via `Get-Content ... compare-deals.ps1` | **17** |
| of those 17, files that also call `Invoke-Expression` | **12** |

So **17 is right and 14 is wrong; the executing count is 12**. `software-craft/applies-here.md`'s
2026-09-08 entry already records 17 and 12, so the two files currently disagree by two.

**And the command in the rules file does not produce either number - it produces 54.** A reader
following the instruction to count rather than quote gets a third figure, which is the failure mode
the instruction was written to prevent. Whatever the fix, the command quoted beside a number should
be the command that yields *that* number.

**Not fixed here** because `.claude/rules/grocery.md` is outside a course run's write scope; a course
run may only write this inbox file.

### I89 - a successful email send whose draft delete fails re-sends to a real person every day, forever `DONE - THE DUPLICATE IS BOUNDED AND THE DELETE FAILURE IS LOUD, 2026-09-08` `queue-6`

**`[CLOSED 2026-09-08. The fix goes further than the item asked, and the reason is worth keeping.]`**

The item proposed making the condition VISIBLE - a `try`/`catch` logging a distinct DELETE-FAILED
line. That is now there, but it would not have stopped anything: a visible unbounded daily email to a
member of the public is still a daily email to a member of the public. The harm needed bounding, not
announcing.

**The reason the loop was unbounded is that the only record of "already told" lived in the system that
fails.** The Ghost draft was both the outbox row AND the processed stamp, so the one failure mode -
the delete - destroyed the evidence that the send had happened. So the send is now recorded LOCALLY
in `grocery/notify-sent-log.json`, written BEFORE the delete is attempted, and the suppression check
reads that rather than the draft.

What shipped in `grocery/notify-item-added.ps1`:

- a `(postId, commodity)` key marked sent is **SUPPRESSED**, whatever state the draft is in. That is
  the unbounded loop, closed.
- the delete is now inside the `try` and its failure prints `DELETE-FAILED` with the reason. It used
  to sit OUTSIDE the catch, so a throw aborted the whole run and left no record that the email had
  already gone - the run then re-entered tomorrow with no memory of it.
- a bounded retry: `delete_attempts` rises, and at 5 the pair goes terminal and Ghost stops being
  asked about a draft that will not go.
- rows pruned at 180 days, deliberately WIDER than the 120-day draft expiry, so nothing that could
  still fire is forgotten.

**No email address is stored.** The log keys on the Ghost post id and carries a 16-char SHA-256
fingerprint of the address so a human can confirm a match. Requester addresses have never been
committed to this repo and this change does not start. The file is tracked, so git is its undo log,
which is E1's finding applied rather than a second undo layer built.

**Verified:** new `-SelfTest`, exit 0, 10 cases - 2 must-fire led by the founding bug (a send whose
delete failed must still suppress tomorrow), 4 must-not-fire including the empty log (`@($null).Count`
is 1 in PS 5.1, which would have made every FIRST send read as a repeat and silenced the feature) and
the pair-key boundary, 4 clean twins over pruning and the fingerprint. `-DryRun` against the live
board and the real Ghost queue ran clean and wrote nothing. `run-gates` exit 0, `pass=276 fail=0` -
up one from 275, which is this self-test being discovered.

**Not done, and not proposed:** nothing yet measures whether an alert was sent twice across the rest
of the estate. This closes the one path that had an unbounded repeat on it.

**Merged from `design\backlog-inbox\lane-event-driven-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** `grocery/notify-item-added.ps1`, read in full 2026-09-08. It is a textbook transactional
outbox: the Ghost DRAFT post tagged `#item-request-queue` is the outbox row, the Worker's
`POST /notify` is the publish, and `Remove-QueueDraft $q.postId` at line 105 is the `processed_on`
stamp. The stamp is per item and inside the loop, which is the right shape and better than the
course's own implementation.

**The residual.** The publish and the stamp are in two systems, so there is a window: the Worker
returns `ok`, `Remove-QueueDraft` throws, the draft survives, and tomorrow's run matches the same
queued request against the same board id and sends the same person the same email. There is
**no attempt counter and no terminal state on the draft**, so a request whose delete can never
succeed is retried daily with no upper bound. The `catch` around the send does not cover the delete.

**Nothing would notice.** `grocery/audit-alert-precision.ps1` measures whether an alert was RIGHT.
Nothing in the estate measures whether one was sent TWICE, and there is no dead-letter convention to
fall back on: `dead letter` and `dead-letter`, case-insensitive, return **zero** hits across
first-party `.ps1`, `.py` and `.md` under `grocery`, `meal-prep`, `graph`, `ops`, `lib` and `design`,
worktrees excluded, measured 2026-09-08.

**What it would touch.** `grocery/notify-item-added.ps1` only. The cheapest fix is an attempt count
plus a terminal tag on the draft itself, because the draft already IS the durable row - no new store
is needed. A `try`/`catch` around `Remove-QueueDraft` that logs a distinct DELETE-FAILED line would
at least make the condition visible, which it currently is not.

**Why it matters here.** This is a live paid site and the recipient is a member of the public who
asked once for one thing. A duplicate is a small harm; an unbounded daily duplicate is not.

### I90 - `meal-prep` reads `grocery/out` directly in 36 scripts and nothing declares the dependency `DONE - THE RATCHET EXISTS AND IT FIRES` `queue-6` `2-WAY` `RUNG1 BUILD`

**`[CLOSED 2026-09-09. `ops/audit-cross-module-reach.ps1`, a ratchet in `run-gates`, baseline 136.]`**

**The detector draws the line the founding grep could not:** `public/board.json` and `content/` are the
PUBLISHED contract and reading one is the contract working; `grocery/out`, `meal-prep/db`,
`graph/state`, `graph/learning` and `sidecar/out` are INTERNALS, and reaching into one from another
module is the finding. That is the distinction that matters, because the internals are gitignored,
which is exactly why a worktree or a CI runner prices nothing and exits 0.

**Measured 2026-09-09 over 528 first-party `.ps1` files (worktrees, `archive/` and `grocery/out`
excluded): 136 code sites in 45 files, plus 18 comment sites.**

| direction | code sites |
|---|---|
| `meal-prep` -> `grocery` | 65 |
| `ops` -> `grocery` | 41 |
| `grocery` -> `meal-prep` | 24 |
| `lib` -> `grocery` | 15 |
| `lib` -> `meal-prep` | 14 |
| `ops` -> `meal-prep` | 6 |
| `lib` -> `graph`, `graph` -> `grocery`, `graph` -> `sidecar` | 2, 1, 1 |

**Two improvements on the founding measurement, and they change the number's meaning.** It counts
**sites, not files** - the founding `grep -rl` counted a file once however many times it reached, and
`lib\pipeline-commit.ps1` alone holds 16. And it **splits code from comment**: only code is ratcheted,
because a comment naming a path is documentation, and gating it would push people to delete the
explanation rather than the coupling.

**Confirmed: the dependency runs both directions**, which `RUNTIME-MAP.md` describes as producer and
consumer. `grocery` reaches into `meal-prep/db` 24 times.

**A ratchet, not a gate, deliberately.** 136 is what it is today and a gate red on day one teaches
people to ignore red. The high-water mark may only go DOWN, and `-UpdateBaseline` **refuses to raise
it** rather than quietly recording a regression.

**Verified by making it fire, not by assuming it would:** self-test 11 of 11 exit 0; a one-line probe
script added under `meal-prep/` moved it to 137 and the audit exited **2** naming both numbers,
`-UpdateBaseline` then **refused** the raise, and removing the probe returned exit 0. `run-gates` exit
0, `pass=283 fail=0`, up from 281 - the self-test and the static entry are both discovered.

**Three of my own defects, all caught by this estate's existing gates rather than by me.** The
dead-detector check refused a detector nothing in production calls, which is how it ended up wired into
`run-gates` instead of sitting inert; `audit-fixture-vocabulary` caught a case I had labelled `CLEAN
TWIN` that asserted an **absence** (that is `MUST NOT FIRE`, and a real clean twin was written in its
place); and `audit-arg-binding` caught the missing `[CmdletBinding()]`.

**SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing.** It matches literal paths in
both slash directions and cannot see a path assembled at run time (`Join-Path $mp $sub`), read from
config, or reached through a variable set three files away. **136 is a floor**, exactly as the founding
36 was. **What it still does not do is declare the dependency** - there is no manifest, and a module
boundary that is only ratcheted is still not one that anything can read.

**Merged from `design\backlog-inbox\lane-event-driven-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** `grep -rl` over first-party `.ps1`, worktrees excluded, measured 2026-09-08:

- **72 of 187** `meal-prep` scripts (38.5%) mention `grocery`
- **36** `meal-prep` scripts reference `grocery/out` or `grocery\out` specifically
- **35 of 383** `grocery` scripts (9.1%) mention `meal-prep`

**What that means.** `docs/RUNTIME-MAP.md` describes these as producer and consumer over the git bus,
but the dependency runs both directions and, more to the point, it reaches into a module's **working
directory** rather than its published artefact. `public/board.json` is the published contract and
`grocery/out/comparison-*.json` is the internals - and the internals are gitignored, which is exactly
why a worktree, a CI runner or a clean checkout prices nothing and exits 0.

**Nothing declares it, so no gate can see it.** A PowerShell script takes a dependency by writing a
path string. There is no manifest, no reference list and no declared module boundary anywhere in the
estate, so a new cross-module reach is invisible at review time and at gate time both.

**The count is a floor, not a coupling metric.** A file-level `grep -rl` counts a mention in a comment
the same as a read. It is enough to establish that the boundary is not enforced; it is not enough to
say how much is real coupling, and no cheaper measurement of that exists today.

**What it would touch.** A new detector under `ops/` that reads first-party `.ps1` for cross-module
path literals and ratchets a high-water mark downward, in the shape of `audit-write-seam` and
`audit-fact-claims`. Deliberately a ratchet, not a hard gate: the number is 36 today and a gate that
is red on day one teaches people to ignore red.

### I91 - the Worker `/notify` shared secret is a deterministic function of the Ghost admin key, with no expiry or rotation path `PARKED - RULED BY BRAD 2026-09-08: OPTION A, ACCEPT IT, AND THIS IS THE RECORD` `queue-6`

**`[RULED 2026-09-08. Brad chose A: accept the current arrangement, and record that it is a decision.]`**

**What is accepted.** `grocery/notify-item-added.ps1` lines 33-36 derive the `X-Notify-Auth` header as
the **SHA-256 hex of `GHOST_ADMIN_KEY`**, and the Worker recomputes the same value. The key itself
never travels, which is the point of the design and is a real property worth keeping. The derived
credential has **no expiry, no rotation procedure and no revocation independent of the admin key** -
so rotating it means rotating the Ghost admin key, which is also what publishes every recipe card.

**Why A is defensible, and it is the reasoning being ratified rather than the convenience.** One
person, one machine, two systems Brad owns, one Worker route. The alternative that is genuinely
better engineering - a client-credentials grant against an identity provider with short-lived tokens
(option C) - is a **service Brad would have to run**, and that is disproportionate for this. Option B,
a second `/notify`-only secret, was the recommendation and was declined; it is recorded here so the
next reader sees it was considered rather than missed.

**THE THING THIS RULING ACTUALLY CHANGES, and it is the whole reason to write it down.** Until today
the arrangement was in force **by default rather than by decision** - which is the identical shape
I36 just resolved for the logs. *A stated forever is a policy; an unstated forever is an accident
that looks identical.* It is now stated.

**THE TRIGGERS THAT REOPEN THIS**, written now because they are the part nobody re-derives:

1. **Any suspicion the Ghost admin key has leaked.** `/notify` is compromised at the same instant and
   there is no way to revoke one without the other. This is the accepted risk, and its bound is that
   `/notify` reaches a member of the public by email.
2. **A SECOND consumer of the derived secret.** One route sharing one secret is proportionate; two
   routes sharing it means a compromise of either is a compromise of both, and B stops being
   optional.
3. **Any move off a single-operator estate.**

**Related and still unowned, unchanged by this ruling:** no skill in the store owns service identity
and access control. `OAuth`, `OpenID` and `JWT` are clean no-matches over 1,350 sections, and
`security-craft` is scoped to adversarial input against LLM systems - its own "does not own" section
says so. That gap is real and is not this item.

**Merged from `design\backlog-inbox\lane-event-driven-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** `grocery/notify-item-added.ps1` lines 33 to 36, read 2026-09-08. The auth header
`X-Notify-Auth` is the SHA-256 hex of `GHOST_ADMIN_KEY`; the Worker recomputes the same value. The
key itself never travels, which is the point of the design and is a real property.

**What it does not have.** The derived credential has no expiry, no rotation procedure recorded
anywhere, and no revocation independent of the admin key: rotating the secret means rotating the
Ghost admin key, which is also what publishes every recipe card. So the blast radius of a rotation is
the whole publish lane, and the practical consequence is that rotation never happens.

**Why this is a ruling and not work.** The estate is one person and one machine, and there is a
defensible position that a long-lived shared secret between two systems Brad owns is proportionate.
The course's alternative - a client-credentials grant against an identity provider with short-lived
tokens - is real but is a service Brad would have to run. **The decision is whether the estate wants
a rotation procedure at all**, and if so whether a second, `/notify`-only secret independent of the
admin key is the cheap version. Nobody should build either until that is ruled.

**Related and unowned.** No skill in the store owns service identity and access control. `OAuth`,
`OpenID` and `JWT` are clean no-matches over 1,350 sections, measured 2026-09-08; `security-craft` is
scoped to adversarial input against LLM systems and its own "does not own" section says so. This is
reported to the orchestrator as a proposed domain and is NOT routed anywhere.

### I92 - A promotion hold latches forever and does not record what it latched against `DONE - CADENCE RULED, AND THE RE-TEST PROVED THE HOLDS RIGHT` `queue-6` `2-WAY` `RUNG1 BUILD`

**`[CLOSED 2026-09-09. Brad ruled: schedule the READ, never the clear; and re-test both live board-class holds.]`**

## The cadence, and what it is NOT

**`--recheck-holds` now runs daily** from `capture-watchdog` check 5a3a. It is read-only - promotes
nothing, clears nothing, runs no guard suite - so a daily run costs one board read and can change no
state. **The CLEAR never runs on a timer.** Sixteen holds sat unexamined for nineteen days and thirteen
turned out to be inert; nobody could have known that without looking, and the recheck existing was not
the same as the recheck being run.

## The distinction that decides whether a hold can EVER expire, and age is not it

The report now classifies every hold by **reason class**:

| class | means | can it expire? |
|---|---|---|
| `identity` | the pattern claims the **wrong product** - a cross-claim, a wrong FORM, a measure-kind mismatch | **never.** No board rebuild makes it true |
| `board` | it disagreed with its own link **on one board**, weeks ago | yes - these are the only real candidates |
| `unclassed` | the reason cannot be read | reported as such, **never guessed into a bucket** |

Live: **identity 3, board 13, unclassed 0 of 16.** `kosher-salt` is the identity case that decided the
whole ruling - its pattern matches "Sea Salt, Coarse, Kosher" and always will, so **a timer-based
expiry would have re-armed a known-wrong claim on a live board.**

## The re-test, and it returned a result nobody predicted

Brad approved re-testing the two live `board`-class holds. Both were released, `--gated` promoted
exactly those two, rebuilt the board and ran the guard suite. **Both FAILED, with the same factors as
19 days and roughly 19 board rebuilds earlier:**

| commodity | 2026-08-21 | 2026-09-09 re-test |
|---|---|---|
| `balsamic-vinegar` / Family Fare | 1.59x unit-basis outlier | **1.59x**, board=0.2465 link=0.3914 [Alessi Balsamic Vinegar 12.75 Oz] |
| `green-olives` / Aldi | 0.54x unit-basis outlier | **0.54x**, board=0.4271 link=0.229 [Tuscan Garden Manzanilla Olives] |

**So "re-testable" did not mean "transient".** The classification was right about the KIND of claim
and the evidence now says these particular two are **stable defects, not board accidents** - which is
exactly the sort of thing that can only be learned by running it. The generic auto-hold reasons were
replaced with the measured causes, as `record_holds` itself instructs.

**The tree came back clean:** `commodities.json` is **byte-identical** to its pre-test md5, the holds
file is back to 16 with the two re-recorded carrying today's date and `board_week`, and
`guards.ps1` on the live board is **exit 0, hard=0, "Safe to publish."**

**Verified:** self-test **24 of 24** (10 must-fire, 8 must-not-fire, 5 clean twins). `run-gates` exit 0,
`pass=293 fail=0`.

**A limitation worth stating: the classifier reads PROSE.** Wording moved a hold between classes twice
in one session - once because two identity reasons said "wrong FORM" and "measure-kind mismatch"
rather than "cross-claim", and once because my own re-test reason said "1.59x factor" rather than
"outlier". Both are fixtures now, but it is only ever as good as the vocabulary the guards happen to
use, and a new guard phrasing will land in `unclassed` until someone teaches it.

**Also still open, and unchanged:** nobody has adjudicated whether the *other* held patterns should
ever be learned. Thirteen are inert today, which means promoting them could not move a cell - not that
they are right.

**`[RUNG 1 SHIPPED 2026-09-08. The latch now has an inspection port. Whether it also gets an
automatic reset is the ruling inside this item and it is untouched.]`**

## What was actually held, measured rather than quoted

`--recheck-holds` on the live board: **16 patterns across 10 commodities, every one held
2026-08-21 - 18 days, against a board rebuilt daily ever since.**

**The item's own docstring says "141 promoted clean and 15 are held". It is 16.** And the repeats
are NOT duplicates: 16 rows, **16 distinct (commodity, pattern) pairs** - `green-olives` and
`insect-spray` each hold three different patterns under one shared reason. Checked rather than
assumed, because a de-dupe of legitimate rows would have silently re-armed three aliases.

## The answer, over 3,177 store rows on `comparison-2026-09-08.json`

| | |
|---|---|
| MOOT - the learner no longer proposes it | **0 of 16** |
| CONTRADICTED - already in `commodities.json` | **0 of 16** |
| **INERT TODAY - matches no row on today's board** | **13 of 16** |

**Thirteen of the sixteen could not move a single cell if they were promoted this morning.** They
are not costing the board anything today, which is the opposite of what "a standing, invisible loss"
implied - and it is only knowable because somebody looked.

**Three are live, and one of them visibly proves itself STILL RIGHT:**

| commodity | board rows | what it would newly claim |
|---|---|---|
| `balsamic-vinegar` | 6 | `Fareway Balsamic Vinegar` |
| `green-olives` (stuffed) | 4 | `Member's Mark Pimento Stuffed Manzanilla Olives, 2 pk.` |
| `kosher-salt` | 1 | `Our Family Sea Salt, Coarse, Kosher 16 Oz` |

**The kosher-salt hold was recorded because its pattern *cross-claims the sea-salt cell*, and the one
row it still matches is that exact cell.** The hold is 18 days old and still correct. That single row
is the argument against any automatic expiry: a hold that ages out on a timer would have re-armed a
known-wrong claim on a live board.

## What shipped

- **`--recheck-holds`**, read-only. Promotes nothing, clears nothing, **does not run the guard
  suite**. Four independent signals per hold, each with its denominator: age, still-learned,
  in-catalog, and board matches with an example. It turns *"16 permanently held, nobody knows"* into
  *"3 need a human, 13 are inert, and here is which."*
- **An absent board reports BLIND, never inert.** `grocery/out/comparison-*.json` is gitignored, so a
  worktree has none, and reporting every hold as harmless there is the confident wrong zero this
  estate keeps paying for.
- **The auto-hold path now records what it latched against.** `record_holds` wrote the literal string
  `"gated-run"` into the `held` field, so an automatic hold **could never be aged** - a recheck could
  not tell one written this morning from one written in August. It now writes a real ISO date, keeps
  the provenance in `held_by`, and adds **`board_week`**, the board its reason was true of. A hold
  that records neither a cause nor a board is unfalsifiable, and that is exactly what the automatic
  path used to write.

**Verified:** new `--selftest`, exit 0 over 9 cases, discovered by `run-gates` as a Python suite -
led by the must-fire that a hold whose stated cause is still on the board keeps its evidence (so a
correct hold is not cleared), and by the one separating an UNPARSEABLE pattern (returns `None`) from
one that matches nothing (returns `[]`), because a hold retired for a rotted regex is a different
failure from one retired for being inert. `run-gates` exit 0, `pass=280 fail=0`, up one. The live
recheck and the normal `--dry-run` both ran and **wrote nothing** - `promotion-holds.json` and
`commodities.json` unchanged.

## What is NOT done, and it is the ruling

**Nothing was cleared and no hold was re-tested against the guard suite.** Clearing one still means a
full compare-deals plus guards cycle, exactly as the file's own note has always said. **The question
Brad has not answered: should holds be re-tested on a cadence, or only on an explicit run?** The
evidence now available to answer it: on-demand costs nothing and is what exists; a cadence costs a
full cycle per batch and **could re-admit an alias that breaks the board on a day nobody is watching**
- and the kosher-salt row shows that is not hypothetical. Written up beside the other rulings in
`design/RULINGS-2026-09-08.md`'s sibling I93.

**Also unresolved:** the three live holds are candidates for a human, not verdicts. Nobody has
adjudicated whether `Fareway Balsamic Vinegar` or the Member's Mark stuffed olives should now be
learned.

**Merged from `design\backlog-inbox\lane-feedback-systems-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

`graph/learning/promote_aliases.py` `gated()` is a genuine closed feedback loop and the best-built
corrector in the estate: promote aliases into the catalog, run the live guard suite as the sensor,
withhold whatever the guards accuse as the actuator, repeat to `--max-rounds`, restore the tree from
a backup at the start of every round, and promote nothing if it never converges. It refuses to start
on a red baseline (line 150) and stops rather than guessing when the failure names nothing it
promoted (line 215). Bound, fail-safe and sensor plausibility check are all present.

The gap is the **actuator has no reset path**, and control theory has a name for that shape: a
latching actuator, whose corrective action persists after the disturbance that justified it is gone.

Two concrete halves:

1. **The holds never expire and nothing re-tests them.** `graph/learning/promotion-holds.json` holds
   patterns permanently. Its dated entries are `"held": "2026-08-21"` with reasons such as
   *"guards 2026-08-21: 1.59x unit-basis outlier vs its own link (Alessi 12.75 Oz)"*. Those reasons
   are statements about the state of the **comparison board on one day**, and the board is rebuilt
   daily. Roughly eighteen rebuilds later the condition that produced the hold has almost certainly
   changed, and nothing in `promote_aliases.py` re-evaluates it. There is no `--recheck-holds`, no
   expiry field, and `held()` (line 78) only ever reads the file.

2. **The gated run records holds with no diagnosable condition.** `record_holds` (line 251) writes
   `"held": "gated-run"` and the generic reason *"the guard suite hard-failed naming this commodity,
   and went green once it was withheld"*, then prints a NOTE asking a human to replace it, because
   *"the gate said no" is not a diagnosis*. Nothing enforces that. A hold written by the automatic
   path therefore cannot be re-evaluated even by hand, because it does not say what to re-check.

**Why it matters here.** A held alias is an alias the board never learns, so the identity graph stays
permanently weaker for a reason that may have expired weeks ago. `promote_aliases.py`'s own docstring
says 141 promoted clean and 15 are held; those 15 are a standing, invisible loss.

**What it would touch.** `graph/learning/promote_aliases.py` (`held`, `record_holds`, a new recheck
path), `graph/learning/promotion-holds.json` (a schema addition), and its must-fire fixture.

**The ruling inside this item, which is Brad's:** should a hold be re-tested automatically on some
cadence, or only on an explicit `--recheck-holds` run? Automatic re-testing costs a full
compare-deals plus guards cycle per hold batch and could re-admit an alias that breaks the board on a
day nobody is watching. On-demand is safe but is the state we already have, because nobody runs it.

---

### I93 - The estate's two one-directional actuators do not share their safety machinery `DONE - ACTUATOR FIXED, SHAPE NAMED, REGISTER BUILT, DETECTOR SHIPPED` `queue-6` `1-WAY` `RUNG1 RULING`

**`[CLOSED 2026-09-09. Brad ruled: all of it - the actuator, the rule, the register and the detector.]`**

**1. The live hazard is closed.** `graph/learning/promote_aliases.py` now carries the rate limit and
plausibility bar that `lib/ratchet.ps1` already had. It refuses a batch over
`MAX_NEW_HOLDS_PER_RUN = 10`, **keeps the existing file**, and says so, with `--accept-holds` as the
deliberate override. Before this, one degraded guard run naming many commodities would have latched a
**permanent** hold for every one of them in a single pass, since holds never expire. **What else was
tried: nothing.** 10 is the first plausible value, grounded on the live set of 16 holds across 10
commodities - a batch bigger than that grows the whole hold set by more than half - and is explicitly
not the survivor of a sweep. Self-test **15 of 15**.

**2. The shape is named** in `.claude/rules/ops-and-gates.md`: *a control constant that may only move
ONE WAY needs a rate limit and a plausibility bar.* With the half that gets forgotten: **refusing is
not enough - the old state must be KEPT and the refusal SPOKEN**, or a run that declined to act is
indistinguishable from a run with nothing to do.

**3. The register exists:** `docs/CONTROL-CONSTANTS.md`, nine constants with their direction, what each
does **when the producer stops**, and how each was tuned. **Most rows say "not recorded" and that is
the honest state** - I94 established the convention going forward and explicitly did not ask for
retro-fill, so only the constants added since carry it.

**4. The detector ships as a REPORT:** `ops/audit-one-way-actuators.ps1`, in `run-gates` at exit 0.

**IT FOUND ONE REAL DEFECT, AND I NARROWED IT TWICE BEFORE SHIPPING RATHER THAN SHIP NOISE.** The first
sweep returned **32 findings over 63 files and nearly all were false**: it matched the bare word
`ratchet`, so it flagged `grocery/audit-null-rate.ps1` **while that file explicitly says the ratchet
asymmetry does not apply to it**, and flagged `ops/run-gates.ps1` for listing ratchet-shaped gates in
its comments. A report that is mostly wrong is one people learn to skip, which is the same failure as a
gate red on day one. Narrowing the latch words to phrases that assert a file's own state latches, and
counting a call to the shared ratchet library as a guard, took it to **4**.

**Of those 4, exactly 1 is real** - and I read all four rather than reporting the count:

| file | verdict |
|---|---|
| `grocery/audit-json-readers.ps1` | **REAL.** A high-water mark that "may only go DOWN" whose tighten branch lowered the baseline **unconditionally** |
| `grocery/audit-asof-evidence.ps1` | false positive: prose about a carry cap that "can never expire" a row |
| `grocery/build-sale-windows.ps1` | false positive: everyday price chips "never expire" |
| `meal-prep/pipeline/repair-basis-relabel.ps1` | false positive: a comment about a case that "can never expire" |

**The real one is fixed.** `audit-json-readers.ps1` was the exact defect `lib/ratchet.ps1` exists for -
its header records four audits that each lowered a mark unconditionally - and it had never adopted the
library. A run that scanned fewer files, or whose pattern rotted, would have written its own blindness
in as a permanent ceiling and printed a pass forever. It calls `Test-RatchetMove` now.

**Verified by making it fire on the live file:** the baseline is 0 today so the branch cannot run, so a
baseline of 10 was planted - the audit exited **2**, said *"found NOTHING where the baseline is 10"*,
**left the baseline file byte-identical**, and the tree returned to exit 0 when restored.
`run-gates` exit 0, `pass=293 fail=0`.

**SCOPE OF THE DETECTOR'S CLEAN REPORT: UNSOUND, and stated in its header.** "One-directional" is a
property of a design, not a spelling. **Its measured precision on this corpus is 1 in 4.** A finding is
worth reading; silence proves nothing.

**Merged from `design\backlog-inbox\lane-feedback-systems-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

`lib/ratchet.ps1` exists because four audits each lowered a high-water mark unconditionally, so a
broken detector finding nothing would record 0 as a permanent ceiling and print "PASSED and
TIGHTENED" forever. `Test-RatchetMove` now refuses a fall to zero and a fall larger than
`-MaxDropPct` (default 60), keeps the old baseline, and reports. In control terms that is a **rate
limit on a one-directional actuator plus a sensor plausibility check**, and it is exactly right.

`promote_aliases.py`'s hold mechanism is the estate's *other* one-directional actuator - it can only
ever withhold more - and it shares none of that machinery. It has a per-run baseline check, but no
rate limit: a single degraded guard run that hard-fails naming many commodities would record a hold
for each of them, permanently, in one pass. There is no equivalent of "a drop this large is
extraordinary, keep the old state and report".

**The ruling:** is there a general shape here worth naming - *a control constant that may only move
one way needs a rate limit and a plausibility bar* - and if so, does it become a third caller of
`lib/ratchet.ps1`, a documented convention, or a `run-gates` detector that finds one-directional
state writes with neither guard? A detector is the cheapest and the most likely to go stale; a
convention is free and unenforced. This is not obvious and it is a design call, not work.

Adjacent, and part of the same question: the estate has no register of its **control constants**.
`$script:BoardStaleHours = 26` and `$script:NeverRanGraceHours = 30` in
`grocery/capture-watchdog.ps1`, `$REARM_DAYS = 14` in `grocery/check-ad-cycles.ps1`, and
`-MaxDropPct 60.0` in `lib/ratchet.ps1` are all tuning parameters of correcting loops, each declared
locally with a good comment and none of them listed anywhere together.
`sidecar/THRESHOLDS.md` is the precedent for what such a register looks like, and it covers score
spaces rather than these.

---

### I94 - Nothing records how a threshold in this estate was tuned `DONE - THE CONVENTION IS IN THE RULES FILE, 2026-09-08` `queue-6`

**`[CLOSED 2026-09-08.]`** `.claude/rules/ops-and-gates.md` now says a tuning constant records
**what else was tried**, not just what it means. `measurement.md` already held that rule for scores -
*a number that moved is not a number that improved: say how far, over how many cases, and how many
variants were tried* - and it did not reach the control constants. It does now.

The named cases stand: `$script:BoardStaleHours = 26`, `$REARM_DAYS = 14`, `-MaxDropPct 60.0`. Each
carries a good comment saying what it means and, at best, which incident produced it. **None says
whether it was the first plausible number or the survivor of a sweep, and those are different
claims.** The course's own demonstration is recorded with it: three simulations at gains 25, 13 and
7.5 do not establish a stable range - nothing rules out instability higher or stability lower, and
the stable set need not even be an interval.

**Retro-filling the existing constants is NOT proposed and was not done**, per the item. The ask is
that the next one added carries it. **A `run-gates` detector for this was considered and rejected**:
it would have to parse intent out of a comment, which is precisely the free-text-signal defect I63
was about.

**Still not measured, and the item says so:** whether `sidecar/THRESHOLDS.md`'s rows carry their
variant counts. That file was not opened on this run either.

**Merged from `design\backlog-inbox\lane-feedback-systems-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

Course finding, module 5: an instructor showing three simulations at proportional gains 25, 13 and
7.5 says explicitly that they do **not** establish the stable range - nothing rules out instability
again at a much higher gain, or stability again below 7.5, and the stable set need not even be an
interval. That is why an analytic criterion exists at all.

The estate's control constants above each carry a comment saying what the value means and, in the
best cases, which incident produced it. What none of them records is **how many values were tried**.
`grocery/capture-watchdog.ps1:73` says `BoardStaleHours = 26` with a dated queue reference;
`check-ad-cycles.ps1:2311` says `$REARM_DAYS = 14` with a reasoned comment. Neither says whether 26
and 14 were the first plausible numbers, or the survivors of a sweep.

This is `.claude/rules/measurement.md`'s existing rule - *a number that moved is not a number that
improved: say how far, over how many cases, and how many variants were tried* - applied to tuning
constants rather than to scores, and the rule does not currently reach them.

**What it would touch.** A one-line convention for the comment beside any tuning constant: the value,
what it means, and **what else was tried**. Retro-filling is not proposed; the ask is that the next
constant added carries it. Whether that becomes a `run-gates` detector is a separate question and
probably not worth it.

**Not measured on this run.** Whether `sidecar/THRESHOLDS.md`'s rows carry their variant counts was
not checked - the file was not opened.


### I95 - every threshold here is tuned on a sample the threshold itself selected `DONE - THE NEAR-MISS ROW IS BEING WRITTEN, 2026-09-09` `queue-6`

**`[CLOSED 2026-09-09 for the half that could be built. The alert half is measured and is Brad's,
exactly as the item predicted.]`**

**The finding, restated because it is the reason this could not wait:** a filter learns from what it
DELIVERED, because that is the only thing anybody judged. That history is not a random sample - it is
exactly the set the current threshold let through - so optimising on it recovers only an **upper
bound**. The threshold does not wander; it **ratchets toward silence**, because the only failure it
can ever observe is a false alarm.

## Shipped: the recall side

`~/.claude/skills/recall-hook.py` now writes an `ev: "nearmiss"` row carrying the best candidate that
did NOT clear the bar, per leg, with `score`, `floor`, `margin`, `offered`, `sid` and `agent`.

**Two design points that are the whole difference between this working and not:**

1. **The row is written ABOVE the `if not picked: return 0` early return.** A turn where NOTHING
   cleared the floor is the turn whose near miss matters most - it is the one case that can argue the
   floor is too HIGH - and the offer-logging block is never reached on that path. Writing it beside
   the offers would have recorded near misses only for turns that already succeeded: **the censored
   sample this item is about, reproduced inside the fix for it.**
2. **The semantic leg now asks with `floor=0` and applies the cut in the hook.** Same top-k, same
   single round trip - the cut is a filter on the result, not a different query - and it is the only
   way the hook can see a candidate the sidecar already discarded. The *empty-means-nothing* signal
   is preserved, so a leg that reached the index and found nothing close enough still stops instead
   of falling through to the weaker lexical retriever, which was a real bug fixed 2026-09-08.

**A defect of my own, caught by reading the first rows it wrote.** I filed the BM25 index leg and the
cosine semantic leg under one leg name, so the collector kept the **max across two scales that do not
share one** - the exact defect `sidecar/THRESHOLDS.md` exists to prevent. They are `lexical-index`,
`lexical-fallback` and `semantic` now, each carrying its own floor on the row.

**Verified:** self-test 15 of 15; driven on three real prompts; rows read back. **The first real near
miss recorded is worth quoting**: *"what should I make for dinner tonight"* scored **8.42 against a
floor of 8.5 - margin 0.08**. That is the off-topic prompt the floor was derived to reject, and it
came within a tenth of clearing. Nothing in the estate could previously have known that.

## The alert side: measured, and it is bigger than a log line

The item's own open question was *"whether the daily chain currently computes a score for conditions
it drops, or whether they never get scored at all. If it is the second, the item is bigger than a log
line and the ruling is Brad's."*

**It is the second.** `grocery/send-alert.ps1` carries no scoring of any kind - alerts are raised by
audits that either find something or do not, and a condition that is not raised is never given a
number. So there is no near-threshold value to log; **building one means giving the audits a score
they do not currently have**, which is a design change to the daily chain rather than a row.

`grocery/audit-alert-precision.ps1` remains structurally unable to see the near miss, and that is now
recorded rather than latent. **The estate's one escape from this trap still stands as the model:**
`sidecar/derive_coverage_floor.py` derived the matcher's floor from 2,816 labelled pairs - evidence
from OUTSIDE the delivery loop - and found the hand-chosen 0.55 was **too high**, with 186 correct
pairs beneath it.

**Merged from `design\backlog-inbox\lane-text-retrieval-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** "Text Retrieval and Search Engines" (ChengXiang Zhai, UIUC), week 6, routed to
`rag-craft/thresholds-and-filtering.md` 53. The course states it about news filtering and it is a
property of the training sample, not of the scorer, so it transfers to anything with a cutoff.

**The finding.** A filter learns from what it delivered, because that is the only thing anybody
judged. That history is not a random sample - it is exactly the set the current threshold let
through - so optimising the threshold on it can only ever recover an **upper bound** on the true
optimum. The threshold might belong lower, and no amount of data collected through the current
threshold can show that, because the items below it were never delivered and never judged.

**Where it lands here, and this one is exact.** `grocery/audit-alert-precision.ps1`'s own header says
what it measures: "how often each alert, **when it fires**, is actually right." Its whole input is
firings, by way of the dispositions `grocery/triage-close.ps1` records on closed items. That file is
already careful about the two things it can see - it prints the denominator, and it refuses a
precision under `-MinCases` rather than quoting a coin flip. **What it structurally cannot see is the
near-miss**: the condition that scored just under the bar and never became an item. So every
disposition this estate has ever recorded is evidence about whether the threshold is too LOW, and
none of it is evidence about whether it is too HIGH.

The same shape holds for `~/.claude/skills/recall-hook.py`'s `MIN_SCORE`/`MIN_COSINE`:
`recall-log.jsonl` records offers, `recall-leg-log.jsonl` records which leg won, and neither records
the top candidate that failed the floor.

**Why it matters rather than being a curiosity.** It gives the drift a direction. A threshold
measured only through itself does not wander; it **ratchets toward silence**, because every piece of
evidence it can gather comes from firings, and the only failure it can observe is a false alarm.
Nothing in the loop can ever argue for firing more.

**It is not I94, and it sharpens I94.** I94 is that nothing records how many values were TRIED for a
tuning constant. This is that even a full sweep of values, scored honestly, would find the wrong
answer, because the scoring set is censored. Both want the same one-line fix in different places.

**What it would touch.** One row: on every evaluation, log the best-scoring candidate that did NOT
clear the bar, with its score. For the alert side that is the near-threshold condition the daily
chain considered and dropped; for the recall hook it is the top section under the floor. It is the
only row that can ever show a floor belongs lower, and it cannot be backfilled - the same shape as
`.claude/rules/measurement.md`'s E24 rule about writing one row per case per arm.

**`[CORRECTED 2026-09-08, hours after filing, by this run's own review pass.]` THE ESTATE HAS
ALREADY SOLVED THIS ONCE, FOR ONE THRESHOLD, AND IT WORKED.** `sidecar\derive_coverage_floor.py`
refuses to let the matcher's coverage floor be chosen by hand and derives it from **2,816
confirmed-correct labelled pairs** - evidence from outside the delivery loop, which is exactly the
escape the finding above prescribes. What it found is what the finding predicts a self-measured
threshold can never find: the hand-chosen `COVERAGE_COS_FLOOR = 0.55` was **too high**, with 186
correct pairs beneath it, and the derived replacement is **0.3848** (`sidecar\out\coverage-floor.json`,
deliberately not yet applied, backlog I13/I14 and E19).

So this item is not "the estate is naive about its thresholds". It is **narrower and more
actionable**: the estate has the pattern, has run it, and has been vindicated by it, on exactly one
of its thresholds.

**Why the alert bar cannot simply copy it.** The matcher had a labelled set to derive from. Alert
conditions have no equivalent corpus and acquiring one would mean judging conditions nobody ever
saw. That is why the near-miss row is the right instrument there rather than a second-best one: it
is how a labelled set below the bar would get built in the first place.

**What was NOT measured on this run.** Whether the daily chain currently computes a score for
conditions it drops, or whether they never get scored at all. If it is the second, the item is bigger
than a log line and the ruling is Brad's.

### I96 - the estate's headline matcher number is arithmetic-mean and so is blind to its hardest cases `DONE - THE TAIL VIEW PRINTS BESIDE MRR, BEFORE THE NEXT COMPARISON, 2026-09-08` `queue-6`

**`[CLOSED 2026-09-08.]`** `sidecar/matcher_eval.py` now prints three lines beside MRR: **gMRR**
(the geometric mean of the reciprocal ranks), the **unranked count** with its denominator, and **how
many cases are still past rank 10** - the population any tail improvement has to move.

**Why the geometric mean specifically.** MRR is an arithmetic mean of `1/r` and is dominated by its
LARGE values, which are the EASY cases; the geometric mean is dominated by the small ones. The
fixture pins the exact blind spot: moving one case from **rank 100 to rank 40** moves MRR by under
0.02 while moving gMRR by more than twice as much. **So a change that helps only the hardest rows was
close to invisible in the estate's headline matcher number, and a change that helps the already-good
rows was not.**

**Neither statistic is claimed to be correct**, which is the honest position and is written into the
docstring - MAP and gMAP can rank two systems differently and neither is right in general. They are
printed together so that **MRR up with gMRR flat** reads as *the easy rows got easier*.

**The abstention rule is NOT weakened, and a clean twin pins that.** An unranked case still
contributes 0 to MRR, per E20. It is EXCLUDED from gMRR because one zero takes a geometric mean to
zero - true and useless - so the unranked COUNT is printed beside it every time. gMRR is never shown
without its denominator.

**Verified:** `matcher_eval.py --selftest` exit 0, 21 cases, up from 16 - one must-fire (the
rank-100-to-40 case), one must-not-fire (a perfect run scores 1.0 on both), three clean twins.
`run-gates` exit 0, `pass=277 fail=0`.

**Nothing about the matcher changed and no matcher comparison was run.** E21 requires the number to
exist BEFORE the next comparison rather than after it, which is the only reason to do this now. The
item's other check stands: no `P@k` comparison exists anywhere, so 14c's insensitivity bug is still
not present.

**Merged from `design\backlog-inbox\lane-text-retrieval-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

**Source.** Same course, week 4, routed to `rag-craft/evaluating-retrieval.md` 14b. MAP is an
arithmetic mean over queries and is therefore dominated by its large values, which are the EASY
queries. gMAP, the geometric mean, is dominated by the small ones. They can rank two systems
differently and neither is correct in general.

**Where it lands.** `sidecar/matcher_eval.py` is this estate's exemplar scorer and it chose its
metrics well - recall@k and MRR, with an explicit must-fire case asserting that an unranked row
lowers MRR rather than vanishing from it, which is the abstention trap handled correctly. Checked and
did NOT find a P@k comparison anywhere, so 14c's insensitivity bug is not present.

**The gap is narrower than that and still real.** `mrr(ranks)` is a plain arithmetic mean of `1/r`.
Reciprocating already compresses the hard end hard: moving a case from rank 100 to rank 40 moves that
case's contribution by 0.015. **So a change that helps only the hardest rows is close to invisible in
the estate's headline matcher number**, and a change that helps the already-good rows is not. That is
the same failure the estate has already written down about rates - `.claude/rules/measurement.md`'s
"a number that moved is not a number that improved" - arriving through the averaging rather than
through the delta.

**What it would touch.** Nothing needs to change today; `matcher_eval.py` reports per-case ranks and
already writes one row per case, so the hard-case view is derivable from data that exists. The ask is
one extra printed line beside MRR - the geometric mean, or simply the count of cases still unranked
at 25 - so that a run which improved only the tail can be told from one that did not. **A number is
needed before the next matcher comparison, not after it**, per E21.

**Explicitly not claimed.** No matcher change has been proposed or measured on this run. This says
the instrument has a blind spot, not that anything was mis-measured through it.


### I97 - Ghost holds every member's signup date and status, and no code here has ever read either for analysis `DONE - RULED AND RUN 2026-09-08, AGGREGATE ONLY; NO PER-MEMBER ROW EXISTS ANYWHERE` `queue-5`

**`[RULED BY BRAD 2026-09-08: option B of three - an aggregate-only pull may happen. Per-member rows
on disk were REFUSED at any price. Built, run, and this is the result.]`**

`ops/member-cohorts.ps1` reads `created_at` and `status` off each member, aggregates **in memory**,
and writes `ops/member-cohorts.json` containing counts only.

**The privacy boundary is ENFORCED, not intended**, and the fixtures assert each rule:

1. **Three permitted properties**, held as a list a self-test pins at three - *a fourth entry is a
   privacy change and must read as one in a diff*. `email` is never referenced by name anywhere.
2. **The output can structurally only hold month strings, status strings and integers.** The
   founding must-fire feeds the aggregator a row that DOES carry an address and a name, and asserts
   neither survives into the aggregate.
3. **No temp file, ever.** There is no intermediate write of any kind.
4. **The output path is asserted BEFORE the first API call** - outside the repo, non-`.json`, and
   relative paths are all refused, each with its own must-fire. Fetching first and validating after
   would mean a bad destination is discovered with the data already in hand.

A last line of defence refuses to write anything matching an address shape even though the structure
cannot produce one. `-WhatIf` asserts the path and fetches nothing; it was run first and did.

**THE ANSWER, 2026-09-08, `MEMBER-COHORTS-COMPLETE members=18 cohorts=2 undated=0`:**

| cohort | total | comped | free | paid |
|---|---|---|---|---|
| 2026-07 | 15 | 7 | 5 | 3 |
| 2026-08 | 3 | 0 | 2 | 1 |
| **all** | **18** | **7** | **7** | **4** |

**The membership is 18 people and 4 of them are paying.** That is the number no file in this repo
held, and it reframes the backlog rather than answering its question: **the constrained layer is
acquisition, not retention.** A retention comparison over 18 members across 2 months has no power at
all, and the script says so in its own output rather than leaving a reader to infer it.

**WHAT THIS CANNOT SAY, and it is the shape of the result rather than a caveat.** Ghost gives CURRENT
status, not a status history. These are **endpoints, not a curve** - a member who cancelled in month
2 and one who cancelled in month 8 are indistinguishable. The shapes carrying the diagnostic value (a
cliff drop against gradual churn, and which period the cliff lands in) cannot come from one snapshot.

**I98 IS THE FIX AND WAS NOT AUTHORISED IN THE SAME RULING**, so it is not started and stays OPEN.
It is a few dozen bytes a month and **every month it waits is a month of curve that cannot be
recovered** - now more sharply, because 2026-07 and 2026-08 are the only two cohorts that exist and
both are already collapsed to endpoints.

**Verified:** self-test exit 0 over 10 cases; `-WhatIf` exit 0 fetching nothing; live run exit 0; and
the written file grepped for an address shape - **zero matches**.

**Run BY HAND.** Not in the daily chain, not in `run-gates`, no schedule.

**Merged from `design\backlog-inbox\cohort-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

Every Ghost members call in the tree is transactional, not analytic:
`worker/index.js:146,170` (find one member by filter, PUT labels), `worker/index.js:328,391`
(read `member.status` at request time to gate paid content), `grocery/send-price-alerts.ps1:103`
(filter members carrying label `alert-<id>`), `grocery/send-friday-digest.ps1` (email all members),
`.claude/skills/lesson/grant-founder.ps1:42-48` (create/update one member),
`.claude/skills/lesson/update-membership-tools.ps1:17`, and the client-side paywall checks in
`grocery/build-deals-page.ps1:1441,2348`.

**`created_at` is never read for a member anywhere.** The only `created_at` reads in the tree are on
graph plan rows, review escalations, and a Ghost *post* query (`grocery/notify-item-added.ps1:59`).
There is no member export, no cohort table, no retention curve, no churn figure and no LTV number in
this repo.

**Why it matters here.** This is a live paid membership. Two businesses acquiring identically diverge
entirely on what fraction of each month's intake is still paying a year later, and that number is
currently unknown. Every acquisition-side item in `BACKLOG-course-findings.md` and every SEO finding
in `growth-craft/applies-here.md` sits on top of it: if month-1 retention is below the floor, the
layer being worked on is above the broken one, which is exactly the failure
`growth-craft/search-position-diagnosis.md` section 1 was written to prevent.

**What it would touch.** One new read-only script - a Ghost Admin API pull of
`id, created_at, status, labels` for all members, bucketed by signup month against current status.
The Admin key already exists and is already used by `send-price-alerts.ps1` and the `lesson` skill,
so no new credential. Method is `growth-craft/cohort-retention.md` sections 1 to 5.

**The ruling needed.** Member emails have never been written to this repo and the export must not
change that - the script must aggregate in memory and commit only the bucketed counts, or write
nothing at all and print. Brad rules on whether a members pull happens at all, and if so whether any
per-member row may touch disk.

### I98 - A point-in-time member export cannot reconstruct WHEN anyone left, so the snapshot has to start before the analysis `DONE - RULED AND RUNNING; THE SERIES STARTED 2026-09-09` `queue-5` `1-WAY` `RUNG1 BLOCKED`

**`[CLOSED 2026-09-09. Brad ruled: start it now, automated, aggregate counts only.]`**

**The first snapshot is taken and committed.** `ops/member-cohorts-history.jsonl`, appended by
`capture-watchdog` check 5a4. Snapshot `2026-09` is **5 rows over 18 members**: July is 7 comped, 5
free, 3 paid; August is 2 free, 1 paid. The rows sum to 18, which is the whole membership.

**Why this had to start before any analysis, restated because it is the entire item:** Ghost holds
CURRENT status and no status history, so a member who cancelled in month 2 and one who cancelled in
month 8 are indistinguishable in any single pull. **The series builds strictly forward and cannot be
backfilled from anything Ghost holds.**

**The privacy boundary is the one Brad ruled for I97 and it is unchanged.** History rows are built from
the same aggregate table, so the structure can hold only month strings, status strings and integers -
no member row, no id, no address, here or anywhere. There is an address-shaped-content refusal on the
append path as well as the rewrite path, because **an append is harder to notice than a rewrite**.
Verified by reading the written file: no address-shaped content, and no `id`, `email` or `name` field.

**Idempotence, and it is the founding bug for a monthly job on a daily chain.** The chain runs every
day; without a guard it would append ~30 duplicate sets a month and turn the series into noise that
still looks like data. **Verified live: a second run on the same day appended nothing and the file
stayed at 5 rows.**

**THE ABSENCE CHECK IS THE HALF THAT MAKES AUTOMATING THIS SAFE.** Per the standing rule, every other
threshold in this estate is an UPPER bound and cannot fire on nothing happening - and the failure mode
here is precisely the producer going quiet, which costs a month of curve silently. `-CheckFresh` fails
at 2 once the newest snapshot passes **40 days**. **What else was tried: nothing. 40 is the first
plausible value** - 31 days plus about a week of slack - not the survivor of a sweep.

**Verified by making it fire rather than assuming:** self-test **21 of 21**; `-CheckFresh` on a
backdated real file exits **2** naming 131 days; on the live series exits **0**; and before the series
existed it exited **3 BLIND**, never 0. `run-gates` exit 0, `pass=287 fail=0`.

**Honest limit: one snapshot is not a curve.** With 2 cohort months and 4 paying members, nothing about
retention is answerable yet, and the script says so in its own output. What changed today is only that
the clock started.

**Merged from `design\backlog-inbox\cohort-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

Ghost's members API gives current status, not a status history. A pull today can say how many
January signups are still paid, but cannot distinguish a member who cancelled in month 2 from one who
cancelled in month 8 - so it yields one endpoint per cohort and not a curve. The curve shapes that
carry all the diagnostic value (cliff drop against gradual churn, and the period the cliff lands in -
`growth-craft/cohort-retention.md` section 4) are exactly what a single snapshot cannot produce.

**This is time-sensitive in a way most backlog items are not.** The cheapest fix is a monthly
committed snapshot of `(signup_month, status) -> count` starting now; every month it is deferred is a
month of curve that can never be recovered. It is a few dozen bytes a month and needs no analysis
built on top of it yet.

**What it would touch.** One aggregate JSON under `graph/state/` or `grocery/out/`, appended monthly
by the existing daily chain. Aggregate counts only, no member rows - which also settles the privacy
half of the finding above.

### I99 - `send-price-alerts.ps1`'s label subscriptions are an already-captured behavioural signal nobody has looked at `DONE - PRE-REGISTERED AND SNAPSHOTTING; THE TEST IS YEARS OFF AND THAT IS THE FINDING` `queue-5` `1-WAY` `RUNG1 BLOCKED`

**`[CLOSED 2026-09-09. Brad ruled: pre-register it and snapshot the counts monthly.]`**

**THE ITEM'S PREMISE IS WRONG IN A WAY THAT CHANGES THE DESIGN.** It describes the label as *"a
per-member, timestamped-by-label opt-in action"*. **A Ghost label carries no per-member timestamp** -
the member either has `alert-<id>` now or does not. So *"set an alert within 30 days of signup"*
**cannot be recovered retrospectively from any pull, ever.** It becomes measurable only going forward,
and only because the monthly series exists, at a resolution of **one month rather than 30 days**. That
is a direct argument for the ruling: the signal was decaying silently.

**Pre-registered in `design/EVAL-alert-retention-2026-09-09.md`, written before any data existed.** The
exposure window, the `>= 1` cut and the bar are fixed there, so a later analysis cannot choose the
split that produces the biggest gap - the third independent arrival of that rule in this estate.

**THE BAR IS 91 MEMBERS PER ARM**, derived rather than asserted: two-proportion test, alpha 0.05,
power 0.80, to detect 50% against 30% retention needs `(1.96 + 0.84)^2 x (0.25 + 0.21) / 0.04 = 91`.

**Measured live 2026-09-09, and it settles the question of whether to analyse now:**

| | |
|---|---|
| members carrying at least one `alert-*` label | **1 of 18** |
| total `alert-*` labels across the membership | **1** |
| exposed arm | **n = 1**, against a bar of 91 |

**So this is not "underpowered", it is a single member.** The honest output is the counts with their
denominators and *"not answerable yet"*, and the script prints exactly that. The reason to snapshot
anyway is that the signal decays if nobody records it.

**Shipped:** `ops/member-alert-history.jsonl`, appended by the same monthly snapshot. Snapshot
`2026-09` is 3 rows: July 14 unexposed / 1 exposed, August 3 unexposed.

**The privacy boundary is tighter here than for I98, deliberately.** A label names a COMMODITY, so
pairing it with a member would be behavioural data about a person. What is derived per member is a
**single integer** and it is bucketed immediately; **no label string is ever kept**, and the append
path refuses outright if one appears in a row. A fixture asserts that a member object carrying both an
email and an `alert-eggs-large` label produces rows containing neither.

**A defect caught before it shipped, and it would have looked like success.** The alert append was
first written inside the cohort snapshot's idempotence branch, so it would have been skipped in any
month whose cohort snapshot was already taken - which is the month it was introduced. The series would
simply never have started, and the run would still have reported exit 0. It has its own check against
its own file now, **verified by watching the alert series start while the cohort series correctly
declined to append a second time.**

**Verified:** self-test **27 of 27** (13 must-fire, 11 must-not-fire, 3 clean twins); the written file
re-read and confirmed to contain no label string and no address; a re-run appended nothing to either
series. `run-gates` exit 0, `pass=287 fail=0`.

**Named for the next reader: confounding is not controlled.** A member who sets an alert is plausibly
more engaged already, so a gap would establish association, not cause. That is written into the
pre-registration rather than left to be rediscovered.

**Merged from `design\backlog-inbox\cohort-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

`grocery/send-price-alerts.ps1:7` documents that subscribers are Ghost members carrying the label
`alert-<id>`, added by the Worker's `POST /alert` (`worker/index.js:146,170`). That is a per-member,
timestamped-by-label opt-in action taken voluntarily after signup.

**Why it matters.** `growth-craft/cohort-retention.md` section 6 calls this an aha-moment candidate:
a specific early action that may separate members who stay from members who leave. The estate is
already collecting the signal and paying nothing extra for it. The testable question is whether
members who set at least one price alert in their first 30 days retain better than those who never
do - and if the gap is large and consistent, prompting the alert during onboarding becomes a
retention lever rather than a feature.

**The rule that must travel with it.** The 30-day threshold and the alert-count cut have to be
written down BEFORE the retention data is pulled. Choosing the split that produces the biggest gap is
selection on noise - the same rule `meal-prep/pipeline/bm25_dedup_probe.py:309` already obeys and
`.claude/rules/measurement.md` already states. This is that rule's third independent arrival.

**Honest caveat.** With a single membership this small the comparison may have no power at all;
report the counts with their denominators and be willing to say the question is unanswerable yet.

### I100 - `cohort` means four different things within reach of one session here `DONE - THE COLLISION IS ON RECORD IN THE RULES FILE, 2026-09-08` `queue-5`

**`[CLOSED 2026-09-08.]`** `.claude/rules/grocery.md` now states that `cohort` here means the
**peer group of products holding a commodity's board cells**, names the five call sites that use it
that way, records that the skills store also uses it for a release cohort (with `retention` meaning
LOG retention and `churn` meaning TEST-SUITE churn), and sets the forward rule: **if member work ever
lands it is written `member cohort` IN FULL, every time**, and the grocery sense keeps the bare word
it has held for months.

The failure it prevents is the one this estate has a name for: a future session greps `cohort` while
working on members, gets a page of grocery hits, and reads them as coverage - an agreeing answer that
is about something else, `[[identity-graph-commodity-is-namespaced]]`.

**The thing worth stealing in the other direction is recorded with it**, because it is the more
valuable half: `build-arrivals-docket.ps1:56-57` already **refuses to score a cohort it cannot form**
and reports BLIND rather than passing it - scoring needs at least 2 other priced cells, and 41 of 492
commodities on the 2026-07-30 board could not reach that. That is the small-cohort discipline the
retention material teaches, implemented here first.

**Merged from `design\backlog-inbox\cohort-2026-09-08.md` on 2026-09-08.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.

In this estate `cohort` means the peer group of products already holding a commodity's board cells:
`grocery/build-arrivals-docket.ps1:27-31,56-57`, `grocery/check-ad-cycles.ps1:1791`,
`grocery/adjudicate-discovery.ps1:23`, `grocery/aisle-test.ps1:35-36`, `sidecar/probe_peer.py:59-80`.
In the skills store it is also a release cohort, `retention` is log retention, and `churn` is
test-suite churn.

**Why it matters.** A future session grepping `cohort` while working on members gets a page of
grocery hits and reads them as coverage. This is the shape
`identity-graph-commodity-is-namespaced` records: an agreeing answer that is about something else.

**What it would touch.** Nothing in code. It is a documentation line - if any member-cohort work
lands, it is written as `member cohort` in full, and the grocery sense keeps the bare word it has
held for months. Filed so the collision is on record rather than discovered later.

**One thing worth stealing in the other direction.** `build-arrivals-docket.ps1:56-57` already
refuses to score a cohort it cannot form and reports it BLIND rather than passing it: scoring needs
at least 2 other priced cells, and 41 of 492 commodities on the 2026-07-30 board could not reach
that (22 with one priced cell, 19 with exactly two). That is the same small-cohort discipline the course
teaches for retention tables, implemented here first.
