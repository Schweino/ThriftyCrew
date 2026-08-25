# EVAL: the registrar's batch road, decomposed - what the 12 turns actually bought

Date: 2026-08-25. Author: the registrar-batch review session (READ-ONLY - no code touched, no
estate write, no drill run). Status: MEASUREMENT with the hypotheses labeled as such. Ordered by
EVAL-map-lane-latency-m1-drill section 8 finding 2: the registrar's first N>1 dispatch came in at
12 turns / 123,401 raw against a <=3 turns / <=120k per-batch target, and nobody had decomposed
it. This is the decomposition, done the way PLAN-map-lane-latency-M1-M4 section 1 was written:
tool call by tool call, from the transcripts, with the code anchors re-grepped rather than trusted.

## 0. The one-paragraph verdict

The batch road is INNOCENT of the miss, and the proof is in the session's own tool calls: **7 of
the 11 calls are recovery from two Claude Code harness defects, not batch work**, and both defects
were REPRODUCED live during this review. The registrar opened with exactly the intended shape - one
parallel semantic sweep, two Greps, one per food family, the same shape that closed the batch-of-one
in 3 turns - but its brace glob carried one slash-bearing member (`out/recipe-board-everyday.json`),
and on this Windows harness ANY slash-bearing glob member matches nothing and silently zeroes the
entire brace alternation. Both sweeps returned "No matches found" against files that provably carry
matches. The session then spent 2 calls diagnosing the silence, 4 calls redoing the sweep file by
file, and 1 call working around the second defect (a minified single-line JSON renders as "[Omitted
long matching line]" under a content-mode Grep - the same wall the jc1 registrar hit and paid the
same one-call workaround for). Strip the 7 recovery calls and the intrinsic session is 4 calls plus
the verdict: 5 turns and roughly 60-75k raw (arithmetic in section 5), against 3 turns / 40,098 at a
batch of one. What remains true, and is a finding rather than a defect: the <=3-turn target edge
EQUALS the batch-of-one zero-friction floor and carries no N term, while the registrar's own
procedure - the semantic sweep that produced the DECISIVE evidence in all three transcripts read
here - scales with the number of food families in the batch. That target arithmetic is Brad's
conversation, and it is stated plainly in section 6 rather than softened.

## 1. What was reviewed, and how the numbers are counted

Three registrar transcripts in `~/.claude/projects/C--Codex-ThriftyCrew/`, identified by their
opening dispatch prompt:

| session | file | proposals | road | lane-log stamp |
|---------|------|-----------|------|----------------|
| m1b (this review's subject) | `84f81910-...jsonl` | 2 (pulled-pork, gouda-cheese) | F2 batch dossier | 12 turns / 123,401 raw / 65 s |
| lf1 round 1 | `bc75e85f-...jsonl` | 1 (fresh-mozzarella) | F2 batch dossier | 3 turns / 40,098 raw / 38 s |
| jc1 | `b3a7059b-...jsonl` | 1 (prosciutto) | pre-F2 single road | 10 turns / 81,929 raw / 54 s |

Two accounting facts pinned first, because the review turns on them:

1. **Raw tokens** = input + cache_read + cache_creation + output, summed per API request. Summed
   off the m1b transcript's own usage stamps: 118,504 in + 4,897 out = **123,401 exactly** - the
   lane log and the transcript agree to the token.
2. **A "turn" in the lane log is a TOOL CALL plus the closing message, NOT an API round trip.**
   lf1's registrar made its 2 Greps IN PARALLEL inside ONE API request and stamped 3 turns
   (2 calls + verdict). m1b made 11 calls across 4 tool-bearing requests plus the verdict request
   and stamped 12. So the 12-vs-3 headline ("four times longer") is the turn metric; on API
   requests it is 5 vs 2 (2.5x), on raw 3.08x, on wall 1.77x (62 s vs 35 s, first token to last).
   The turn metric charges parallel same-request calls as if they were serial round trips.

The m1 drill's histogram for this session - 20 assistant messages, 5 thinking blocks, 11 tool
calls: 8 Grep, 2 Read, 1 Glob, zero web calls - is confirmed exactly. One addition it did not
state: **all 5 thinking blocks are EMPTY (0 characters), in all three sessions** - the same
zero-thinking shape the drill reported for the mapper.

**CORRECTED 2026-08-25 (same day, from the T-shakedown mapper transcript).** This eval repeated the
m1 drill's misreading rather than checking it. A thinking block here carries a `signature` running to
tens of thousands of characters with its `thinking` text redacted to `""` in the local transcript, so
"0 characters" means unreadable, never absent. The registrar sessions were therefore reasoning too,
and this section's closing claim below - that every second is tool round trips plus generation - is
not supported by the evidence it cites. It does not change this eval's VERDICT (the batch road is
still innocent, and the friction decomposition is unaffected), but it does mean the registrar's own
wall clock has a reasoning component nobody has measured.

