# Estate backlog from the course programme

Everything the Claude/AI course queue has surfaced that we should CHANGE in this estate. Opened
2026-09-06 while working the 15-course queue (`~/.claude/skills/course/QUEUE.md`; per-course detail
in `LEDGER.md` beside it).

**This is a backlog, not a plan.** Nothing here is ordered work until Brad rules on it. Each item
says what, why, and what it would touch, so the size of the bet is visible before anyone takes it.

Status: `OPEN` proposed, not started · `DONE` shipped, commit named · `WONTFIX` ruled out.

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
3. **Nothing is armed yet.** Both switches are off, so today this changes nothing - it is capability,
   not protection, until someone turns one on.
4. **`publish.ps1:285` needs teaching before staging can be armed on the publish chain** - it GETs the
   public page after the PUT to confirm it shipped, and would report a failure when nothing shipped.

### E2 - Bare numeric codes cross agent boundaries `DONE` `5a7fccf0`
*Source: AI Agents in Python (course 6).* "An agent that receives error 32 is finished." Our gate
exit codes are exactly that shape. Anywhere a gate's exit code reaches an agent without a
words-level translation is a place an agent retries identically or invents a meaning. Grep for it.
Note the irony: while adding D2 I put "exit 2" into five agent prompts and had it wrong -
`run-gates` uses exit 3, the recipe battery uses 2. Corrected in `6a05dcd7`, but that is the exact
failure this item is about.

### E3 - Tool-list relevance hazard across twelve agent definitions `PARTLY DONE` `803af3d2`
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

---

## Accuracy

### E4 - The dedup pipeline is embeddings-only `OPEN`
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

### E5 - Validate at source `OPEN`
*Source: MCP (course 3).* A direct criticism of any tooling that hands a model raw rows to sift. The
four-layer stack is format -> business rules -> self-prompted semantic -> human review, with **low
confidence routed to review rather than rejection**. Applies to the ingredient queue and the
capture readers.

### E19 - No matcher in the estate has a scored test set `OPEN`
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

### E20 - Match rates are reported without their abstention rate `OPEN`
*Source: same course, section 14 of the file above.* A matcher that returns `UNUSABLE`, `PENDING`
or nothing on the rows it finds hard, and is then scored only on the rows it answered, **outscores
one that attempts everything** - and neither number looks wrong. Any accuracy or match-rate figure
computed over non-null output has this in it. The fix is small: report coverage beside every such
figure, or substitute a documented fallback for the declines and score that too. Worth an audit of
where the estate already quotes a bare rate, starting with the pricing pre-pass and the ingredient
mapper. Cheap, and it changes how existing numbers should be read rather than requiring new code.

### E21 - Nothing in the estate states how far a number has to move to count `OPEN`
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

### E22 - Rare-target rules are judged on fixtures with a 50% base rate `OPEN`
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

### E23 - Our test sets are built out of successes `OPEN`
*Source: same course, section 12, and it is publication bias wearing our clothes.* Fixtures and
golden files here are assembled from bugs we found and cases we already handle correctly. Cases that
failed silently were never written down, so they are absent from the evidence and **their absence is
invisible in the score** - the literature's version of this at least leaves a detectable cliff in the
p-value distribution, and ours leaves nothing. Same root as the "one failing query per step" habit
E19 flags. The mitigation is a work habit rather than a build: **record the case at the moment it
fails**, including the ones fixed by hand and moved on from, so the corpus is not exclusively
successes. `known-wrong.json` and `research-worklist.json` are already the right shape for this and
are populated by rulings rather than by failures. Small, ongoing, and it compounds.

### E24 - Every A/B here logs counts, and counts cannot be un-aggregated `OPEN`
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

**The fix is a logging convention, not a statistics build**: any run that scores two arms over one
case set writes **one row per case per arm, keyed by case id**, and the totals are derived from that
file rather than being the file. Cheap to adopt going forward, impossible to backfill, which is the
argument for doing it before the next comparison rather than after. Overlaps E21 (nothing states how
far a number must move) and E20: those two say what to compare against, this one says keep the
evidence that lets you compare at all. **Worth pointing at `sidecar/` and the recipe-dedup RESCORE
lane first** - both already re-score a fixed corpus, so both are one column away from compliant.

### E25 - No similarity threshold here records which kind of space it was tuned on `OPEN`
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

### E26 - A term that is identically zero on our fixtures is untested, not correct `OPEN`
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

### E6 - Fact Check List before we publish `OPEN`
*Source: Prompt Engineering (course 4).* Ask the generator for the fundamental claims that would
undermine its own output, then diff that list against the prose. Cheap pre-publish check, close in
spirit to what `post-publish-reviewer` does afterwards - and on the correct side of the publish,
which is E1's whole point.

---

## Efficiency and ergonomics

### E7 - `.worktreeinclude` `DONE` `4e8102c2`
*Source: Claude Code in Action (course 1).* A repo-root file listing gitignored files to copy into
every new worktree. Would automate the manual copy-in that `run-gates-blind-in-worktrees` and
`worktrees-lack-the-boards-the-engines-price-on` both describe. **Needs sizing first** - the full
ignored set is ~25 GB, so it must be a narrow list: the four gates' real inputs plus the three board
files.

### E8 - "Don't ask" permission mode for unattended runs `OPEN`
*Source: Claude Code in Action (course 1).* Purpose-built for CI, scheduled jobs and overnight
batches: pre-approved tools only, everything else auto-denied with no prompt to hang on. May fit the
scheduled tasks and the daemon better than what they use now.

### E9 - Model choice is pinned per agent, but MATE's M is per call `OPEN`
*Source: AI Agents Architecture (course 7).* All twelve definitions pin one model. A tool that makes
its own LLM call can pick its own. Highest-leverage split: an expensive model for the up-front plan,
a cheap one to execute it.

