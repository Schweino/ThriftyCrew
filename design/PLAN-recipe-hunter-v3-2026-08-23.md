# PLAN: Recipe Hunter v3 - Harvest Local, Judge Frontier, Orchestrate on the Box

Date: 2026-08-23. Author: Fable (end-to-end review session, at Brad's direction: "find where we can
move stuff to local llm to save tokens... a full redesign is absolutely okay... speed and accuracy are
the two most important things... utilize up to 8 cores").
Status: IN BUILD. Phases 0 (D1 + D2), 1 (D3 + D4 + D5) and 2 (D6) built 2026-08-23, each with its
gate record in section 6; phase 3 (D9, the daemon) is the next build and everything after it is still
plan only.
Corrections made during a build are folded into this document in the same commit and marked
CORRECTED with the date and the measurement behind them - the plan is the spec, so it is the plan
that moves when code reality disagrees with it.

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
   discovery stays an occasional Claude sourcer job.
   **CORRECTED 2026-08-23 (phase 1 build, measured).** This document and the phase-0 gate record both
   said the ledger "has 5 domains", and phase 1 therefore budgeted one Opus discovery round to reach
   the gate's >=6 publishers. The ledger actually holds **20 rows, of which 7 are `reliable`** -
   budgetbytes, recipetineats, skinnytaste, thecozycook, isabeleats, spendwithpennies, wellplated -
   and the other 13 are the migrated block list, which is a different thing from an absent publisher.
   All 7 enumerate: 9,012 recipe URLs from sitemaps alone, no WP-REST fallback needed. **The discovery
   round was not required and was not run.** The lesson generalises: read the ledger, do not quote a
   count of it from a plan.
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
   **CORRECTED 2026-08-23 (build):** the sauce family is settled MECHANICALLY first, by the very
   keyword vocabulary considered-dishes.ps1 already uses, and the 27B is asked only about the ones it
   leaves. `Get-Family` returns `plain` when no keyword matched, which is not a family - it is the
   absence of a signal, and it is exactly the case worth a model. So `--crawl` writes the matched
   family or `null`, and `--classify` resolves the nulls. Measured on the 858-entry pool: the keyword
   vocabulary settles the large majority for free, and no GPU is needed to stock a backlog at all.
   **CORRECTED 2026-08-23 (gate round 1): the mechanical protein/method/starch detectors as first
   written were first-substring-wins, and the first REAL 20-dossier pop showed that to be wrong in
   ways no synthetic fixture had exercised** - "Chicken Madeira" read as BEEF from its beef broth,
   "Jalapeno Popper Chicken" read as PORK from its bacon, "chili powder" made a breakfast taco a
   STEW, breadcrumbs made Swedish meatballs a `bread` starch, and "Chicken and Stuffing Casserole"
   read as SAUSAGE from the sausage in its stuffing. The detectors are now weighted: broth/stock
   phrases are removed before matching; a named CUT outranks a bare noun; bacon and ham are weak
   evidence; a protein named in the TITLE wins when the ingredients corroborate it ("Chicken Fried
   Steak" is the counterexample that keeps the title rule honest - it names chicken, contains none,
   and correctly reads beef); method words are word-boundary regexes with the title deciding when it
   speaks. Every one of those defects is frozen as a must-fire fixture with its clean twin. And the
   correction MECHANISM matters more than any one correction: `--resignature` re-derives every
   signature from the CACHED page, so a detector fix reaches the whole pool without a single
   re-fetch - 652 signatures re-derived in 60 s on the day, zero network. Fix the detector,
   re-derive from cache, never crawl again; that is the pattern for this entire class.
   **The enums are not invented here**: the method vocabulary is the one considered-dishes.ps1
   already records (`-Method` values in `db\considered-dishes.json`), and the sauce-family
   vocabulary is the one make-saturation.ps1 already derives - one taxonomy shared with the
   saturation brief and the prior-rulings ledger, or the three stop lining up. Score
   each candidate against the live catalog and the backlog: find-similar word overlap + bge-m3
   cosine + considered-dishes prior rulings. High-similarity candidates carry their top-5 neighbours
   into the dossier; nothing is auto-rejected by similarity alone except exact URL/slug re-finds.
   **Refresh the digest first** (`make-catalog-digest.ps1`) whenever recipes have published since it
   was last built: both neighbour sources read `pipeline\catalog-digest.json`, and on 2026-08-23 it
   lagged recipes-db by 16 recipes - 16 published dinners invisible to every dossier scored that
   day. (The published-slug ENTRY guard does not have this hole; it reads the db union the digest.)
5. **Rank and store** into `candidate-pool.json`. One entry per candidate, shape (so the pool has a
   contract, not a vibe):
   `{slug, name, url, domain, first_seen, last_verified, signature: {protein, method, sauce_family,
   starch}, band: {cal, carbs, protein_g, verified: true|false}, servings, ingredients_verbatim: [],
   neighbours: [{slug, score, shared}], prior_rulings: [], saturation_pressure,
   status: "available" | "taken:<run-id>" | "ruled:<verdict>"}`.
   **CORRECTED 2026-08-23 (build), three points on that shape.** (a) The schema carries three fields
   this list did not name, and each is load-bearing rather than decorative: `band.reason` (WHY a band
   is unverified, so the decider is not guessing), `entered_by: "crawl" | "ingest"` (provenance, and
   the thing the --ingest fixture asserts), and `exclusion` on a candidate the standing conditions
   rule out. (b) A candidate the band filter REJECTS is not dropped - it is stored with
   `status: "ruled:out-of-band"` and the numbers that ruled it, minus its ingredient lines. Dropping
   it would mean re-fetching the same page on the next crawl to re-earn the same answer, which is the
   churn the pool exists to end; storing it as `ruled:` keeps it out of every dossier by the same
   mechanism that keeps a decider's rejection out. (c) "an exact already-published slug never enters
   the pool" is checked against `recipes-db.json` UNION the catalog digest, not the digest alone: on
   2026-08-23 the digest held 540 recipes and the db held more, so a digest-only guard would have
   admitted an already-published dish. The estate's "read the digest, not the 3.9 MB db" rule is about
   an AGENT'S CONTEXT; a local script has no such constraint and should read the authority.

   **Pool growth, named now rather than discovered later (2026-08-23):** the pool is permanent memory
   and permanent memory grows. At the standing nightly cap (60 x 7 publishers) roughly 250 candidates
   a night are ruled out on arrival, so the ruled rows - not the available ones - are the growth
   curve. A ruled row is therefore SLIMMED to what it can still be asked ("have we seen this URL, and
   what did we decide"): identity, provenance, and the numbers that ruled it, without the scoring
   apparatus only an available candidate uses. Measured 607 B -> ~300 B per row, which puts a year of
   nightly crawling near 25 MB rather than 55 MB. If that still proves too heavy once the daemon runs
   it unattended, the next move is a companion file for ruled rows, and that is a D9 decision with a
   real number behind it rather than a guess made here.

   **harvest.py is the pool's single writer.** Consumption and rulings flow back through it
   (`harvest.py --mark-taken <slug> --run <id>` / `--mark-ruled <slug> --verdict <v>`), invoked by
   the orchestrator when the decider rules - a candidate the decider rejected must never resurface
   as `available`, and one a run took must not be offered to a second run. Top-up sourcer finds
   enter through the SAME gate (`harvest.py --ingest <candidates.json>`), so every candidate -
   crawled or searched - gets the same band check, signature, and dedup scoring before the pool
   will hold it; there is exactly one road into the pool. The pool is the
   institutional memory the 48% dupe churn never had.

   **GAP, found 2026-08-23 and left open deliberately: recipes IN FLIGHT in another open run are
   invisible to the dedup surface.** It covers the live catalog (find-similar + the embedding lane's
   catalog side), the backlog (pool side) and prior rulings - but a recipe between acceptance and
   publication in a DIFFERENT run is in none of those: not in the digest (unpublished), not in the
   pool (sourced before the pool existed or taken by that run), not in the ledger (no ruling yet).
   Measured on the gate run: `jalapeno-popper-chicken-casserole` sits at `priced` in the lowcarb-100
   run dir while the pool offered `jalape-o-popper-chicken` as novel and the decider accepted it -
   arguably the same dinner by its own three-of-four rule, and no signal could have shown it. The fix
   is mechanical: a third neighbour `side: "in-flight"`, read from `runs\*\state` for states that are
   neither rejected nor published, surfaced in the dossier like the other two sides. It belongs to
   the next session that touches harvest.py, or to D9's daemon at the latest; it does NOT block D6.
   Until it lands, the batch auditor remains the catch-point for this collision class - at the cost
   v3 exists to stop paying.

   Politeness is part of the contract: respect robots.txt, per-domain pacing of one request every
   2-4s regardless of worker count, a per-domain nightly cap, and every fetch outcome recorded to
   source-domains (three failures = blocked, exactly as the ledger already scores).
   **The recording half of that contract was BROKEN and is now fixed (2026-08-23, measured).**
   source-domains.ps1 is a read-modify-write of one JSON file, and until the harvester existed its
   only writers were one sourcer at a time. Eight concurrent fetches means eight processes reading the
   same file, each incrementing its own copy, and the last one winning: **2,293 real fetches on the
   gate crawl produced 65 recorded outcomes**, so roughly 97% of the ledger's evidence was being
   dropped. That is not a cosmetic undercount - `blocked` is earned at three failures with no
   successes, so a publisher failing eight times at once could be recorded once and never reach the
   threshold, and the rule that stops this estate hammering a wall would stop firing at exactly the
   moment it is needed. The whole read-modify-write now runs inside a named system mutex (released by
   the OS if a writer dies, so a crashed worker cannot wedge the ledger), with an 8-child-process
   fixture in `-SelfTest`. Any other single-file ledger the daemon writes to concurrently needs the
   same treatment - this is the first place fan-out met a single-writer file, not the last. A publisher that
   walls the harvester is skipped and reported, never hammered - same doctrine as the stores.

Embeddings and GPU: bge-m3 for a few hundred short signature strings is small. Run it CPU-side first
and **measure** (lib_match.py already falls back to CPU; no CPU number exists today); if CPU is too
slow, batch embedding runs in the sidecar's GPU window (before llama-server starts, per nightly.ps1
ordering). The harvest lane gets its **own embed-cache namespace** - score_cache.py prunes on save to
the texts the sweep saw, so sharing the sweep's cache would evict harvest vectors (sweep.py:35-37).
**MEASURED 2026-08-23 (D4), and the branch is closed:** bge-m3 on CPU is **36.36 ms per signature
string** (300 cold texts, 10.9 s of model work after a 4.4 s load; recorded in
`meal-prep\db\harvest-embed-latency.json`). A whole-pool build - every available candidate against
all 544 catalog recipes - is well under a minute cold and near-instant warm through the cache. **No
GPU window is needed for this lane and none was built**, which also means the harvest plane stocks a
backlog with the card completely free. The harvest cache is `sidecar\out\harvest-embed-cache\`; it
saves WITHOUT `keep_only`, because pruning to one crawl's texts would evict the catalog vectors every
candidate is scored against, and score_cache's own MAX_ROWS rebuild is the growth backstop.

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
agent stops running shell entirely.
**Two dispatch-shape rules the gate run earned (2026-08-23, both now bridge behavior and both D9
fixtures):** (a) **every decide dispatch after the first carries the run's accepted-so-far list.**
The bridge's first round omitted it and the "single decider" became N independent deciders wearing
the same name: it rejected `antipasto-salad` as a near-twin (bge 0.977) in batch 1, then ACCEPTED
`antipasto-pasta-salad` in batch 2, and accepted two different chicken salads across the rounds.
v2's dispatch carried "already accepted this run"; dropping it in the port was the error. The D9
fixture: the second batch's prompt provably contains the first batch's acceptances. (b) **the
daemon marks candidates `taken:<run-id>` at POP time, before dispatch** - the bridge does not,
which is safe only while exactly one run exists; two concurrent runs popping the same available
candidates would both pay a decider for them. The serial chain has a measured speed shape worth
knowing before anyone calls it a bug: ~2-4 minutes per 10-candidate batch (gate rounds, 2026-08-23),
so a 120-candidate run's decide pass is roughly 25-50 minutes of wall-clock, linear in pool size -
and it is FRONT-LOADED, off the write/qa/audit critical path, which is why the singleton costs the
run nothing it was not already paying.
Acceptance pacing keeps v2's WIP discipline: the orchestrator
pops candidates from the pool only while accepted-but-unresolved recipes sit under the WIP limit
(25), so a deep backlog cannot flood the paid lanes.
Local 27B's role: none in the ruling. (An adversarial "argue this is a dupe of its top neighbour"
ordering pass is a candidate for later - **explicitly DEFERRED out of the initial build**; revisit
only if phase-6 measurements show the decider mis-prioritizing, and never as a verdict.)
The recipe-dedup-selector agent definition's dossier-contract rewrite shipped with D5 on
2026-08-23 (the parallel per-protein selectors and selected-*.json outputs are retired, and after
round 1 wrote one anyway, the agent's frontmatter tool list is read-only - see the D5 record).

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
**SHIPPED 2026-08-23 with D6**, together with the sentence that makes the rule safe to obey: a
page in the extractor's queue is never a page nobody tried, because a down endpoint BLOCKS the
sweep instead of dispatching. `ops\audit-prompt-backup.ps1 -Sync` was run and `ops\prompt-backup`
is committed with it.
**Three D6 build notes earned in phase 1 (2026-08-23):** (1) **reuse harvest.py's parsers.**
`find_recipe_node`, `flatten_instructions`, `ingredient_lines`, `extract_number` and `parse_yield`
exist there with fixtures, shape-matched to fetch-recipe.ps1's PS implementations; a third JSON-LD
parser inside local_extract.py would be the pu-lib trap with a new face. Import them. (2) **when
llama-server is down, rungs 1 and 2 are BLOCKED (exit 2) - never silently escalated to rung 3.**
Rung 3 exists for pages the local pass FAILED ON, not for hours nobody started the server; a sweep
that quietly promotes every page to a Claude extractor because the card was idle re-creates the v2
cost structure in one unattended evening. Same refusal contract as `harvest.py --classify`, which is
the pattern's reference implementation. (3) **the phase-2 gate corpus already exists**: 2,293 pages
sit in the fetch cache and four accepted recipes sit at `selected` in
`runs\hunt-2026-08-23-v3-phase1-mini`, every one with its page cached - the "50 cached pages" the
gate asks for need no fetching and no politeness budget.
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
**ADDED 2026-08-23, from the source-domains lesson: `db\ingredient-resolutions.json` is the next
single-file read-modify-write ledger in a lane that fans out.** The map lane runs 2 concurrent
workers, and source-domains.ps1 under the harvester's 8 measured what last-writer-wins costs a
ledger like this: 2,293 outcomes recorded as 65, a 97% loss. D7 builds resolution writes behind the
same named-system-mutex pattern from day one (or routes them through the daemon's single pen with
the rest of the bookkeeping), with a concurrent-writers fixture; it does not wait to measure the
loss a second time. The audit rule generalises: before any lane's cap is raised above 1, enumerate
every single-file ledger its stage writes and give each one a mutex or a single pen.
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
- **scale-ratio check** (BUILT, phase 0 D2): per-line implied ratio vs the recipe's own; flags
  hand-adjusted lines,
- **prose-number equality** (BUILT, phase 0 D2, with its scope corrected in §4.5's thresholds): a
  numeral presenting itself as one of the recipe's own stats vs that stat (tokens pass by
  construction),
- title/credit presence + URL match, dash sweep (exists), servings-claim consistency.
The QA agent gets the battery output and rules only what code cannot: deliberate-substitution
defensibility, method survival, dish identity. Verdict schema, one repair cycle, re-QA - unchanged.
QA is 0.3% of tokens; this is pure **accuracy**: the checks that caught 573 post-hoc fidelity findings
become hard pre-gates, and the agent's attention lands entirely on the judgment cases.

### S8 AUDIT -> wave-preaudit battery + judgment sign-off

New `wave-preaudit.ps1 -RunDir -Wave` (the F3 fix), running the entire mechanical audit surface
**8-wide across the SHARED checks, and serially across the slugs**
(CORRECTED 2026-08-23 at build time, measured both ways - this document said 8-wide across the slugs).
The slug loop is not the expensive part and fanning it out makes it slower: build-card2.ps1 caches the
parsed 5.8 MB db\costed.json in a process global, so the first rebuild costs 0.81 s and every one after
it costs 0.05 s, while a process per slug re-pays the parse eight times. The expensive part is the
shared block - audit-spec-contradictions alone is 14.1 s of a 14.5 s whole-wave run - so that is what
runs concurrently, eight children at once. A whole 9-slug wave takes 14.5 s and a scoped one-slug
re-audit takes about 3 s.
macro recompute per spec from food-macros-db (all four macros, tolerance 5 cal and 2 g - the same
tolerances build-v2-spec.ps1 enforces at write time, so a spec that passed the build passes this or one
of the two is lying); cost reconciliation, which the build split into TWO named checks because they are
true at different times (CORRECTED 2026-08-23): `cost-engine-consistency` asks whether the engine row is
internally coherent - line utils sum to the batch, both per-serving tiers derive, first run is true plus
pantry, tiers ordered, lines_unpriced zero, no line costing nothing - and is true whenever it is run;
`cost-reconcile` asks whether the SPEC prints the numbers that engine row holds, to the cent. Measured
2026-08-23 over the 20 published lowcarb-100 recipes: the first is clean on 20 of 20, the second finds
drift on 10 of 20, because db\costed.json is regenerated whenever grocery prices move and a spec keeps
its build-time figures until a recost pass rewrites them. Both are findings for a wave about to publish;
the report carries both mtimes so the auditor can tell price age from a spec that was written without
re-syncing its cost block, and the fix in either case is recost-spec-cost-block.ps1;
card rebuild to per-slug scratch dirs + structural byte-compare vs a known-good card;
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

Judgment calls go out as headless Claude Code invocations.

**CORRECTED 2026-08-24 (D9 build, measured on Claude Code CLI 2.1.173). This subsection was written
on a premise that is false, and the correction makes the adapter simpler and stronger rather than
harder.** What it said: "`claude -p` cannot invoke a named subagent as its top-level agent -
subagents in `.claude\agents\` are things a running session delegates to, not entry points - and
prompting a headless main loop to 'use the recipe-writer subagent' pays for TWO contexts per call".
The second half is still true of *prompting* a main loop to delegate. The first half is not, because
the CLI has a flag for exactly this:

```
echo "List the exact names of every tool available to you right now, comma separated." \
  | claude -p --agent recipe-source-qa --output-format json
result     -> "WebFetch, Read, Grep, Glob, Bash, PowerShell"   (that agent's frontmatter list EXACTLY)
modelUsage -> claude-fable-5                                    (that agent's frontmatter model)
num_turns  -> 1                                                 (ONE context; nothing delegated)
```

So the adapter dispatches `claude -p --agent <name>`, and this is BETTER than reconstruction for a
reason beyond convenience: reconstructing the agent would make `hunt_dispatch.py` a SECOND reader of
the frontmatter, and two readers of one authority is how this estate's forked-taxonomy defects start.
With `--agent`, the CLI reads the definition file and the adapter cannot disagree with it - section
4.4a's "the frontmatter is the single authority" holds by construction instead of by care.

**`--effort` also exists on this CLI** (low/medium/high/xhigh/max), so point 4 below has no gap left
to report: `model`, `effort` and `tools` all reach the dispatch. The adapter still parses the
frontmatter, for two jobs: to pass `--effort` explicitly (the same value the file states, so it
cannot disagree), and to CHECK that the model which actually billed is the model the file pins - a
silently downgraded pin is recorded as a finding on the result rather than refused, because the pin
is the frontmatter's to state and the CLI's to honor.

The reconstruction road below is BUILT AND FIXTURED ANYWAY, one flag away
(`hunt_dispatch.dispatch(..., reconstruct=True)`), as the fallback if a future CLI drops `--agent`:

1. Parse the agent's `.claude\agents\<name>.md` frontmatter (model, tools, effort) and body.
2. Dispatch `claude -p` with: `--model <the pinned model>`, `--append-system-prompt <the agent
   body>`, `--allowedTools <the frontmatter tool list>`, `--output-format json`, cwd = repo root,
   and the estate's permission settings. The user prompt is the dossier + stage contract only.
   (One mechanical detail the D9 build found and pinned: the prompt travels on STDIN, never as a
   positional argument. Windows caps a command line at 32,767 characters and a dossier batch can
   approach that, and the CLI's variadic flags will swallow a positional prompt - measured,
   `--tools "" <prompt>` exits with "Input must be provided either through stdin or as a prompt
   argument".)
3. Parse the JSON result envelope; validate the payload against the stage schema in the daemon;
   re-ask once on schema failure - **and enum violations ARE schema failures: the re-ask quotes the
   refusal's named violations back to the agent, and the daemon NEVER auto-coerces (ADDED 2026-08-23,
   measured).** On the gate run a decider whose prompt spelled out the closed enums still returned
   nine invented values (`soup/stew`, `turkey/beef`, `no-cook`, `skillet+assemble`, `grill`, `egg`,
   ...); decide_apply refused the whole payload with every violation named, which is the correct
   machine behavior. The gate demonstration then normalised those nine BY HAND, once, with the
   mapping recorded in the run's scratchpad - a one-time act of the operator, not a precedent.
   Silently coercing an invented taxonomy into a legal one is how a ledger stops noticing it is
   being forked, so the daemon's only move on an enum violation is the re-ask;
   then per-slug retry budgets and the breaker exactly as hunt-lib
   prescribes. A transport/timeout failure is a null - STUCK, never a verdict (B5).
4. Where a frontmatter field has no CLI flag, record the gap in the drill report rather than
   silently dropping it. **RESOLVED 2026-08-24: there is no such field.** `--model`, `--effort` and
   `--allowedTools` all exist on CLI 2.1.173, and on the `--agent` road the CLI applies all three
   from the file itself.

**The phase-3 drill must dispatch every agent type once against scratch inputs and (a) diff its
behavior against a Workflow-dispatched twin, (b) measure the fixed per-call overhead** - a headless
invocation loads project context (CLAUDE.md, settings, memory) on every call, and whether that costs
more or less than a Workflow subagent's per-dispatch overhead is a question for the drill's
measurement, not for this document's assumption.

**RUN 2026-08-24. Full record in `meal-prep\out\d9-gate\adapter-drill.json` and
`adapter-drill-notes.md`; the shared prompt spec is `meal-prep\pipeline\hunt-dispatch-drill.json`,
one file both roads read so neither can quietly ask a different question.**

*(a) The behavior diff: 10 agent types, 10 of 10 conforming on BOTH roads, every named key AGREES,
zero findings.* Reconstructing an agent outside the harness does not change what it decides.

*(b) The overhead, measured on deliberately ~60-token prompts so the input count IS the fixed part:*

| | headless (`--agent`) | Workflow twin |
|---|---|---|
| input tokens per dispatch, mean | **18,050** | **46,572** |
| median | 15,470 | 49,624 |
| range | 7,220 - 30,942 | 18,452 - 78,624 |
| wall clock, mean | 7.3 s | (10 in parallel, 12.7 s total) |

**The headless road costs ~2.6x LESS context per dispatch than a Workflow subagent**, so the
counter-move this paragraph reserved - bigger dossiers per call - is not needed, and the batch sizes
stay caps rather than becoming quotas for overhead reasons. (Cache caveat for anyone re-measuring:
three of the ten headless dispatches read 20-23k tokens from a warm prompt cache and seven created
theirs cold, so 18,050 is a mixed-cache mean and should be quoted as one.) The recorded fallback in
§4.2 remains available and was not needed.

*One divergence the drill surfaced, and it matters for why the daemon validates at all.* The
Workflow harness FORCES structured output; the daemon validates after the fact. Given a field typed
as a string whose honest answer was the JSON literal `null`, the harness coerced the answer to the
string `"null"` and passed, while the adapter refused the payload whole, re-asked once quoting the
violation, got the same honest `null` and refused again. Neither is wrong, but they are not the same
guarantee, and for a daemon whose rule is NEVER auto-coerce, the validate-then-refuse behavior is the
one this plan wants.

**State-write ownership changes with the daemon, and this is an accuracy feature, not a style
choice:** judgment agents stop running `hunt-run.ps1` / `ingredient-queue.ps1 -Add` / ledger stamps
themselves. They return schema'd verdicts; the daemon performs every state advance, queue add,
`-Derive`, lane-log line (both start/end events, since it owns a real clock) and ledger stamp,
attributed `-By <stage>`. Agent-side marshalling bugs (B8's composite `-Terms` string) become
impossible rather than warned against - **but only through one specific invocation form, and this
document previously left that unsaid. CORRECTED 2026-08-23, measured during D5's drill:
`powershell -File script.ps1 -A one two` binds ONE element and SILENTLY DROPS the rest, and
`powershell -File script.ps1 -A one,two` binds ONE element whose value is the string `one,two`.
PS 5.1 `-File` therefore CANNOT carry a multi-element `[string[]]` from a subprocess argv at all** -
it can only reproduce B8 or truncate, and truncation is the worse of the two because nothing refuses
it. Handing a JSON array to `-File` would re-create B8 with a Python accent. The daemon marshals
through `-Command` with every element single-quote-escaped individually
(`& 'script' -A 'one','two,with,commas'; exit $LASTEXITCODE`), which produces a real PowerShell
array; the trailing `exit $LASTEXITCODE` is not decoration either, because without it powershell.exe
reports its own success and every 0/1/2 script reads as clean. That one road is
`hunt_lib.ps_invoke`, built in phase 1, and both broken `-File` shapes are frozen as MUST-FIRE
fixtures in decide_apply's suite so nobody simplifies it back.
(A process note, recorded because the failure mode will recur: this very correction was written
during phase 1 and SILENTLY LOST - its patch script asserted on a later edit and wrote nothing,
while the session verified only the other edit's landing. The phase-1 commit message claims it; the
document did not carry it until the 2026-08-23 cold read. When a multi-edit patch fails partway,
re-verify EVERY edit it carried, not the one that failed.)
Two deliberate exceptions: the pricer keeps `-Record`/
`-Promote` (script-enforced evidence contract, §3 S5), and content artifacts (extraction JSON,
intake prose, spec builds via build-v2-spec) remain the agents' own writes - they are the work
product, not bookkeeping.

**The wave lane's control flow is a PORT, not a rewrite.** `runWave`/`trimWave` in
hunt-orchestrator.js encode S8 trim, the repair cycle, the B11 mtime postcondition, and the B-4
scope gate, each carrying a dated founding bug. The daemon reproduces that control flow
decision-for-decision (the agent-as-shell steps inside it become direct calls; everything else keeps
its order and its refusal conditions), and the hunt-lib fixtures for planTrim / chooseScope /
repairClaimHolds are the parity proof.

One conflation to refuse (2026-08-23 audit): the extract lane's cap of 3 below counts CLAUDE
escalation agents only; the local ladder's concurrency is the GPU slot budget in §4.3 and the two
are separate ledgers - a sweep saturating 4 server slots while 3 escalation agents run is the
intended steady state, not a cap violation.
Concurrency per lane caps as in v2 §2.4 (extract 3, map 2, price 1, write 3, qa 2, decide 1, wave
serial), with the WIP limit (25 accepted-but-unresolved) gating pool pops exactly as it gated
sourcing. All caps, the WIP limit, retry budgets and breaker thresholds live as named constants in
hunt_lib.py - they are daemon CONFIG, not architecture. (LANE_CAPS, WIP_LIMIT and DECIDE_BATCH sit
there since phase 1; the retry budgets and breaker thresholds arrive with the D9 port of
hunt-lib.js, which owns them today.) With the front end nearly free, the
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
| harvest fetches | 8 workers, MEASURED 2026-08-23 at 131 pages/min - which IS the politeness ceiling (7 domains / 2-4 s each), so more workers buy nothing | network + per-domain politeness |
| JSON-LD parse, band filter, signatures | CORRECTED 2026-08-23: runs INSIDE the 8 fetch threads, and no process pool was built or is needed - the crawl sits at the politeness ceiling with CPU idle, and --resignature re-derives 652 signatures in 60 s single-threaded. Build the pool only if a measurement ever shows parse waiting on CPU, which nothing has | trivial CPU |
| bge-m3 embeddings | **CPU, measured and settled 2026-08-23: 36.36 ms/text, whole-pool build 24 s cold / 0 s warm - the GPU branch is CLOSED, not deferred** | trivial CPU (§3 S1) |
| local 27B calls (line-split, full extract, enum, adversarial) | 4 (serve.ps1 default `-Slots 4`; more queues). **AUDITED 2026-08-23, and there is a CONTEXT-BUDGET CONFLICT D6 must resolve by measurement, not discover mid-sweep:** serve.ps1's `-c 16384` is the TOTAL KV budget SPLIT across slots - 4 slots = 4,096 tokens per slot - while rung-2 full-page transcription sends ~24k chars of page (~6k tokens) plus `max_tokens=4096`, roughly 10k tokens, which fits only a 1-slot split at the default context. Rung-1 line-splits (CORRECTED 2026-08-24: ~750 tokens/slot after D6's prompt rewrite - the
rewrite that took the pilot from 1-in-7 to 6-of-7 made the prompt ~450 tokens, and the size
estimate here predated it) still fit 4 or even 8 slots trivially (serve.ps1's own header measured 8 slots at 2.2x aggregate, flat past 8). So the sweep's shape is: rung-1 fans wide, rung-2 runs narrow or the server runs with raised `-Context` if VRAM allows - a measured decision recorded at D6 build time. The fan-out pattern is the estate's existing one: ThreadPoolExecutor with jobs <= Slots (graph\bench\adversarial_probe.py, `--jobs ... coupled to serve.ps1 -Slots`). **RESOLVED 2026-08-23 (D6 build, measured on the box, and the audit's prediction was exactly right).** llama-server's `/props` reports the per-slot budget rather than the total, which is the only honest source since `-c` and `--parallel` are start-time flags: at serve.ps1's defaults it reports **4,096 tokens per slot**, and rung 2 needs **~11,465** (a 24k-char page at 3.5 chars/token plus 4,096 out plus headroom). Raising `-c` is not the way out - measured free VRAM with the 4-slot server up was **1,200 MiB**, against the ~1.5-2 GB doubling the KV cache would need. What DOES work costs nothing: **`-Slots 1` at the same `-c 16384` gives one slot the whole 16,384** and measured **14,688 MiB used, i.e. LESS VRAM than the 4-slot server**, because `-c` is the total either way. So the sweep is two passes on two server shapes - rung 1 fanned at 4 slots, rung 2 narrow at 1 - and `extract_sweep.py --from-report` exists precisely so pass 2 targets only what pass 1 escalated instead of re-earning 45 settled answers. The dangerous alternative is named in code: local_extract REFUSES rung 2 on a too-small slot (exit 2) rather than truncating the page, because a page cut at the slot ceiling still substring-verifies line by line - the checker proves what IS there and can never prove what is absent | GPU |
| QA battery / wave-preaudit | 8-wide across the SHARED checks, serial across slugs (S8's CORRECTED 2026-08-23 finding: the slug loop rides build-card2's process-global costed.json cache, and fanning it re-pays the 5.8 MB parse per child) | CPU, seconds |
| cost engine, costed.json, recipes-db | **serialized by the daemon's cost-engine mutex (§4.5)** - spec assembly stays parallel, the cost pass does not | correctness |
| CDP store sweeps | 1 thread per store (existing) | vendor politeness - the floor |
| Claude lanes | v2 §2.4 caps | plan/session budget |

The PLAN-use-the-cores rules apply: no fan-out may silence a watcher; single-writer files stay
single-writer; vendor pacing is the floor no core count moves.

### 4.4 GPU scheduling

llama-server is started by hand at run start and stopped at run end (`graph\pipeline\nightly.ps1
-StopOnly`), per the standing ownership rule; a hunt run must be off the card before the 07:00 ad
pull and 08:00 capture (their sweeps go BLIND otherwise), and the nightly chain owns 21:30-06:30.
Harvest's embedding batches run CPU - measured 2026-08-23 at 36.36 ms per signature string, the
whole question is closed and nothing about harvest ever asks for the card except `--classify`. Nothing new schedules
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
| harvest cursor + nightly caps | `meal-prep\db\harvest-state.json` | harvest.py -> itself (committed) |
| embed CPU latency record | `meal-prep\db\harvest-embed-latency.json` | harvest_embed --measure -> the §4.3 GPU decision (committed) |
| embedding neighbours | `meal-prep\db\harvest-neighbours.json` | harvest_embed --build -> harvest --rescore (NOT committed - regenerable in 24 s cold, 0 s warm) |
| decide dossier batch | run-scoped, from `harvest.py --dossier --out` | harvest.py -> bridge/daemon decide dispatch (transient) |
| DECIDE verdict file | run-scoped; decide_apply accepts EITHER a bare DECIDE payload OR hunt-pool-seed.js's own return shape (`{verdicts:[{batch,decisions,note},...]}`) verbatim - it flattens the batches itself and a `stuck` batch contributes nothing, so the operator never hand-merges (ADDED 2026-08-23 after the gate run did exactly that with a throwaway one-liner) | bridge/daemon -> decide_apply.py (transient) |
| extraction | `<RunDir>\extracted\<slug>.json` | rung 1/2 (local) or rung 3 (Claude) -> map, QA, coverage_check |
| extraction ESCALATION (ADDED 2026-08-23, D6) | `<RunDir>\extracted\<slug>.escalation.json` | the sweep -> the rung-3 extractor dispatch. Same contract with `state: "escalate"` plus the failure reason and the unverified lines S3 says the dispatch must carry. A DIFFERENT filename on purpose: a half-settled extraction sitting under the settled name is how a run publishes a recipe nothing verified. A later rung settling the page DELETES the escalation file, so a stale one can never be dispatched |
| extraction sweep report (ADDED 2026-08-23, D6) | `<RunDir>\extracted\sweep-report.json` | extract_sweep.py -> the phase gate, and `--from-report` for the narrow rung-2 pass |
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
- **Dossier (ADDED 2026-08-23 - the phase-1 gate run showed the contract was underspecified, and each
  of these three fields was added because a measured disagreement traced back to its absence).** Per
  candidate: `{slug, name, url, domain, signature, band, servings, ingredients_verbatim (capped at
  22 lines - DOSSIER_INGREDIENT_CAP in harvest.py),
  neighbours: [{slug, name, score, shared, source, side}], prior_rulings, saturation_pressure,
  batch_concerns: [], catalog_checked: {live_recipes_searched, live_matches, backlog_matches},
  entered_by}`.
  - **`side` on every neighbour: `live-catalog` or `backlog`.** The embedding lane scores a candidate
    against the live catalog AND the rest of the backlog, and the two mean opposite things: a live
    neighbour is a published dinner this candidate would duplicate, a backlog neighbour is another
    unruled candidate. Shipping them unlabelled is why the first gate round's decider went and read
    `catalog-digest.json` itself - it said so in its own note - which is precisely the corpus read S2
    exists to remove. Unlabelled neighbours are worse than no neighbours.
  - **`catalog_checked`.** Without it, "no live matches" and "nobody looked" are the same bytes, and a
    decider that cannot tell them apart will go and look. Stating the search makes an empty match list
    EVIDENCE OF ABSENCE.
  - **`batch_concerns`** (cold-plate / breakfast / cook-to-order / not-a-main), from S1 item 3's
    batch-scalability rules. A FLAG that demotes in the pop order, never a filter that rejects: a taco
    salad and a frittata both trip the keyword rules and both can be perfectly good batch prep, so the
    mechanical layer records the concern and the decider rules. Local may reject on arithmetic it can
    defend; "is this the kind of dinner this board sells" is not arithmetic.
  Measured size with all three additions: 1.9-3.3 KB per dossier against S2's 2-3 KB budget - the
  stretch is deliberate and paid for itself, buying a 37% token drop and 5-to-3 tool calls per batch
  between the gate rounds. The cap that carries the cost model is the batch size (<=10), not the
  kilobyte.
- **`record` enum enforcement (ADDED 2026-08-23, measured).** `record.protein` must be one of
  chicken/beef/pork/turkey/sausage/any, and `record.method` must be one of the values
  `db\considered-dishes.json` already records, plus `any`. Checked in `validate_decide`, not asked for
  in the prompt: a decider whose prompt named the closed enum in as many words still returned
  `soup/stew`, `skillet+salad`, `no-cook`, `skillet+assemble`, `grill`, `turkey/beef`,
  `sausage/chorizo`, `salami/cheese` and `egg`. Those go verbatim into considered-dishes, whose
  Get-DishKey builds dish identity out of `protein|method|sauce-family` - so an invented value does not
  look untidy, it mints an identity nothing will ever match again and the ledger quietly stops
  recognising its own entries. The method list is READ from the ledger rather than copied into
  hunt_lib, because a quoted copy is the same forked-taxonomy defect one level up.
- **Dispatch schemas:** the normative baseline is hunt-orchestrator.js's inline set (CANDS, STAGE,
  MAPPED, DERIVE, QA, WAVECLOSE, AUDIT, REPAIRCHECK, PUB), moved verbatim into hunt_lib.py. Two
  named deltas, and only these: **SEL is replaced by DECIDE** - `{decisions: [{slug, verdict:
  "accepted" | "rejected-dupe" | "rejected-not-fit" | "deferred", reason, dupe_of: [], record:
  {name, protein, method, verdict, reason}}], note}` (the `record` block is what the daemon writes
  to considered-dishes verbatim); **WRITE drops its macro fields** - the band is settled pre-write,
  so the writer returns `{slug, status, state, detail}` only.
  **What that costs between D9 and D8, stated so a reader does not mistake a hole for a weakened
  gate (ADDED 2026-08-24, D9 build).** The workflow's write lane gated the band on the writer's OWN
  REPORTED numbers, which those dropped fields carried; D8's `build-intake-skeleton.ps1` pre-write
  band gate is a phase-4 deliverable. In the interval the daemon enforces the band by reading the
  BUILT SPEC - `db\recipes\<slug>.json`'s `stat.cal` and `stat.carbs` - after the write lane returns.
  That is a mechanical postcondition over the artifact instead of a self-report about it, so it is
  strictly the stronger of the two, and it needs nothing from D8. `hunt_lib.in_band` is the shared
  predicate either way, and it is one of the ported functions the parity gate covers.

  **How a DECIDE verdict lands on the state machine (ADDED 2026-08-23 - the build found this document
  silent on it, and silence here is how a verdict gets faked).** hunt-run.ps1 allows exactly two exits
  from `sourced` (`selected`, `rejected-dupe`) while DECIDE has four verdicts. The routing is
  normative and lives in `hunt_lib.DECIDE_STATE_ROUTE`:

  | verdict | run state | considered-dishes | pool |
  |---|---|---|---|
  | `accepted` | `sourced` -> `selected` | record | `ruled:accepted` |
  | `rejected-dupe` | `sourced` -> `rejected-dupe` | record | `ruled:rejected-dupe` |
  | `rejected-not-fit` | **none** - it never entered the run | record | `ruled:rejected-not-fit` |
  | `deferred` | none | **none** - there is no ruling to record | back to `available` |

  Forcing `rejected-not-fit` into `rejected-dupe` would put a lie in the ledger the next run reads
  ("not a fit" is not "a duplicate"), and burying a `deferred` candidate would lose one nobody
  rejected. A verdict a state machine cannot express is a verdict that gets faked or lost - the same
  reasoning that added `rejected-macros` on 2026-08-16.

  The apply is **all-or-nothing on schema conformance**: a payload that fails `validate_decide` is
  exit 2 with NOTHING written, because half a verdict on disk is worse than none - the half that
  landed looks decided. It also refuses a slug the pool has never held, so a ruling about a candidate
  nobody harvested cannot put a phantom in the ledger.

**Exit-code convention** for every new battery/pre-resolve script: 0 = clean, 1 = findings (the
machine report is still written), 2 = could-not-run (missing input, parse failure). **Exit 2 is a
blocked stage, never a pass** - could-not-look is never a clean bill, mechanized.

This DIFFERS from `lib\guard-contract.ps1`'s older vocabulary (0 clean / 1 findings / 2 hard / 3
could-not-evaluate) and from the existing audit-*.ps1 scripts (which use 2 for a self-test failure), and
the difference is deliberate: v3 fixes ONE convention for every new battery so a caller never has to
know which script it is talking to. Noted here so a later session does not "fix" a new battery back to
the old numbering. What the new batteries DO inherit from guard-contract is the completion marker -
`<NAME>-COMPLETE` as the last line of stdout - because "did it finish" and "what did it find" are
different questions and this estate has conflated them at least five times.

**Thresholds (defaults; change only with a recorded reason in the run dir)**

- Band: inclusive on both edges, exactly as the run's conditions state them.
- Scale-ratio: the recipe's ratio is the MEDIAN of per-line implied ratios (scaled grams vs source
  qty); a line deviating >10% after the house quarter-quantization allowance = battery FAIL routed
  to the QA agent's judgment (a deliberate substitution may survive); 5-10% = note. Lines the
  source states without a quantity are exempt.
- Prose-number equality (SCOPE CORRECTED 2026-08-23, measured): a numeral in `prose.*` or
  head.description that **presents itself as one of the recipe's own stats** must equal that stat at its
  printed precision - a `$N.NN` against stat.cost_ps, an `N cal/calories` against stat.cal, an
  `N g protein / carbs / fat` against the matching stat, an `N servings/portions/containers` against the
  serving count. `{{...}}` tokens pass by construction; package-size claims are NOT in scope here - they
  stay under the writer's cost-line-tracing contract and the auditor.
  This document first asked for EVERY numeral literal to equal a stat. Measured against four real wave-3
  specs, that reads 40 legitimate literals as defects - oven temperatures (350), pan dimensions (9 by
  13), cook times, step numbers, the 93/7 lean ratio - roughly ten per clean recipe, which is exactly how
  a guard joins this estate's dead-guard pile. Two further readings are load-bearing and were also
  measured: a **bare** `$N` is not a per-serving claim (every upsell in the catalog ends "all for $1 a
  month" and the intro's takeout comparison is a bare `$12`), and an **upper-bound** claim is a different
  statement from a quote - "under 15 grams of carbs" on an 11 g recipe is TRUE and 17 of the 20 published
  lowcarb-100 recipes carry that exact sentence, so a bound is exempt only while the bound actually
  holds ("under 5 grams" on a 6 g recipe still fires, and a negated bound is not a bound).
  The patterns are `spec-contradiction-lib.ps1`'s, extended to carbs, fat and the serving count, and the
  battery's self-test asserts the shared ones against that file's source text so the two cannot drift.
- Local line-split acceptance (rung 1): `raw` equals the JSON-LD line; qty and unit substrings of
  raw verbatim; qty+unit+item+prep must jointly cover >=90% of raw's non-stopword tokens. ANY
  failing line sends the whole page to rung 2.
  ("Non-stopword" here is a COVERAGE ALLOWANCE local to this one check - the handful of glue words a
  correct split legitimately drops ("of", "the", "a", "and", "or", "to", "into", "for", "plus
  punctuation-only tokens"). Define the list in local_extract.py next to the check and pin it with
  the round-trip fixtures. It is NOT find-similar's STOP list and must not import it - that list
  exists to kill name-identity noise and deliberately swallows words like "chicken" that a split
  must never be excused from covering.)
  **CORRECTED 2026-08-23 (D6 build, measured on a 7-publisher pilot and then on the 50-page gate corpus). Three things belong to this threshold that this paragraph did not name, and the first is the biggest.**
  - **The PROMPT is part of the threshold.** The split prompt's first draft carried the extractor agent's own wording - item is "the food itself, brand and preparation stripped" - and said nothing about the parentheticals publishers put in their own JSON-LD. That settled **1 page in 7**. The model was obeying: it stripped "small" from "small onion", "extra virgin" from "extra virgin olive oil", "divided" from a cheese line, and dropped "(or gluten-free flour mix)" entirely - every one a word the round-trip check is RIGHT to demand back. The check was not too strict; the instruction was telling the model to throw material away. Rewritten to state the rule the checker enforces (every word lands somewhere; keep size/cut/grade/form/variety words; the whole bracketed note goes in prep), the SAME corpus settled **6 of 7**. A threshold and the prompt that feeds it are one mechanism, and tuning the threshold before reading the prompt would have been the wrong move on a 14% settle rate.
  - **A bracketed CURRENCY amount is struck from the line before it is counted.** Budget Bytes prints its per-ingredient cost inside its JSON-LD ("2 cloves garlic ($0.16)"), which failed 17 of 17 lines on that publisher - every page it has. $0.16 is not a property of the garlic, and the only way to "cover" it is to stuff a dollar amount into prep where the mapper and pricer would read it as something the recipe says about the food. This is an ANNOTATION rule (it removes a bracketed price), NOT a stopword (which would remove a word), and the fixture pins the difference: a bracketed NOTE is still demanded.
  - **A boolean covers the words that set it.** `optional: true` accounts for "optional", "to taste", "garnish", "desired" - the line "1/4 teaspoon cayenne pepper (optional)" was transcribed perfectly and failed only because the covering set looked in four text fields when the answer was in a fifth. Note the direction, which is the whole safety of it: the excuse applies ONLY when the flag is set, so a line saying "(optional)" that the model reads as not-optional still fails.
  **A KNOWN escalation class, recorded rather than excused:** a line naming a BRAND ("1/3 cup Specially Selected Sicilian Extra Virgin Olive Oil") cannot both satisfy the extractor contract's "brand stripped" rule and cover every token. It escalates, and that is the right answer - brands cannot be enumerated, and the alternative is a hole in the check wide enough to hide a dropped food in.

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

**CORRECTED 2026-08-24 (D9's drain drill, measured): "unchanged" was not available, because
audit-lane-shape.ps1 was counting every dispatch TWICE.** `hunt-run.ps1 -Lane` grew an `event` field
on 2026-08-16 so a stage could stamp both ends and its duration could finally be measured; the audit
never learned about it and kept treating every LINE as an invocation. So since that date it has read
every dispatch as two and every item as a duplicate, which means `<lane>-lane-duplicate-items` has
fired BY CONSTRUCTION on every paired log, and every invocation count it printed was doubled.
Measured on a lane log the daemon wrote - 4 dispatches, 8 lines - it reported 2 map and 6 price
invocations with all four price terms flagged as repeats, and not one of those was real. The fix is
`Get-Invocations`: a start and an end sharing lane + label + item list are ONE invocation, and the
END line is the survivor because it carries the token stamp; a line with no `event` at all is an
older unpaired line and stands alone, which keeps the audit readable against historical logs. Frozen
as fixture 3b in `audit-lane-shape.ps1 -SelfTest`, both directions: the collapsed pair reports no
duplicate, and the raw lines are shown to be exactly what used to fire it. **This also means the
lane-shape findings on the v2 lowcarb-100 log are partly an artifact and should be re-read, not
quoted.**

**And one thing the pen-ownership rule moves that this document did not name (ADDED 2026-08-24, found
by the drain drill).** v2's audit dispatch told the auditor, in prose, to run `batch-ledger.ps1
-Stamp -Stage audit` on a GO, and wave-publish's P2 gate refuses to publish a batch with no audit
stamp. Under section 4.1a the agent stops running shell - so if the daemon does not stamp it, nothing
does, and every wave stops dead at P2. The verdict stays the auditor's; only the pen moves. The same
applies to the batch OPEN when a drill runs on a scratch ledger, since `hunt-run -WaveClose` has no
`-LedgerPath`, only `-NoLedger`.

## 5. Deliverables

Each ships with its must-fire fixture and clean twin in the same commit, per the guard-fixture rule.

- **D1 `wave-preaudit.ps1`** - the mechanical audit battery (S8), shared checks 8-wide with per-slug
  scratch dirs, machine report + exit codes per the §4.5 contract; auditor dispatch slimmed to report +
  residue. Fixtures: a spec with a broken macro recompute MUST FIRE; a clean wave passes; a card
  rebuild diff fires on a mutated built card; a missing input exits 2 and reads as blocked, not
  clean.
  BUILT 2026-08-23. Ships with 34 predicate fixtures plus an END-TO-END drill that runs the script as a
  child process against a scratch meal-prep root: the clean twin, the broken-macro MUST FIRE, the mutated
  reference card, a missing manifest, a scope naming a slug the wave never listed, and a missing required
  input - the last four all asserting exit 2. It also extracted P8's four endpoint predicates into
  `pipeline\feed-endpoint-lib.ps1` so wave-publish.ps1 and the preaudit read ONE copy of "which feed do
  the cards fetch"; wave-publish -SelfTest still owns those fixtures and stays green, which is what
  proves the move changed no rule.
- **D2 QA battery** - extend coverage_check.py with scale-ratio and prose-number checks (thresholds
  per §4.5) + the `<slug>.battery.json` emitter. Fixtures: one hand-adjusted line fires the ratio
  check; a prose literal disagreeing with stat fires; `{{cost_ps}}` tokens never fire.
  BUILT 2026-08-23, six checks: coverage, scale-ratio, prose-numbers, title/credit/URL, dash sweep,
  servings-claim, behind `--battery`; the bare `--spec/--source --json` form is unchanged so the existing
  QA instruction keeps working. 60 fixtures. Building it surfaced **a live defect in coverage_check.py
  itself**: `_names` looked for an `ingredients` array, a v2 BUILT spec keeps its lines in `scaler.ing`,
  and the QA lane passes the built spec - so the tool has been reporting ZERO spec ingredients and every
  source line as DROPPED since it shipped (2026-08-16). Fixed and pinned. Three further matcher
  corrections, each measured over the 20 published lowcarb-100 recipes and each shipped with its own
  must-fire and clean twin: a parenthetical is a note about the food and not the food (an oil-packed
  tomato ended in the word "oil" and could not pair with the source's tomatoes); a source line joining
  two foods with AND is two requirements, which makes the check STRICTER; a line offering alternatives
  with OR is a choice the source itself made, so picking one invents nothing; and a food a sectioned
  source lists twice while the spec carries one line is CONSOLIDATED with a note about the summed amount,
  not a false DROP. Hard findings over those 20 recipes fell from 88 to 63, and the residue is what the
  check is for - each one a named INVENTED/DROPPED pair that is a real substitution question for the QA
  agent (chicken stock against Chicken Broth, avocado oil against Olive Oil, Gouda against Cheddar).
  A subset-pairing rule that would have quieted the remaining "shredded mozzarella" against "Mozzarella
  Cheese" class was **considered and rejected**: it also pairs "Rice" with "wild rice", and a wrong
  pairing hides an invention, which is the failure direction this check must never take.
- **D3 `harvest.py` + `candidate-pool.json`** - enumeration, cached fetch, band filter, signatures,
  dedup scoring, ranked backlog with the S1 pool schema and single-writer verbs (--mark-taken,
  --mark-ruled, --ingest for sourcer finds); source-domains feedback on every fetch. Fixtures: a
  page with out-of-band JSON-LD nutrition is filtered with the numbers recorded; a no-JSON-LD page
  is kept flagged; an ambiguous serving basis demotes to band-unverified (never a guess); an exact
  already-published slug never enters the pool; a `ruled:` candidate never resurfaces as available;
  an --ingest candidate gets the same band/signature/dedup treatment as a crawled one.
  BUILT 2026-08-23. `meal-prep\pipeline\harvest.py`, stdlib-only under C:\Codex\Python312, 88
  fixtures green (57 at first commit; the gate round added the signature-detector, batch-concern,
  neighbour-side and entry-guard classes; D6 added the HTML-entity class to `ingredient_lines`), marker HARVEST-COMPLETE, verbs --crawl / --classify /
  --ingest / --mark-taken / --mark-ruled / --dossier / --rescore / --resignature / --status
  (--resignature re-derives every signature from the cached page: the correction mechanism for the
  whole detector class, zero network). Three things the build settled that the plan had
  left to the implementer, each recorded above where it belongs (S1 items 1, 4 and 5): the ledger
  holds 7 reliable publishers rather than 5, so no sourcer discovery round was needed; the sauce
  family is settled mechanically first and only the residue goes to the 27B; and out-of-band and
  excluded candidates are STORED as `ruled:` rather than dropped, which is what makes the pool memory
  instead of a queue. **One taxonomy, not three:** the family vocabulary is PARSED OUT of
  considered-dishes.ps1 at load time rather than copied into Python (a third hand-maintained copy is
  the pu-lib trap), the method enum is read from `db\considered-dishes.json`'s own -Method values, and
  a ledger method with no detector here is a FINDING rather than a silent miss. To compose the two
  ledgers without a second copy of either rule, `find-similar.ps1` and `considered-dishes.ps1 -Query`
  each gained a `-BatchFile` mode answering many questions in one process through the SAME scorer /
  matcher, with a fixture in each asserting the batch road returns the single road's answer exactly.
  The page cache is fetch-recipe.ps1's, by the same key - a fixture asserts our key against the PS
  implementation, because two key functions that drift means two caches and a politeness budget spent
  twice.
- **D4 embedding lane** - bge-m3 signature vectors with a harvest-owned cache namespace; CPU
  latency measured and recorded before any GPU scheduling is built. Fixture: cache eviction twin
  proving harvest vectors survive a sweep save.
  BUILT 2026-08-23. `meal-prep\pipeline\harvest_embed.py`, run under `sidecar\.venv` (it exits 2
  naming the right interpreter under any other one, rather than half-working). 11 fixtures green.
  CPU measured at 36.36 ms per signature string and recorded, and the plan's "if CPU is too slow"
  branch is therefore CLOSED as not needed - see S1. The eviction twin proves both halves: in a
  SHARED namespace a sweep's `save(keep_only=...)` really does evict harvest vectors, and in the
  owned namespace they survive the same save with the same numbers. A third case pins that the hazard
  is the MAX_ROWS cap rather than the save, so a future reader cannot conclude the sharing was safe
  after watching one under-cap run do nothing.
- **D5 dossier builder + decider dispatch** - kills the adjudicator lane; one decider call per <=10
  candidates; decider is sole author of acceptances and rulings, returned as a schema'd verdict the
  orchestrator writes (S2). Includes the recipe-dedup-selector prompt rewrite to the dossier
  contract. Fixture: a dossier carrying a known catalog near-duplicate surfaces it in the neighbour
  block; a decider verdict is written to accepted-slugs/considered-dishes byte-for-byte as ruled.
  BUILT 2026-08-23, in four pieces. `hunt_lib.py` (the ONE module section 4.5 names) carries the
  DECIDE schema, the exit-code constants, the state routing table above, `validate_decide`, and
  `ps_invoke`; D9 ports hunt-lib.js's pure functions into the same module under section 4.2's parity
  gate. `harvest.py --dossier` pops ranked candidates and emits 2-3 KB dossiers. `decide_apply.py` is
  the deterministic writer - validate-everything-then-apply, 43 fixtures (32 at first build; the
  gate round added the closed-enum refusals after a live decider invented nine taxonomy values; the
  2026-08-23 cold read added the state-metadata and workflow-shape classes) including
  an END-TO-END DRILL
  against a scratch run dir that asserts the ledger row equals the verdict's `record` block field by
  field, that `dupe_of` lands as DISTINCT terms, that a deferral goes back on the shelf, and that
  re-applying a verdict does not double-count an acceptance. `hunt-pool-seed.js` is the phase-1 bridge
  workflow. The recipe-dedup-selector prompt is rewritten to dossier-in / verdict-out and now says in
  as many words that it runs no commands and writes no files - and, after the round-1 decider wrote
  a v2-shape `selected.json` into the run dir despite that prose, the prohibition was converted into
  a read-only frontmatter tool list (`tools: Read, Grep, Glob`), which is the enforcement and the
  prose is now just the explanation; `ops\audit-prompt-backup.ps1 -Sync` was
  run and `ops\prompt-backup` is committed with it.
  **The bridge deliberately does NOT apply verdicts inside the sandbox.** Doing so would mean spawning
  a Claude agent whose entire job is one PowerShell line, which is finding F2 - so the workflow returns
  rulings and the box writes them. That is the same division of labour the daemon will have, minus the
  process boundary. It also means the bridge costs exactly ONE agent per ten candidates and nothing
  else.
- **D6 `local_extract.py` v2** - `--from-jsonld` mode + per-line split verification + round-trip
  check; orchestrator-facing exit contract (settled / escalate); the extractor agent's
  "try local first" section removed/gated for its escalation-only role (S3). Fixtures: an invented
  line MUST FIRE the substring check; a JSON-LD line split that drops a token fails round-trip.
  BUILT 2026-08-23, in three pieces. `local_extract.py` gained rung 1 (`--from-jsonld`), the
  section 4.5 contract emitter (`to_contract`), the `/props` slot-context probe, and a `--selftest`
  with **38 fixtures** including an end-to-end drill that runs the CLI as a child against a dead
  endpoint and asserts exit 2, the named server, and that NOTHING was written; the old
  `--url`/`--file` form is untouched, exactly as D2 kept coverage_check's. `extract_sweep.py` is the
  phase-2 bridge - cache-only, ladder, contract, lane-log per settle - with **23 fixtures** of its
  own, among them a drill against the real hunt-run.ps1 in a scratch run dir proving the lane line
  is `lane=extract by=local in=0 out=0`, and its must-fire twin proving an ESCALATION writes no
  settle line. The JSON-LD parsing is harvest.py's, imported (a fixture asserts the module), and
  building on it found a live defect in that shared parser: **`recipeIngredient` arrives
  HTML-ESCAPED** ("softened &amp;amp; cut into cubes"), so `raw` was carrying entity text the
  contract says is "the line exactly as printed". Fixed in `ingredient_lines` and
  `flatten_instructions` with four fixtures - it had already cost one real page an escalation over
  the token "amp".
  One more rule the build earned and froze: **the sweep's file cleanup runs ONE WAY.** Settling
  clears an earlier escalation file (or the extract lane dispatches a Claude extractor for a page
  already transcribed), but escalating never clears an earlier SETTLE - the round-2 rung-1-only
  pass re-ran a page round 1 had settled at rung 2 and deleted a verified extraction to put a
  failure in its place. A verified transcription is not made wrong by a later, cheaper pass not
  reaching it. Must-fire fixture, both directions.
  **PINNED FOR THE PHASE-2 BUILDER (2026-08-23 cold read - facts, not guesses):**
  - The file exists and works; D6 EXTENDS it. Its transport is `graph\lib\llm.py`'s LocalLLM with a
    deliberate 600 s timeout (the comment above that number says why - do not "fix" it down). Its
    verification block is already the shape §4.5's extraction contract refers to:
    `{lines, verified, unverified, verified_rate, unverified_lines, passed}` with the 0.85 bar in
    `MIN_VERIFIED` - reuse it verbatim for the jsonld rung, do not mint a second shape. Its output
    already carries `escalate` and `escalate_reason`.
  - The existing CLI (`--url` / `--file` `[--json]`, exit 0 settled / 1 escalate) KEEPS WORKING,
    exactly as D2 kept coverage_check's bare form when it added `--battery`. `--from-jsonld` is an
    addition. The one exit-code change: llama-server unreachable becomes a clean **exit 2
    could-not-run** naming the server (today it would traceback) - which completes the §4.5 mapping
    for this script: 0 = settled, 1 = escalate (that IS the findings case here), 2 = could-not-run.
  - The pre-extraction sweep (the phase-2 bridge) is a thin driver over this file: for each accepted
    slug it reads `source_url` from `<RunDir>\state\<slug>.json` (populated at state creation -
    decide_apply passes it since 2026-08-23; the pool entry carries the same URL as a cross-check),
    pulls the page from the fetch cache, runs the ladder, writes
    `<RunDir>\extracted\<slug>.json` per §4.5, and writes the lane-log line per settle
    (`-Lane -LaneName extract -By local`, tokens 0) - the sweep CAN shell, so §4.5's lane-log
    completeness rule is its job until the daemon takes it.
  - **Concurrency and the wall-clock envelope (2026-08-23 audit).** Drive the server with a thread
    pool at jobs <= Slots, the pattern graph\bench already uses. The arithmetic that says what
    "good" looks like: a short grammar call measured 2.74 s, a recipe carries ~10-20 ingredient
    lines, so rung-1 per-line splitting runs ~27-55 s/page SERIAL and ~7-14 s/page fanned across 4
    slots - the phase-2 gate's 50 pages are ~8-12 minutes fanned versus ~25-45 serial, and a sweep
    that measures near the serial number is leaving the card idle. Read the §4.3 local-27B row
    BEFORE building: rung-2 full pages do NOT fit a 4-slot context split at serve.ps1's defaults,
    and that conflict is resolved by measurement at build time, not discovered as mysterious
    overflows mid-sweep. Endpoints, so nothing is guessed: llama-server is port 8080 (llm.py speaks
    `/v1`, harvest.py --classify speaks native `/completion` + `/health`); the bge sidecar is 8077
    and is NOT involved in D6 at all - phase 1 moved harvest embeddings to CPU, so the extraction
    sweep has the whole card.
- **D7 `map-preresolve`** - the pre-resolved decision table + mechanical unbid hold; mapper prompt
  rewritten to the residual contract. Fixtures: a cache-resolved term never reaches the residual; an
  unbid resolved term holds the recipe with a named follow-up.
  **Ambiguity resolved before it becomes a guess (2026-08-23 cold read):** S4 says the mapper's
  result includes "holds", while this section's schema-delta list says SEL->DECIDE and WRITE are the
  ONLY schema changes. Both are true, read this way: the MECHANICAL unbid hold happens in
  map-preresolve BEFORE any agent and never reaches the mapper at all; a JUDGMENT hold the mapper
  itself raises is expressed through the EXISTING MAPPED fields (`status`/`state`/`detail` naming
  the follow-up), not a new schema field. If the D7 build finds that inadequate, the fix is a third
  NAMED delta recorded in §4.5 in the same commit - never an implicit field.
  **ADDED 2026-08-24, a phase-2 fact the D7 builder must not guess around: rung-1 `item` fields
  KEEP their describing words.** The round-trip check demands every non-glue word of the line land
  in some field, so a verified rung-1 extraction says "boneless skinless chicken thighs", "small
  onion", "extra virgin olive oil" - NOT the stripped noun the v2 Claude extractor tended to
  return. Any normalisation toward the vocabulary happens inside map-preresolve's matching (where
  it is evidence-checked), never by asking extraction to pre-strip; an extraction that dropped
  "boneless skinless" would be a WORSE extraction and D6's checker now refuses it. Expect the
  cache/vocab/alias lookups to see the richer strings and measure the residual rate against them.
  Composed surfaces, by path so nobody greps for them: `meal-prep\pipeline\ingredient-vocab.ps1`,
  `meal-prep\pipeline\ingredient-resolutions.ps1`, `grocery\price-ingredient.ps1`,
  `meal-prep\db\densities.json`, `meal-prep\db\each-nouns.json`.
- **D8 `build-intake-skeleton.ps1`** - machine-complete intake skeleton; the pre-write band gate;
  writer prompt rewritten to prose-only; the orchestrator's post-write machine-field diff (S6).
  Fixtures: a skeleton field the writer changed is refused by the diff; an out-of-band skeleton
  retires before any writer dispatch; a clean prose-only fill passes untouched.
- **D9 `hunt-daemon.py` + `hunt_lib.py` + the dispatch adapter (§4.1a)** - **BUILT 2026-08-24;
  the phase-3 gate record is in section 6.** The port, under §4.2's
  parity gate; daemon-owned state writes and lane-log start/end pairs with token stamping; the wave
  control flow ported decision-for-decision. Fixtures: the full hunt-lib suite ported, plus
  daemon-level twins for B5 (null is STUCK), B6 (per-slug budgets), B7 (first-token verdicts), B8
  (a mapper verdict with terms as a JSON array lands on the queue as distinct terms), B10 (trim),
  B11 (repair-claim mtime check), and the cost-engine mutex (§4.5: two concurrent write-lane
  completions produce serialized cost passes and a parseable costed.json); plus the adapter drill
  artifacts: per-agent behavior diff vs a Workflow twin and the measured per-dispatch fixed
  overhead.
  **ADDED 2026-08-23, five more D9 obligations from phase 1's measured findings:** every PowerShell
  call that carries an array goes through `hunt_lib.ps_invoke` - the `-File` binding twins (silent
  drop, composite string) are frozen in decide_apply's suite and the daemon inherits them, never a
  second invocation style; any single-file ledger written by a lane whose cap exceeds 1 takes the
  source-domains named-mutex pattern, with a concurrent-writers fixture PER LEDGER (the measured
  cost of skipping one: 2,293 outcomes recorded as 65); the decide dispatch threads accepted-so-far
  (fixture: the second batch's prompt contains the first's acceptances); candidates are marked
  `taken:<run-id>` at pop, before dispatch; and the dedup surface gains the `in-flight` side from
  open run dirs (the jalapeno-popper collision, S1). Also inherited from the bridge: the daemon
  writes the decide lane-log lines natively with real token stamps - the bridge cannot (no shell in
  the sandbox), so until D9 lands every bridge run ends with the operator recording them by hand,
  as the mini-run's were.
  **PINNED FOR THE PHASE-3 BUILDER (2026-08-24, from the phase-2 build - facts, not guesses):**
  - **The extract lane's mechanics already exist; import them.** `extract_sweep.py` carries the
    ladder (`Ladder`, `sweep_one`), the contract writer (`write_record`, with the one-way cleanup
    rule and its must-fire fixtures both directions), the corpus report (`report`), and the
    slot-context probe (`local_extract.slot_context`, reading llama-server's `/props`). The daemon
    calls `run_sweep(..., do_lane_log=False, do_advance=False)` and performs the advances and lane
    lines through its own pen per section 4.1a - it does NOT re-derive the ladder, for the same
    reason D6 imported harvest's parsers instead of writing a third one.
  - **The daemon never starts or stops llama-server.** Section 4.4 stands unchanged. At extract-lane
    start it reads the live slot context: rung 1 fits any shape (the D6 split prompt is ~450 tokens
    + the line + 256 out, ~750/slot total - still under half of even an 8-slot 2,048-token split);
    rung 2 requires `local_extract.RUNG2_MIN_SLOT_CTX` (~11,465), which only the 1-slot
    shape provides. When the live shape cannot fit rung 2, escalation files ACCUMULATE and the
    daemon's own status surface (its analogue of hunt-run's -Status) names the pending narrow pass - the operator then either restarts the
    server narrow and lets the daemon drain rung 2 via the `--from-report` shape, or rules the batch
    straight to rung 3. Rung-1-failed pages ARE legitimate rung-3 work (rung 3 exists for pages the
    local pass failed on), so skipping an unavailable rung 2 by OPERATOR RULING is within doctrine;
    doing it silently or automatically is not.
  - **One cheap retry before paying anything more.** Rung 1 at temp 0.1 is not deterministic
    (measured: a page whose ONE failing line sat at 88% round-trip coverage settled on re-run with
    zero code change, and a different page flipped the other way between rounds). The rule, stated
    so nobody has to guess which number means what: retry rung 1 ONCE when at most
    `RUNG1_RETRY_MAX_FAILED_LINES` (= 1) lines failed AND every failing line's per-line round-trip
    coverage (the `coverage` field in the escalation's `failures[]`) is >=
    `RUNG1_RETRY_MIN_COVERAGE` (= 0.85) - near-misses only; a qty/unit substring failure or a
    low-coverage mangle goes straight down the ladder. ~10 GPU-seconds against a ~50 s rung-2
    attempt or a Claude dispatch. D9 ADDS these constants to hunt_lib as daemon config (they do
    not exist yet - the failures[] coverage field they read does), with a fixture proving a
    second identical failure still escalates - one retry, never a loop.
  - **The rung-3 dispatch and its landing.** The `<slug>.escalation.json` file IS the dispatch
    payload (S3: the failure reason and unverified lines travel with the page; the extractor is
    told not to re-run the local script). The daemon writes the extractor's returned JSON through
    the SAME section 4.5 contract, `extracted_by: "claude"`, computes the `verification` block
    mechanically with `local_extract.verify()` against
    `local_extract.page_text_from_html(<cached HTML>)` - NOT against the raw HTML: an ingredient
    line interleaved with inline tags ("1 lb <strong>chicken</strong>") never substring-matches
    raw markup, so skipping the strip would smear honest Claude extractions with a false-low
    verified_rate. (Rung 2 itself feeds verify() through the same function.) RECORDING, not
    gating:
    rung 3 is the last rung, so a low verified_rate there is surfaced to source-QA as a concern
    rather than escalated to nowhere - and deletes the escalation file on settle (the one-way
    cleanup rule; leaving it would double-dispatch a settled page).
  - **The economics to plan the lane around (all measured on the 50-page gate corpus):** rung 1
    settles 92% at 9.5 s/page fanned; rung 2 settles 3 of 16 attempts (~19%) at ~50 s/page on the
    narrow server and lifts the ladder to 94%; the residue is 6%. The ladder's value sits almost
    entirely in rung 1 - budget the card and the operator asks accordingly.
- **D10 price evidence pre-pass** (paths, so nothing is guessed: `grocery\probe-ingredient.ps1`,
  `grocery\pull-browser-stores.py`, `grocery\search-verdict-lib.ps1`, `grocery\price-ingredient.ps1`,
  `grocery\ingredient-queue.ps1`) - probe + unattended CDP gathering wired into the price lane's
  dossier; pricer prompt rewritten to adjudicate-and-attend. Fixture: an UNUSABLE sweep state reads
  as PENDING, never not-carried (the founding rule, mechanized).
- **D11 SKILL.md v3 rewrite + agent-prompt slimming** - constants out of per-call prompts into the
  agent definitions (prefix-cache friendly), stage contracts updated to dossier-in/ruling-out, the
  v3 lane diagram, and the run-budget practice (fresh session per phase; ask Brad for the usage %
  before each phase - the daemon cannot see the meter either).
  **ADDED 2026-08-23: every rewritten agent gets the MINIMAL tool list its contract needs, declared
  in frontmatter.** On the gate run a decider forbidden IN PROSE from writing files wrote a v2-shape
  `selected.json` into the run dir anyway; the fix was `tools: Read, Grep, Glob`, not better prose.
  A prohibition in prose is a request; a missing tool is a contract. Where an agent must keep Write
  for its work product (the writer's intake prose, the extractor's transcription), the enforcement
  is the mechanical postcondition instead - D8's locked-field diff, D6's substring verifier - and
  the D5 decider conversion is the reference for the pattern.
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
  BUILT 2026-08-23: both agent definitions and both hunt-orchestrator.js dispatch prompts carry the
  concrete battery commands, and ops\prompt-backup was synced in the same commit.
- **Phase 1 bridge:** the harvester feeds the existing orchestrator through the proven drain-mode
  shape - hunt/adjudicate lanes off, one seed step reads the pool and pipes accepted work downstream;
  the decider dispatch carries dossiers inline. The mini-run for the phase gate runs in exactly this
  configuration.
  BUILT 2026-08-23 as `meal-prep\pipeline\hunt-pool-seed.js`, in three steps with the sandbox in the
  middle of them: `harvest.py --dossier` on the box (no agents), one recipe-dedup-selector call per
  <=10 dossiers in the workflow, `decide_apply.py` on the box (no agents). **The apply step is
  deliberately outside the sandbox**: applying a verdict from inside it would mean spawning a full
  Claude agent whose entire job is one PowerShell line, which is finding F2 itself. So the bridge
  costs exactly ONE agent per ten candidates and nothing else, and when the daemon lands (D9) the
  first and third steps become function calls in its own process with nothing about the second
  changing. hunt-orchestrator.js is untouched apart from a header note marking its hunt/adjudicate
  lanes superseded; DRAIN mode still carries whatever the bridge seeds from `selected` downstream.
  One operating duty until D9: the bridge cannot write lane-log lines, so after each bridge run the
  operator records the decide dispatches under `select` via `hunt-run.ps1 -Lane` with lane-tokens'
  per-transcript figures - §4.5's lane-log completeness rule does not pause for the interim.
- **Phase 2 bridge:** until the daemon exists, rungs 1-2 of the extraction ladder run as a
  pre-extraction sweep over the accepted candidates (a script pass on the box, since the Workflow
  cannot shell), and the workflow's extract lane is dispatched only for the escalations the sweep
  left behind.
  **Phase-2 pickup (2026-08-23, so the next session starts building instead of hunting):** read, in
  order, local_extract.py's header (the file D6 extends - its transport, verification block and exit
  codes are pinned in the D6 bullet), harvest.py's parser functions (reused, never re-implemented),
  §4.5's extraction contract and rung-1 thresholds, and the D6 bullet itself. The gate corpus: the
  four accepted recipes at `selected` in `runs\hunt-2026-08-23-v3-phase1-mini` (their `source_url`
  is in each state file; every page cached), plus enough available in-band candidates' cached pages
  to reach the gate's 50, drawn across all 7 publishers - `harvest.py --dossier --count N` pops them
  ranked, or read the pool directly for URLs; either way the pages come from the cache, zero
  fetches. llama-server must be up (hand-started, §4.4) before the sweep runs; a down server is
  exit 2 BLOCKED, never an escalation. And since the server is up anyway: run
  `harvest.py --classify` in the same sitting - phase 1 never could (the server was down all
  session), so the pool's sauce_family nulls are still unfilled, and every null widens a dossier's
  neighbour search that one classify pass would sharpen. Zero extra GPU scheduling; the card is
  already hot.

| phase | items | gate to pass before the next phase |
|---|---|---|
| 0 | D1 + D2 (batteries) | batteries green on the real lowcarb-100 wave dirs; a re-audit of one repaired slug costs seconds + one scoped sign-off |
| 1 **DONE 2026-08-23** | D3 + D4 + D5 (harvest + decider) | a harvest of >=200 in-band candidates from >=6 publishers with dupe-dossier spot-check; decider ruling on dossiers alone matches a hand check on 20 candidates; front-end token share re-measured on a mini-run |
| 2 **DONE 2026-08-23** | D6 (extraction ladder) | rung-1/2 settle rate and escalation rate measured on 50 cached pages; zero unverified lines pass |
| 3 | D9 (the daemon + §4.1a adapter) | hunt-lib parity suite green; adapter drill: per-agent behavior diff vs Workflow twins + measured per-dispatch overhead; drain drill per §4.2; audit-lane-shape clean on the daemon's log |
| 4 | D7 + D8 (map/write slimming) | mapper residual rate measured; one wave written from skeletons with guards green |
| 5 | D10 (price pre-pass) | one real absent-term batch priced with pre-gathered evidence; ladder states honest per store |
| 6 | **the proving run**: ~20 recipes, wave size 10, Brad-directed conditions | success criteria written before the run, incl.: per-recipe tokens (billed measure) and steady-state wall-clock per published recipe both measured against §7's targets; >=5x fewer Claude invocations per published recipe than the 27 measured; zero gate weakened; every new defect class frozen as a fixture same-day |
| E (optional) | 27B LoRA (extraction/line-split), cross-encoder dish-dedup fine-tune | only after 6; >=3 seeds per arm; detached LoRA never a merged GGUF |

**Phase 0 gate: PASSED 2026-08-23** (commit d0d8af5c). Evidence, so the next session does not re-earn
it: batteries run whole-wave against the real lowcarb-100 dirs in ~14 s each (waves 1/3/4; wave 2 exits
2 on its genuinely empty reconciled manifest, which is the correct answer, not a stumble); a scoped
re-audit of one slug is 13 s and exits 0; the five self-test suites are green (wave-preaudit 48,
wave-publish 43, guard-contract 9, test-guards 48, qa-battery 69; zero FAIL). The one live finding
class the batteries surfaced - `cost-reconcile` drift on 10 of 20 published specs - is real, is being
repaired in its own session through recost-spec-cost-block.ps1, and does not gate phase 1. Do not
chase it from a build session, and expect specs/costed.json to be moving underneath any verification
run while that repair session is open.

**Phase 1 gate: PASSED 2026-08-23.** Evidence, so the next session does not re-earn it.

*Gate 1 - a harvest of >=200 in-band candidates from >=6 publishers, with a dupe-dossier spot-check.*
**MET.** `meal-prep\db\candidate-pool.json` holds 2,162 entries: **679 available from 7 publishers,
of which 244 are band-verified in band** (the strict reading; the looser reading, "the band filter did
not rule it out", is all 679). 1,384 were filtered out of band and 99 excluded on the standing
conditions - all recorded with the numbers that ruled them, none re-fetchable. 9,012 recipe URLs
enumerated from sitemaps alone; 2,293 pages fetched and cached. The dupe-dossier spot-check:
`sausage-and-white-bean-soup` surfaced `tuscan-white-bean-sausage-soup` at word-overlap 40 (all four
identity words) and bge-m3 0.899, both labelled `live-catalog`, and the decider killed it 4-of-4 on
exactly that evidence; `ground-beef-stroganoff` surfaced `ground-beef-stroganoff-pasta` at bge 0.965.
A DEVIATION, recorded: the per-domain nightly cap was raised from its 60 default to 340 for the gate
crawl, because the gate needed >=200 band-verified in one afternoon and the measured in-band rate is
~12%. The default stands at 60 for scheduled use; nothing about harvest is scheduled in this phase.

*Gate 2 - the decider ruling on dossiers alone matches a hand check on 20 candidates.* **MET on the
second round, and the first round is the more useful record.** A hand check of all 20 was written to
disk BEFORE any dispatch so the comparison could not be anchored (2 accept / 9 rejected-dupe /
9 rejected-not-fit, judged from full ingredient lists, find-similar at Top 8, and direct slug lookups
in recipes-db.json).
  - **Round 1: 7 of 20 exact, 8 of 20 on the accept/reject binary.** That is a fail, and it was worth
    more than a pass would have been, because all three causes were findable: (a) neighbours were not
    labelled live-vs-backlog, so the decider could not tell a published dinner from another unruled
    candidate and went to read `catalog-digest.json` itself - **it reported this defect in my build in
    its own return note**; (b) no batch-scalability signal, and 6 of the disagreements were exactly
    "is this a batch dinner" calls; (c) my bridge dispatched each batch with no memory of the last, so
    the single decider was really N independent ones - it rejected `antipasto-salad` as a dupe in
    batch 1 and accepted its twin `antipasto-pasta-salad` in batch 2.
  - **Round 2, same 20 candidates, after fixing all three: 15 of 20 exact; on the 18 candidates the
    decider actually RULED, 15 of 18.** (An earlier draft of this record said "16 of 20 binary" and
    "four disagreements" - both were arithmetic errors, corrected 2026-08-23 against the recorded
    verdict files; there are FIVE disagreements.) Two of the five are DEFERRALS, which are
    non-rulings routed back to the shelf: `instant-pot-pulled-pork` (hand check said dupe; the
    decider flagged the same 3-of-4 collision and deferred it to audit) and `balsamic-chicken` (hand
    check said accept; the decider's reason caught what the hand check missed - the page plates the
    chicken over a berry-and-arugula salad). One is the decider being right where the hand check was
    coarse: `lentil-sausage-soup` is a different legume and a tomato base, not another white-bean
    soup, and lentils are absent from the catalog entirely. Two are genuine borderline splits on the
    near-duplicate threshold that the decider itself flagged as borderline
    (`mushroom-chicken-pasta`, `chicken-broccoli-ziti`). **Zero cases where the decider is plainly
    wrong.** Token cost fell with the same fixes: 1,672,970 context-moved in round 1 to 1,050,460 in
    round 2 (-37%), with tool calls per batch dropping 5 -> 3, which is the corpus reads going away.
  - The full write path was then demonstrated on the real verdict. `decide_apply.py` REFUSED it first
    (exit 2, nothing written, 9 invented enum values named), which is the enum enforcement above doing
    its job on live output; after normalisation it wrote 4 acceptances, 5 dupe rejections to run state,
    18 ledger rows all `by=decider`, 9 not-fit rulings that correctly took NO run state, and returned
    2 deferrals to `available`.
  - *Addendum, same day.* The gate demonstration ran the pool/ledger writes against SCRATCH copies
    while the run-dir state writes were real - which left the committed run dir claiming state the
    live pool and ledger did not carry, a trap for the next session. The verdict was therefore
    re-applied through the same decide_apply path against the LIVE stores (idempotent on the run
    dir: state advances and the accepted-slugs append skip work already done). Live pool after:
    661 available (226 band-verified), 18 newly ruled, the 2 deferrals back on the shelf; 18 rulings
    in `db\considered-dishes.json`, all `-By decider`, run `hunt-2026-08-23-v3-phase1-mini`. And one
    §4.5 deviation recorded: the bridge cannot write lane-log lines (no shell in the sandbox) and
    decide_apply does not know token counts, so the mini-run's four decide dispatches were
    lane-logged by hand under `select` with each transcript's tokens measured by lane-tokens itself
    (r1: 741,282/19,444 and 896,058/16,186; r2: 562,011/5,784 and 472,877/9,788). D9's daemon owns
    that line natively; until then every bridge run ends with the operator recording its decide lane
    lines the same way. The cold read also found the entry advance passing only `-Detail`: hunt-run
    sets `title`/`source_url`/`protein` ONLY at state-file creation, the wave manifest is built from
    exactly those fields, and no later -Advance can back-fill them - so the mini-run's nine state
    files were created with all three empty. decide_apply now passes `-Title`/`-SourceUrl`/`-Protein`
    from the pool candidate (drill fixture: the created state file carries them), and the nine were
    repaired by deleting and replaying the advances through the fixed path against a discard ledger
    (the 18 live rulings already stood; replaying against the live store would have doubled them).
    Two audit facts recorded so later sessions reason from them rather than around them
    (2026-08-23): **(a) the round-2 decider still read the corpus.** Both batches made 3 tool calls
    where a dossier-only ruling needs 1 (StructuredOutput), and batch 2's own note says it
    "adjudicated against the live catalog-digest.json" - despite the dispatch stating the catalog
    had been searched for it. Roughly a third of the 1.05M context-moved is those extra turns. The
    zero-tool decider (no Read at all, single-turn) is therefore a REAL efficiency lever - but it
    is a phase-6 MEASURED decision, not a build-time convenience, because the residue principle
    cuts the other way: Read is also how the decider double-checks, and round 2's accuracy may
    lean on exactly the reads the lever would remove. **(b) the read-only tool restriction is not
    yet live-tested.** Both gate rounds ran BEFORE the frontmatter was restricted (round 2 is when
    the stray selected.json appeared), so the first bridge run of phase 2+ is the restricted
    decider's first live dispatch - watch it, do not assume it.

*Gate 3 - front-end token share re-measured on a mini-run in the phase-1 bridge configuration.*
**MET.** Measured with `lane-tokens.ps1`, the same instrument and the same context-moved measure that
produced the 75.5% baseline. The bridge ran drain-shaped: hunt and adjudicate lanes off, one seed step
reading the pool, dossiers inline, two decider calls for 20 candidates and no other agent.

| measure | v2 measured | v3 phase-1 measured |
|---|---|---|
| front-end tokens, per candidate | n/a | 52,523 (round 2: 1,050,460 / 20) |
| front-end tokens, per published recipe | 28,385,055 | ~630,000 at the plan's 12-candidates-per-published yield |
| front-end share of run tokens | 75.5% | **~6.4%** (target <15%) |
| front-end Claude invocations per published recipe | ~27 | **1.2** (target <=6 total) |

The share holds the downstream lanes at their v2 measured cost (9,203,210 context-moved per published
recipe), because phases 2, 4 and 5 have not slimmed them yet - so this is the conservative number and
it will improve. Two caveats stated rather than buried: the per-published figures use the plan's own
12-candidates-per-published yield (this round accepted 4 of 20, which would make it worse, and 11 of
20 in round 1, which would make it better - one mini-run is not a yield measurement), and
context-moved counts cache reads, so it is a volume measure and not a bill, exactly as section 1.2
says.

Two clarifications recorded for the phase-1 builder, so neither becomes a mid-build stall:

- ~~**The gate's ">=6 publishers" exceeds today's ledger.** source-domains has 5 domains.~~
  **WITHDRAWN 2026-08-23 by the phase-1 build - the premise was wrong.** The ledger holds 20 rows, of
  which **7 are `reliable`**; the other 13 are the migrated block list, which is not the same thing as
  a publisher we do not have. All 7 enumerate (9,012 recipe URLs from sitemaps alone). The gate's
  >=6 publishers was met from the ledger, **the sourcer discovery round was not needed and was not
  run**, and its budget was not spent. The road S1 names is still the road when the ledger genuinely
  runs thin - a Claude discovery round whose finds enter through `harvest.py --ingest` like every
  other candidate - but it was not needed here. The transferable lesson: a plan may point AT a ledger;
  it must not quote a count OF one, because the count is the ledger's to state and it moves.
- **PS 5.1 collection traps, pinned.** Two of the three defects wave-preaudit shipped with on its
  first day were invisible to every pure-predicate fixture: an OrderedDictionary's ambiguous indexer,
  and `@()` over a List[object] of dictionaries throwing "Argument types do not match". Both are frozen
  as fixtures in `wave-preaudit.ps1 -SelfTest`; read them before writing any new PS collection code,
  and prefer an end-to-end drill (run the script as a child against a scratch root) for anything whose
  failure mode only appears when results are collected.
  **A THIRD trap joined them during phase 1 (2026-08-23, measured): `@(<pipeline> | ConvertFrom-Json)`
  on a MANY-element JSON array binds ONE element of type Object[].** ConvertFrom-Json emits the whole
  array as a single pipeline object in PS 5.1, and `@()` then collects that one object - so the
  estate's standing "wrap ConvertFrom-Json in @()" rule is only the one-element half of the story,
  and on a many-element file it is actively wrong. ASSIGN FIRST, THEN WRAP (`$p = ... | ConvertFrom-Json;
  $rows = @($p)`). It cost both new `-BatchFile` roads their entire batch - every query collapsed into
  one row whose key was all the keys joined by spaces - and it was invisible at batch size one, which
  was exactly the size the first fixture used. Frozen as must-fire three-row fixtures in
  `find-similar.ps1 -SelfTest` and `considered-dishes.ps1 -SelfTest`. **D7's map-preresolve.ps1 and
  D8's build-intake-skeleton.ps1 are the next new PS collection code this plan orders; their builders
  read all three traps first, and any fixture over a collection uses at least three elements.**
  **A FOURTH TRAP, and this one is about the fixtures rather than the code (2026-08-24, D9,
  measured). A CONCURRENCY FIXTURE THAT CANNOT LOSE A ROW PROVES NOTHING, and the estate had one.**
  `source-domains.ps1 -SelfTest`'s "8 concurrent -Record calls all land" test - the very fixture this
  plan tells every later ledger to copy (see D9's phase-1 obligations) - PASSED WITH ITS OWN MUTEX
  NEUTERED. The reason is arithmetic, not PowerShell: each `Start-Job` child spawns its own
  powershell.exe at roughly a second apiece while the read-modify-write costs about two
  milliseconds, so no two writers were ever inside the critical section at the same time. There was
  no race to lose. Two things are needed and both are now in `source-domains.ps1` and
  `ingredient-resolutions.ps1`: **a START BARRIER** (every child is handed the same UTC instant and
  spins until it arrives) and **a critical section slow enough to overlap** (the scratch store is
  seeded with 400 rows, which puts the read-modify-write in the tens of milliseconds). With both,
  the neutered runs measured `kept 1 of 4 rows` and `ok=-1 of 8, kept 0 of 400`; with the locks in
  place, both are green. The locks were always right; only their fixtures were asleep. **Every
  concurrent-writers fixture this plan orders - ingredient-resolutions is the one D9 built, and any
  later ledger a cap>1 lane writes - must be PROVEN to fail with its lock removed before it counts.**

**Phase 2 gate: PASSED 2026-08-23.** Evidence, so the next session does not re-earn it.

*The corpus.* Exactly the 50 cached pages the pickup block named: the 4 accepted recipes at
`selected` in `runs\hunt-2026-08-23-v3-phase1-mini` plus 46 available band-verified candidates
popped round-robin across all 7 publishers. **Zero fetches, zero politeness budget** - every page
came off the harvester's cache, which is what the pool exists for.

*Gate 1 - rung-1/2 settle rate and escalation rate on 50 cached pages.* **MET, and measured
twice, because the first round was worth more than a pass.**

| round | settled at rung 1 | settled at rung 2 | escalated to Claude | settled overall | s/page (rung 1, fanned) |
|---|---|---|---|---|---|
| 1 (after the pilot's prompt rewrite - 4.5's first correction) | 38/50 = **76%** | 2 of 12 attempted | 10/50 = **20%** | 40/50 = 80% | 9.6 s |
| 2 (adding the HTML-entity parser fix + the for-serving prompt line) | 46/50 = **92%** | 1 of 4 attempted | **3/50 = 6%** | 47/50 = **94%** | 9.5 s |

(The prompt AS FIRST WRITTEN never ran on the gate corpus: it measured **1 settled page in 7** on
the pre-gate pilot, which is what forced 4.5's first correction before any 50-page sweep was worth
the GPU time. Round 1 is the rewritten prompt; round 2 is the same prompt plus the two smaller
fixes named in its label.)

Round 1's 13 escalations, recounted from `gate-pass1.json` (2026-08-24 cold read - an earlier
draft of this record said "9 of one narrow class", which was wrong on both numbers): **11 of the
13 failed on exactly one line.** Six of those eleven were one narrow class - a for-serving /
for-topping / adjust-to-taste note left out of prep, fixed by ONE added prompt sentence; one was
the HTML-entity defect in the shared parser (`&amp;`); four were assorted single-word drops. The
two multi-line failures were the brand class (5 lines of "Specially Selected...") and Budget
Bytes prices embedded INSIDE prose notes ("(12 oz total, $1.29)", 7 lines) - which the
price-annotation rule deliberately does not strike, because striking a price out of a sentence
would take words with it. Round 2 fixed the parser and added the one prompt sentence - **never the
threshold** - and the escalation rate fell from 20% to 6%. Honesty about the residue of that gain:
two of the round-2 settles (the beets line that dropped a "4", the KFC flavour note) had no fix
aimed at them and settled on the re-roll, and one page went the other way (settled round 1,
escalated round 2 pass 1, re-settled on the narrow pass) - that is the nondeterminism item below,
not a hidden third fix. **The plan's own estimate for this deliverable was "~5-15% of pages"
reaching the Claude extractor; the measured figure is 6%.** The three survivors are honest hard
pages: the brand class ("1/3 cup Specially Selected Sicilian Extra Virgin Olive Oil"), a dropped
"1" in "1 dry pint cherry or grape tomatoes", and a dropped "stalks" in "2 large celery
stalks".

Rung 2's own numbers, across both rounds: **3 of 16 attempted pages settled (19%) at ~50 s/page**
on the narrow server. That is expensive and low-yield, and it is a real finding for D9: the
ladder's value sits almost entirely in rung 1, so a daemon deciding how to spend the card should
run rung 1 over everything and treat rung 2 as an occasional second look rather than a stage.

*Gate 2 - ZERO unverified lines pass into any settled extraction.* **MET, mechanically.** Both
sweep reports carry `unverified_lines_in_settled: 0` over all 50 pages, and it cannot be otherwise
by construction: rung 1's bar is EVERY line (one failure escalates the whole page), and the
settled contract carries the verifier's block so the claim is auditable rather than asserted. The
fixture pins it from the other side - an escalation is written to a DIFFERENT filename, so an
unsettled page cannot occupy the settled name.

*Gate 3 - wall clock against the D6 envelope (~7-14 s/page fanned; near-serial means an idle
card).* **MET at 9.5-9.6 s/page mean, 476-482 s for 50 pages.** The fan-out is doing real work and
the number proves it rather than assuming it: the SAME page measured 13.5 s fanned across 4 slots
and 22.8 s on the 1-slot server, and the whole rung-2 pass ran at 49 s/page where rung-1 pages ran
at 9.5. A serial rung-1 sweep would have been ~25-45 minutes; it was 8.

*The bridge did real work, not a drill.* All four accepted recipes were extracted locally,
advanced `selected -> extracted` through hunt-run.ps1, and lane-logged `by=local, in=0, out=0`.
That is four Claude extractor invocations the run did not pay for, and the lane log says so.

*Also done in the same sitting, per the phase-2 pickup block:* `harvest.py --classify` ran while
the card was hot and filled the pool's sauce-family nulls that phase 1 could never reach.

*Six-dimension check (2026-08-24, numbers from the gate corpus, recorded so nobody re-audits from
guesses):* **Concurrency** - one shared ThreadPoolExecutor at jobs <= Slots for rung-1 lines; the
sweep's own writes are serial (one page settles at a time), lane-log lines go through hunt-run.ps1
one at a time, and the one-way file cleanup is fixtured both directions, so no single-writer file
gained a second writer. **CPU cores** - the lane is GPU-bound by design; CPU sits idle during a
sweep and that is correct, not waste (the 8-core budget is for harvest/battery fan-out, which this
lane does not touch). **GPU slots** - 3.4x measured against the 4x ideal (595 line-splits at a
2.74 s serial baseline would be ~1,630 s; the fanned sweep ran 476 s), i.e. ~85% slot utilisation;
the missing 15% is each page's tail lines idling slots, and cross-page packing would recover ~1.4
s/page - a deferred lever, measured before built, not worth complexity at today's corpus sizes.
**Speed** - 9.5 s/page mean against the 7-14 s envelope; 50 pages in 8 minutes where serial would
be ~27. **Efficiency** - 47 of 50 pages settled for 0 Claude tokens; the 4 accepted recipes cost
the run zero extractor dispatches; classify filled 370 nulls in the same GPU sitting. **Accuracy**
- zero unverified lines in any settled extraction (mechanical, both reports), every settle carries
its verifier block, and the failure direction is preserved everywhere: uncached page, down server
and too-small slot are all exit-2 BLOCKED, never a silent pass or a silent Claude dispatch.

Two things a phase-3 builder should carry forward. **(a) Rung 1 is not deterministic.**
`jalape-o-popper-chicken` escalated on one line at 88% round-trip coverage (17 of 18 lines
verified) and settled on the next pass with no
code change between them (temp 0.1, not 0). A borderline page is a coin the sweep flips, so a
settle rate is a rate and not a verdict about a page, and the daemon should not treat one
escalation as a permanent property of a URL. **(b) The two-server-shape sweep is an operating
shape, not a workaround** - see the resolved conflict in section 4.3, and `--from-report` is what
makes it cheap.

**Phase 3 gate: PASSED 2026-08-24.** Evidence, so the next session does not re-earn it.

*Gate 1 - the hunt-lib parity suite green, every ported fixture, both implementations, shared
vectors.* **MET. 58/58 on both sides.** `hunt-lib-vectors.json` holds one vector per assertion
hunt-lib.js's own selfTest already made, in four kinds: pure calls, a bumpRetries SEQUENCE (B6 is
about state carried between calls), a breaker operation sequence, and five named async channel
scenarios. `hunt_lib.py --parity` runs them against the port; `hunt-lib-parity.js` runs the SAME file
against hunt-lib.js in a zero-agent Workflow (run wf_26cad6f5-70e: 0 agents, 0 tokens, 9 ms). The JS
side splices hunt-lib.js's source in by generator with its SHA-256 stamped, and `hunt_lib.py
--selftest` re-hashes the shipped file and fires if the two drift - because the first build passed
the source through `args` and evaluated it, and the harness refuses that ("EvalError: Code generation
from strings disallowed for this context").

*Gate 2 - the adapter drill: every agent type once, behavior diffed against a Workflow twin, fixed
per-dispatch overhead measured.* **MET, and it corrected this document.** See §4.1a: `--agent` works,
`--effort` exists, 10 of 10 agree on both roads, and the headless road costs 18,050 input tokens per
dispatch against the twin's 46,572.

*Gate 3 - the drain drill per §4.2.* **MET.** `hunt_daemon_drill.py`, seeded from the real
lowcarb-100 dir's `-Status` (read-only) and then working on a copy: a wave of 4 closed, preaudited,
audited GO and walked every publish gate under `wave-publish -DryRun` (P1 verdict, P1b freshness, P2
ledger stamp, P3 states, 4 would publish, 0 held, no reviewer dispatched because a dry run publishes
nothing); 3 more recipes walked write -> qa -> qa-passed; the run dir diffed clean against the
contract - files, directories, lane-line keys, lane vocabulary, state-file keys - with 7 start/end
pairs all carrying token stamps. The judgment agents and `build-v2-spec -RunCost` are stood in for,
each for a stated reason, and the drill's report says so rather than hiding it.

*Gate 4 - audit-lane-shape clean on a daemon-produced lane log.* **MET, after fixing the audit.**
A run dir the daemon wrote from `-Init` onwards, driven through the two lanes the audit actually
shape-judges: `map 1 invocation, 3 distinct items, floor 1` and `price 1 invocation, 4 distinct
items, floor 1`, "lane shape matches the design", findings=0, exit 0. Getting there required the
`Get-Invocations` correction recorded in §4.5 - the audit had been counting every dispatch twice
since 2026-08-16 - and two daemon fixes the drill earned: the map lane now enqueues a whole
micro-batch before waking the pricer once (waking per slug turned the cross-recipe drainer into a
per-recipe stage), and a term already sent to the pricer this run is never sent again (`absent_terms`
is consumed destructively, so the second recipe wanting a shared term re-queued it behind a pricer
that had already ruled).

*Three things a phase-4 builder should carry forward.* **(a) The drill wrote to the live batch
ledger before anyone noticed** - two open w5/w6 rows that `batch-ledger -Verify` would have called
stalled batches forever. Reverted, and the daemon now takes a `--ledger` scratch path that every
batch-ledger call goes through, mirroring wave-publish's own `-LedgerPath`. Any drill that touches
the wave lane uses it. **(b) A concurrency fixture that cannot lose a row proves nothing** - see the
fourth PS trap in this section. **(c) The QA battery correctly exits 2 when a spec was never built,
and the daemon records that as a finding and still dispatches source-QA.** Could-not-look is never a
clean bill, and it is also never a reason to skip the judge.

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

Phase-1 measurements against these targets (2026-08-23, the bridge mini-run; full evidence in the
section 6 gate record): front-end share **6.4%** against the <15% target, and **1.2** front-end
Claude invocations per published recipe against the ~27 measured baseline, both at the plan's
12-candidates-per-published yield assumption and both by lane-tokens' context-moved measure - the
same instrument as the 75.5% baseline. The billed-tokens and wall-clock rows remain phase 6's to
measure.

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
| duplicate dish published | 8-agent adjudication + decider | signature + embedding + prior-rulings dossier, then the same decider (in-flight recipes in OTHER open runs stay a blind spot until S1's `in-flight` side lands - gap dated 2026-08-23) |
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
  MEASURED 2026-08-23: no starvation - all 7 reliable publishers enumerate, 9,012 recipe URLs from
  sitemaps alone, zero WP-REST fallbacks needed. The number that DOES bound the backlog is the
  in-band rate: ~11% of crawled pages land band-verified in band (244 of 2,162 pool entries; another
  435 sit available band-unverified for the decider), and the rate declines as the priority-ordered
  URLs are consumed. At the standing 60-page nightly cap that is roughly 45 band-verified candidates
  a night across the estate - fine for steady state, and the reason the gate crawl ran with an
  explicitly recorded raised cap rather than a bigger default.
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