Every second of these sessions is tool
round trips plus generation.

## 2. The 2-proposal session (m1b), tool call by tool call

Dispatch prompt: 14,739 chars. Verified against `registrar_batch_prompt` (hunt-daemon.py:1747) and
the rendered text in the transcript: the dossier carries, PER proposal, everything F2 4.2.2
specced - the near-miss rows across all three namespaces, the live feed's price cell for the
proposed id and every near row, the floor-map answer, the label greps, the sibling language, and
the mapper's case. Nothing the dossier promised is missing from it.

**API request 1** - 18,282 raw (17,596 context write + 685 out), first token 4.0 s after dispatch.

| # | call | what it was for | what came back |
|---|------|-----------------|----------------|
| 1 | Grep `carnitas\|bbq\|barbecue\|pulled\|shredded\s*pork\|smoked pork`, path `grocery`, glob `{commodities.json,recipe-commodities.json,out/recipe-board-everyday.json,recipe-floor-id-map.json}` | the semantic sweep for proposal 1, under spellings the dossier's word-overlap list cannot see | **"No matches found" - a FALSE NEGATIVE** (commodities.json provably carries `pulled`, `bbq` rows; see section 4) |
| 2 | Grep `gouda\|edam\|smoked cheese`, same shape of glob + `out/smp-feed.json` | the semantic sweep for proposal 2 | **"No matches found" - same false negative** |

These two calls ARE the intended batch shape: one parallel request, one sweep per food family,
identical in kind to the two parallel Greps that closed lf1 in 3 turns. Had they returned their
matches, the session's remaining work was the verdict and at most a follow-up read.

**API request 2** - 18,644 raw. The model states the problem in its own text: "The greps came back
empty - before trusting that, let me confirm the glob actually hit the files."

| # | call | what it was for | what came back |
|---|------|-----------------|----------------|
| 3 | Grep `pork` on `commodities.json` directly, count mode | proving the file has content its glob missed | 49 occurrences |
| 4 | Glob `*.json` on `grocery` | proving the files exist where the glob pointed | the file list |

Both calls are diagnosis of the harness, not registrar work. The model's conclusion, verbatim from
request 3's text: "The brace-glob silently missed the files."

**API request 3** - 25,465 raw. The sweep redone file by file, four calls:

| # | call | what it was for | what came back |
|---|------|-----------------|----------------|
| 5 | Grep both term families on `commodities.json` | redo of calls 1-2 | the real matches: `pulled`/`smoked` inside EXCLUDE lists, `bbq-sauce`, the gouda-in-an-exclude line 67537 |
| 6 | Grep on `recipe-commodities.json` | redo | bbq in honey's note, `\bpork\b` |
| 7 | Grep on `out\recipe-board-everyday.json` | redo | sugar-free-bbq-sauce, pork-tenderloin rows |
| 8 | Grep on `out\smp-feed.json` | redo, feed half | **"[Omitted long matching line]" - the second harness defect**: the feed is minified one-line JSON, and content-mode Grep omits long lines |