### E10 - Long-running lanes have no progress tracking `OPEN`
*Source: AI Agents Architecture (course 7).* The Recipe Hunter daemon runs far past the point where
its initial plan is still near the front of context. Fix is a cheap end-of-iteration progress report
every Nth loop; calibrate N by running plan-only and watching for where drift starts.

### E18 - Tool arguments are untrusted model input, and our pattern does not validate them `OPEN`
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

### E11 - Tool decorators and tag-scoped registries for the daemon `OPEN`
*Source: AI Agents in Python (course 6).* Derive each tool's schema from its signature, docstring
and type hints. Removes the class of bug where an agent's map of a tool has drifted from the tool,
and makes "which agents can write?" a grep instead of an audit.

### E12 - Document-as-implementation `OPEN`
*Source: AI Agents Architecture (course 7).* Brad's rulings, the band rules and the naming
conventions are already written for humans and already change without a deploy. Loading the rules
file at run time and pairing it with a schema'd verdict is smaller than the equivalent code, and
removes the class of bug where the ruling document and the enforcing script have drifted.

### E13 - Pass references, not copies `OPEN`
*Source: AI Agents Architecture (course 7).* Models read far more than they can write, so a
delegating agent physically cannot restate a large memory as a task description. Emit memory ids and
inflate them in code. Beats the output cap and makes paraphrase of the referenced content
structurally impossible. Relevant anywhere we hand a brief to a spawned agent.

### E14 - Agent definitions front-load their rules `OPEN`
*Source: MCP (course 3), mechanism from Mastering Claude Code (course 8).* A five-trigger framing
plus a hierarchical context walk is a cheaper shape for the estate's per-directory conventions than
the current front-loading.

**Course 8 supplied the actual mechanism: `.claude/rules/`, one topic per file, with YAML front
matter carrying a `paths` glob so the file loads ONLY when Claude touches a matching file.**

> **Verify the mechanism before building on it.** That account is **single-sourced from one course**
> and nothing on this machine corroborates it - no `.claude/rules/` directory, no `paths` key on any
> file. Registered as C3 in `~/.claude/skills/course/CLAIMS-REGISTER.md`. First step of this item is
> a two-file test proving a rule file actually loads conditionally, not a restructure. That is
conditional loading, which we had written down nowhere - `claude-code-craft` had been posing the
attention-budget problem since course 2 without an answer to it.

Direct fit here: the estate's conventions are already per-directory. `grocery/`, `meal-prep/`,
`graph/`, `ops/`, `site/` each have rules that are noise when you are working anywhere else, and the
root `CLAUDE.md` currently carries the lot. Splitting them into path-scoped rule files would shrink
the always-on load without losing anything.

Related timing fact worth knowing before restructuring: **only CLAUDE.md files at or above the
current working directory load at session start**; a subdirectory CLAUDE.md loads lazily. So a
`meal-prep/CLAUDE.md` costs nothing until someone works in there.

### E16 - Plugin hooks written in bash fail on Windows `WONTFIX` - measured, no estate change owed
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

### E17 - Skill invocation flags are a matrix, and ours are all set the same `OPEN` `LOW`
*Source: Building Apps and AI Agents (course 9).* Invocation control is two independent flags, not
one switch: `disable-model-invocation: true` makes a skill user-only, `user-invocable: false` makes
it Claude-only. All eight of our personal skills set `user-invocable: true`.

**Deliberately not changed.** The cost of leaving it is seven extra entries in the slash menu; the
benefit is being able to force-load a reference on purpose ("load `rag-craft` before we design
this"), which is occasionally worth having. It does not suppress model invocation either way. Listed
so the decision is visible rather than accidental, not because it needs doing.

### E15 - "Ask for Input" for rules-first prompts `DONE` `8e3de6d9`
*Source: Prompt Engineering (course 4).* One statement, and it must come last. Fixes the annoyance
where a rules-first prompt invents its own first input instead of waiting.

---

## Infrastructure and hygiene

Found while running the programme; not course-derived.

### I1 - `~/.claude` is not under version control `OPEN`
294 KB across 17 skill files plus the global `CLAUDE.md` - seven courses of distilled learning - on
one disk, no repo, no remote. Snapshot taken 2026-09-06 to
`~/.claude/backups/skills-2026-09-06`, which protects against a bad edit but **not disk failure**.
Durable fix needs Brad's call: a private repo for `~/.claude`, or committing the skills into this
repo under a marked path (simpler, but creates two copies that drift).

### I6 - Bypass-permissions is opted in at the account level, with no sandbox under it `OPEN` `BRAD'S CALL`
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

### I2 - Stray artifacts at the repo root `DONE` `558321d5`
`3 cups sliced, for topping` (1 file) and `CodexThriftyCrewgroceryoutcaptures_sink` (empty - a
mangled `C:\Codex\ThriftyCrew\grocery\out\captures_sink`). Both look like path-construction bugs.
Untouched deliberately: something wrote them and may still be writing them, so find the writer
before deleting the evidence.

### I3 - `C:\Codex\CLAUDE.md` and `C:\Codex\Fantasy\CLAUDE.md` have no backup `OPEN`
Neither directory is a git repo. Same exposure as I1, smaller.

### I4 - Fantasy has 212 Python files and no version control `OPEN`
No branch to abandon, no diff to review, no undo. `git init` there is worth one conversation.

### I5 - Coursera enrollment lapsed on `building-with-the-claude-api` `OPEN`
Will not reinstate by clicking - three attempts. Course-specific, not account-wide. All content was
already extracted and routed; outstanding are 6 ungraded dialogues and that course's progress ticks.
Needs Brad to click enroll himself.
