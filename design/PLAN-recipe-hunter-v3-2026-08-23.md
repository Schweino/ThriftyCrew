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

### S1 HARVEST (new; replaces the hunt lane's steady state)

A local harvester (`meal-prep\pipeline\harvest.py`) with two sub-commands, split by what they need:
**`--crawl`** (enumerate, fetch, parse, band-filter, mechanical signature parts, dedup-score,
store) needs NO GPU and runs any time, operator-started; **`--classify`** (the sauce-family
local-enum backfill) needs llama-server up, so it runs only while the card is hand-held per §4.4
and REFUSES with a clear message when the server is down (the audit-semantic-identity BLIND
pattern) - pool entries sit with `sauce_family: null` until a classify pass fills them, and a null
sauce-family only widens the neighbour search, never blocks a candidate. Nothing about harvest is
scheduled in the initial build; folding a harvest step into graph\pipeline\nightly.ps1 (the
sanctioned owner of scheduled GPU work) is a later decision for Brad.

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
   **Parse JSON-LD nutrition defensively - this is a silent-wrongness trap.** Values arrive as
   strings with units ("418 kcal", "20 g"), `recipeYield` arrives as ranges and prose ("8", "6-8",
   "makes 8 patties"), and some sites publish per-RECIPE nutrition where schema.org means
   per-serving. Rules: numbers are extracted, never inferred; a yield that does not parse to one
   integer, or nutrition whose serving basis is ambiguous (e.g. calories implausible for one serving
   of the stated dish class - outside 100-2000), demotes the candidate to `band-unverified` rather
   than filtering it in or out on a guess. The band filter may only ever act on numbers it can
   defend; everything else is a flag for the decider.
4. **Signature + dedup scoring**: build the dish signature (protein | method | sauce-family | starch)
   - protein/method/starch mechanically from ingredients+instructions, sauce-family by local-27B
   closed-enum classification (grammar-forced, and *only* a shortlist key, never a verdict).
   **The enums are not invented here**: the method vocabulary is the one considered-dishes.ps1
   already records (`-Method` values in `db\considered-dishes.json`), and the sauce-family
   vocabulary is the one make-saturation.ps1 already derives - one taxonomy shared with the
   saturation brief and the prior-rulings ledger, or the three stop lining up. Score
   each candidate against the live catalog and the backlog: find-similar word overlap + bge-m3
   cosine + considered-dishes prior rulings. High-similarity candidates carry their top-5 neighbours
   into the dossier; nothing is auto-rejected by similarity alone except exact URL/slug re-finds.
5. **Rank and store** into `candidate-pool.json`. One entry per candidate, shape (so the pool has a
   contract, not a vibe):
   `{slug, name, url, domain, first_seen, last_verified, signature: {protein, method, sauce_family,
   starch}, band: {cal, carbs, protein_g, verified: true|false}, servings, ingredients_verbatim: [],
   neighbours: [{slug, score, shared}], prior_rulings: [], saturation_pressure,
   status: "available" | "taken:<run-id>" | "ruled:<verdict>"}`.
   **harvest.py is the pool's single writer.** Consumption and rulings flow back through it
   (`harvest.py --mark-taken <slug> --run <id>` / `--mark-ruled <slug> --verdict <v>`), invoked by
   the orchestrator when the decider rules - a candidate the decider rejected must never resurface
   as `available`, and one a run took must not be offered to a second run. Top-up sourcer finds
   enter through the SAME gate (`harvest.py --ingest <candidates.json>`), so every candidate -
   crawled or searched - gets the same band check, signature, and dedup scoring before the pool
   will hold it; there is exactly one road into the pool. The pool is the
   institutional memory the 48% dupe churn never had.

   Politeness is part of the contract: respect robots.txt, per-domain pacing of one request every
   2-4s regardless of worker count, a per-domain nightly cap, and every fetch outcome recorded to
   source-domains (three failures = blocked, exactly as the ledger already scores). A publisher that
   walls the harvester is skipped and reported, never hammered - same doctrine as the stores.

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
**Authorship vs pen:** the decider remains the sole AUTHOR of acceptances and considered-dishes
rulings - but in v3 it returns them as a schema'd verdict and the orchestrator performs the writes
(accepted-slugs.json, `considered-dishes.ps1 -Record`, state advances), attributed `-By decider`. The
agent stops running shell entirely. Acceptance pacing keeps v2's WIP discipline: the orchestrator
pops candidates from the pool only while accepted-but-unresolved recipes sit under the WIP limit
(25), so a deep backlog cannot flood the paid lanes.
Local 27B's role: none in the ruling. (An adversarial "argue this is a dupe of its top neighbour"
ordering pass is a candidate for later - **explicitly DEFERRED out of the initial build**; revisit
only if phase-6 measurements show the decider mis-prioritizing, and never as a verdict.)
The recipe-dedup-selector agent definition needs its dossier-contract rewrite (its current text
specifies parallel per-protein selectors and selected-*.json file outputs, both retired here) - that
rewrite is part of D5.