**API request 4** - 28,096 raw. One more recovery call, then the two legitimate evidence reads:

| # | call | what it was for | what came back |
|---|------|-----------------|----------------|
| 9 | Grep `.{60}(?:gouda\|pulled\|carnitas).{60}` with `-o` on the feed | the workaround for call 8's omitted line | the real feed matches: recipe NAMES (slow-cooker-pulled-pork-bowl etc.), not price rows |
| 10 | Read `commodities.json` offset 20560 | the full pork-shoulder row | its exclude list: `"smoked", "pulled", ...` - the decisive evidence for the pulled-pork approval |
| 11 | Read `commodities.json` offset 21770 | the full rotisserie-chicken row (its exclude also carries `pulled`) | the corroborating exclude |

**API request 5** - 32,914 raw, 33.7 s of it generation (2,451 output tokens). The verdict: both
proposals approved, each with a full prescription at the agent definition's ordered rigor
(include/exclude design, allowlist pairs, namespace, capture worklist), plus the sibling
cross-read. The verdict's own reasons cite the sweep, not the dossier: "pork-shoulder's own
EXCLUDE list, which contains 'pulled' and 'smoked'" and "the only 'gouda' string in the entire
estate is inside an EXCLUDE pattern".

**Pass 2, the collision re-check: COST ZERO.** No second dispatch appears in the transcript or the
lane log, and the code path says why - `registrar_rulings` (hunt-daemon.py:1475-1507) only
re-dispatches when two approvals share a `collision_key`, and pulled-pork vs gouda-cheese do not.
The re-check did honest work for free.

**Wall decomposition**: 62 s first-token-to-last (the 65 s stage stamp adds dispatch overhead).
4.0 s to first token; 24.2 s of tool phase (4 round trips, 11 calls); 33.7 s generating the final
verdict. The single largest wall item is the verdict generation, and it is the gate's actual
product - it scales with approvals, since each approval carries a prescription.

## 3. The batch-of-one sessions beside it

