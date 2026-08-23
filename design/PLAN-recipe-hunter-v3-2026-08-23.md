# PLAN: Recipe Hunter v3 - Harvest Local, Judge Frontier, Orchestrate on the Box

Date: 2026-08-23. Author: Fable (end-to-end review session, at Brad's direction: "find where we can
move stuff to local llm to save tokens... a full redesign is absolutely okay... speed and accuracy are
the two most important things... utilize up to 8 cores").
Status: PROPOSED, awaiting Brad's direction. **Plan only - nothing in this document has been built.**

Prereq reading, in order: design\PLAN-recipe-hunter-v2-2026-08-15.md (the current architecture of
record, section 2.4), design\PLAN-recipe-hunter-v2.1-2026-08-15.md (serveability + audit economics),
design\PLAN-token-efficiency-2026-08-16.md (the measured waste inventory this plan inherits),
design\PLAN-local-matching-rescope-2026-08-23.md (the local model's measured envelope). This plan
supersedes none of them wholesale; section 10 says exactly which rules move and which do not.

## 0. The verdict in one paragraph

v2's gates are sound and its lane model is right. Its cost structure is upside down: **75.5% of all
tokens buy candidate discovery and dedup** - work that is mostly crawling, arithmetic and similarity
ranking - while the stages that genuinely need a frontier model (prose, adjudication, audit sign-off)
are a fraction of the bill. Meanwhile the orchestrator lives in a sandbox with no filesystem and no
clock, so it **spawns a full Claude agent to run one PowerShell line** dozens of times per run, and the
batch auditor - the most expensive agent in the flow, 31% of the shakedown - spends most of its context
re-deriving arithmetic that deterministic scripts already compute. v3 restructures the flow into three
planes: a **HARVEST plane** (local, ~zero tokens) that continuously stocks a pre-qualified candidate
backlog; a **JUDGMENT plane** (Claude, small) where every dispatch receives a mechanically pre-built
dossier and returns a schema'd ruling; and a **MECHANICS plane** (scripts, no LLM) that does everything
else, fanned across up to 8 cores. The orchestrator moves out of the Workflow sandbox onto the box,
where mechanical steps are function calls instead of agent invocations. Target: **>=5x fewer Claude
invocations per published recipe, front-end tokens cut ~10x, wall-clock dominated by writing and
auditing instead of hunting** - with every v2 gate preserved and several defect classes caught earlier
and mechanically.

## 1. The review: what was measured, what is sound, what is upside down

### 1.0 What this review covered

SKILL.md; PLAN v2 + v2.1 + token-efficiency + local-matching(+rescope) + use-the-cores 1/2 +
finetune-feasibility; all 10 agent definitions; hunt-orchestrator.js (1,474 lines), hunt-lib.js,
hunt-run.ps1, wave-publish.ps1, audit-lane-shape.ps1; local_extract.py, coverage_check.py; the local
inference stack (serve.ps1, llm.py, bench, sidecar, nightly.ps1); the grocery pricing stack
(ingredient-queue, price-ingredient, probe-ingredient, search-verdict-lib, carriage, capture lanes,
pull-browser-stores.py); the build stack (build-v2-spec, cost-recipes, build-card2, propagate,
vocab/resolutions/find-similar/considered-dishes/source-domains/fetch-recipe); and the three real run
dirs including lane-log.jsonl (834 lines) and the wave audit reports.

### 1.1 Sound - keep, verbatim

- **The two rules** (Rule B; unchecked-is-never-not-carried) and their measured basis.
- **The state machine** (hunt-run.ps1: single writer, derived pending counts, legal-transition graph,
  `held`, atomic writes, self-test). Nothing in this plan writes state any other way.
- **The lane model** with the singleton pricer and term-keyed cross-recipe queue.
- **The gate stack**: build-v2-spec write-time guards (unknown-name, unbid, cheapest-fallback, macro
  recompute +/-5 cal, dash sweep), wave-publish P1-P8 + E6/E7 serveability with rollback-to-held,
  batch-ledger, audit-lane-shape, the auditor's authority (never overruled), one-repair-cycle QA,
  scoped re-audits, S8 trim.
- **The memory ledgers** built 2026-08-16..23: considered-dishes, ingredient-resolutions,
  source-domains, fetch-recipe page cache + JSON-LD, find-similar, make-saturation.
- **hunt-lib.js**: all twelve founding-bug fixtures. Any orchestrator, in any language, must pass them.
- **The verified-local-extraction pattern** (local_extract.py): local output never trusted, every `raw`
  line proven by substring against the page, escalate-on-failure. This is the template for every local
  placement in v3.

### 1.2 The measured cost structure (run wf_11382034-6fd, lane-tokens.ps1, 1,335 transcripts)

| lane | agents | context-moved tokens | share |
|---|---|---|---|
| hunt | 245 | 325,543,422 | **43.3%** |
| select | 333 | 242,157,676 | **32.2%** |
| map | 627 | 98,727,543 | 13.1% |
| write | 15 | 36,282,000 | 4.8% |
| unknown (mostly wave/audit, unlogged then) | 37 | 24,280,307 | 3.2% |
| extract | 58 | 12,127,231 | 1.6% |
| price | 10 | 10,653,000 | 1.4% |
| qa | 10 | 1,994,125 | 0.3% |

(Context-moved counts cache reads; it is a volume measure, not a bill. The shakedown's billed measure:
786k tokens per recipe; the v2.1 target of 200-250k has never been hit. The audit alone was 31% of the
shakedown.) From lane-log.jsonl of the real 100-run: **265 hunt + 275 select dispatches produced 91
accepted recipes, of which 44 (48%) died as dupes and 20 published** - ~27 front-end Claude
invocations per published recipe.

### 1.3 The five structural findings

**F1. The front end searches when it should harvest.** Sourcers are Opus agents running WebSearch +
WebFetch per round, re-discovering a corpus that is largely enumerable: the reliable publishers carry
schema.org JSON-LD Recipe blocks (ingredients, instructions, **nutrition**) reachable by sitemap and
WordPress REST enumeration, ~4KB against a 591KB rendered page (measured, fetch-recipe.ps1). The band
filter (400-650 cal, <=35g carbs) is arithmetic on JSON-LD nutrition. Dedup adjudication is sharded
across 8 Opus agents each re-reading context per 3-candidate batch, then a 9th decides. Discovery and
first-pass dedup are not judgment work, and they are 75.5% of the spend.

**F2. The orchestrator pays an agent for every shell command.** The Workflow sandbox has no
filesystem, no clock, no shell. So `wave-close`, `derive-after-batch`, `verify-repair`,
`macro-reject`, `qa-reject`, `trim`, and the ledger stamps are each a **full Claude agent invocation
whose entire job is one `powershell -File ...` line** (hunt-orchestrator.js: laneLog dispatches at
lines ~459, ~517, ~850, ~923, ~993, ~430). In the wave lane roughly half the agent calls are shell
proxies. The sandbox also imposes the 16-concurrent / 1000-call harness caps that B6 died against.

**F3. The audit re-derives arithmetic.** The wave-2 NO-GO report (the real artifact) is ~80%
deterministic recomputation: 10/10 macro recomputes from food-macros-db, 10/10 cost reconciliations
to the cent against costed.json, card rebuilds to a scratch dir with byte-level structural compare,
protein derivation by construction, voice sweep, gate walks. Every one of those is already a script
(`parse-compute.ps1`, `cost-recipes.ps1`, `build-card2.ps1`, `audit-*.ps1`) - the auditor re-performs
them inside a Fable context window. Its actual judgment residue (the spinach form-flip, the
wrong-price-class call, one Worcestershire condition question) is a small fraction of the report.

**F4. Extraction is already solved locally but still pays a Claude wrapper.** local_extract.py
measured 1.000 valid strict JSON with mechanical substring verification, yet the flow still spawns a
Fable extractor agent per page whose first instruction is "run the local script." The wrapper is most
of the cost. Worse, when JSON-LD is present the extraction needs **no LLM at all**: recipeIngredient
lines are the page's own machine statement; only the per-line field split (item/qty/unit/prep) needs
a model, and that sub-task is verifiable line by line.

**F5. Map, price, QA and write each bundle a mechanical majority with a judgment residue.** The
mapper re-resolves terms the resolution cache and closed vocabulary already answer, re-derives scale
arithmetic and buy strings that densities.json + Get-FriendlyAmt compute, and only then exercises real
judgment (new terms, form flips, each-weight calls). The pricer drives browsers by hand for stores the
estate already sweeps unattended (`pull-browser-stores.py`, CDP, one thread per store, shipped
2026-08-23), while its true monopoly is one question: *is this candidate row actually the ingredient?*
QA's heaviest check is already code (coverage_check.py); scaling-ratio and prose-number checks are
arithmetic still done by the model. The writer produces a whole intake JSON when only the prose fields
(intro/shop_smart/make_it/portion/cost_closing/upsell, head.description/steps) need a voice - every
machine field is derivable from the mapped file and JSON-LD.

### 1.4 The local stack's measured envelope (what may move local, and in what shape)

Hardware: RTX 5070 Ti 16GB + Ryzen 9 9950X (16C/32T) + 64GB. Qwen3.8-27B Q3_K_XL on llama.cpp,
4 slots, grammar-forced JSON. Sidecar: bge-m3 + bge-reranker behind HTTP (port 8077) with a
disk-backed score cache (warm sweep 0.4s, zero GPU). llama-server (~13.5GB) and the sidecar (~3.5GB)
**cannot co-reside** on the card; graph\pipeline\nightly.ps1 owns scheduled ordering.

| task shape | measured | verdict for v3 |
|---|---|---|
| grammar-constrained structured extraction | 1.000 valid strict JSON (n=40 x 3 gates + thousands live) | **local by default**, always mechanically verified |
| saying NO (rejection) | 0 wrong of 117 audited (CI 0-3.2%) | local may reject / filter / rank |
| asserting a MATCH | **37% false** at 0.90-0.98 confidence | **never local**; a local YES is at most a lead |
| adversarial re-ask ("argue NO") | 86.4-point separation, signal only | local may order/score, never rule |
| throughput | 2.74s per short call; 3.6x at jobs=4; ~45 tok/s/stream, 80 aggregate | 4 concurrent local workers, that's the budget |
| 27B QLoRA fine-tune | feasible: 8.3h/epoch on-box (0.33GiB headroom) or ~$10 cloud | optional Phase E only, detached LoRA, >=3-seed gate |

**The v3 local-placement doctrine, three rules, non-negotiable:**
1. **Local output is never trusted, always verified** - substring proof, closed enums, or arithmetic
   recompute. No verifier, no local placement.
2. **Local may reject, filter, rank and flag. It may never assert an identity** - not "this row is the
   ingredient", not "these two dishes are the same", not "this map is correct".
3. **Everything user-visible in Brad's voice, and every carriage / mapping / audit ruling, stays
   frontier** - the writer, decider, mapper, pricer, source-QA, auditor, reviewer, registrar remain
   Claude agents with their existing model pins.

## 2. The v3 architecture: three planes

```
 PLANE 1: HARVEST (local box, ~zero tokens, runs continuously / overnight)
 ────────────────────────────────────────────────────────────────────────
   publisher enumeration (sitemaps, WP-REST, category indexes; source-domains ledger)
     -> fetch-recipe.ps1 cache (content-addressed, JSON-LD preferred)     [8 fetch workers]
     -> band + structure filter (arithmetic on JSON-LD nutrition/servings) [instant]
     -> dish signature (protein x method x sauce-family; mechanical + local-enum, verified)
     -> dedup scoring: find-similar + bge-m3 embedding shortlist + considered-dishes
     -> CANDIDATE BACKLOG (meal-prep\db\candidate-pool.json): ranked, deduped, pre-qualified,
        persistent across runs. A "hunt" becomes a pop, not a search.

 PLANE 2: JUDGMENT (Claude agents, existing pins, dossier-in / schema'd-ruling-out)
 ────────────────────────────────────────────────────────────────────────
   DECIDE   1 x recipe-dedup-selector    accept/reject per ~10-candidate dossier (2-3KB each)
   EXTRACT  recipe-hunter-extractor      ESCALATIONS ONLY (no JSON-LD + local verify failed)
   MAP      recipe-ingredient-mapper     residual terms only, over a pre-resolved table
   PRICE    recipe-hunter-pricer         singleton; adjudicates pre-gathered rows; drives ONLY
                                         the attended stores (Walmart, Aldi) + blocked retries
   WRITE    recipe-writer                prose fields only, over a machine-complete skeleton
   QA       recipe-source-qa             judgment residue over the QA battery's dossier
   AUDIT    recipe-batch-auditor         judgment residue over wave-preaudit's report; signs GO/NO-GO
   REVIEW   post-publish-reviewer        unchanged
   REGISTRAR commodity-registrar         unchanged
   (+ a rare novelty top-up sourcer round when the backlog cannot satisfy the run's conditions)

 PLANE 3: MECHANICS (scripts + the on-box orchestrator, no LLM, up to 8 cores)
 ────────────────────────────────────────────────────────────────────────
   hunt-run.ps1 state machine | ingredient-queue + Rule B | price-ingredient / probe-ingredient
   unattended CDP store sweeps (pull-browser-stores.py) | coverage/scale/prose-number QA battery
   wave-preaudit battery (8-wide) | build-v2-spec + cost engine | build-card2 | wave-publish.ps1
   lane-log + audit-lane-shape | batch-ledger | local-LLM calls (4 GPU slots) | retries, timers, breaker
```

Publishing stays exactly as v2 built it: waves, batch audit GO, `wave-publish.ps1` only, serveability
gate with per-slug rollback to `held`, post-publish review, ledger close.

## 3. Stage-by-stage redesign

### S-HARVEST (new; replaces the hunt lane's steady state)

A local harvester (`meal-prep\pipeline\harvest.py`) that runs on demand and/or in the nightly window:

1. **Enumerate** recipe URLs from the source-domains ledger's reliable publishers via sitemap.xml,
   `/wp-json/wp/v2/` and category/tag indexes. No search engine, no WebSearch budget. New-publisher
   discovery stays an occasional Claude sourcer job (the ledger has 5 domains today; it grows by
   recording, and one Opus discovery round a month is plenty).
2. **Fetch through fetch-recipe.ps1** (cache + domain-outcome recording already built), 8 workers,
   politeness delays per domain. The cache means the extractor and QA never re-fetch.
3. **Filter mechanically**: JSON-LD present -> nutrition vs the run band is arithmetic; servings
   stated; method words vs batch-scalability rules (no deep-fry-to-order etc.); protein class from
   ingredient nouns; seafood/ground-chicken exclusions by ingredient match. Pages without JSON-LD
   nutrition are kept but flagged `band-unverified` (a Claude decider may still accept structurally
   low-carb dishes, as the current sourcer prompt does).
4. **Signature + dedup scoring**: build the dish signature (protein | method | sauce-family | starch)
   - protein/method/starch mechanically from ingredients+instructions, sauce-family by local-27B
   closed-enum classification (grammar-forced, and *only* a shortlist key, never a verdict). Score
   each candidate against the live catalog and the backlog: find-similar word overlap + bge-m3
   cosine + considered-dishes prior rulings. High-similarity candidates carry their top-5 neighbours
   into the dossier; nothing is auto-rejected by similarity alone except exact URL/slug re-finds.
5. **Rank and store** into `candidate-pool.json`: signature, source, band numbers, verbatim
   ingredient lines (from JSON-LD), neighbour list, saturation-region pressure. The pool is the
   institutional memory the 48% dupe churn never had.

Embeddings and GPU: bge-m3 for a few hundred short signature strings is small. Run it CPU-side first
and **measure** (lib_match.py already falls back to CPU; no CPU number exists today); if CPU is too
slow, batch embedding runs in the sidecar's GPU window (before llama-server starts, per nightly.ps1
ordering). The harvest lane gets its **own embed-cache namespace** - score_cache.py prunes on save to
the texts the sweep saw, so sharing the sweep's cache would evict harvest vectors (sweep.py:35-37).

Effect: the hunt lane's 245 agents / 325M tokens become a nightly local job plus ~1 top-up sourcer
round per run. **This is the single biggest change in the plan.**

### S2 SELECT -> one decider over dossiers (adjudicator lane deleted)

The 8-adjudicator shard existed because candidates arrived raw. With the harvester's dossiers
(signature, band, neighbours-with-evidence, prior rulings, saturation), first-pass dedup is already
done mechanically; what remains is exactly the decider's monopoly: cross-pool judgment, accept/reject
to protein targets, and the single write of accepted-slugs + considered-dishes rulings. One
recipe-dedup-selector invocation per ~10 candidates, dossiers inline (2-3KB each), schema'd verdict
out. The select lane's 333 agents / 242M tokens become ~1 call per 10 candidates with no corpus reads.
Local 27B's role: none in the ruling. Optionally, an adversarial "argue this is a dupe of its top
neighbour" pass orders the dossier (86.4-pt separation shape, signal only).

### S3 EXTRACT -> mechanical first, local second, Claude last

Priority ladder, run by the orchestrator (no Claude wrapper):
1. **JSON-LD present** (the majority on reliable publishers): ingredients/instructions/servings are
   parsed mechanically. The per-line field split (item/qty/unit/prep/optional/section) runs on the
   local 27B per line, grammar-forced, and is verified: `raw` must equal the JSON-LD line (identity by
   construction), qty/unit must re-substring into it, and the split must round-trip
   (qty+unit+item+prep tokens covering the line). Failures fall to rung 2.
2. **local_extract.py** full-page transcription with the existing 85% substring bar.
3. **Escalate to the Claude extractor** exactly as today (`escalate: true` only).
The extractor agent definition does not change; it just stops being invoked for pages rungs 1-2
settle. Expected Claude extraction calls: ~5-15% of pages (bench it in the proving run). Extraction
was only 1.6% of tokens - this is as much an *accuracy and latency* play (JSON-LD is the page's own
statement; no 24k-char prompt truncation) as a cost one.

### S4 MAP -> mechanical pre-resolve, Claude for the residual

New `map-preresolve.ps1` (or .py) runs per micro-batch before any agent is paid:
- For every extracted ingredient: ingredient-resolutions cache -> ingredient-vocab exact/alias ->
  price-ingredient carriage/board answer -> densities/each-nouns availability -> bid-exists check.
- Output: a decision table where the (measured) majority of lines arrive **pre-resolved with
  evidence**, and the residual is precisely enumerated: unresolved names, DIFFERENT-FORM flags,
  new-food suspects, missing food-DB rows, missing densities.
- The **unbid hold** (token-efficiency B-2) is enforced here mechanically: resolved-but-unbid lines
  hold the recipe at `mapped` with a named follow-up; nothing unbid ever reaches the writer.
The mapper agent then rules ONLY the residual: identity judgments, form flips, each-weight calls,
label transcription for new food-DB rows, the macro cross-check vs source (fed the arithmetic
pre-computed: scaled grams x food-DB vs source-published macros, so it verifies rather than derives).
Registrar path unchanged. Local 27B's role: `ingredient-vocab -Query` candidate ordering at most
(rank, never resolve - "Dry White Wine" auto-matching "White Wine Vinegar" is the founding reason).
Map was 13.1% at 627 agents; expect the residual to cut its context by well over half and its call
count substantially, and - more important - to make the vocabulary misses of 2026-08-16 structurally
impossible to reach the writer.

### S5 PRICE -> pre-gathered evidence, judgment-only sessions (shape unchanged)

The singleton lane, Rule B, the queue, -Derive, promotion to carriage.json: all unchanged. What
changes is what the pricer does with its minutes:
- **Server pre-pass (mechanical, before the agent):** probe-ingredient.ps1 for Baker's + Family Fare
  (already server-side), retry ladder + 3-state verdict from search-verdict-lib.
- **Unattended browser pre-pass (mechanical):** pull-browser-stores.py CDP sweeps for Fareway, Sam's
  (needs the member session live), and Hy-Vee single lookups, with the existing pacing profiles and
  wall detection (a wall stops the lane and leaves UNUSABLE, which reads as PENDING - never
  not-carried). This is the same code the capture estate already trusts daily.
- **The pricer agent** receives, per term, the gathered candidate rows + verdict-ladder states from
  all reachable stores, and does the only two things that need it: adjudicate rows ("Saffron Road
  Drunken Noodles is not saffron") and drive the two attended stores (Walmart, Aldi via Brad's
  Chrome) plus any store the pre-pass left UNUSABLE. Records and promotes exactly as today.
Price is 1.4% of tokens - this is a **wall-clock and accuracy** change, not a token one: pricer
sessions shrink from browser-driving marathons to short adjudications, and the search ladder is
enforced by code on every lane instead of by hand on five.
Local 27B's role: none in verdicts. (Optional signal: adversarial "argue this row is NOT the
ingredient" ordering, same doctrine as everywhere else.)

### S6 WRITE -> prose only, over a machine-built skeleton

New `build-intake-skeleton.ps1`: assembles everything mechanical in the intake from mapped\*.json and
the extraction - name/slug/protein/cuisine/source_url, the full `ingredients[]` (grams + buy strings
are already the mapper's arithmetic), `macros_per_serving` (parse-compute), head times (JSON-LD),
visibility. The writer receives the skeleton plus the transcription and fills ONLY: prose.*,
head.description/keywords/steps, writer_notes, forbidden_prose_terms - the fields with no mechanical
check behind them, in Brad's voice, with the existing cost-line-tracing contract. build-v2-spec and
its guards unchanged. Effect: writer calls shrink (4.8% -> ~2-3%) and the writer structurally cannot
introduce a number, which retires the class of prose-number defects rather than catching them at QA.

### S7 QA -> battery first, judgment residue second

Extend the mechanical battery (all pure code, run by the orchestrator before the agent):
- coverage_check.py (built; invented/dropped by head-noun pairing),
- **scale-ratio check** (new): per-line implied ratio vs the recipe's own; flags hand-adjusted lines,
- **prose-number equality** (new): every literal number in prose vs the spec's stat (tokens pass by
  construction),
- title/credit presence + URL match, dash sweep (exists), servings-claim consistency.
The QA agent gets the battery output and rules only what code cannot: deliberate-substitution
defensibility, method survival, dish identity. Verdict schema, one repair cycle, re-QA - unchanged.
QA is 0.3% of tokens; this is pure **accuracy**: the checks that caught 573 post-hoc fidelity findings
become hard pre-gates, and the agent's attention lands entirely on the judgment cases.

### S8 AUDIT -> wave-preaudit battery + judgment sign-off

New `wave-preaudit.ps1 -RunDir -Wave` (the F3 fix), running the entire mechanical audit surface
**8-wide across the wave's slugs**:
macro recompute per spec from food-macros-db; cost reconciliation per spec vs costed.json (to the
cent, tiers ordered); card rebuild to a scratch dir + structural byte-compare vs a known-good card;
protein derivation + update-recipes-db -DryRun; audit-spec-contradictions / audit-store-integrity /
audit-vocab-integrity / audit-unbid-ingredients / audit-cost-plausibility; voice sweep; P8 endpoint
provenance + feed probe. Output: a machine report (per-slug PASS/FAIL per check, with numbers).
The recipe-batch-auditor receives that report and spends its context on the residue: mapping
soundness precedents, price-class plausibility, cross-recipe checks, condition questions - and it
**remains the authority**: it can re-derive anything it distrusts, its GO/NO-GO contract, the scope
declaration, S8 trim, P1b freshness are all unchanged. Re-audits after recipe-local repairs become
nearly free: re-run the battery on the repaired slugs (seconds) + a scoped sign-off.
This attacks the shakedown's 31% directly and makes the third-round-full-re-audit mistake cheap even
when it happens.

### S9 PUBLISH / REVIEW - unchanged

wave-publish.ps1 exactly as built (P1-P8, E6/E7, held, scoped git adds, push-is-deploy). The
post-publish reviewer additionally receives the wave's preaudit report and the collateral count, as
today.

## 4. The orchestrator moves onto the box

### 4.1 What and why

`meal-prep\pipeline\hunt-daemon.py` (Python 3.12, asyncio; the interpreter path rule applies -
C:\Codex\Python312\python.exe): a local process that owns lanes, queues, retries, the breaker, wave
sequencing - everything hunt-orchestrator.js does - with three abilities the sandbox denies:
1. **Mechanics are function calls.** hunt-run.ps1, ingredient-queue.ps1, the batteries, build-v2-spec,
   wave-publish run as subprocesses; results parsed directly. Every agent-as-shell-proxy call in F2
   disappears. Lane-log lines are written by the daemon itself (with -InputTokens/-OutputTokens
   stamped from each agent result, which harvest-lane-tokens currently backfills).
2. **The local LLM is a native client** (graph\lib\llm.py, 4 jobs), and harvest/extract/battery work
   fans out over a process pool (cap 8 - Brad's stated core budget; the box has 16 cores, but the
   capture lanes, the sidecar and the OS keep theirs).
3. **Real timers and real resume.** The breaker can distinguish a wall from flakiness by clock;
   resume re-seeds from `hunt-run.ps1 -Status` + the queue, which is the drain-mode shape already
   proven, instead of `resumeFromRunId` cache replay.

Claude dispatch: headless `claude -p` per judgment call (agent selected by name so the pinned
`.claude\agents\*.md` definitions and models keep applying), `--output-format json`, prompt =
dossier + the stage contract, output schema-validated by the daemon with per-slug retry budgets and
the breaker exactly as hunt-lib prescribes. Concurrency per lane caps as in v2 §2.4 (extract 3, map
2, price 1, write 3, qa 2, decide 1, wave serial).

### 4.2 The re-derivation risk, met head on

The estate's scar tissue is explicit: eleven of twelve defects came from re-deriving the orchestrator
from prose, and SKILL.md forbids exactly that. So the port is governed:
- **hunt-lib parity gate.** hunt-lib.js's pure functions port 1:1 to `hunt_lib.py` with the SAME
  fixture set (B5-B11 + channel semantics), plus the fixtures run against both implementations with
  shared test vectors. The daemon may not dispatch a single agent until the parity suite is green.
- **State, queue, lane-log, ledger, publish contracts do not move.** The daemon calls the same .ps1
  surfaces; audit-lane-shape.ps1 judges its lane log unchanged; a run dir produced by the daemon is
  indistinguishable in shape from one produced by the workflow.
- **Drain-mode drill before any live run**: seed from the existing lowcarb-100 run dir's -Status,
  walk 2-3 recipes through write/qa/wave with publish in -DryRun, diff the run dir against the
  contract.
- **Fallback recorded now:** if headless dispatch proves unreliable, the fallback is NOT to abandon
  v3 - it is to keep a thin Workflow orchestrator for the judgment lanes only, with the daemon doing
  harvest + batteries + seeding via one read-state agent call per resume. That fallback still
  captures F1, F3, F4, F5; it re-pays F2 only for the judgment lanes' bookkeeping.

### 4.3 Core and GPU budget (the "8 cores" answer)

| work | parallelism | bound by |
|---|---|---|
| harvest fetches | 8 async workers | network + per-domain politeness |
| JSON-LD parse, band filter, signatures | 8-proc pool | trivial CPU |
| bge-m3 embeddings | CPU first (measure); else GPU batch in the sidecar window | see §3 S-HARVEST |
| local 27B calls (line-split, full extract, enum, adversarial) | 4 (server --parallel 4; more queues) | GPU |
| QA battery / wave-preaudit | 8-wide across slugs | CPU, seconds |
| cost engine, costed.json, recipes-db | **serial** - single-writer files | correctness |
| CDP store sweeps | 1 thread per store (existing) | vendor politeness - the floor |
| Claude lanes | v2 §2.4 caps | plan/session budget |

The PLAN-use-the-cores rules apply: no fan-out may silence a watcher; single-writer files stay
single-writer; vendor pacing is the floor no core count moves.

### 4.4 GPU scheduling

llama-server is started by hand at run start and stopped at run end (`graph\pipeline\nightly.ps1
-StopOnly`), per the standing ownership rule; a hunt run must be off the card before the 07:00 ad
pull and 08:00 capture (their sweeps go BLIND otherwise), and the nightly chain owns 21:30-06:30.
Harvest's embedding batches schedule around llama-server, or run CPU. Nothing new schedules
llama-server; install-nightly-task.ps1 remains the only scheduler.

## 5. Deliverables

Each ships with its must-fire fixture and clean twin in the same commit, per the guard-fixture rule.

- **D1 `wave-preaudit.ps1`** - the mechanical audit battery (S8), 8-wide, machine report; auditor
  dispatch slimmed to report + residue. Fixtures: a spec with a broken macro recompute MUST FIRE; a
  clean wave passes; a card rebuild diff fires on a mutated built card.
- **D2 QA battery** - extend coverage_check.py with scale-ratio and prose-number checks + a
  `qa-dossier` emitter. Fixtures: one hand-adjusted line fires the ratio check; a prose literal
  disagreeing with stat fires; `{{cost_ps}}` tokens never fire.
- **D3 `harvest.py` + `candidate-pool.json`** - enumeration, cached fetch, band filter, signatures,
  dedup scoring, ranked backlog; source-domains feedback on every fetch. Fixtures: a page with
  out-of-band JSON-LD nutrition is filtered with the numbers recorded; a no-JSON-LD page is kept
  flagged; an exact already-published slug never enters the pool.
- **D4 embedding lane** - bge-m3 signature vectors with a harvest-owned cache namespace; CPU
  latency measured and recorded before any GPU scheduling is built. Fixture: cache eviction twin
  proving harvest vectors survive a sweep save.
- **D5 dossier builder + decider dispatch** - kills the adjudicator lane; one decider call per <=10
  candidates; decider remains sole writer of accepted-slugs + considered-dishes. Fixture: a dossier
  carrying a known catalog near-duplicate surfaces it in the neighbour block.
- **D6 `local_extract.py` v2** - `--from-jsonld` mode + per-line split verification + round-trip
  check; orchestrator-facing exit contract (settled / escalate). Fixtures: an invented line MUST
  FIRE the substring check; a JSON-LD line split that drops a token fails round-trip.
- **D7 `map-preresolve`** - the pre-resolved decision table + mechanical unbid hold; mapper prompt
  rewritten to the residual contract. Fixtures: a cache-resolved term never reaches the residual; an
  unbid resolved term holds the recipe with a named follow-up.
- **D8 `build-intake-skeleton.ps1`** - machine-complete intake skeleton; writer prompt rewritten to
  prose-only. Fixture: a skeleton field the writer changed is refused (numbers are not the writer's).
- **D9 `hunt-daemon.py` + `hunt_lib.py`** - the port, under §4.2's parity gate, lane-log token
  stamping, drain drill. Fixtures: the full hunt-lib suite ported, plus daemon-level twins for B5
  (null is STUCK), B6 (per-slug budgets), B7 (first-token verdicts), B10 (trim), B11 (repair-claim
  mtime check).
- **D10 price evidence pre-pass** - probe + unattended CDP gathering wired into the price lane's
  dossier; pricer prompt rewritten to adjudicate-and-attend. Fixture: an UNUSABLE sweep state reads
  as PENDING, never not-carried (the founding rule, mechanized).
- **D11 SKILL.md v3 rewrite + agent-prompt slimming** - constants out of per-call prompts into the
  agent definitions (prefix-cache friendly), stage contracts updated to dossier-in/ruling-out, the
  v3 lane diagram, and the run-budget practice (fresh session per phase; ask Brad for the usage %
  before each phase - the daemon cannot see the meter either).

## 6. Build order, with gates and stop-rules

Ordered so the biggest measured burns fall first and the risky move is proven before it is load-bearing:

| phase | items | gate to pass before the next phase |
|---|---|---|
| 0 | D1 + D2 (batteries) | batteries green on the real lowcarb-100 wave dirs; a re-audit of one repaired slug costs seconds + one scoped sign-off |
| 1 | D3 + D4 + D5 (harvest + decider) | a harvest of >=200 in-band candidates from >=6 publishers with dupe-dossier spot-check; decider ruling on dossiers alone matches a hand check on 20 candidates; front-end token share re-measured on a mini-run |
| 2 | D6 (extraction ladder) | rung-1/2 settle rate and escalation rate measured on 50 cached pages; zero unverified lines pass |
| 3 | D9 (the daemon) | hunt-lib parity suite green; drain drill per §4.2; audit-lane-shape clean on the daemon's log |
| 4 | D7 + D8 (map/write slimming) | mapper residual rate measured; one wave written from skeletons with guards green |
| 5 | D10 (price pre-pass) | one real absent-term batch priced with pre-gathered evidence; ladder states honest per store |
| 6 | **the proving run**: ~20 recipes, wave size 10, Brad-directed conditions | success criteria written before the run, incl.: per-recipe tokens (billed measure) and wall-clock published; >=5x fewer Claude invocations per published recipe than the 27 measured; zero gate weakened; every new defect class frozen as a fixture same-day |
| E (optional) | 27B LoRA (extraction/line-split), cross-encoder dish-dedup fine-tune | only after 6; >=3 seeds per arm; detached LoRA never a merged GGUF |

**Stop-rules.** Re-measure with lane-tokens/harvest-lane-tokens after phases 1, 3 and 6; if the
remaining spend concentrates somewhere this plan did not predict, the measurement wins and the order
changes. If phase 3's parity gate cannot be made green, ship the §4.2 fallback and stop there - the
plan still captures the large wins.

## 7. Cost and speed model (targets to measure, not promises)

Per published recipe, front-end Claude invocations fall from ~27 measured to ~2 (one decider call per
~10 candidates at the measured ~12-candidates-per-published-recipe yield, plus amortized top-up
sourcing). Extraction Claude calls fall from 1/page to escalations only. Wave-lane shell-proxy calls
fall to zero. The audit's context shrinks to residue + report.

| measure | v2 measured | v3 target |
|---|---|---|
| Claude invocations / published recipe | ~27 front-end + ~10 downstream | **<=6 total** |
| billed tokens / published recipe | 786k shakedown; 200-250k targeted, never hit | **<=150k median** |
| front-end share of run tokens | 75.5% | **<15%** |
| candidate supply latency | minutes-hours of live Opus searching | backlog pop (harvest amortized overnight) |
| re-audit after a recipe-local repair | a full auditor pass | battery seconds + scoped sign-off |
| pricer session shape | browser-driving marathon | adjudication + 2 attended stores |

Wall-clock steady state becomes write -> QA -> wave (the paid lanes), with harvest and batteries
off-path. The pricer singleton and vendor pacing remain the floor for absent-term recipes, by design.

## 8. Accuracy: where each known defect class dies in v3

| defect class (all real, all dated) | v2 catch-point | v3 catch-point |
|---|---|---|
| invented/plausible extraction | source-QA, after write | substring verification at extract, before anything is paid |
| vocabulary miss -> $0.00 ingredient | build-v2-spec throw (after write paid) | map-preresolve, before write |
| unbid ingredient reaches writer | B-2 rule in prompts | mechanical hold at `mapped` |
| prose number drift | QA/audit reading prose | writer cannot produce numbers (skeleton) + battery equality check |
| hand-adjusted scaling line | QA judgment | scale-ratio arithmetic in the battery |
| duplicate dish published | 8-agent adjudication + decider | signature + embedding + prior-rulings dossier, then the same decider |
| "no results" suggestion grid read as results | pricer discipline by hand | search-verdict-lib enforced in code on every store lane |
| unchecked store read as not-carried | prompts + queue arithmetic | unchanged queue arithmetic + UNUSABLE-from-code sweeps |
| audit certifying stale bytes | P1b mtime gate | unchanged, plus battery re-runs are cheap so freshness is easy to restore |
| repair claims that changed nothing | verify-repair agent call | daemon mtime check, no agent |

The audit and reviewer keep their full authority to distrust and re-derive anything; nothing above
narrows what they may check - it narrows what they must re-derive to earn a verdict.

## 9. How this could backfire

- **The harvester starves on enumeration** (publishers without sitemaps/REST, or which block
  crawlers). Mitigation: the ladder keeps the Claude sourcer as top-up; source-domains records which
  publishers enumerate; the phase-1 gate measures yield before anything depends on it.
- **Local line-split quietly mangles fields that still substring-verify** (e.g. prep/optional
  misassigned). Mitigation: round-trip coverage check (D6), and source-QA's coverage battery
  downstream pairs on head nouns, which catches item misassignment; measured escalation rate in the
  phase-2 gate.
- **Signature enums flatten distinct regional dishes into one key** -> false dupe pressure.
  Mitigation: similarity is never auto-reject; the dossier shows the neighbour evidence and the
  decider rules; considered-dishes stays advisory.
- **The daemon re-earns the twelve orchestrator bugs.** Mitigation: §4.2's parity gate is a hard
  precondition, the fixtures are ported not rewritten, and the fallback is recorded in advance.
- **`claude -p` headless dispatch behaves differently from the Workflow harness** (permissions,
  model pins, structured output). Mitigation: phase-3 drill dispatches every agent type once against
  scratch inputs and diffs behavior before any live run; fallback per §4.2.
- **GPU contention breaks the 07:00/08:00 sweeps.** Mitigation: §4.4 - hand start/stop, nightly.ps1
  -StopOnly, the existing nvidia-smi guards stay as backstops; harvest embeddings CPU-first.
- **CDP sweeps trip walls the pricer used to avoid by being slow.** Mitigation: the sweeps reuse the
  capture estate's pacing profiles and wall-stop behavior verbatim; a wall leaves PENDING; Walmart
  and Aldi stay attended, as the capture estate already concluded.
- **The backlog goes stale** (publishers edit recipes; prices/carriage drift). Mitigation: candidates
  re-verify at extract time from the cache-or-refetch, and carriage is only ever ruled at price time.

## 10. What does not move (the invariants, restated so nobody relitigates them)

Rule B; unchecked is never not-carried; extraction is transcription; the ingredient vocabulary and id
namespace are closed (registrar gate); the mapper's evidence gate and null-is-safe; no stage writes
board cells; the writer computes no number; no em dashes; 14-serving scaling; wave-publish.ps1 is the
only publish path; the auditor is never overruled; no gate is ever weakened to pass a recipe; the
lane log is append-only and audit-lane-shape judges every run; spawned tasks use repo-relative paths;
nothing writes the tree while a wave is being verified; deviations are recorded in the run dir before
the run. The local-placement doctrine (§1.4) joins this list: **local may verify-ably transcribe,
reject, rank and flag; it may never assert an identity or touch Brad's voice.**

## 11. Explicitly out of scope

- Weakening or cheapening the audit tier (its 31% bought every correct NO-GO this estate has).
- Per-recipe publishing (the wave boundary amortizes propagate + the audit).
- Reviving anything from the deleted V3 platform.
- Fine-tuning as a dependency of anything above (Phase E is optional and gated).
- Parallelizing the price lane (singleton stands; a change there is a measured decision for Brad).
- Any board/commodity capture-pipeline changes beyond reading what it already produces.