### S3 EXTRACT -> mechanical first, local second, Claude last

Priority ladder, run by the orchestrator (no Claude wrapper):
1. **JSON-LD present** (the majority on reliable publishers): ingredients/instructions/servings are
   parsed mechanically. The per-line field split (item/qty/unit/prep/optional/section) runs on the
   local 27B per line, grammar-forced, and is verified: `raw` must equal the JSON-LD line (identity by
   construction), qty/unit must re-substring into it, and the split must round-trip
   (qty+unit+item+prep tokens covering the line). Failures fall to rung 2.
2. **local_extract.py** full-page transcription with the existing 85% substring bar.
3. **Escalate to the Claude extractor** exactly as today (`escalate: true` only).
The extractor agent is invoked only for pages rungs 1-2 could not settle - and its definition needs
one edit for that role: its current "TRY THE LOCAL MODEL FIRST" section is REPLACED with
escalation-role text ("you receive only pages the local pass could not settle; the failure reason
and unverified lines are in your dispatch - do not re-run the local script"), because in v3 every
page that reaches it has ALREADY failed the local pass, and re-running local_extract there would
waste minutes re-earning a failure the dispatch already carries.
Expected Claude extraction calls: ~5-15% of pages (bench it in the proving run). Extraction
was only 1.6% of tokens - this is as much an *accuracy and latency* play (JSON-LD is the page's own
statement; no 24k-char prompt truncation) as a cost one.

### S4 MAP -> mechanical pre-resolve, Claude for the residual

New `map-preresolve.ps1` (PowerShell - it composes ingredient-vocab, ingredient-resolutions and
price-ingredient, which are all PS surfaces) runs per micro-batch before any agent is paid, writing
`mapped-pre\<slug>.json` per the §4.5 contract:
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
**The mapper stops running hunt-run and ingredient-queue itself.** It returns a schema'd result
(per-slug decisions, absent_terms as a JSON array, optional_terms, holds); the orchestrator performs
`-Advance`, `ingredient-queue -Add` and `-Derive` from that structure. This retires the B8 class
(`-Terms 'a,b'` bound as one composite string parking recipes forever) by construction - a JSON
array cannot be comma-joined by accident - instead of by prompt warning.
Registrar path unchanged. Local 27B's role in mapping: **none in the initial build** (a
vocab-candidate ordering signal is DEFERRED alongside S2's and S5's; and it could only ever rank,
never resolve - "Dry White Wine" auto-matching "White Wine Vinegar" is the founding reason).
Map was 13.1% at 627 agents; expect the residual to cut its context by well over half and its call
count substantially, and - more important - to make the vocabulary misses of 2026-08-16 structurally
impossible to reach the writer.

### S5 PRICE -> pre-gathered evidence, judgment-only sessions (shape unchanged)

The singleton lane, Rule B, the queue, -Derive, promotion to carriage.json: all unchanged. What
changes is what the pricer does with its minutes:
- **Server pre-pass (mechanical, before the agent):** probe-ingredient.ps1 for Baker's + Family Fare
  (already server-side), retry ladder + 3-state verdict from search-verdict-lib.
- **Unattended browser pre-pass (mechanical):** pull-browser-stores.py CDP sweeps for Fareway and
  Hy-Vee single lookups, with the existing pacing profiles and wall detection (a wall stops the
  lane and leaves UNUSABLE, which reads as PENDING - never not-carried). This is the same code the
  capture estate already trusts daily. **Sam's Club sweeps only when the driver profile carries a
  live member session** - the daemon checks that precondition before dispatching the sweep, and an
  absent session makes Sam's UNUSABLE for the batch (the pricer attends it), never a guess against
  a logged-out storefront.