**lf1 (`bc75e85f`), 1 proposal, F2 dossier (9,290 chars), 3 turns / 40,098 / 35 s.** Two API
requests. Request 1 (16,395 raw): TWO PARALLEL Greps - `mozzarella|bocconcini|ovoline|ciliegine|
burrata` over `grocery` glob `*.json`, and the same family over `grocery\out` - the identical
semantic-sweep move, with NO slash-bearing glob, and both returned rich content (8,361 and 5,357
chars). Request 2 (23,703 raw): the verdict, 22.2 s of generation. Its reason cites what only the
sweep found: `reduced-fat-mozzarella` (a row the dossier's word-overlap list missed), the
BelGioioso capture sitting in carriage.json, and the ad-archive price spread (~3x) that settles
same-food-different-form. No Read calls at all - the broad greps' content output was enough.

**jc1 (`b3a7059b`), 1 proposal, pre-F2 evidence block only (3,685 chars), 10 turns / 81,929 /
51 s.** Four API requests, 9 tool calls: the same semantic sweep (prosciutto, pancetta, capicola,
coppa, speck, salami...), a ham-label sweep, per-file checks of the feed, the floor map and the
dupe allowlist, an `ingredient-vocab.ps1` query - and note call 7 of 9: the feed grep returned
"[Omitted long matching line]" and cost the same one-call `-o` workaround m1b paid. The F2 dossier
deleted the floor-map, allowlist, feed-cell and label-grep calls from this shape (lf1 made none of
them); it did not and cannot delete the semantic sweep.

**Shape comparison, the review's whole point in one table:**

| | jc1 (pre-F2, N=1) | lf1 (F2, N=1) | m1b (F2, N=2) |
|---|---|---|---|
| tool calls | 9 | 2 | 11 |
| ...of which harness-friction recovery | 1 | 0 | 7 |
| ...intrinsic (sweep + evidence reads) | 8 | 2 | 4 |
| API requests | 4 | 2 | 5 |
| turns (lane metric) | 10 | 3 | 12 |
| raw | 81,929 | 40,098 | 123,401 |
| raw per proposal | 81,929 | 40,098 | 61,700 |
| wall (first token to last) | 51 s | 35 s | 62 s |
| verdict generation | ~20 s / 1,936 out | ~22 s / 1,640 out | ~34 s / 2,451 out |

Even AS MEASURED, friction included, the batch road at N=2 cost 25% less per proposal than the
pre-F2 single road. The dispatch-count claim held and the per-proposal economics held; the turn
count is what blew out, and section 4 says why.

## 4. The two harness defects, reproduced during this review

**Defect 1: a slash-bearing glob member matches nothing, and poisons the whole brace alternation.**
Reproduced 2026-08-25 with the Grep tool this session runs on - the same tool the registrar ran on:

- The EXACT call 1 (pattern `carnitas|bbq|barbecue|pulled|shredded\s*pork|smoked pork`, path
  `grocery`, glob `{commodities.json,recipe-commodities.json,out/recipe-board-everyday.json,
  recipe-floor-id-map.json}`): **"No matches found"**.
- The same call with the slash member removed from the brace: matches immediately (bbq and pulled
  rows in recipe-commodities.json and beyond).
- Control on the slash member alone: `pulled|bbq` has 5 verified occurrences in
  `grocery\out\recipe-board-everyday.json` (direct-path grep). glob `out/recipe-board-everyday.json`
  from path `grocery`: **"No matches found"**. glob `recipe-board-everyday.json` from path
  `grocery\out`: the 5 occurrences.
- And the poisoning: glob `{commodities.json,out/recipe-board-everyday.json}` with the same
  pattern, path `grocery`: **"No matches found"** - even the basename member that matches dozens of
  rows on its own returns nothing once a slash member shares the brace.

The behavioral rule, measured: on this Windows harness, a Grep `glob` member containing `/` never
matches, and its presence silences every other member of a brace glob. HYPOTHESIS, stated as such:
the likely mechanism is a path-separator mismatch (the glob is matched against `\`-separated
paths), but the mechanism is the harness's business - the measured behavior is what the estate's
prompts have to live with.

**CORRECTED 2026-08-25 (the G1 build, measured the same day with four more controls before the
guidance sentence was written).** The paragraph above is wrong in its rule and its hypothesis, and
the correction matters because the wrong version would have taught every judge a superstition. A
slash-bearing glob does NOT "never match": it is ANCHORED AT THE REPO ROOT instead of at the `path`
argument. Measured, pattern `pulled|bbq`, path `grocery`:

| glob | result |
|------|--------|
| `commodities.json` | 39 hits across **4 files** - including `regression-inputs\` and two `engine-backup\` copies |
| `out/recipe-board-everyday.json` | 0 |
| `grocery/out/recipe-board-everyday.json` | **5** |
| `**/out/recipe-board-everyday.json` | **5** |
| `**/recipe-board-everyday.json` | **5** |
| `out\recipe-board-everyday.json` | 0 |
| `out/*.json` | 0 |
| `{commodities.json,**/recipe-board-everyday.json}` | 5 - and **0 from commodities.json** |
| `{grocery/commodities.json,grocery/out/recipe-board-everyday.json}` | **20 across both** |

These are ripgrep's own glob semantics: a pattern with no separator matches the BASENAME at any
depth, a pattern with one is anchored relative to the search root, and a backslash is the escape
character rather than a separator. The brace "poisoning" is real but is a CONSEQUENCE, not a
separate rule - one separator anywhere in the pattern makes the whole thing path-anchored, so the
slash-free alternatives stop basename-matching and anchor at the root too, where they match
nothing. The registrar's four-member glob failed for exactly that reason: all four became
root-anchored, and none of the four files sits at the repo root.

TWO THINGS THIS CHANGES BEYOND THE WORDING. First, the fix is a rule an agent can apply rather than
a taboo to obey: `grocery/out/smp-feed.json` and `**/out/smp-feed.json` both work, so nothing needs
avoiding. Second, and this one is an ACCURACY finding the original paragraph missed entirely: a
bare basename glob silently reads STALE COPIES. `commodities.json` matched `regression-inputs\`
and two `engine-backup\` copies alongside the live file, so a registrar sweeping `*.json` under
`grocery` can quote a backup's row as the live estate - which is a wrong answer in the direction
this gate exists to prevent. That is why the shipped guidance tells the reader to check the paths
in their hits, and it is a finding for Brad in its own right: nothing today stops a sweep from
citing an engine backup.

**Defect 2: content-mode Grep on minified one-line JSON returns "[Omitted long matching line]".**
`grocery\out\smp-feed.json` is single-line. m1b call 8 and jc1 call 7 both hit it and both paid
one extra call for the `-o` context workaround. Two independent sessions, same wall, same
workaround - this one is deterministic, not stochastic.

**Cost attribution, measured off the request stamps**: API requests 2 and 3 (44,109 raw, 35.7% of
the session) exist ONLY because of defect 1 - they contain nothing but diagnosis and redo. Request
4 is mixed: one workaround call (defect 2) beside the two legitimate Reads, and requests 4 and 5
carry the recovery bloat forward in their context. Conservative floor for the friction bill:
**44,109 raw and 7 of 12 turns**. Estimate including request 4's share and the carried context:
~55-65k raw, roughly half the session. The first figure is measurement; the second is arithmetic
over it and labeled estimate.

## 5. The diagnosis, stated as measurement

Of the four candidate diagnoses the review was ordered to rule between:

1. **"The dossier fails to carry what the registrar needs" - NO for everything it promised.** The
   rendered prompt carries every F2 4.2.2 item, verified against both the transcript and
   `registrar_batch_prompt`/`registrar_dossier` (hunt-daemon.py:1723-1784). There is exactly one
   thing the registrar needed that the dossier does not carry - the SEMANTIC sweep (carnitas,
   edam, bocconcini: synonym knowledge) - and the dossier CANNOT carry it by ratified design:
   `commodity_near_misses` ranks by shared words because mechanical code may rank but never assert
   identity (the fork PLAN-latency 3.2 closed). The sweep is judgment work, it stays with the
   judge, and in all three transcripts it produced the decisive evidence of the ruling.
2. **"The registrar re-derives what it was handed" - NO.** It never re-read the near-miss list,
   never re-checked a feed cell the dossier had answered, never touched the floor map (lf1 and m1b;
   jc1 predates the dossier and did make those calls - which is F2 working). Its greps hunted
   UNLISTED spellings, exactly the "look further" the NOT_EXHAUSTIVE language licenses.
3. **"The collision re-check does honest work that costs turns" - NO.** Pass 2 dispatched nothing:
   zero turns, zero tokens (section 2).
4. **"Two proposals are two investigations that share nothing" - PARTLY, and it is the small
   part.** The intrinsic work scales with food families: 2 sweep greps instead of 1, and here 2
   evidence Reads (both for the pork ruling; gouda's evidence fell out of the redo grep). That is
   4 intrinsic calls at N=2 against lf1's 2 at N=1. The batch also AMORTIZED the friction: one
   session diagnosed the glob failure once for both proposals, where two singles would each have
   rolled the same dice.

**The actual diagnosis, in one sentence: the 12 turns decompose as 4 intrinsic calls + 7
harness-friction recovery calls + 1 verdict, and the friction - two reproduced Grep defects, one
stochastic (the model's choice of a slash-bearing brace glob) and one deterministic (the minified
feed) - is what carried the session from a plausible 5 turns to 12 and from ~70k raw past the
120k edge.**

The counterfactual, labeled as the arithmetic it is: with call 1 and 2 returning their matches, the
session's shape is request 1 (2 sweep Greps) + at most one evidence-read request (the two
commodities.json Reads, ~24k raw at that context size) + the verdict request (~29k) = **4-5 tool
calls, 5-6 turns, ~60-75k raw** - raw comfortably inside target, turns still over the 3-turn edge.
If the broad-sweep output had been rich enough to skip the Reads (as it was on lf1), 3 turns /
~45k. So a zero-friction batch-of-two lands between "target met exactly" and "turns 2x over, raw
well inside" - which is why section 6 is a conversation about the target, not a softening of it.

## 6. The target arithmetic - for Brad, stated plainly

The <=3 turns / <=120k per-batch target was written in PLAN-latency-F1-F7 4.4 BEFORE any batch
measurement existed. What the three transcripts now show:

- **The 3-turn edge is exactly the N=1 zero-friction floor.** lf1 hit it to the turn: 2 sweep
  calls + verdict. It contains no allowance for a second food family, and the registrar's own
  definition orders the work that scales: "MECHANICAL SWEEP first... Then search SEMANTICALLY" is
  unconditional in the Procedure section, the ADDED 2026-08-25 paragraph licenses re-derivation
  ("verify the shown work... go looking wherever the dossier smells incomplete"), and the dossier
  itself brands its list NOT exhaustive. For any real food there is always a plausible other word.
  The sweep is not disobedience and not waste - it found reduced-fat-mozzarella, the pork-shoulder
  excludes, and the gouda exclude, and every verdict leaned on it.
- **Under the current turn accounting the intrinsic floor at N proposals is roughly N+1 to N+3
  turns** (one sweep grep per food family, 0-2 evidence reads, one verdict) even though the sweep
  greps ride ONE API request. If turns were counted per API round trip, the same sessions read
  3 (lf1), 5 (m1b as measured), ~3 (m1b clean) - and the 3-turn edge becomes defensible at any N
  that keeps its sweep parallel. The metric and the target disagree about what they are measuring.
- **The raw edge survives N=2 cleanly** (~60-75k counterfactual, 123,401 only under a 44k+ friction
  bill) but grows with N on two axes: ~2.2k tokens of dossier per proposal in every request's
  context, and more requests as evidence reads accumulate. At N=5 the fixed-plus-dossier context
  alone is ~24k per request; four requests is ~100k before any friction. HYPOTHESIS: the 120k edge
  is tight but reachable at N=5 with parallel sweeps and no friction; it will not survive a single
  glob cascade at that width.

So the honest sentence the brief asked for: **the target was set from arithmetic before any batch
existed, its turn edge equals a batch-of-one's floor, and it does not survive contact with a batch
of two under the current turn metric even with zero friction - by 1 to 3 turns, while raw passes.**
Whether the turn edge gains an N term, moves to per-request counting, or stands as a forcing
function is Brad's call. Thursday's wide run will dispatch wider batches than two; without a
ruling, every one of them reports as a MISS on turns regardless of conduct.

## 7. What a fix would have to change, NOT built, and what being wrong costs

Ranked by measured payback. None of these touch a gate, a pin, the batch road, or the collision
re-check; item 3 is a measurement decision, not a build.

1. **Tell the registrar (and every grepping agent) about the two Grep defects, in the dispatch
   prompt or the agent definition** - M4's class: prompt-only, roughly three sentences. "A glob
   member containing a slash matches nothing on this harness and silences the whole brace - grep
   per file or use basename globs from the containing directory. `grocery\out\smp-feed.json` is
   one minified line - content-mode grep returns an omitted-line stub; use `-o` with a context
   pattern." Measured payback on this session alone: 7 of 12 turns and at least 44k raw.
   COST OF BEING WRONG: ~100-150 prompt tokens per dispatch forever; the guidance goes stale if
   the harness fixes the glob behavior (it then misdescribes the tool but breaks nothing); and it
   must be worded so it never reads as "do not sweep" - a sentence that discourages the sweep
   would gut the evidence the verdicts run on, which is a gate weakening and off the table.

   **BUILT 2026-08-25 (unit G1), on Brad's order after this review was delivered.** One shared
   `Daemon.GREP_HARNESS_NOTE` constant, rendered into the four dispatch prompts whose agents sweep:
   `registrar_batch_prompt`, `map_prompt`, `qa_prompt` and `audit_prompt`. The pricer and the
   decider carry Grep and were DELIBERATELY LEFT OUT - neither sweeps a namespace, and the omission
   is pinned by its own clean twin so a later edit cannot widen it by accident. The durable copy
   went into `.claude\agents\commodity-registrar.md`, because that agent is consulted outside the
   daemon too, and `-Sync` is clean. The note states the measured RULE (basename-at-any-depth,
   root-anchored-when-a-separator-is-present, the brace consequence, the backslash, the minified
   feed) rather than the taboo, per the section 4 correction, and its final clause aims the distrust
   at the empty RESULT and never at the sweep. Six fixtures, daemon suite 207 -> 213, all three
   neuter proofs RUN and reverted with the counts the suite actually printed (blanking the constant
   is 5 red, not the 4 predicted). What is NOT built: items 2 and 3 below, both still proposals.
   The prompt cost measured out at 1,075 characters / 163 words (order 270 tokens) per dispatch
   rather than the 100-150 tokens estimated above, because the rule needs its worked examples to be
   applicable. Against a session that burned 44,109 raw on the failure it prevents, that is the
   trade, and it is stated rather than buried.
2. **Hand the registrar the mapper's already-checked spellings per proposal.** The mapper's case
   already names what it checked ("under Gouda, Gouda Cheese and Cheese Gouda"); the dossier could
   render that as a checklist line so the registrar's sweep starts from the unchecked synonyms.
   Payback: unmeasured, plausibly small (the sweep is 1-2 calls already). COST OF BEING WRONG: if
   the rendered list reads as authority ("these were checked, trust them"), a wrong mapper claim
   propagates into the ruling unverified - it must render as claim, never as clearance.
3. **Reconcile the turn metric with the target** - either count turns per API request in the lane
   log (parallel calls were the design intent; the metric currently punishes them) or give the
   registrar target an N term (e.g. <=N+2 turns / <=(40k + 25k*N) raw, numbers to be set from
   Thursday's width, not from this N=2 point). COST OF BEING WRONG: a metric change rewrites what
   every historical number means (6b, jc1, lf1, m1 all counted calls) - the baselines would need
   restating in the same commit, or every future comparison silently lies. A target change made
   casually is exactly the softening the standing rule forbids; it needs Brad's ruling and the
   arithmetic on the record, which section 6 is.

NOT a fix and named so nobody builds it: making the daemon pre-run "semantic" greps with a synonym
list. That is mechanical code asserting identity - the fork PLAN-latency 3.2 closed, and this
review re-closes it: the whole value of the sweep in all three transcripts was judgment about
which words to look under.

## 8. Corrections owed and written in this commit

- **EVAL-map-lane-latency-m1-drill-2026-08-25.md section 8 finding 2** - CORRECTED: the "grew four
  times longer" framing is the turn metric only (raw 3.08x, API requests 2.5x, wall 1.77x), and
  the decomposition attributes 7 of the 11 tool calls to reproduced harness friction, not to the
  batch road. Pointer to this document.
- **PLAN-latency-F1-F7-2026-08-25.md section 4.4** - MEASURED block: the first N>1 measurement,
  its miss, and where the decomposition lives. The target text itself is UNTOUCHED - changing it
  is Brad's, per section 6.

## 9. What this review does not measure, said plainly

The registrar at N>2 (unmeasured; section 6's width arithmetic is labeled hypothesis). The
probability of the glob failure recurring (the choice of a slash-bearing brace glob is model
variance; observed once in four registrar sessions, and two singles would have rolled twice).
Whether the harness Grep behavior is version-dependent (reproduced today on this machine, in this
session, with controls; not tested elsewhere). Thursday's wide proving run was NOT started, no
code was edited, no live file was written, and the estate's suites were not run because nothing
that feeds them changed.