- **The pricer agent** receives, per term, the gathered candidate rows + verdict-ladder states from
  all reachable stores, and does the only two things that need it: adjudicate rows ("Saffron Road
  Drunken Noodles is not saffron") and drive the attended browser surfaces per its existing
  two-surface contract (Walmart and Aldi today) plus any store the pre-pass left UNUSABLE.
  **The pricer keeps running `-Record`/`-Verdict`/`-Promote` itself** - unlike the other lanes, its
  evidence contract is enforced at the script layer (carried-requires-a-price, exact store names,
  PENDING-never-promotes) and that enforcement is worth keeping at the point of entry. `-Derive`
  after each invocation moves to the orchestrator.
Price is 1.4% of tokens - this is a **wall-clock and accuracy** change, not a token one: pricer
sessions shrink from browser-driving marathons to short adjudications, and the search ladder is
enforced by code on every lane instead of by hand on five.
Local 27B's role: none in verdicts. (An adversarial row-ordering signal is **DEFERRED out of the
initial build**, same as S2's - build it only if phase-6 measurement shows the pricer needs it.)

### S6 WRITE -> prose only, over a machine-built skeleton

New `build-intake-skeleton.ps1`: assembles everything mechanical in the intake from mapped\*.json and
the extraction - name/slug/protein/cuisine/source_url, the full `ingredients[]` (grams + buy strings
are already the mapper's arithmetic), `macros_per_serving` (parse-compute), head times (JSON-LD),
visibility. The writer receives the skeleton plus the transcription and fills ONLY: prose.*,
head.description/keywords/steps, writer_notes, forbidden_prose_terms - the fields with no mechanical
check behind them, in Brad's voice, with the existing cost-line-tracing contract. build-v2-spec and
its guards unchanged. Effect: writer calls shrink (4.8% -> ~2-3%) and the writer structurally cannot
introduce a number, which retires the class of prose-number defects rather than catching them at QA.

Two consequences worth naming so they get built:
- **The run-band gate moves BEFORE write.** The skeleton carries `macros_per_serving` from
  parse-compute, so an out-of-band recipe is retired at skeleton build (state `rejected-macros`, as
  the existing state machine already supports) before any prose is paid for. v2 checked the band on
  the WRITE result - after the most expensive per-recipe stage had already run.
- **The skeleton is a postcondition, not a suggestion.** After the writer returns, the orchestrator
  diffs the intake's machine fields against the skeleton it issued; any drift (a gram, a buy string,
  a macro) rejects the intake and re-dispatches with the drift named. That is the D8 fixture's
  enforcement mechanism.

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
cent, tiers ordered); card rebuild to per-slug scratch dirs + structural byte-compare vs a
known-good card;
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

### 4.1a The dispatch adapter (the part of D9 most likely to be built wrong - read this twice)

Judgment calls go out as headless Claude Code invocations. **`claude -p` cannot invoke a named
subagent as its top-level agent** - subagents in `.claude\agents\` are things a running session
delegates to, not entry points - and prompting a headless main loop to "use the recipe-writer
subagent" pays for TWO contexts per call (the main loop plus the subagent), which quietly defeats
the plan. The adapter therefore reconstructs each agent from its definition file:

1. Parse the agent's `.claude\agents\<name>.md` frontmatter (model, tools, effort) and body.
2. Dispatch `claude -p` with: `--model <the pinned model>`, `--append-system-prompt <the agent
   body>`, `--allowedTools <the frontmatter tool list>`, `--output-format json`, cwd = repo root,
   and the estate's permission settings. The user prompt is the dossier + stage contract only.
3. Parse the JSON result envelope; validate the payload against the stage schema in the daemon;
   re-ask once on schema failure; then per-slug retry budgets and the breaker exactly as hunt-lib
   prescribes. A transport/timeout failure is a null - STUCK, never a verdict (B5).
4. Where a frontmatter field has no CLI flag (e.g. `effort`), record the gap in the drill report
   rather than silently dropping it; if it materially changes an agent's behavior, that is a
   phase-3 finding to resolve before go-live, not after.

**The phase-3 drill must dispatch every agent type once against scratch inputs and (a) diff its
behavior against a Workflow-dispatched twin, (b) measure the fixed per-call overhead** - a headless
invocation loads project context (CLAUDE.md, settings, memory) on every call, and whether that costs
more or less than a Workflow subagent's per-dispatch overhead is a question for the drill's
measurement, not for this document's assumption. If measured overhead is large, the counter-move is
bigger dossiers per call (the batch sizes are caps, not quotas), and the recorded fallback in §4.2
remains.

**State-write ownership changes with the daemon, and this is an accuracy feature, not a style
choice:** judgment agents stop running `hunt-run.ps1` / `ingredient-queue.ps1 -Add` / ledger stamps
themselves. They return schema'd verdicts; the daemon performs every state advance, queue add,
`-Derive`, lane-log line (both start/end events, since it owns a real clock) and ledger stamp,
attributed `-By <stage>`. Agent-side marshalling bugs (B8's composite `-Terms` string) become
impossible rather than warned against. Two deliberate exceptions: the pricer keeps `-Record`/
`-Promote` (script-enforced evidence contract, §3 S5), and content artifacts (extraction JSON,
intake prose, spec builds via build-v2-spec) remain the agents' own writes - they are the work
product, not bookkeeping.

**The wave lane's control flow is a PORT, not a rewrite.** `runWave`/`trimWave` in
hunt-orchestrator.js encode S8 trim, the repair cycle, the B11 mtime postcondition, and the B-4
scope gate, each carrying a dated founding bug. The daemon reproduces that control flow
decision-for-decision (the agent-as-shell steps inside it become direct calls; everything else keeps
its order and its refusal conditions), and the hunt-lib fixtures for planTrim / chooseScope /
repairClaimHolds are the parity proof.

Concurrency per lane caps as in v2 §2.4 (extract 3, map 2, price 1, write 3, qa 2, decide 1, wave
serial), with the WIP limit (25 accepted-but-unresolved) gating pool pops exactly as it gated
sourcing. All caps, the WIP limit, retry budgets and breaker thresholds live as named constants in
hunt_lib.py - they are daemon CONFIG, not architecture. With the front end nearly free, the
bottleneck moves to write/qa/audit, so raising those caps after the proving run measures them is a
legitimate lever - **a measured decision for Brad**, per the estate's speed-measured-not-guessed
rule, with one exception that is architecture: the price lane stays a singleton, full stop.

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
| bge-m3 embeddings | CPU first (measure); else GPU batch in the sidecar window | see §3 S1 |
| local 27B calls (line-split, full extract, enum, adversarial) | 4 (server --parallel 4; more queues) | GPU |
| QA battery / wave-preaudit | 8-wide across slugs | CPU, seconds |
| cost engine, costed.json, recipes-db | **serialized by the daemon's cost-engine mutex (§4.5)** - spec assembly stays parallel, the cost pass does not | correctness |
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

### 4.4a Model pins: preserved, and re-ratified against the changed roles

**The frontmatter in `.claude\agents\*.md` is the single authority on model and effort.** The
dispatch adapter (§4.1a) reads it per call; nothing in v3 hardcodes a model anywhere, and this
table is a dated ratification record, NOT a second source of truth - if the two ever disagree, the
frontmatter wins and this row is stale. (The estate's own lesson: duplicated lists in two agent
prompts is what source-domains.ps1 was built to retire.)

| agent | pin (2026-08-23) | what v3 changes about its job | pin verdict |
|---|---|---|---|
| recipe-sourcer | opus-4-8 / high | volume collapses to rare top-up + new-publisher discovery | HOLD - rarer, but each call is open-ended research, the hardest shape there is |
| recipe-dedup-selector (DECIDE) | opus-4-8 / high | absorbs the adjudicators' work; rules over dossiers | HOLD - it now carries the whole dedup ruling alone; if anything this pin matters MORE |
| recipe-hunter-extractor | fable / medium | escalation-only: the pages local could not settle | **HOLD, and explicitly do not cheapen** - see the residue principle below |
| recipe-ingredient-mapper | fable / high | residual-only: the judgment lines, pre-resolved table supplied | HOLD |
| recipe-hunter-pricer | opus-5 / medium | adjudicates pre-gathered rows; attends the walled stores | HOLD - carriage rulings are unrecoverable downstream |
| recipe-writer | opus-4-8 / high | prose only, over a machine-locked skeleton | HOLD - what remains is exactly the part that needs the voice |
| recipe-source-qa | fable / medium | judgment residue over the battery report | HOLD |
| recipe-batch-auditor | fable / high | judgment residue over the preaudit report; still signs GO/NO-GO | HOLD - the tier that caught B12, the lying repair, and both correct NO-GOs |
| post-publish-reviewer | fable / high | unchanged | HOLD |
| commodity-registrar | fable / medium | unchanged | HOLD |

**THE RESIDUE PRINCIPLE, and it is the point of this subsection.** v3 strips the mechanical
majority out of every judgment lane. What is left in each dispatch is the *hard residue* - the
pages local could not verify, the ingredients the cache and vocabulary could not resolve, the
findings arithmetic could not settle. **The average call gets harder, not easier, even as it gets
shorter.** So the standing conclusion is: v3 is an argument for HOLDING every pin, and against
every tier downgrade.

This matters because a future efficiency-minded session will read the slimmed prompts, see small
inputs, and reason "these are cheap now, drop a tier." One specific inversion is already on the
record and must not be re-derived wrongly: PLAN-token-efficiency-2026-08-16 section 4 Group E
floated the extractor as "the only cheap-model candidate among the Fable pins, because source-QA
independently re-checks its output." **That argument is void in v3, twice over.** First, the easy
pages no longer reach the extractor at all - only the ones a verified local pass failed on. Second,
the safety net Group E leaned on is weakest on exactly that set: coverage_check compares the built
spec against the TRANSCRIPTION, so an invented transcription passes coverage by construction, and
source-QA's independent anchor is the live page re-fetch - which is unavailable precisely on the
blocked and unparseable pages that dominate escalations. An invented recipe remains the worst
outcome in this flow; cheapening the extractor in v3 means putting the weakest model on the
hardest inputs at the point where the net has the widest holes.

Model-tier changes therefore stay OUT of this plan entirely (§11), exactly as Group E held them:
each is its own measured experiment against a baseline, ordered by Brad, never a build-time
convenience.

### 4.5 Contracts (normative - the no-guessing appendix)

Every artifact v3 introduces, with its path, producer, and shape. An implementer should never have
to invent a filename, a field, or a threshold; if something here conflicts with code reality at
build time, fix THIS document in the same commit rather than deviating silently.

**Artifacts**

| artifact | path | producer -> consumers |
|---|---|---|
| candidate pool | `meal-prep\db\candidate-pool.json` | harvest.py (SOLE writer; the daemon serializes every mutation call through one lock) -> daemon, dossier builder |
| extraction | `<RunDir>\extracted\<slug>.json` | rung 1/2 (local) or rung 3 (Claude) -> map, QA, coverage_check |
| map pre-resolve table | `<RunDir>\mapped-pre\<slug>.json` | map-preresolve -> mapper dispatch, daemon |
| mapper decision file | `<RunDir>\mapped\<slug>.json` | mapper agent (unchanged contract) -> skeleton builder, auditor |
| intake skeleton snapshot | `<RunDir>\intake\<slug>.skeleton.json` | build-intake-skeleton.ps1 -> the post-write diff |
| intake (writer-completed) | `<RunDir>\intake\<slug>.json` | skeleton builder writes machine fields; writer completes prose IN PLACE -> build-v2-spec |
| QA battery report | `<RunDir>\qa\<slug>.battery.json` | QA battery -> QA dispatch, daemon |
| QA verdict | `<RunDir>\qa\<slug>.json` | recipe-source-qa (unchanged shape) -> daemon, auditor |
| wave preaudit report | `<RunDir>\waves\wave-<k>.preaudit.json` | wave-preaudit.ps1 -> auditor dispatch, reviewer dispatch, daemon |
| price evidence | `<RunDir>\price-evidence\batch-<n>.json` | server probe + CDP sweeps -> pricer dispatch |
| dispatch schemas + daemon config | `meal-prep\pipeline\hunt_lib.py` (ONE module) | daemon + fixtures |

**Shape rules**

- **Extraction is ONE contract regardless of rung.** All three rungs emit the exact shape the
  extractor agent already returns - `{state, reason, title, source_url, servings, time_total,
  time_active, ingredients: [{raw, item, qty, unit, prep, optional, section}], instructions: [],
  concerns: []}` - plus `extracted_by: "jsonld-local" | "local-page" | "claude"` and the verifier's
  `verification` block. Downstream code must not care which rung settled a page. JSON-LD
  `recipeInstructions` arrives as plain strings OR `HowToStep`/`HowToSection` objects; the parser
  flattens both into the ordered string list.
- **Pre-resolve rows:** per ingredient `{raw, canon_item, bid, board, resolution: "resolved" |
  "unresolved" | "different-form" | "unbid" | "new-food-suspect", gpu_known, density_known,
  fooddb_known, evidence, source: "cache" | "vocab" | "alias"}`.
- **Skeleton locked vs writer-fillable** (from the intake schema in build-v2-spec): LOCKED - name,
  slug, protein, cuisine, source_url, visibility, `ingredients[]` (item/grams/buy),
  `macros_per_serving`, head.prepTime/cookTime/totalTime. WRITER-FILLABLE - `prose.*`,
  head.description/keywords/steps/step_names, `writer_notes`, `forbidden_prose_terms`. The
  post-write check is `build-intake-skeleton.ps1 -Verify -InFile <intake> -Skeleton <snapshot>`:
  exit 1 on any locked-field drift, naming the fields.
- **Preaudit report:** per-slug per-check `{check, verdict: "pass"|"fail", numbers, detail}` plus
  one shared-checks block (db-agreement-class audits, P8 probe) that runs ONCE per wave, not per
  slug. Card rebuilds go to per-slug scratch dirs (no collision). **The auditor's
  `wave-<k>.audit.md` remains the artifact wave-publish P1/P1b read; the preaudit report is an
  input to the auditor, never a substitute for its GO.**
- **Price evidence:** per term per store `{store, state: "MATCHES"|"EMPTY"|"UNUSABLE", term_used,
  attempts: [], hits: [{item, price, size, url}] (cap 8), reason}` - the search-verdict-lib shape,
  serialized. The pricer adjudicates from it and records via ingredient-queue exactly as today.
- **Dispatch schemas:** the normative baseline is hunt-orchestrator.js's inline set (CANDS, STAGE,
  MAPPED, DERIVE, QA, WAVECLOSE, AUDIT, REPAIRCHECK, PUB), moved verbatim into hunt_lib.py. Two
  named deltas, and only these: **SEL is replaced by DECIDE** - `{decisions: [{slug, verdict:
  "accepted" | "rejected-dupe" | "rejected-not-fit" | "deferred", reason, dupe_of: [], record:
  {name, protein, method, verdict, reason}}], note}` (the `record` block is what the daemon writes
  to considered-dishes verbatim); **WRITE drops its macro fields** - the band is settled pre-write,
  so the writer returns `{slug, status, state, detail}` only.

**Exit-code convention** for every new battery/pre-resolve script: 0 = clean, 1 = findings (the
machine report is still written), 2 = could-not-run (missing input, parse failure). **Exit 2 is a
blocked stage, never a pass** - could-not-look is never a clean bill, mechanized.

**Thresholds (defaults; change only with a recorded reason in the run dir)**

- Band: inclusive on both edges, exactly as the run's conditions state them.
- Scale-ratio: the recipe's ratio is the MEDIAN of per-line implied ratios (scaled grams vs source
  qty); a line deviating >10% after the house quarter-quantization allowance = battery FAIL routed
  to the QA agent's judgment (a deliberate substitution may survive); 5-10% = note. Lines the
  source states without a quantity are exempt.
- Prose-number equality: every numeral literal in `prose.*` and head.description must equal one of
  stat.{cal, protein, carbs, fat, cost_ps} or the serving count at its printed precision; `{{...}}`
  tokens pass by construction; package-size claims are NOT in scope here - they stay under the
  writer's cost-line-tracing contract and the auditor.
- Local line-split acceptance (rung 1): `raw` equals the JSON-LD line; qty and unit substrings of
  raw verbatim; qty+unit+item+prep must jointly cover >=90% of raw's non-stopword tokens. ANY
  failing line sends the whole page to rung 2.

**Resume seed table** (the daemon's `-Status`-driven re-entry; normative so nobody re-derives it):

| state on disk | daemon action |
|---|---|
| sourced / selected | extraction ladder |
| extracted | map lane |
| mapped with open holds (unbid / vocab follow-ups) | held list in -Status output; NOT dispatched |
| pricing / parked | run `-Derive` first; price lane only if still pending |
| priced | skeleton build (band gate) -> write lane |
| spec-built / written | qa lane (stages skip work whose output file exists) |
| qa-passed | wave pool |
| waved | wave lane, resuming at the first un-stamped ledger stage |
| published, not verified | post-publish review pending |
| held | open-items report; never auto-republished |
| STUCK (per the prior run's report) | re-enter the lane that stalled |

**The cost-engine mutex (a live race v2 tolerated; v3 removes it).** `build-v2-spec -RunCost`
shells the cost engine, which rewrites `db\costed.json`; the write lane runs 3 concurrent writers,
so v2 raced on that file (the wave-2 audit watched costed.json rewritten mid-audit by wave-3
traffic). The daemon holds ONE process-wide lock around every cost-engine invocation - the -RunCost
cost pass, preaudit cost re-runs, compute-v2-perserving. Spec assembly stays parallel; only the
cost pass serializes. Fixture in D9: two write-lane completions landing together produce two
serialized cost passes and a costed.json that parses.

**Lane-log completeness:** every settle gets a lane-log line, including rung-1/2 local extractions
(`-By local`, tokens 0) - the lane log is the only record of the run's SHAPE, and a page settled
locally is work done, not work skipped. audit-lane-shape continues to judge the log unchanged.

## 5. Deliverables

Each ships with its must-fire fixture and clean twin in the same commit, per the guard-fixture rule.

- **D1 `wave-preaudit.ps1`** - the mechanical audit battery (S8), 8-wide with per-slug scratch
  dirs, machine report + exit codes per the §4.5 contract; auditor dispatch slimmed to report +
  residue. Fixtures: a spec with a broken macro recompute MUST FIRE; a clean wave passes; a card
  rebuild diff fires on a mutated built card; a missing input exits 2 and reads as blocked, not
  clean.
- **D2 QA battery** - extend coverage_check.py with scale-ratio and prose-number checks (thresholds
  per §4.5) + the `<slug>.battery.json` emitter. Fixtures: one hand-adjusted line fires the ratio
  check; a prose literal disagreeing with stat fires; `{{cost_ps}}` tokens never fire.
- **D3 `harvest.py` + `candidate-pool.json`** - enumeration, cached fetch, band filter, signatures,
  dedup scoring, ranked backlog with the S1 pool schema and single-writer verbs (--mark-taken,
  --mark-ruled, --ingest for sourcer finds); source-domains feedback on every fetch. Fixtures: a
  page with out-of-band JSON-LD nutrition is filtered with the numbers recorded; a no-JSON-LD page
  is kept flagged; an ambiguous serving basis demotes to band-unverified (never a guess); an exact
  already-published slug never enters the pool; a `ruled:` candidate never resurfaces as available;
  an --ingest candidate gets the same band/signature/dedup treatment as a crawled one.
- **D4 embedding lane** - bge-m3 signature vectors with a harvest-owned cache namespace; CPU
  latency measured and recorded before any GPU scheduling is built. Fixture: cache eviction twin
  proving harvest vectors survive a sweep save.
- **D5 dossier builder + decider dispatch** - kills the adjudicator lane; one decider call per <=10
  candidates; decider is sole author of acceptances and rulings, returned as a schema'd verdict the
  orchestrator writes (S2). Includes the recipe-dedup-selector prompt rewrite to the dossier
  contract. Fixture: a dossier carrying a known catalog near-duplicate surfaces it in the neighbour
  block; a decider verdict is written to accepted-slugs/considered-dishes byte-for-byte as ruled.
- **D6 `local_extract.py` v2** - `--from-jsonld` mode + per-line split verification + round-trip
  check; orchestrator-facing exit contract (settled / escalate); the extractor agent's
  "try local first" section removed/gated for its escalation-only role (S3). Fixtures: an invented
  line MUST FIRE the substring check; a JSON-LD line split that drops a token fails round-trip.
- **D7 `map-preresolve`** - the pre-resolved decision table + mechanical unbid hold; mapper prompt
  rewritten to the residual contract. Fixtures: a cache-resolved term never reaches the residual; an
  unbid resolved term holds the recipe with a named follow-up.
- **D8 `build-intake-skeleton.ps1`** - machine-complete intake skeleton; the pre-write band gate;
  writer prompt rewritten to prose-only; the orchestrator's post-write machine-field diff (S6).
  Fixtures: a skeleton field the writer changed is refused by the diff; an out-of-band skeleton
  retires before any writer dispatch; a clean prose-only fill passes untouched.
- **D9 `hunt-daemon.py` + `hunt_lib.py` + the dispatch adapter (§4.1a)** - the port, under §4.2's
  parity gate; daemon-owned state writes and lane-log start/end pairs with token stamping; the wave
  control flow ported decision-for-decision. Fixtures: the full hunt-lib suite ported, plus
  daemon-level twins for B5 (null is STUCK), B6 (per-slug budgets), B7 (first-token verdicts), B8
  (a mapper verdict with terms as a JSON array lands on the queue as distinct terms), B10 (trim),
  B11 (repair-claim mtime check), and the cost-engine mutex (§4.5: two concurrent write-lane
  completions produce serialized cost passes and a parseable costed.json); plus the adapter drill
  artifacts: per-agent behavior diff vs a Workflow twin and the measured per-dispatch fixed
  overhead.
- **D10 price evidence pre-pass** - probe + unattended CDP gathering wired into the price lane's
  dossier; pricer prompt rewritten to adjudicate-and-attend. Fixture: an UNUSABLE sweep state reads
  as PENDING, never not-carried (the founding rule, mechanized).
- **D11 SKILL.md v3 rewrite + agent-prompt slimming** - constants out of per-call prompts into the
  agent definitions (prefix-cache friendly), stage contracts updated to dossier-in/ruling-out, the
  v3 lane diagram, and the run-budget practice (fresh session per phase; ask Brad for the usage %
  before each phase - the daemon cannot see the meter either).
  **Every agent-prompt or skill edit in D5/D6/D7/D8/D10/D11 must be followed by
  `ops\audit-prompt-backup.ps1 -Sync` with `ops\prompt-backup` committed** - the estate audits live
  prompts against that mirror and flags unsynced drift as a finding.

## 6. Build order, with gates and stop-rules

Ordered so the biggest measured burns fall first and the risky move is proven before it is
load-bearing. **Phases 0-2 land BEFORE the daemon exists, so each names its bridge to the current
Workflow orchestrator** - none of them is inert while phase 3 waits:

- **Phase 0 bridge:** the batteries are run BY the agents as their first instruction (exactly the
  coverage_check.py pattern that already works) - the auditor's dispatch starts "run wave-preaudit
  and audit the residue", the QA dispatch starts with the QA battery. The daemon later moves the
  invocation pre-dispatch; the token savings start now either way.
- **Phase 1 bridge:** the harvester feeds the existing orchestrator through the proven drain-mode
  shape - hunt/adjudicate lanes off, one seed step reads the pool and pipes accepted work downstream;
  the decider dispatch carries dossiers inline. The mini-run for the phase gate runs in exactly this
  configuration.
- **Phase 2 bridge:** until the daemon exists, rungs 1-2 of the extraction ladder run as a
  pre-extraction sweep over the accepted candidates (a script pass on the box, since the Workflow
  cannot shell), and the workflow's extract lane is dispatched only for the escalations the sweep
  left behind.

| phase | items | gate to pass before the next phase |
|---|---|---|
| 0 | D1 + D2 (batteries) | batteries green on the real lowcarb-100 wave dirs; a re-audit of one repaired slug costs seconds + one scoped sign-off |
| 1 | D3 + D4 + D5 (harvest + decider) | a harvest of >=200 in-band candidates from >=6 publishers with dupe-dossier spot-check; decider ruling on dossiers alone matches a hand check on 20 candidates; front-end token share re-measured on a mini-run |
| 2 | D6 (extraction ladder) | rung-1/2 settle rate and escalation rate measured on 50 cached pages; zero unverified lines pass |
| 3 | D9 (the daemon + §4.1a adapter) | hunt-lib parity suite green; adapter drill: per-agent behavior diff vs Workflow twins + measured per-dispatch overhead; drain drill per §4.2; audit-lane-shape clean on the daemon's log |
| 4 | D7 + D8 (map/write slimming) | mapper residual rate measured; one wave written from skeletons with guards green |
| 5 | D10 (price pre-pass) | one real absent-term batch priced with pre-gathered evidence; ladder states honest per store |
| 6 | **the proving run**: ~20 recipes, wave size 10, Brad-directed conditions | success criteria written before the run, incl.: per-recipe tokens (billed measure) and steady-state wall-clock per published recipe both measured against §7's targets; >=5x fewer Claude invocations per published recipe than the 27 measured; zero gate weakened; every new defect class frozen as a fixture same-day |
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
| wall-clock / published recipe, steady state | days-scale runs with restarts | **<=30 min measured** (write ~20min/3 lanes + qa ~10min/2 + audit amortized /10) |
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
  model pins, effort mapping, structured output). Mitigation: the §4.1a adapter reconstructs agents
  from their definition files rather than hoping a flag exists; the phase-3 drill dispatches every
  agent type once against scratch inputs and diffs behavior before any live run; fallback per §4.2.
- **Headless per-call fixed overhead eats the savings** (each `claude -p` loads project context
  fresh). Mitigation: the drill MEASURES it against a Workflow twin before anything depends on it;
  the counter-moves are larger dossiers per call (batch sizes are caps, not quotas) and, at the
  limit, the §4.2 fallback, which keeps Workflow dispatch for judgment lanes.
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
- **Model-tier changes to any Claude agent.** Every pin holds (§4.4a); the residue principle says
  v3 makes each remaining call harder, so a downgrade is the opposite of what this plan implies. A
  tier change is its own measured experiment, ordered by Brad, never a build-time convenience.
- Parallelizing the price lane (singleton stands; a change there is a measured decision for Brad).
- Any board/commodity capture-pipeline changes beyond reading what it already produces.
