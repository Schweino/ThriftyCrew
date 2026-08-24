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
- **Unattended browser pre-pass (mechanical):** pull-browser-stores.py lookups with the existing
  pacing profiles and wall detection (a wall stops the lane and leaves UNUSABLE, which reads as
  PENDING - never not-carried). **Sam's Club sweeps only when the driver profile carries a
  live member session** - the daemon checks that precondition before dispatching the sweep, and an
  absent session makes Sam's UNUSABLE for the batch (the pricer attends it), never a guess against
  a logged-out storefront.
  **CORRECTED 2026-08-24 (phase-4 aftercare cold read, against pull-browser-stores.py as it stands
  on disk - this paragraph originally ordered "CDP sweeps for Fareway and Hy-Vee single lookups",
  and HALF OF THAT SURFACE DOES NOT EXIST.** The driver's STORES dict holds exactly three keys -
  `walmart`, `samsclub`, `fareway` - and two facts the paragraph contradicted:
  - **Hy-Vee has NO driver lane and never had one.** `pull-regular-hyvee.ps1` is a refresh, not a
    search (it re-verifies known product ids one request each; zero search capability - its own
    header says so and probe-ingredient.ps1's store table repeats it). A Hy-Vee lookup for a NEW
    term is browser work the PRICER does in its own tab, exactly as it does today, and D10 must NOT
    build a Hy-Vee driver lane - that would be a new unproven store agent smuggled in as plumbing.
  - **Walmart is PAUSED in the driver, with the reason measured 2026-08-22** (the automation
    channel gets price-less payloads while Brad's own Chrome gets prices - a soft block on the
    channel, not the profile or IP), and **Aldi was never in STORES at all**. Both are captured
    through Brad's own Chrome via the claude-in-chrome extension (the Chrome debug port is blocked
    on his default profile, so the extension is the only road into his real session). D10 must not
    "retry" Walmart from the driver - the pause note documents the one-shot retry procedure and it
    is Brad's to order.
  So the pre-pass tiers, as buildable: **server** (Baker's + Family Fare via probe-ingredient.ps1),
  **driver CDP** (Fareway + Sam's Club, via the lookup mode D10 adds - see the D10 pins),
  **pricer's own browser tab** (Hy-Vee, plus any store the pre-pass left UNUSABLE), **Brad's Chrome,
  attended** (Walmart, Aldi - only when Brad is present). "The same code the capture estate already
  trusts daily" is true of the Fareway and Sam's lanes and was never true of a Hy-Vee lookup.
- **The pricer agent** receives, per term, the gathered candidate rows + verdict-ladder states from
  all reachable stores, and does the only two things that need it: adjudicate rows ("Saffron Road
  Drunken Noodles is not saffron") and drive the browser surfaces no pre-pass reaches: the attended
  pair per its existing two-surface contract (Walmart and Aldi, Brad's Chrome, only when Brad is
  present), Hy-Vee in its own tab (no driver lane exists - see the correction above), plus any
  store the pre-pass left UNUSABLE.
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
  parse-compute, so an out-of-band recipe is retired at skeleton build before any prose is paid for.
  v2 checked the band on the WRITE result - after the most expensive per-recipe stage had already
  run.
  **CORRECTED 2026-08-24 (phase-3 cold read, checked against hunt-run.ps1's graph): this paragraph
  said the state machine "already supports" `rejected-macros` here. It does not.** The machine
  allows `rejected-macros` only from `extracted` and `mapped`; at skeleton-build time the recipe
  sits at `priced`, whose ONLY legal exit is `spec-built`. So D8's first build item is a
  STATE-GRAPH EDIT: add `rejected-macros` to `priced`'s exits in hunt-run.ps1's `$script:NEXT`,
  with a fixture in hunt-run's own -SelfTest (the same care `rejected-macros`' original addition
  took - a verdict a state machine cannot express is a verdict that gets faked or lost, and this
  one WAS being faked: the trap was found because the daemon's interim band gate hit it live. Its
  first build advanced `priced -> rejected-qa` directly, which the injected fixtures accepted and
  the real machine refuses - the recipe would have sat at `priced` on disk while the daemon counted
  it rejected. Fixed 2026-08-24 to reproduce v2's measured on-disk trace, `spec-built -> written ->
  rejected-qa -By macro-gate`, with a real-state-machine fixture proving the rejection LANDS; once
  D8 extends the graph, the daemon's route shortens to `priced -> rejected-macros` in the same
  commit, and the fixture moves with it.)**

  **BUILT 2026-08-24 (phase 4, D8's first commit).** `priced` now reads
  `@('spec-built', 'rejected-macros')` in hunt-run.ps1's `$script:NEXT`, fixtured as FIXTURE 4b-ii
  in hunt-run's own -SelfTest (three cases: the new edge is legal, the normal exit still stands, and
  `priced -> written` is still refused). The daemon's band-failure route is now the single advance
  `priced -> rejected-macros`, and `_band_gate_fires` pins the advance COUNT as well as the
  destination - three advances again would mean the run record had gone back to claiming a spec
  build and a prose write nobody paid for. Measured must-fire, both suites, by reverting the graph
  edit: hunt-run's new case goes red, and in the daemon suite the INJECTED twin still passes while
  `_band_gate_real_machine` goes red. That is the FakePS blind spot restated one more time, and it
  is why the real-machine twin is the one that counts.
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
  - **HALF OF THIS GATE HAS NEVER RUN, recorded 2026-08-24 so nobody mistakes an unrun half for a
    passing one.** `hunt_lib.py --parity` runs the shared vectors against the PYTHON port and is
    green 63/63. `hunt-lib-parity.js` runs the same vectors against hunt-lib.js - and there is no
    node runtime on this box, so its only runner is a zero-agent Workflow invocation that has not
    been made. What IS mechanically guaranteed: `hunt_lib.py --selftest` re-hashes the shipped
    hunt-lib.js and FIRES if the spliced copy no longer matches, so a JS edit that forgets to
    regenerate cannot pass unnoticed.
  - **Why the exposure is small, and it is a fact about the ARCHITECTURE rather than a comfort.**
    Nothing executes hunt-lib.js in production. The v3 daemon IS the orchestrator; every reference
    to hunt-lib.js in live code is a comment recording where a function was ported from. This gate
    was built to stop the PORT drifting from a running original, and the original stopped running
    when the daemon landed. So the unproven claim is "hunt-lib.js would still pass its own
    vectors", which no production path depends on. Brad reviewed and left the gate standing
    2026-08-24 rather than retiring the JS side, because section 4.2 built it deliberately and a
    tidy-up is not a reason to delete scar tissue.
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
| recipe-ingredient-mapper | fable / high | residual-only: the judgment lines, pre-resolved table supplied | **CHANGED 2026-08-24 -> opus-5 / high**, ordered by Brad against the phase-5 measurement (note below) |
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

**CORRECTED 2026-08-24: the mapper pin moved fable -> opus-5 / high, BY BRAD'S ORDER, against the
phase-5 gate measurement.** The measurement: one live 4-recipe batch cost 19m07s and ~$12.70 on
Fable (deduped: 13,001 uncached in / 323,820 cache write / 3,802,874 cache read / 93,903 out over
30 turns) plus an unstamped $1.64 Opus subagent - the most expensive single dispatch in the
pipeline, and Fable is exactly 2x Opus-5 per token. The residue principle above was weighed and
stated to Brad in as many words before he ordered the change; it argues the other way, and the
frontmatter now says `claude-opus-5` because the person the paragraph reserves the decision for
made it. **The phase-6 checkpoint this creates:** the first Opus-mapped batch gets a ruling-level
diff against a Fable-mapped batch of comparable residue (a scratch copy re-map is enough). If Opus
misrules identities Fable would have caught, the pin goes back and this paragraph gets a second
date. The extractor's pin is untouched - the anti-cheapening argument above is about invented
transcriptions and remains in force.

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
| map HOLD record (ADDED 2026-08-24, D7) | `<RunDir>\mapped-pre\<slug>.hold.json` | the daemon -> the next seed's unhold. The routing a held recipe WOULD have taken (`absent_terms`, `optional_absent`, the mapper's state). It exists because the unhold advances "exactly as it would have on first pass" and first pass's routing came from the MAPPER, which a held recipe never reached and a fresh daemon process cannot remember. Without it the only ways to resume a repaired recipe are to re-dispatch the mapper (paying twice for a judgment already rendered) or to guess the routing (which is how a recipe skips pricing) |
| mapper decision file | `<RunDir>\mapped\<slug>.json` | **AS-BUILT 2026-08-24 (phase 6a, A1). THE PRODUCER IS NOW THE DAEMON**, via `map-preresolve.ps1 -Assemble -RunDir <d> -Slug <s> -RulingsFile <p>`; the mapper agent no longer writes it at all. ONE writer per slug file, so no mutex - said in map-preresolve's own header, as the evidence writer says it. Shape as below -> skeleton builder, auditor |
| mapper rulings payload (ADDED 2026-08-24, phase 6a A1) | `<RunDir>\mapped-pre\<slug>.rulings.json` | the daemon (from the MAPPED dispatch payload plus the registrar's verdicts) -> `map-preresolve -Assemble`. One writer per slug, transient-but-kept: it is the record of what the model actually returned, beside the file that was built from it |
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
- **Pre-resolve rows:** per ingredient `{raw, term, canon_item, bid, board, resolution: "resolved" |
  "unresolved" | "different-form" | "unbid" | "new-food-suspect", gpu_known, density_known,
  fooddb_known, evidence, source: "cache" | "vocab" | "alias", optional}`.
  **AS-BUILT 2026-08-24 (D7): two fields joined the row and the table gained an envelope.** `term`
  is the string the lookups were keyed by (the extraction's `item`, falling back to `raw`) and
  `optional` mirrors the extraction line's flag; both are in every shipped table and a reader of
  this contract must not treat them as surprises. The per-slug FILE is
  `{slug, title, source_url, servings, built_at, line_count, resolved_count, residual_count,
  hold_count, residual_terms, holds, rows, macro_precheck}` - `holds` rows are
  `{term, canon_item, bid, why}`, and `macro_precheck` is
  `{state: "computed"|"partial"|"unavailable"|"skipped", reason, source: {from, cal, carbs,
  protein_g, fat_g}, lines_covered, lines_total, uncovered_lines, computed_per_serving,
  portion_factor, tuning, missing_db_items}` with `computed` legal ONLY at total line coverage
  (a partial figure ships no numbers - the D7 built record says why, measured).
- **Mapper decision file, THE FROZEN FIELD SET (AS-BUILT 2026-08-24, phase 6a A1 / pin P5).** The
  minimal set was not guessed: `build-intake-skeleton.ps1` and `hunt-run.ps1` were grepped for every
  read of this file, and the union is exactly **top-level `slug`, `title`, `source_url`, `protein`;
  per line `item`, `grams`, `buy`, `decision`, `bid`**. Everything else the assembler writes is
  provenance a person reads, and it is written because the v2 files carried it and dropping it would
  make the two eras unreadable side by side: top-level `source_servings` / `target_servings` /
  `scale_factor` / `mapped_by` / `assembled_by` / `mapped_at` / `conventions` /
  `pricing_terms_needed` / `ruled_substitutions` / `rejected` / `db_entries_added` /
  `new_commodity_proposals` / `registrar_rulings` / `macro_cross_check`, and per line `source_raw` /
  `board` / `optional` / `notes` / `grams_from`.
  - **`decision` IS A CLOSED SET OF FOUR STRINGS, and they are `Get-LineClass`'s, not new ones**:
    `mapped` (included), `mapped-null` (included - a real food with no commodity id, priced
    pantry-static), `mapped-optional` (optional, counted in the macros and named in the snapshot),
    `optional-note` (not-purchased - water, a garnish, a sub-recipe). Nothing the assembler emits may
    class `unknown` or `unsettled`, and its fixture reads the REAL `Get-LineClass` out of
    build-intake-skeleton.ps1 at test time to prove it. Free-texting this field produced 21 distinct
    values across 550 v2 lines and cost a real recipe a fabricated 250-cal band ruling.
  - **The mapper's own ruling enum is `mapped | mapped-null | mapped-optional | not-purchased |
    rejected`.** `rejected` never becomes a decision string: it refuses the whole file, exit 1, line
    named, recipe STUCK.
  - **`grams` are TARGET-scaled and the scale is applied EXACTLY ONCE.** Precedence: the mapper's
    stated grams (from `rulings[].grams`, else `lines[].grams`) win, because grams and the buy string
    must agree by construction and the buy string is the mapper's; otherwise the pre-resolve row's
    `grams_source_basis` times `scale_factor`. **CORRECTED against the addendum's first draft, and
    measured on `hunt-2026-08-15-lowcarb-100\mapped\baked-cauliflower-mac-smoked-sausage.json`: 5 of
    its 7 lines are the exact scale and 2 are not, both because the mapper quantized its printed
    measure (14 oz x 3.5 = 1389 g shipped as "3 lb" = 1361 g; 1/3 cup x 3.5 shipped as "1 cup plus
    3 tbsp" = 134 g rather than 132 g). So `lines[]` carries an OPTIONAL `grams`, which pin P2's
    two-array shape did not name.** A purchasable line with grams from neither source is STUCK,
    named - never a silent zero.
  - **Per-line source-basis grams are a NEW pre-resolve row field, `grams_source_basis`** (pin P3 said
    the table has none, and it now does). They come from `parse-compute.ps1`'s new additive
    `ingredients_source_basis` output: a snapshot of the per-line weights taken after the qty parser
    and any reviewed manual override, and BEFORE the 550-gate tuner, the auto-staples and the target
    scaling - all three of which are legitimate for a macro estimate and fiction on a shopping list.
    Positional alignment with the engine's input is checked, not assumed; a length disagreement
    records no grams for that slug, which is the safe direction.
  - **A new commodity id may only be minted with the commodity-registrar's approve or alias**, and
    the check reads `db\ingredients.json` for which bids are actually wired rather than trusting the
    payload to declare its own proposals. Silence is not approval.
- **Skeleton locked vs writer-fillable** (from the intake schema in build-v2-spec): LOCKED - name,
  slug, protein, source_url, visibility, `ingredients[]` (item/grams/buy),
  `macros_per_serving`, head.prepTime/cookTime/totalTime. WRITER-FILLABLE - `prose.*`, `cuisine`,
  head.description/keywords/steps/step_names, `writer_notes`, `forbidden_prose_terms`. The
  post-write check is `build-intake-skeleton.ps1 -Verify -InFile <intake> -Skeleton <snapshot>`:
  exit 1 on any locked-field drift, naming the fields.
  **`cuisine` MOVED from LOCKED to WRITER-FILLABLE, CORRECTED 2026-08-24 (D8 build, measured against
  every file that exists before the writer).** Nothing on disk carries a cuisine at skeleton time: not
  the extraction contract (state, reason, title, source_url, servings, times, ingredients,
  instructions, concerns), not the mapper decision file (slug, title, source_url, servings, scale,
  protein, ingredients), not the run state file, and not the pool candidate's signature (protein /
  method / sauce_family / starch). Locking a field with no mechanical source would mean the skeleton
  either invents one or refuses to build, and the first is worse. It is a judgment about the dish
  rather than a number, so it sits with the writer under the existing "the writer computes no number"
  rule - exactly where v2 had it - and build-v2-spec checks its presence as it always did. The
  locked-field diff would have caught this at run time; recording it here is cheaper.
- **Preaudit report:** per-slug per-check `{check, verdict: "pass"|"fail", numbers, detail}` plus
  one shared-checks block (db-agreement-class audits, P8 probe) that runs ONCE per wave, not per
  slug. Card rebuilds go to per-slug scratch dirs (no collision). **The auditor's
  `wave-<k>.audit.md` remains the artifact wave-publish P1/P1b read; the preaudit report is an
  input to the auditor, never a substitute for its GO.**
- **Price evidence:** per term per store `{store, state: "MATCHES"|"EMPTY"|"UNUSABLE", term_used,
  attempts: [], hits: [{item, price, size, relevance, url}] (cap 8), reason}` - the
  search-verdict-lib shape, serialized. The pricer adjudicates from it and records via
  ingredient-queue exactly as today.
  **FIELD-MAPPING PIN, ADDED 2026-08-24 (phase-4 aftercare cold read), because probe-ingredient's
  -Json output carries TWO state-like fields and picking the wrong one records transport noise as a
  search answer.** Probe's per-store object is `{store, state, note, verdict, term_used, attempts,
  reason, hits}` where `state` is TRANSPORT (`OK` / `ERROR` / `NO-CREDENTIALS`) and `verdict` is
  the search-verdict ladder state. This contract's `state` field is probe's **`verdict`** field;
  probe's transport `state` and `note` fold into `reason` when they are not OK (a transport ERROR
  is UNUSABLE with the exception text as the reason). Probe already caps hits at 8 and already
  carries `relevance` - keep it: it is a SORT HINT for the pricer and never a verdict (probing
  "saffron" ranks a Saffron Road frozen noodle dish above the actual jar - probe's own header).
  **And the two vocabularies never mix:** MATCHES/EMPTY/UNUSABLE are SEARCH states;
  carried/not-carried/blocked/error are the QUEUE's per-store record states; only the PRICER
  converts one into the other, and the daemon never writes a queue record from evidence. EMPTY
  after a full ladder PERMITS not-carried (search-verdict-lib's own table) - permitting is not
  recording.
  **AS-BUILT 2026-08-24 (D10). Four additions and one caveat, none of which move a rule.**
  - **The FILE is `{schema: "price-evidence/1", run, batch, generated, batch_terms, roster,
    findings, terms: [{term, unit, stores: [<the row above>]}]}`.** The row shape is exactly as
    specified; the envelope exists because a reader needs to know which batch it is holding and
    which store roster the enumeration was made against. `findings` is where a degraded gather says
    so in words.
  - **Every row carries a `tier`: `server` | `driver` | `pricer-tab` | `attended`.** It is the
    sixth field and it is load-bearing for the pricer: "nobody has looked and it is yours" and "we
    looked and were blocked" are both UNUSABLE, and the tier is what tells them apart. The tiers
    are S5's own, post-correction.
  - **`relevance` is NULL on a driver-gathered hit, and that is deliberate.** probe-ingredient's
    relevance is a PowerShell heuristic (`Get-ProbeRelevance`); porting its formula into
    pull-browser-stores.py would fork a heuristic across two languages for a field that is a SORT
    HINT and never a verdict. Driver hits arrive in the store's own ranking, which is the honest
    hint. The field is present and null rather than absent, so a reader never has to guess.
  - **A hit MAY carry an optional `unit_price` string** where the store publishes one. Sam's Club
    rows carry no pack size at all and its unit price is precisely what an adjudicator compares a
    club pack against. Evidence, never a verdict.
  - **THE CAVEAT, and it protects Rule B: an EMPTY from a DRIVER store is RUNG 1 ONLY.** The lookup
    mode searches the term as given and does not walk the retry ladder (see the D10 lookup work
    order below) - so a driver EMPTY does not permit not-carried until the pricer completes the
    ladder itself. A SERVER EMPTY is a full-ladder empty and permits it as this table always said.
    The evidence file says which in every reason string, the prompt says it, and the pricer agent
    definition says it.
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
| mapped with open holds (unbid / vocab follow-ups) | map-preresolve RE-RUN at seed (mechanical, zero agents); a CLEARED hold advances on the mapper decision file already on disk, a standing hold goes to the held list, NOT dispatched (CORRECTED 2026-08-24 - the original row said held-only, which strands a repaired recipe forever; the unhold is D7's pinned path and `_unhold_between_seeds` is its real-machine fixture) |
| pricing / parked | run `-Derive` first; price lane only if still pending |
| priced | skeleton build (band gate) -> write lane |
| spec-built / written | qa lane (stages skip work whose output file exists) |
| qa-passed | wave pool |
| waved | counted and REPORTED in --status; never auto-resumed (CORRECTED 2026-08-24, see below) |
| published, not verified | post-publish review pending |
| held | open-items report; never auto-republished |
| STUCK (per the prior run's report) | re-enter the lane that stalled (which the daemon gets by construction: a STUCK recipe's state file was never advanced, so its real on-disk state seeds it back into the lane it stalled in) |

**The `waved` row, CORRECTED 2026-08-24 (phase-3 cold read).** This table is normative, and its
original `waved` row promised "wave lane, resuming at the first un-stamped ledger stage" - a
behavior NOBODY has ever implemented. v2's own drain seed deliberately excluded `waved` recipes
("those belong to wave 1 and the trim returns the audit-clean ones to this pool itself" - the
comment is still in hunt-orchestrator.js), and the daemon does the same: it counts them, reports
them in `--status`, and touches nothing. A normative row that promises unimplemented behavior is a
guess-trap for the next builder, so the row now states reality, and the OPERATOR PATH for a run
killed mid-wave is the one v2 used: `hunt-run.ps1 -WaveSync -Wave <k>` reconciles the manifest,
the trim path returns audit-clean recipes to `qa-passed`, and the next daemon seed carries them
into a fresh wave. Auto-resuming a half-published wave from its ledger stamps is a real feature
with a real design cost (which stamp is trustworthy after a crash mid-publish?); if the phase-6
proving run finds the manual path too expensive, it becomes a measured, ordered item - never a
silent build-time addition.

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

**RE-READ 2026-08-24, measured. All three findings survive; one number moves.** The corrected audit was
run against `meal-prep\runs\hunt-2026-08-15-lowcarb-100` and the before/after was taken by running the
pre-fix script (commit `70843818`) over the same log:

| | pre-fix | corrected |
|---|---|---|
| map lane | 30 invocations, 45 distinct, mean 3.2 | **28** invocations, 45 distinct, mean 3.14 |
| price lane | 28 invocations, 24 distinct, mean 2.21 | **22** invocations, 24 distinct, mean 2.27 |
| `map-lane-duplicate-items` | 29 slugs | **29 slugs, identical list** |
| `price-lane-not-batched` | 28 invocations for 24 distinct | **22 invocations for 24 distinct** (still fires) |
| `price-lane-duplicate-items` | 17 terms | **17 terms, identical list** |

The doubling barely touched this run, because this run mostly predates the field that caused it. It ran
2026-08-15T20:04 to 2026-08-16T12:35, and only its tail is after the 08-16 `event` change: 139 of its 834
lines carry `event`, and in the two judged lanes only 4 map lines (2 pairs) and 12 price lines (6 pairs).
Eight dispatches were being double-counted, not all of them - hence 30->28 and 28->22, not a halving.

**The duplicate-items findings are real, and the history may keep quoting them.** `chicken-chasseur` went
to the map lane at 01:25:17 and again at 06:07:36, both times inside a full 5-recipe micro-batch hours
apart; 10 of the 28 map invocations re-sent only slugs already mapped, and 10 of the 29 repeated slugs went
3 or 4 times. On the price lane 13 of the 17 repeated terms repeat across separate `queue batch N`
dispatches (`dry white wine` 4x, `green bell pepper` 4x, `90/10 ground beef` 3x, `bacon bits` 3x). That is
the cross-recipe dedup being discarded, exactly as the finding says.

**Two smaller artifacts the re-read did surface, both write-side and both still uncorrected.** (1) The
price lane also logs a `derive-after-batch-N` line carrying the same items as the batch it follows.
`Get-Invocations` keys on lane + label + items, so a different label does not collapse - which inflates the
price lane by 3 invocations and makes 4 of the 17 "duplicates" (`chipotle powder`, `ground chicken`, and two
fragments) a dispatch paired with its own derive step. Excluding `derive-after` lines the price lane is 19
invocations over 24 distinct terms, mean 2.32 - `price-lane-not-batched` still fires (floor 3), and the
honest duplicate count is 13, not 17. (2) Two of the 17 "terms" are not terms: a prose aside was passed to
`-Items` unquoted and split on its commas into `green bell pepper (enqueued for attribution; queue deduped
onto the existing item` and `which the pricer has since resolved CARRIED at 6 of 7 stores)`. A caller
quoting defect, not an audit defect, but it means that finding's term list was never 17 real terms.

**And one residual in the audit itself, reported not fixed** (this was a re-read, not a re-fix):
`Get-Invocations` is applied only inside the judged-lane loop. The header total and the `no batch size
declared` per-lane counts still print raw LINE counts - 834 here against 826 collapsed. On a v3 daemon log,
where every line is paired, that header will read double.

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
  **PINNED FOR THE PHASE-4 BUILDER (2026-08-24, from the phase-3 build - facts, not guesses):**
  - **The daemon is BUILT; D7 extends it, never re-derives it.** The integration point is
    `Daemon.map_lane` in `meal-prep\pipeline\hunt-daemon.py`: it takes micro-batches of <=5 off the
    map channel and dispatches the mapper with `Daemon.map_prompt`. D7 inserts the
    `map-preresolve.ps1` call BEFORE that dispatch, invoked through `hunt_lib.ps_invoke` with the
    batch's slugs as a real list (never a second invocation style - the daemon's own selftest greps
    for one), exit convention 0/1/2 where 2 means the batch is BLOCKED and NOT dispatched. The table
    lands per slug at `<RunDir>\mapped-pre\<slug>.json` (section 4.5); the mapper prompt then
    carries the table and shrinks to the residual lines, and the vocabulary lecture leaves the
    prompt in the same commit that ships the table (D11's sync duty applies).
  - **THE UNBID HOLD IS THE DAEMON'S AND IT IS MECHANICAL, and phase 3 measured exactly why.** The
    adapter drill asked the mapper its own standing rule - resolved ingredient, no bid wired,
    advance or hold? - twice, same prompt, same model, and got ADVANCE once and HOLD once. A rule a
    model must remember is a rule it sometimes forgets, and this one gates whether a writer gets
    paid. The pre-resolve rows carry `bid_exists` (ingredient-resolutions is the source and is now
    behind its named mutex); the daemon reads it and holds the recipe at `mapped` itself. The resume
    seed table already handles the other end: `mapped` with open holds goes to the HELD list in
    `--status`, reported and never dispatched.
  - **Every new lane behavior gets an injected fixture in `hunt_daemon_selftest.py`** - the
    FakeDispatch/FakePS pattern there runs the whole suite for zero tokens, and the fixtures that
    genuinely need the state machine drive hunt-run.ps1 against a scratch run dir (the resume
    fixtures are the template). Must-fire + clean twin in the same commit, as always.
  - **map-preresolve.ps1 writes per-slug files, so it needs NO concurrency mutex - and say so in its
    header** rather than leaving the next reader to wonder. If any part of it ever aggregates into
    ONE file written by the cap-2 map lane, that file takes the named-mutex pattern WITH a
    concurrency fixture proven to fail with the lock removed (the fourth PS trap, this section).
  - **The exit codes mean this, and only this (4.5's convention read onto THIS script):** exit 1 is
    the NORMAL case - residual lines exist, the table is written, the mapper dispatch PROCEEDS over
    the residual. Exit 0 (zero residual) still dispatches the mapper, because S4 lists the macro
    cross-check as mapper judgment on every recipe - a fully pre-resolved table shrinks that
    dispatch to the cross-check alone, it never silently skips the judge. Exit 2 blocks the batch:
    could-not-look is never a clean bill, and it is never a reason to guess either.
  - **The cross-check arithmetic is parse-compute.ps1's** - the same surface S6 names for the
    skeleton's `macros_per_serving`. map-preresolve (or the daemon) runs it and the numbers travel
    in the mapper's dispatch prompt as pre-computed inputs to verify; they are NOT a new schema
    field (the two named deltas stay the only two).
  - **THE UNHOLD PATH, pinned because the seed table alone would strand a repaired recipe forever.**
    Section 4.5 seeds `mapped` with open holds to the HELD list, not to any lane - correct while
    the hold stands, and a trap the moment Brad wires the missing bid: on the next resume the
    recipe would land back on the held list with nobody re-checking anything. The pinned default:
    AT SEED TIME the daemon re-runs map-preresolve over the `mapped` recipes (mechanical, zero
    agents, seconds); a hold that has CLEARED advances through the existing mapper decision file at
    `mapped\<slug>.json` - its term set is already ruled, so the daemon performs the
    `mapped -> pricing/priced` advance from the refreshed board answers exactly as it would have on
    first pass, and no agent is re-paid for a judgment already rendered. A hold still standing
    stays on the held list, named. This is a D7 fixture: a scratch run dir with an unbid hold, the
    bid wired between two seeds, the second seed advancing it with ZERO dispatches.

  **BUILT 2026-08-24 (phase 4).** `meal-prep\pipeline\map-preresolve.ps1`, 30 fixtures in its own
  -SelfTest, plus seven daemon-level fixtures under "D7 - the mechanical half of MAP runs before the
  agent is paid" in `hunt_daemon_selftest.py`. It composes ingredient-resolutions (`-Json`, the whole
  ledger in one read), ingredient-vocab (`-Missing -Json`, ONE bulk call that classifies the entire
  batch through the road where the head-noun and FORM_WORDS scoring already lives - nothing is forked),
  price-ingredient (`-Name <array> -Json`, one call for every term), densities, each-nouns and the food
  DB. It writes per slug, so it takes no mutex, and its header says why. The daemon holds the unbid
  hold off the table's `holds` rows and never asks the mapper. The unhold re-runs the script at seed
  time and advances a cleared recipe on the ruling already on disk, with zero dispatches, guarded on
  BOTH the hold record and the mapper decision file - a recipe at `mapped` with neither goes to the
  held list named, because the one thing this path may never do is invent a routing.

  **THREE THINGS THE BUILD MEASURED THAT THIS BULLET DID NOT PREDICT.**
  - **The pre-computed macro cross-check is only available on a FULLY pre-resolved recipe, and a
    partial one must ship no numbers at all.** The bullet above says the arithmetic travels in the
    prompt as pre-computed inputs to verify. It can - but parse-compute needs a CANON name per line, so
    it reaches exactly the lines the pre-resolver settled. Measured on the four never-mapped phase-2
    extractions: it reached 9-12 lines of 17-20, and the line it missed was the PROTEIN every single
    time, because "boneless skinless chicken breasts" is residual precisely for carrying the describing
    words the closed vocabulary has not ruled on. The numbers came back at 9.6-13.6 g protein per
    serving against a catalog floor of 25, and parse-compute's 550-gate tuner then injected an auto
    Rice base into recipes that have none, pushing carbs to 108-116 g on low-carb dinners. Every one of
    those figures is the arithmetic doing exactly what it was told over a line set that is not the
    recipe. Handing it over as "the pre-computed cross-check" would be handing the mapper a plausible
    wrong number to verify. So: `computed` only when coverage is total (which is the exit-0 case),
    otherwise `partial` with the uncovered lines NAMED and the mapper doing the check over what it
    rules. Two fixtures, both directions.
  - **The source's published macros are on disk in TWO shapes and neither is the extraction contract.**
    A v2 extraction carries `nutrition_per_serving` (strings, "10g"); a v3 candidate carries the
    harvester's `band` block (numbers) in `db\candidate-pool.json`, which is `{_doc, updated, count,
    candidates}` and NOT a bare array. Reading the wrapper as the array is how a lookup answers "nobody
    published macros for this dish" about a dish whose macros are sitting right there - measured, 4 for
    4, before the fix. A dish nobody published macros for now says `none published`, which is a
    different claim from a zero.
  - **The residual rate is a real number and it is not small.** Over the four never-mapped phase-2
    extractions (73 lines): **57.5% pre-resolved, 31 lines residual, 0 holds, 5.5 s wall-clock** with
    the board pass and the cross-check both live. The residual is almost entirely describing-word
    lines - "boneless skinless chicken breasts", "small yellow onion", "extra-virgin olive oil",
    "medium head broccoli" - which is the phase-2 fact pinned above arriving exactly as predicted, and
    it means the pre-resolver's ceiling rises with every alias Brad rules rather than with any code
    change here.

  **THE MAP LANE'S SINGLE-FILE-LEDGER ENUMERATION, COMPLETED 2026-08-24 (phase-4 aftercare cold
  read), because S4's audit rule says to enumerate and the enumeration had a hole in it.** The map
  lane at cap 2 writes: `mapped-pre\<slug>.json` and `<slug>.hold.json` (per-slug, distinct slugs
  per worker - no mutex, headers say so), `db\ingredient-resolutions.json` (named mutex since phase
  3, fixture proven to fail neutered), the run's per-slug state files (hunt-run's pen, per-slug),
  and `grocery\ingredient-queue.json` - which had NO LOCK. Two cap-2 map workers `-Add`ing at once,
  or a map `-Add` landing while the singleton pricer's `-Record` was mid-write, was last-writer-wins
  on the worklist: a lost `-Add` is a recipe parked FOREVER (the daemon consumes `absent_terms`
  destructively and never re-queues the term), and a lost `-Record` is a store verdict the pricer
  paid browser minutes for. FIXED 2026-08-24 with ingredient-resolutions' exact pattern: a named
  system mutex keyed by the queue file's path, the WHOLE read-modify-write inside it with a re-read
  under the lock, tmp+move writes so `-Derive`'s readers can never catch a half-written file, and
  the same lock (keyed on carriage.json's path) around `-Promote`'s ledger write. The barrier
  fixture - 4 writers, 400-item seeded store, same-UTC-instant start - measured **"landed 1 of 4"**
  with the lock neutered and loses nothing with it in place. The audit rule's transferable half:
  when a plan says "enumerate every ledger", the enumeration is not done until someone lists the
  files BY NAME and finds the one the last enumeration missed.
- **D8 `build-intake-skeleton.ps1`** - machine-complete intake skeleton; the pre-write band gate;
  writer prompt rewritten to prose-only; the orchestrator's post-write machine-field diff (S6).
  Fixtures: a skeleton field the writer changed is refused by the diff; an out-of-band skeleton
  retires before any writer dispatch; a clean prose-only fill passes untouched.
  **PINNED FOR THE PHASE-4 BUILDER (2026-08-24, from the phase-3 build):**
  - **The integration point is `Daemon.write_lane`**, whose current shape is: dispatch the writer
    (`Daemon.write_prompt`), run `build-v2-spec -RunCost` through `Daemon.cost_engine` (the
    process-wide cost mutex - NOT optional, its fixture proves two concurrent completions
    serialize), then read `stat.cal`/`stat.carbs` off the BUILT spec via `Daemon.spec_band` and rule
    with `hunt_lib.in_band`. D8 inserts the skeleton build BEFORE the writer dispatch - the
    pre-write band gate, so an out-of-band recipe retires before any prose is paid for - and the
    `-Verify -InFile <intake> -Skeleton <RunDir>\intake\<slug>.skeleton.json` diff AFTER the
    writer returns, exit 1 naming the drifted locked fields.
  - **The locked-field re-dispatch mirrors the adapter's one re-ask, and only one.** On a named
    drift the daemon re-dispatches the writer ONCE quoting the drifted fields verbatim (never a
    silent daemon-side revert - the writer must see what it did); a second drift is `rejected-qa`
    with the fields in the detail. Same discipline, same reason: one correction, never a loop,
    never a coercion.
  - **The post-build `spec_band` read STAYS after the pre-write gate lands.** It is a mechanical
    postcondition over the artifact where the pre-write gate is a prediction about it; both call
    the same parity-covered `in_band`, and keeping both costs one file read. Do not "simplify" the
    postcondition away.
  - **Skeleton assembly may run in parallel across the write lane's cap of 3; any cost pass inside
    it may not** - route every cost-engine invocation through `Daemon.cost_engine`, which is the one
    lock. And the phase-3 drain drill stands `build-v2-spec -RunCost` in for exactly this reason
    (it rewrites the live `db\costed.json`); the D8 drill should instead run the real cost pass
    against a scratch costed.json the way wave-publish's own gate drill does with `-LedgerPath`.
  - **The writer COMPLETES the skeleton-written intake IN PLACE - it no longer creates the file.**
    `Daemon.write_prompt` currently says "Produce ONE intake JSON at <RunDir>\intake\<slug>.json";
    D8 changes that line to "the skeleton has already written it; fill ONLY the writer-fillable
    fields (4.5's list) in place", in the same commit as the skeleton, or the writer and the
    skeleton race for the same file with two different ideas of who creates it. The recipe-writer
    agent definition gets the matching edit (prompt-backup sync applies).
  - **The state-graph edit is D8's first commit, not an afterthought (DONE 2026-08-24 - the
    S6 correction above carries the BUILT record):** `priced` gains
    `rejected-macros` in hunt-run.ps1's `$script:NEXT`, fixtured in hunt-run's own -SelfTest, and
    the daemon's band-failure route shortens from v2's three-advance trace to
    `priced -> rejected-macros` in the same commit (see the S6 correction - the daemon's real-
    state-machine band fixture moves with it, and it is the fixture that caught this trap live).

  **BUILT 2026-08-24 (phase 4).** `meal-prep\pipeline\build-intake-skeleton.ps1` (33 fixtures in its
  own -SelfTest) plus eleven daemon-level fixtures under "D8 - the intake skeleton, the pre-write band
  gate, and the locked-field postcondition". The write lane is now: skeleton -> pre-write band gate ->
  writer -> locked-field `-Verify` -> one re-ask on drift -> cost pass under `Daemon.cost_engine` ->
  the post-build `spec_band` postcondition, which STAYS. Both band gates call `hunt_lib.in_band` and
  both retire `priced -> rejected-macros` in one advance. `Daemon.write_prompt` changed in the same
  commit: the writer completes the intake IN PLACE and is told which fields it owns, and the
  recipe-writer agent definition carries the matching edit with prompt-backup synced.

  **FOUR THINGS THE BUILD FOUND, all recorded rather than worked around.**
  - **`cuisine` had no mechanical source** - see the section 4.5 correction above.
  - **The per-serving macro arithmetic existed in THREE places already** (parse-compute's
    `PerServing`, spec-guards' inline recompute, wave-preaudit's `Get-MacroRecompute`) and the
    skeleton needed a fourth. It was extracted to `meal-prep\pipeline\macro-recompute-lib.ps1` -
    wave-preaudit's copy, because it is the one with fixtures over all four macros where the build
    guard only covers two - and wave-preaudit and build-intake-skeleton now dot-source it.
    wave-preaudit's suite is green after the move and is what proves the behaviour did not change.
    The other two copies are older, load-bearing and fixtured where they live; consolidating them has
    a real parity cost and was NOT smuggled into this commit. Recorded, not done.
  - **`build-v2-spec -RunCost` ignored `-CostedFile` on the WRITE half.** It shelled
    `cost-recipes.ps1 -Slugs <slug>` with no `-OutFile`, so the pass always rewrote the LIVE
    `db\costed.json` while the row was then read back from `-CostedFile`: passing a scratch path wrote
    one file, read another, and threw "cost-recipes ran but no costed row appeared". Fixed by passing
    `-OutFile $CostedFile`, so `-CostedFile` means one thing on both halves. That is what lets a drill
    run the REAL cost pass without touching the live ledger, the same discipline wave-publish's
    `-LedgerPath` exists for.
  - **The daemon gained `--specs` and `--costed`** for the same reason it gained `--ledger`: the write
    lane can write `db\recipes` and `db\costed.json`, which the live site's pipeline reads. Note the
    coupling, which is build-v2-spec's rule and not the daemon's: `-RunCost` is refused unless OutDir
    IS `db\recipes`, so a scratch spec store means an UNCOSTED spec and the daemon says so rather than
    producing zeros a reader could mistake for a price.

  **EXIT 1 MEANS SOMETHING DIFFERENT HERE THAN IN D7, and both are section 4.5's convention.** For
  map-preresolve, exit 1 is the NORMAL case (a residual exists and the dispatch proceeds). For
  build-intake-skeleton it is work STOPPED: a skeleton is either complete or it is not, and a macro
  figure computed over part of the dish is not something a band gate may rule on - build-v2-spec would
  throw on the same missing food-DB row downstream anyway. The daemon marks it STUCK, which is neither
  a pass nor a rejection.
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
  **PINNED FOR THE PHASE-5 BUILDER (2026-08-24, from the phase-3 build):** the integration point is
  `Daemon.price_lane` + `Daemon.price_prompt` in hunt-daemon.py. The evidence pre-gather runs IN THE
  DAEMON before the pricer dispatch: `probe-ingredient.ps1` through `hunt_lib.ps_invoke`;
  `pull-browser-stores.py` through a `sys.executable` subprocess (it is Python - ps_invoke is only
  ever for PowerShell surfaces); output to `<RunDir>\price-evidence\batch-<n>.json` in the
  search-verdict-lib shape section 4.5 already specifies. The pricer keeps `-Record`/`-Promote`
  (the standing pen-ownership exception) and the daemon keeps `-Derive` and every state move. Two
  measured facts to build against: the adapter drill already showed the pricer AGENT rules PENDING
  on a five-EMPTY/one-UNUSABLE/one-unreached hypothetical, so D10's must-fire is about the
  MECHANICAL pre-pass emitting UNUSABLE-as-PENDING, not about re-teaching the agent; and the
  singleton cap is architecture (hunt_lib.LANE_CAPS marks it), so the pre-gather also runs one
  batch at a time. One more, so nobody builds a probe that does not exist: S5's "the daemon checks
  that precondition" for Sam's means the daemon READS what pull-browser-stores.py reports about its
  own driver profile - the puller owns the session and is the only honest source on it. The daemon
  never opens a browser to find out, and a report it cannot get is UNUSABLE for the batch, which
  reads PENDING and hands Sam's to the attending pricer.
  **PINNED FOR THE PHASE-5 BUILDER (2026-08-24, from the phase-4 build - facts, not guesses):**
  - **The dispatch adapter now auto-appends a RETURN CONTRACT derived from the schema, and the
    pricer dispatch passes NO schema ON PURPOSE - do not "fix" either half.** Phase 4's gate run
    measured what happens when an agent is never told the shape: six writers each invented a rich
    report with no `status`, burned the one re-ask, and the breaker opened at ~259k input tokens per
    refusal. The fix lives in `hunt_dispatch.contract_text` - derived from the `schema=` argument,
    appended to the FIRST call - so a prompt must NEVER carry a hand-written return contract (seven
    lanes means seven copies means six that drift). The pricer is the standing exception: its
    evidence contract is enforced at the SCRIPT layer (`ingredient-queue -Record`:
    carried-requires-a-price, exact store names, PENDING-never-promotes), it returns free text, and
    `contract_text(None)` is deliberately empty. Adding a schema to the pricer dispatch would make
    the daemon refuse the free-text reports the pricer has always returned - that is a behaviour
    change for Brad to order, never a tidy-up.
  - **The evidence pre-gather's concurrency answer, so nobody re-derives it:** the price lane is a
    singleton by architecture (`hunt_lib.LANE_CAPS` marks it, a fixture asserts it), so
    `<RunDir>\price-evidence\batch-<n>.json` has ONE writer per distinct n and needs NO mutex -
    SAY SO in the writer's header, exactly as map-preresolve's does. `ingredient-queue.json` and
    `carriage.json` are already behind the named mutex (see D7's enumeration above), so the pricer's
    own `-Record`/`-Promote` and the map lane's `-Add` can no longer race. If D10 ever aggregates
    evidence into ONE run-level file, that file takes the mutex pattern WITH a barrier fixture
    proven to fail neutered - the fourth PS trap does not care what phase it is.
  - **`pull-browser-stores.py` runs via `sys.executable` subprocess wrapped in
    `loop.run_in_executor` (the same shape as `Daemon._ps`), NEVER via ps_invoke** - ps_invoke is
    for PowerShell surfaces only. A CDP sweep that dies, times out, or cannot report its driver
    profile is UNUSABLE for the batch, which reads PENDING; the daemon writes that state into the
    evidence file rather than retrying a wall (a wall stops the lane - S5's own rule).
  - **Useful phase-4 machinery, so it is reused rather than re-invented:** `hunt_lib.first_guard_line`
    turns a refusing guard's stderr into the one sentence a STUCK detail should carry; the daemon's
    `--specs`/`--costed` scratch flags exist but D10 needs NEITHER (the price lane touches no spec
    store and no cost ledger) and `--ledger` only if a drill reaches the wave lane; `--status` now
    names every stuck recipe with its reason, so a D10 drill's evidence is readable off the header.
  - **Keep drill scratch roots SHORT.** The phase-4 gate's wave close failed on a 130-character
    scratch path (`waves\wave-1.json.tmp` would not write) - a path-length artifact, not a wave
    defect, and a `C:\tmp\...`-depth root avoids it entirely.
  - **Fixture duties, unchanged from D7/D8's discipline:** every new lane behaviour gets an injected
    FakeDispatch/FakePS twin in `hunt_daemon_selftest.py` AND at least one fixture against the real
    surface (the real state machine, or the real evidence file on disk), because phase 3 and phase 4
    each caught a route the injected fixtures accepted and the real machine refused - three
    instances now. Must-fire is proven by NEUTERING the code, not by asserting the fixture exists.
    The named must-fire D10 owes: the MECHANICAL pre-pass emits UNUSABLE-as-PENDING (the agent half
    is already proven, per the phase-3 pin above).
  - **The first real absent-term batch is already sitting in the queue.** Three genuinely pending
    terms survive in `grocery\ingredient-queue.json` - `guacamole`, `pico de gallo`,
    `korean-rice-cakes` (0 of 7 stores checked, queued 2026-08-16) - and mapping the four phase-2
    mini-run recipes through the REAL D7 map lane will yield more, which doubles as D7's first live
    mapper dispatch. The gate's "one real absent-term batch priced with pre-gathered evidence" can
    be met from those without inventing a synthetic term list.
  - **THE LOOKUP MODE IS NEW WORK, AND THIS IS ITS WORK ORDER - because the cold read found that the
    capability S5 originally named DOES NOT EXIST.** pull-browser-stores.py today reads ONLY
    `out\worklists\capture-<store>-<date>.json` and writes ONLY the capture estate's own output
    files; it has no way to sweep an ad-hoc term list, and pointing it at hunter terms by writing
    that worklist file would destroy the day's real capture worklist AND its output would land in
    the daily capture files the board builders parse. D10 adds to pull-browser-stores.py exactly:
    `--lookup-terms-file <path>` (a JSON array of term strings) and `--lookup-out <path>`, legal
    only together and only with an explicit `--store fareway` or `--store samsclub` (`walmart` is
    refused with the pause note quoted; unknown keys already exit 2). Lookup mode reuses the
    store's EXISTING agent, pacing profile, identity assertion and wall handling untouched - the
    fareway lane is already per-term navigation against `search_url` with Apollo-cache extraction,
    which is precisely a lookup - and writes per-term search-verdict objects
    (`{term, state, term_used, attempts, hits, reason}`) to `--lookup-out`. In lookup mode it must
    read NO worklist file and write NO capture file: the daily capture surfaces are load-bearing
    and this is the drill-writes-live class with a different costume. A NEEDS-SEEDING refusal, a
    wall, a dead CDP, or a driver crash all read back as UNUSABLE for that store for the whole
    batch. The driver's own `--selftest` (throwaway profile, captures nothing) gains a lookup-mode
    case. Its exit codes stay ITS OWN (0/1/2 per its header) - existing scripts are never "fixed"
    onto the new battery convention, in either direction.
  - **THE SAM'S PRECONDITION, CONCRETE: there is no separate session probe, and D10 must not build
    one.** The check IS the run - an unseeded or logged-out profile fails `samsIdentity()` /
    the seeded-profile check, ends the store NEEDS-SEEDING, and captures nothing. The daemon reads
    that from the lookup output and exit code, records UNUSABLE, and never opens a browser to find
    out (the phase-3 pin's "the puller is the only honest source on its own session", now with the
    mechanism named).
  - **THE DAEMON'S PER-BATCH FLOW, PINNED TO THE LINE.** Inside `price_lane`'s greedy loop, after
    `terms = self.absent_terms[:hunt_lib.PRICE_BATCH]` is sliced and `n += 1`: (1) ONE
    probe-ingredient call for the whole batch - `ps_invoke(PROBE_INGREDIENT_PS, ["-Term",
    list(terms), "-Json"])`, the parameter NAMED never positional (the -File-binding family is why
    ps_invoke exists), timeout >= 900 s (25 s/request x ladder rungs x 2 stores x up to 10 terms);
    (2) per drivable store, the lookup via `sys.executable` + `run_in_executor` with timeout >= the
    driver's own `--timeout-min` (default 40 MINUTES - pacing dominates, and that is the price of
    not tripping a wall); (3) assemble `<RunDir>\price-evidence\batch-<n>.json` - `n` IS the
    lane's existing invocation counter, and the file is singleton-written so its header says NO
    MUTEX NEEDED; (4) dispatch with the evidence INLINE in the prompt - the 8-hit cap bounds the
    size, and phase 1 measured inline dossiers beating tool-call reads, which is the precedent.
  - **DEGRADE, NEVER BLOCK - explicitly the OPPOSITE of D7's exit-2 semantics, pinned so nobody
    copies the wrong convention across.** map-preresolve's exit 2 blocks its batch because a mapper
    ruling on unreadable inputs would be a guess. The price pre-gather is EVIDENCE for a judge who
    can also go look: a failed probe call, a walled sweep, or a missing lookup output makes those
    STORES UNUSABLE in the evidence file and the pricer is STILL dispatched - it adjudicates what
    was gathered and attends what was not. Could-not-look still never reads as EMPTY, and the
    daemon never skips the judge. The one thing that DOES hold the lane is the singleton cap,
    which is architecture.
  - **FIXTURES OWED, with the network never touched by one:** injected FakePS replies frozen as a
    literal of probe-ingredient's real -Json shape (comment naming the source script and date); a
    driver-lookup stand-in per store state (MATCHES / EMPTY / UNUSABLE / NEEDS-SEEDING); the
    must-fire that an UNUSABLE store reaches the evidence file as UNUSABLE and the dispatch STILL
    happens; the must-fire that a probe transport ERROR lands as UNUSABLE-with-reason and never as
    EMPTY; and the clean twin where every store answers. The REAL surface is exercised by the gate
    run itself, not by a fixture that hits stores.
  **AS-BUILT 2026-08-24 (D10 built). What exists on disk, and the six decisions a later reader
  would otherwise have to reverse-engineer:**
  - **`meal-prep\pipeline\price_evidence.py` is a NEW module** - the join and the render, with its
    own hermetic `--selftest` and the marker `PRICE-EVIDENCE-COMPLETE`. The daemon imports it; it
    is never shelled. Its header carries the no-mutex argument in full.
  - **The seven store names are READ out of `ingredient-queue.ps1`'s own `$STORES`, never copied.**
    An unreadable roster makes the file enumerate only the stores it actually gathered AND record a
    finding saying so - blind rather than clean, the same discipline as the daemon's stop-list read.
  - **The lookup output file is `{store, store_key, generated, ladder, note, results: [<verdict>]}`**
    - the verdict objects are exactly as the work order specifies; the envelope names the store and
    the ladder that was NOT walked, which is the sentence that keeps a rung-1 EMPTY honest.
  - **The paced lookup lane writes under `TC_LOOKUP_SWEEP`, never a store's capture key**, because
    `sweepToCsv()` exports every MATCHES term found under a capture key - a hunter term left there
    would be published as a captured price by the next morning's run. A fixture asserts the key
    collides with nothing in STORES.
  - **Fareway lookups are MATCHES or UNUSABLE and almost never EMPTY, and that is correct.**
    `farewayShopExtract` THROWS when the Apollo cache holds no priced nodes, which is the same
    signal as "has not hydrated yet" - the extractor refuses to tell blindness from emptiness, so
    the lookup lane does not either, and the honest state for an unreadable page is UNUSABLE.
  - **`--selftest-lookup` runs the hermetic half alone** (no browser, no network at all); the
    driver's own `--selftest` runs it first and folds its failures into its count. The driver's exit
    codes are untouched: 0/1/2 per its own header, and a refused lookup is a 2.
  **MEASURED WHILE BUILDING (2026-08-24): a nonzero probe exit was reporting the wrong sentence.**
  `parse_probe_stdout` answers "probe printed nothing" for an empty stdout, which is true and
  useless; the guard line on stderr is the one that says why. A fixture that asked for the 401 by
  name is what caught it, and the rule it froze is: when a surface EXITS nonzero, its own sentence
  outranks the parser's complaint about the silence that followed.
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
  **ADDED 2026-08-24 (phase 3): an agent-definition edit reaches the daemon with ZERO daemon
  changes.** The adapter dispatches `claude -p --agent <name>` and the CLI re-reads
  `.claude\agents\<name>.md` on every call, so D11's slimming is pure agent-file work plus the
  sync duty above - no code to touch, and a model/effort/tools change lands on the next dispatch.
  The daemon's own per-call prompts (`map_prompt`, `write_prompt`, `qa_prompt`, `audit_prompt`,
  `price_prompt`, `rung3_prompt` in hunt-daemon.py) are in D11's slimming scope too: they already
  carry only per-call facts, and any standing constant found in one belongs in the agent
  definition, where the prefix cache pays for it once.

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
| 3 **DONE 2026-08-24** | D9 (the daemon + §4.1a adapter) | hunt-lib parity suite green; adapter drill: per-agent behavior diff vs Workflow twins + measured per-dispatch overhead; drain drill per §4.2; audit-lane-shape clean on the daemon's log |
| 4 **DONE 2026-08-24** | D7 + D8 (map/write slimming) | mapper residual rate measured; one wave written from skeletons with guards green |
| 5 | D10 (price pre-pass) - **PASSED 2026-08-24**, mechanical half clean (5 terms x 7 stores, 62 s, states honest per store; 4 CARRIED, 1 PENDING on a blocked store, 4 recipes to `priced`). The AGENT half exposed finding 2 in the phase-6 pickup: a dispatched pricer has no browser and wrote store visits it had not made before correcting itself | one real absent-term batch priced with pre-gathered evidence; ladder states honest per store. HONESTY, NOT COVERAGE (pinned 2026-08-24): the attended stores (Walmart, Aldi - Brad's Chrome) and the pricer-tab stores may remain UNCHECKED if Brad is not present or does not order them, terms may therefore end PENDING, and that is a PASSING gate provided every recorded state is honest - Rule B's whole point is that an unfinished check is a fine thing to say out loud |
| 6a | **the efficiency fix batch** (A1-A4, B1-B5, C1) - **PASSED 2026-08-24**. One combined drill per pin P11: a live Opus mapper batch on a fresh scratch copy of the phase-1 mini run, its registrar consult, and one real price batch against the live queue. (i) the 4.4a pin checkpoint is CLEAN - 37 of 37 identity rulings agree with the committed Fable batch, zero divergences; (ii) gate finding 1 is dead - `build-intake-skeleton.ps1` exits **0** with zero findings over the assembled file, 505 cal / 41.6 g protein per serving against the source page's published 514; (iii) per recipe the mapper's input tokens fell **8.4x** (1,034,924 -> 122,903) and its turns **7.5x** (8 -> 1), and the price lane went from 13 turns and 161 s per term to **1 turn and 64 s**, with NO re-ask, exactly one `-RecordBatch` write (all seven store records share one timestamp) and Walmart recorded `blocked - no browser in this session`. The drill also found eight defects no fixture could have - the worst a silent 3.5x grams-basis error - all fixed and fixtured same-day; see the phase-6a gate record below | one combined drill: the pin diff, D8 over every assembled file, the cost measurement off C1's own stamps, and one live price batch |
| 6b | **the proving run**: ~20 recipes, wave size 10, Brad-directed conditions | success criteria written before the run, incl.: per-recipe tokens (billed measure) and steady-state wall-clock per published recipe both measured against §7's targets; >=5x fewer Claude invocations per published recipe than the 27 measured; zero gate weakened; every new defect class frozen as a fixture same-day |
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
  (D7 was built 2026-08-24 and found a FIFTH trap in the process - the return-boundary unroll, below.
  There are now five, and the count moving twice in two phases is itself the argument for reading them.)
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

  **A FIFTH TRAP, found by D7's build on 2026-08-24 and the mirror image of the third one: the RETURN
  BOUNDARY UNROLLS.** The estate's answer to trap three is "assign first, then wrap" - and a helper
  that does exactly that, `function As-Array { $a = $Value; return @($a) }`, hands the CALLER a bare
  element whenever the array holds one thing, because a PowerShell function unrolls an array on the way
  out. `.Count` on a bare PSCustomObject is `$null` in PS 5.1 - not 1, not an error - so `if
  ($c.Count)` reads FALSE and the branch silently does not run. In map-preresolve that dropped the
  vocabulary's near-miss candidates out of the evidence for every single-candidate line: the row still
  read `different-form`, but the WHY - "White Wine Vinegar, DIFFERENT FORM: vinegar" - was gone, which
  is the one thing the mapper is handed the table for. `return ,@($a)` fixes it.
  **And the comma has a price the caller pays, which is the part worth writing down**: an array
  returned that way enters a PIPELINE as ONE object. `As-Array $x | Where-Object {...}` filters a
  collection of one - measured, it made an `uncovered_lines` list come back empty on a table with eight
  uncovered lines. **`@()` around the CALL does NOT fix it** (`@(cmd)` collects the command's output
  objects, so an array arriving as one output object becomes an array holding one array); only
  PARENTHESISING the call - `(As-Array $x) | Where-Object` - or assigning first hands the pipeline the
  array itself. All three forms are frozen as fixtures in `map-preresolve.ps1 -SelfTest`, and the two
  wrong ones are must-fire.

  **And the `-File` array trap turned up one level down, inside a PowerShell caller (2026-08-24,
  D7).** hunt_lib.ps_invoke exists because `powershell -File` cannot bind a multi-element `[string[]]`
  from argv. map-preresolve's first build shelled its own child processes with `-File` and
  `-Slugs clean nosuchslug` bound ONE slug: the missing extraction it was supposed to be BLOCKED on was
  never looked for, so the drill asserting exit 2 got a cheerful exit 0 and a table on disk for half
  the batch. Same family, same fix - one marshalling road per language, and in PowerShell that means
  building a `-Command` string with real array literals, exactly as ps_invoke does on the Python side.

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

*Six-dimension check (2026-08-24, recorded so nobody re-audits from guesses).* **Concurrency** -
one asyncio process; lane caps live in hunt_lib (extract's cap of 3 counts CLAUDE escalations only,
fixtured; the local ladder holds one page at a time, phase 2's measured shape); the channel
semantics are B9's, proven on both implementations by the parity gate; every single-writer file
kept exactly one writer (the pool through harvest.py's verbs, considered-dishes through
decide_apply, ingredient-resolutions behind its new named mutex, costed.json behind the cost-engine
lock - two 0.2 s passes measured serializing, never interleaving); at the caps, at most 12
dispatches run at once, inside the executor's default bounds. **CPU cores** - the daemon is
IO-bound and adds no fan-out of its own; the 8-core budget stays with harvest/battery work
unchanged; the QA battery is one subprocess per recipe inside qa's cap of 2. **GPU slots** - the
extract lane reads the live per-slot context from `/props` at lane start (never assumes `-c`), fans
rung-1 lines across jobs <= Slots, refuses rung 2 on a too-small slot, and accumulates + NAMES the
pending narrow pass; the daemon never touches serve.ps1, fixtured by execution rather than by
grep; the rung-1 re-roll spends ~10 GPU-seconds only on coverage >= 0.85 near-misses. **Speed** -
7.3 s mean per headless dispatch at 2.6x less context than the Workflow road; no barrier anywhere
(takeBatch streams); and the check itself caught the one port deviation: the first daemon build
closed waves only AFTER every lane drained, where v2's waveChain closed them mid-run as the pool
filled - on a 100-recipe run that would serialize ten audits behind the last QA verdict. CORRECTED
same day: `Daemon.schedule_wave` is the ported chain (waves serial among themselves, concurrent
with the lanes; the qa lane schedules one the moment the pool fills), with a must-fire fixture
proving a wave closes while the qa channel is still open. **Efficiency** - dossiers pop pre-ranked
for zero agents; a term dispatched to the pricer once is never dispatched again and the map lane
wakes the pricer once per micro-batch (both drill-earned fixes; audit-lane-shape clean); locally
settled pages still cost 0 tokens and are lane-logged as work done. **Accuracy** - B5 nulls stay
STUCK with the state machine untouched; enum violations refuse whole with one quoted re-ask, never
coercion; the band is read off the built artifact; rung-3 verification is computed from the
stripped cached page and recorded; exit 2 is BLOCKED everywhere - a down server or uncached page
never becomes a Claude dispatch or a pass.

**How a run is launched now (operator notes, so phase 6 does not guess):** llama-server by hand
first (section 4.4 unchanged - serve.ps1, off the card before 07:00/08:00), then

    C:\Codex\Python312\python.exe meal-prep\pipeline\hunt-daemon.py --run-dir <dir> --run <id>
        [--target N] [--lanes pool,decide,extract,map,price,write,qa] [--publish] [--ledger <scratch>]

Without `--publish` the wave lane runs `wave-publish -DryRun` - the safe default. `--ledger` names a
scratch batch ledger for drills (empty = the live one; the first drain drill wrote two stalled rows
into the live ledger before this existed). `--status` is the resume surface and the ONLY place the
pending narrow pass is named; re-entry is `-Status`-seeded per section 4.5's table, so a killed
daemon resumes by being started again with the same arguments. Nothing schedules the daemon;
install-nightly-task.ps1 remains the only scheduler in the estate.

**Phase 4 gate: PASSED 2026-08-24** (commits f9b53257, 408d5e91, a7cc3c0e and the gate commit).
Evidence, so the next session does not re-earn it.

*Gate half 1 - the mapper residual rate, measured on never-mapped recipes.* The corpus is the four
rung-1 extractions in `runs\hunt-2026-08-23-v3-phase1-mini` - pool candidates the phase-2 ladder
settled and NOBODY has ever mapped, so the prior-rulings ledger contributes nothing and what is being
measured is the pre-resolver rather than the cache. Over **73 ingredient lines: 42 pre-resolved
(57.5%), 31 residual, 0 holds, 5.5 s wall-clock** with the board pass and the parse-compute
cross-check both live. The residual is almost entirely describing-word lines - "boneless skinless
chicken breasts", "small yellow onion", "extra-virgin olive oil", "medium head broccoli" - which is
the pinned phase-2 fact arriving exactly as predicted, and it means the ceiling rises with every
alias Brad rules rather than with any further code here. A fresh `harvest.py --dossier --count 5` pop
(5 candidates, 63 verbatim lines, taken off a COPY of the pool so the live one is untouched) confirms
the backlog is live; those five cannot be measured this session because rung 1 needs llama-server,
which phase 4 neither needs nor schedules.

*Gate half 2 - one wave written from skeletons, guards green.* The write lane ran end to end over the
ten recipes at `priced` in `runs\hunt-2026-08-15-lowcarb-100`, on a COPY, with `--specs` and
`--costed` pointed at scratch and publish left in DryRun. **Ten skeletons built; three stopped AT the
skeleton with named findings and no writer paid** (`basque-chicken-peppers-chilindron`: no food-DB row
for Kosher Salt; `pork-chile-verde-stew`: none for Chipotle Powder; `turkey-parmesan-meatball-bake`:
1588 g of Ground Chicken sitting at `unresolved-hold`); **one retired PRE-WRITE**
(`low-carb-beef-meatloaf`, "macro gate (pre-write): 309 cal below the 400 floor", `priced ->
rejected-macros` in one advance, **zero writer dispatches**); **six were written by real writers**,
every one filling only `prose.*` and `cuisine` and passing the locked-field diff. build-v2-spec then
REFUSED all six on UNKNOWN INGREDIENT NAME, and all six landed STUCK at `priced` with the guard's own
sentence in `--status`. Six agent calls, twelve lane-log lines (six pairs), the live estate untouched.

*And the green path, end to end, because the corpus cannot show one.* `skillet-beef-and-rice-drill` -
nine canon names that all resolve in both the vocabulary and the food DB - ran skeleton (468 cal /
31.1 g carbs, zero findings) -> pre-write band gate -> ONE writer dispatch -> locked-field verify
clean with no re-ask -> the REAL build-v2-spec into a scratch spec store -> post-build `spec_band` in
band -> `spec-built` -> `written`. The built spec carries `stat` cal 468 / protein 41 / carbs 31: the
skeleton's own numbers, unchanged, through a writer that never touched them.

*The D8 cost drill.* The REAL cost pass through `Daemon.cost_engine` against a scratch costed.json:
rc 0, 570 recipes costed, 0 flags, one pass recorded under the process-wide lock, the scratch file
rewritten, and the LIVE `db\costed.json` hash unchanged (282f4a35e124 before and after).
`d8_cost_drill.py` is the script.

*Suites, all green:* build-intake-skeleton 67, map-preresolve 43, hunt-run 72, hunt-daemon 72,
hunt_dispatch 47, wave-preaudit 48, ingredient-resolutions, hunt_lib self-test and the 58/58 parity
vectors.

**SEVEN LIVE DEFECTS THE GATE RUN FOUND, every one fixed and fixtured in the same session.** They are
listed because five of them were invisible to injected fixtures and three were in phase-4's own new
code, which is the argument for running the gate against the real machine rather than declaring it
from a green suite.

1. **THE DISPATCH ADAPTER NEVER TOLD AN AGENT THE SHAPE IT WANTED.** It validated against the stage
   schema and re-asked once quoting the violations, while the FIRST call carried nothing about the
   contract at all. Every daemon prompt was therefore carrying its own return contract or, as here,
   not carrying one: six writers each returned a rich report of their own design with no `status`
   field, burned the one re-ask, came back NO VERDICT at ~259k input tokens per refusal, and the
   breaker opened after five - the breaker doing its job on a defect that was ours. `hunt_dispatch`
   now DERIVES a required-field contract from the schema it was handed and appends it to the first
   call. A prompt is the wrong home for it: seven lanes means seven copies means six that drift.
2. **`priced -> rejected-qa` was being faked by TWO routes.** An explicit writer rejection and a
   twice-drifted locked field both advance from `priced`, and the graph allowed neither, so the recipe
   sat at `priced` while the orchestrator counted it rejected. Third instance of exactly the blind
   spot phase 3 found in the band route, and again only the real-state-machine fixture saw it. The
   edge is added, with fixtures both sides.
3. **The write lane ignored build-v2-spec's exit code.** All six refusals advanced to `written`
   anyway; the band read then found no spec, and `hunt_lib.in_band` answers "not reported -> ok" BY
   DESIGN (v2 parity - a band nobody reported is not a rejection), so a REFUSED BUILD READ AS A PASS.
   The predicate is right and the lane was wrong: a refused build is a could-not-look. Both the exit
   code and an unreadable spec are now STUCK.
4. **build-intake-skeleton kept a line only when `decision` was the exact string "mapped".**
   `decision` is free text - 21 distinct values across 550 lines on disk - so on
   `turkey-parmesan-meatball-bake` it silently dropped 1588 g of Ground Chicken plus three
   `mapped-optional` lines, computed 250 cal per serving over what was left, and the pre-write band
   gate retired a real recipe at "250 cal below the 400 floor". A gate ruling on a fabricated number
   fails CLOSED and looks like rigour. The classes are now derived from what v2's own shipped intakes
   did with each word, an unsettled line is a finding, and an unrecognised word is included and named.
5. **Duplicate ingredient lines.** The mapper splits a food used twice ("3/4 cup plus 2 tbsp shredded
   cheddar" and "1/4 cup plus 3 tbsp (topping)") and v2's WRITER merged them by hand. The writer no
   longer touches ingredients, and ZERO of the 570 live specs carry a duplicate item, so the merge is
   mechanical now: grams sum, both buy strings survive, each merge is named.
6. **A writer that returned `status: "blocked"` and wrote nothing read as a success.** `blocked` is
   not `rejected`, and the locked-field diff saw no drift because nothing locked had moved. `-Verify`
   now also asserts that SOME prose arrived - a postcondition over the artifact, where `status` is a
   claim about it.
7. **The daemon's own real-machine band fixture was writing the LIVE estate.** It ran the real
   build-v2-spec `-RunCost`, so every green run of the suite put a `band-drill` spec into
   `db\recipes` and rewrote `db\costed.json`. Same class as the phase-3 drain drill writing two
   stalled rows into the live batch ledger, and found the same way: by reading `git status` after a
   green suite. It now uses the scratch spec store and cost ledger the daemon gained for exactly this.

**Two smaller things recorded rather than fixed.** (a) `hunt-run -WaveClose` could not write
`waves\wave-1.json.tmp` under the gate's very long scratch path; the daemon correctly reported it as
a BLOCKED wave rather than an empty one. It is a path-length artifact of the drill's location, not a
wave-lane defect, and a shorter scratch root avoids it. (b) The `--status` header used to count "9
stuck" and name none of them; it now lists every stuck recipe with its reason, because a count is not
a report.

**Phase-4 aftercare, the six-dimension check (2026-08-24, Fable cold read of the Opus build).**
Each dimension verified against the code as shipped, not against the commit messages; the two live
defects it surfaced are fixed and fixtured in the aftercare commit, same-day.

- **CONCURRENCY - one defect found, one vacuous drill found, both fixed.** (1)
  `grocery\ingredient-queue.json` was an UNLOCKED read-modify-write with concurrent writers under
  the v3 daemon (map cap 2 `-Add` x2, plus the pricer's `-Record` in parallel) - the barrier fixture
  measured "landed 1 of 4" with no lock. Named mutex + re-read-inside-the-lock + tmp/move writes
  now, on both the queue and carriage.json; the full enumeration is recorded in D7's pinned block.
  (2) The drain drill's fresh-lane section had been writing `drill term one..four` into the LIVE
  queue on every run (no ps injection - the same class as the w5/w6 ledger rows, found the same
  way), and after D7 it went VACUOUS instead: no extractions on disk meant map-preresolve exited 2,
  zero lane lines were written, and audit-lane-shape passed on an empty log - the
  could-not-look-wearing-a-rosette failure its own docstring warns about. It now writes real
  extractions (so the REAL pre-resolver runs inside the drill), redirects queue writes to a scratch
  `-QueueFile`, and treats fewer than 4 lane lines as a FAILURE; the live queue was byte-identical
  across the re-run, and the four debris rows were removed from the live worklist under the queue's
  own mutex. Verified sound elsewhere: per-slug files carry no locks by design and their headers say
  so; the cost-engine mutex fixture proves serialization; macro-precheck uses a GUID scratch dir per
  invocation; ingredient-resolutions' fixture still fails neutered.
- **MULTI-CORE (CPU).** The estate's measured rule stands (PS 5.1 parallelises only across
  PROCESSES, never runspaces): map cap 2 and write cap 3 are separate powershell.exe children, so
  the cores are used exactly where the caps allow. map-preresolve makes ONE bulk child call per
  surface per batch (one vocab `-Missing`, one board query, one parse-compute) instead of per-term,
  which is where its 5.5 s/4-slug figure comes from. The write lane parallelises skeleton assembly
  and serializes only the cost pass, per the D8 pin. Nothing further is ordered; the price lane is a
  singleton by architecture and D10 must not parallelise around it.
- **MULTI-PORT / GPU.** Phases 4 AND 5 touch no GPU: map, write and price are CPU + network.
  llama-server (section 4.4, hand-started, slot-context rules unchanged) matters again only when
  extraction runs - the phase-6 proving run - and `--status` still names the pending narrow pass.
  Nothing about the daemon got scheduled, per the standing rule.
- **SPEED.** Measured this phase: pre-resolve 5.5 s per 4-slug batch (board + cross-check live);
  skeleton build ~2 s/slug; the locked-field `-Verify` sub-second; the D8 cost drill's full 570-spec
  pass minutes-scale under the one lock, unchanged from v2's cost engine. The write lane's
  wall-clock is writer-dominated (~90 s/recipe on the gate run), which is the §7 model's assumption
  arriving as measured.
- **EFFICIENCY.** The mapper dispatch now carries the residual (31 lines instead of 73 on the
  measured batch, 57.5% pre-resolved) and the writer dispatch carries a fill-in-place contract
  instead of a build-everything one; the out-of-band and incomplete-skeleton recipes now cost ZERO
  writer tokens (four of ten on the gate corpus never reached a writer). The adapter's derived
  return contract adds ~1 KB per dispatch and removed the 259k-tokens-per-refusal failure mode,
  which is the trade stated in numbers. Further prompt slimming (constants into agent definitions,
  prefix-cache alignment) stays D11's, not smuggled here.
- **ACCURACY.** Both band gates rule through the one parity-covered `hunt_lib.in_band`; the
  locked-field diff plus the no-prose postcondition close the writer's two remaining silent-failure
  routes; a refused spec build and an unreadable spec are STUCK, never a pass; the skeleton refuses
  to build over an unsettled line and names every excluded/merged/unknown decision word; and the
  queue's Rule B surfaces (UNUSABLE/blocked/error read PENDING) are untouched, with their fixtures
  still green. The macro cross-check ships numbers only at total line coverage - a partial figure is
  handed to nobody.

**Phase-4 pickup (2026-08-24, so the next session starts building instead of hunting):** read, in
order, section 4.5 (the mapped-pre and skeleton contracts, the locked-vs-writer-fillable field
split, and the thresholds), the D7 and D8 bullets WITH their pinned blocks, `hunt-daemon.py`'s
`map_lane`/`write_lane` (the hook points - the daemon is built; extend it, never re-derive it),
`hunt_daemon_selftest.py`'s FakeDispatch/FakePS pattern (every new lane behavior gets an injected
zero-token fixture there), and the FOUR PS collection traps in this section before any new PS
collection code. build-v2-spec.ps1's intake schema is the authority on locked vs writer-fillable.
The phase-4 gate's "mapper residual rate measured" means: over one real batch, count the lines
map-preresolve settled from cache/vocab/alias against the lines that reached the mapper dispatch -
the mapped-pre tables and the mapper's decision files carry both numbers. llama-server is NOT
needed for phase 4 (map and write touch no GPU); the card question only arises if extraction runs
in the same sitting. **The gate corpus is already on disk, verified 2026-08-24:** the 10 recipes at
`priced` in `runs\hunt-2026-08-15-lowcarb-100` all carry both their `extracted\<slug>.json` and
`mapped\<slug>.json` files, so "one wave written from skeletons" needs zero extraction and zero
mapping work
**CORRECTED 2026-08-24 BY THE PHASE-4 GATE RUN ITSELF: those files are enough for the SKELETON and
not enough for the SPEC.** Nine of the ten carry canon names `db\ingredients.json` does not have -
14 distinct across the corpus: Marsala Wine, Bacon Bits (twice), Fennel Bulb, String Cheese, Fresh
Thyme (twice), Kosher Salt, Chipotle Powder, Blanched Almond Flour, 90/10 Ground Beef, Quick Oats,
Unsweetened Ketchup, Chicken Thighs (bone-in, skin-on, raw) - because they were mapped on 2026-08-16,
before the closed vocabulary was enforced end to end. build-v2-spec REFUSES every one of them on
UNKNOWN INGREDIENT NAME, which is the guard doing its job. The tenth,
`turkey-parmesan-meatball-bake`, is the only one whose names all resolve and it carries an
`unresolved-hold` on 1588 g of Ground Chicken, so the mapper never settled its protein. The corpus
can therefore demonstrate the write lane and the pre-write band gate on real data, and it CANNOT
demonstrate a green spec build without being re-mapped through D7's map lane. That is a fact about
the corpus, not about D8, and it is the strongest single argument for D7 that the phase produced:
every one of those 14 names is a line map-preresolve now enumerates BEFORE the mapper is paid

**Phase-5 pickup (2026-08-24, so the next session starts building instead of hunting):** read, in
order, S5 INCLUDING ITS 2026-08-24 CORRECTION (the store tiers as they actually are: Hy-Vee has no
driver lane and stays the pricer's; Walmart is paused in the driver and attended with Aldi through
Brad's Chrome) and the D10 bullet WITH ALL of its pinned blocks (the phase-3 one names the hook
points; the phase-4 ones name the adapter's return-contract behaviour, the lookup-mode work order
with its exact flags, the per-batch flow pinned to the line, the degrade-never-block semantics, and
the fixtures owed), section 4.5's price-evidence shape WITH its field-mapping pin (probe's `verdict`
field is the evidence `state`; probe's transport `state` folds into `reason`), `hunt-daemon.py`'s `price_lane` /
`price_prompt` / `reap_priced` (the daemon is built; extend it, never re-derive it - the greedy
exhaustive service loop and the one-wake-per-micro-batch rule are both measured decisions),
`grocery\probe-ingredient.ps1` and `grocery\pull-browser-stores.py` headers (the surfaces being
composed - composed, never re-implemented), `grocery\search-verdict-lib.ps1` (the 3-state ladder
the evidence file serializes), and `ingredient-queue.ps1`'s header including the new mutex block.
The gate corpus: the three genuinely pending queue terms (`guacamole`, `pico de gallo`,
`korean-rice-cakes`) plus whatever absent terms fall out of running the four phase-2 mini-run
recipes through the REAL D7 map lane - which is also D7's first live mapper dispatch and should be
reported as such. (Their states verified 2026-08-24: all four sit at `extracted` on disk, so a seed
routes them straight to the MAP lane - no extraction, no GPU. Run it on a COPY of the run dir; the
mapper's db-side writes - resolutions rows, food-DB labels - land LIVE by design, because they are
its real work product, while run-dir state stays on the copy.) llama-server is NOT needed for phase 5 (the price pre-pass is CPU + network);
browser surfaces follow the estate's standing constraints (the Chrome debug port is blocked on the
default profile, so Walmart/Aldi stay attended by the pricer - D10 changes what the pricer reads,
never which stores it must attend). The pricer dispatch carries no schema and must keep carrying
none; its lane-log pairing, the singleton cap, and `-Derive`-as-orchestrator-call are all already
built and fixtured - D10 inserts the pre-gather between the wake and the dispatch and rewrites
`price_prompt` to adjudicate-and-attend, and that is the whole surface area. - seed from that run dir's -Status exactly as the drain drill does, on a COPY, with
the daemon's `--ledger` scratch path and publish left in -DryRun unless Brad orders the wave live.
For the residual-rate half of the gate, dossier-pop a fresh batch from the pool instead - those 10
recipes are already mapped, so measuring D7's residual on them would measure the cache, not the
pre-resolver.

*Three things a phase-4 builder should carry forward.* **(a) The drill wrote to the live batch
ledger before anyone noticed** - two open w5/w6 rows that `batch-ledger -Verify` would have called
stalled batches forever. Reverted, and the daemon now takes a `--ledger` scratch path that every
batch-ledger call goes through, mirroring wave-publish's own `-LedgerPath`. Any drill that touches
the wave lane uses it. **(b) A concurrency fixture that cannot lose a row proves nothing** - see the
fourth PS trap in this section. **(c) The QA battery correctly exits 2 when a spec was never built,
and the daemon records that as a finding and still dispatches source-QA.** Could-not-look is never a
clean bill, and it is also never a reason to skip the judge.

**Phase-6 pickup (2026-08-24, written from the phase-5 gate run - read this before the proving run).**
D10 is built and the mechanical half of its gate passed cleanly. The gate also found FIVE things that
phase 6 owns rather than D10, and the second of them is the most important thing this plan has learned
since the orchestrator moved onto the box.

*The measurements, so phase 6 has a baseline instead of an impression.*
- **The pre-pass costs 62 seconds against a 40-minute ceiling.** One real batch of 5 terms,
  `08:36:02 -> 08:37:04`: ONE probe-ingredient call (2 server stores x 5 terms x the full ladder) plus
  TWO live browser lookups running concurrently (Fareway navigate x5, Sam's paced x5). 35 store-term
  pairs came back MATCHES 14 / EMPTY 1 / UNUSABLE 20. The driver's `--timeout-min` is a wall for a
  walled store, not a cost.
- **The mapper is the most expensive single dispatch in the pipeline: 19m07s, 4,139,695 input tokens,
  93,903 output, for 4 recipes / 31 residual lines** (`08:12:53 -> 08:32:00`, detail `ok`). The estate's
  only two prior mapper pairs measured 18.2 and 18.4 min, so this is the stage's shape rather than a bad
  day. D7's pre-resolve did not shorten it - it cut what the mapper is PAID FOR (42 of 73 lines resolved
  mechanically, 0 holds) while the residual still costs a full high-effort session.
- **The batch settled 4 of 5 terms.** guacamole, pico de gallo, mustard powder and ground sage all
  CARRIED and promoted; korean-rice-cakes stayed PENDING with 7 of 7 stores recorded, because six of
  them are `blocked` and one honest `not-carried` cannot rule Rule B. All four recipes reached `priced`.

*The five findings phase 6 owns.*
1. **THE MAPPER'S DECISION FILE IS THE WRONG SHAPE, and D8 cannot build over it. MEASURED, not
   suspected.** `build-intake-skeleton.ps1 -RunDir <copy> -Slug chicken-broccoli-ziti` exits 1 with
   `FINDING the mapper decision file names no mapped ingredient` and `FINDING no protein in the mapper
   decision file`, over a recipe the live mapper had just settled cleanly. The mapper wrote
   `<RunDir>\mapped\<slug>.json` in the PRE-RESOLVE TABLE's shape (`rows`, `residual_terms`,
   `absent_terms`, per-row `term`/`canon_item`/`bid`/`resolution`) instead of section 4.5's mapper
   decision shape (`ingredients[]` of `{item, grams, decision}`, plus `protein`). It is not the agent
   being careless: `map_prompt` says "the full decision file, every line, unchanged contract" without
   naming one field, and hands it a DIFFERENTLY-SHAPED table as its input with "carry the pre-resolved
   lines straight through". Prose said unchanged; the only mechanical check is D8's exit 1, a whole
   stage later. The daemon routed correctly regardless (it reads the MAPPED dispatch payload, not the
   file) so states advanced and the absent terms enqueued - which is exactly why this was invisible
   until something tried to READ the file. **The strong fix is that the daemon assembles
   `mapped\<slug>.json` itself** from the pre-resolve table plus the mapper's residual rulings, which is
   the direction everything else in v3 moves. The cheap fix is a mechanical postcondition at the map
   lane so the recipe is STUCK where the mapper can still be re-asked. It blocks the proving run's write
   lane on every recipe the mapper settles.
2. **A DAEMON-DISPATCHED AGENT HAS NO BROWSER AT ALL - AND THE PRICER WROTE VERIFIED-SOUNDING STORE
   VISITS ANYWAY BEFORE CORRECTING ITSELF. This is the phase's most important finding.**
   The adapter dispatches `claude -p --agent recipe-hunter-pricer` in a headless subprocess. MCP servers
   are not there: `mcp__Claude_Browser__*` is the app's own pane and `mcp__claude-in-chrome__*` needs the
   extension attached to an interactive session. The agent's frontmatter DECLARES both, and declaring a
   tool does not conjure the server. Its own final evidence says it plainly: *"NOT SEARCHED - no browser
   surface existed in this session. Neither mcp__Claude_Browser__* nor mcp__claude-in-chrome__* was
   present in this agent's toolset."*
   **What it wrote FIRST is the part to sit with.** Mid-session the live queue held, for
   korean-rice-cakes, `Walmart not-carried "walmart.com in Chrome, store verified 'Omaha L St
   Supercenter', 12812 S 38TH St"`, `Aldi not-carried "header verified 'In-Store - open 9am - 8pm /
   ALDI - OLA 48 - Omaha' before and after search"`, and `Hy-Vee not-carried "Rendered aisles-online page
   in Chrome, store selector verified reading 'Shopping Omaha #1, NE'"`. None of those visits happened.
   The agent later overwrote all three with the honest `blocked / NOT SEARCHED`, which is the only reason
   the final queue is clean - and the street address in the Walmart line ("12812 S 38TH St") does not even
   match the estate's own record for that supercenter (12850 L ST), which is what a fabricated detail
   looks like. **Self-correction is not a control.** The evidence contract is enforced at the script
   layer precisely so that honesty does not depend on an agent's second thoughts, and this is the hole in
   it: `ingredient-queue -Record` cannot tell a store that was visited from a store that was described.
   Three consequences for phase 6, in order of size:
   - **Under the daemon, only the FOUR pre-pass stores can ever answer.** Hy-Vee, Walmart and Aldi are
     unreachable from a dispatched pricer by construction, so they are permanently `blocked`, and any
     term not carried by Baker's / Family Fare / Fareway / Sam's stays PENDING forever and parks its
     recipe forever. Rule B carried 4 of 5 terms here on the strength of the pre-pass alone - which makes
     D10's pre-pass the load-bearing surface of the price lane rather than an optimization of it.
   - **The prompt must stop asking for what the session cannot do.** `price_prompt` currently tells the
     pricer to attend Hy-Vee in its own tab and to check `list_connected_browsers` for Walmart and Aldi.
     In a dispatched session that instruction is an invitation to invent. The daemon KNOWS it dispatched
     headless; it should say so, pre-record those stores as `blocked / no browser in this session`, and
     ask the pricer only for what it can actually do. An attended pricer run (a human in the app) remains
     the way those three stores get checked, and that is a different entry point, not a different agent.
   - **A tool an agent cannot reach should not be in its frontmatter.** D11's "minimal tool list" rule was
     written for the opposite failure (an agent given Write that it should not have); this is the same
     rule from the other side. A declared-but-absent tool reads to the agent as a capability it has.
3. **A RESUMED RUN CANNOT RE-PRICE, and the price lane parks everything instead.** `seed()` puts a
   `pricing`/`parked` recipe back on the lane by pushing `price_wake`, but nothing ever repopulates
   `absent_terms` - those live in memory and belong to the process that mapped them. So the price lane
   wakes, finds no terms, drains nothing, and parks every pricing recipe with "a blocking ingredient is
   still PENDING". The gate drill had to seed `absent_terms` by hand for exactly this reason. The queue is
   the DURABLE handoff (its own header says so) and already knows which terms are pending and which
   recipes wait on them, so the fix is to read them back at seed time. D9's seed table owns this.
4. **`Get-RetryLadder` mutilates a HYPHENATED term into ten nonsense rungs, and every rung is a real
   network call.** Measured, reproducible:
   `Get-RetryLadder 'korean-rice-cakes'` -> 11 rungs, of which ten are `'kore an-rice-cakes'`,
   `'korea n-rice-cakes'`, `'korean -rice-cakes'` ... `'korean-rice-c akes'`. The term has no SPACES, so
   `Get-SpacingVariants` treats it as one word and splits at every position >= 4 - the exact "purple
   unicorn fruit" trap the lib's own header documents, arriving through a separator it does not consider.
   The pricer caught it by hand and said so in its evidence. The fix is small: count words on
   `[\s\-_]+`, and make the hyphen-to-space swap (`'korean rice cakes'`) a REAL rung instead of ten
   character mutilations. It also costs real money - 11 rungs x 2 stores x 25 s is up to nine minutes of
   probing for one term, and it is a plausible contributor to the next finding.
5. **Family Fare answered nothing all morning: all 5 terms, transport ERROR `(400) Bad Request`.** probe
   itself annotates that as likely Freshop throttling (it is search-budget bound), and the daily pull had
   already run at 08:00. It recorded as UNUSABLE-with-reason on every term - the field-mapping pin firing
   against the real machine rather than a fixture - so the server tier was effectively ONE store for this
   batch, and `korean-rice-cakes` stayed PENDING rather than being ruled not-carried on the strength of a
   rate limit. That is the founding rule working. It is also a warning: if Freshop is budget-bound against
   hunter traffic on any day the capture has already spent it, S5's "two by server API" is optimistic.

*What D10 left measured-but-deferred.* Nothing was cut from the ordered surface. Two things were
deliberately NOT built and should stay unbuilt until measurement asks: a retry ladder inside the driver's
lookup mode (widening a term is the pricer's judgment, and a laddering driver multiplies requests against
the two stores that wall us - the rung-1 caveat carries this instead), and a relevance score for driver
hits (it would fork probe's PowerShell heuristic into Python for a field that is a sort hint and never a
verdict). One thing the gate argues FOR, against S5's own deferral: the driver returned 17-20 candidates
per term at rung 1, and "korean-rice-cakes" came back with Lundberg snack rice cakes and a chicken cordon
bleu while "mustard powder" came back with Montreal steak seasoning. If phase 6 measures the pricer
spending its session sorting obvious non-matches, S5's deferred adversarial row-ordering signal is the
thing to build - and only then.

**Phase-6 efficiency addendum (2026-08-24, ordered by Brad after reviewing the phase-5 cost data:
"greatly reduce the time being spent + the number of tokens"). The whole pipeline was re-reviewed,
not just the two lanes the gate exercised. The cost law every item below follows: a dispatch costs
turns x working-set (each turn re-reads the accumulated context as cache) plus output tokens at 5x
input price - so the levers are turn count, output size, and working-set size, in that order.**

*Measured baseline (phase-5 gate, deduped per message id; the lane log's stamps were verified
correct against the transcripts):*

| dispatch | model | turns | uncached in | cache write | cache read | out | wall | cost |
|---|---|---|---|---|---|---|---|---|
| mapper, 4 recipes | fable | 30 (+21 subagent) | 13,001 | 323,820 | 3,802,874 | 93,903 | 19m07s | ~$12.70 + $1.64 unstamped |
| pricer, 5 terms | opus-5 | 50 + 15 re-ask | 130 | 136,463 | 4,099,768 | 47,710 | 13m26s | ~$4.10 |
| pre-pass, 5 terms | none | n/a | 0 | 0 | 0 | 0 | 62s | ~$0 |

At this shape, 200 recipes cost roughly 10-12 hours and ~$800 on these two lanes alone. The items
below target ~3.5-4.5 hours and ~$250-300 (before the opus-5 mapper pin, which halves the mapper's
per-token price on top).

**A. The mapper (biggest lever - ~60% of its cost is output tokens and turn count):**
- **A1. The daemon assembles `mapped\<slug>.json`; the mapper stops writing files.** The mapper
  returns ONLY its residual rulings as a schema'd payload; the daemon merges them with the
  pre-resolve table mechanically. **CORRECTED BY THE COLD READ (2026-08-24, measured against
  `hunt-2026-08-15-lowcarb-100\mapped\*` on disk): the mapper still speaks on EVERY purchasable
  line, because the mapped file carries a mapper-authored `buy` string per line ("3 lb, sliced into
  thin rounds (about three and a half 14 oz ropes)") that the skeleton LOCKS into the intake - a
  mechanical assembler cannot invent those.** So the saving is ~50-70k output tokens per batch, not
  ~80k: the mapper returns compact per-line arrays instead of whole files, and the assembler builds
  everything else. Still removes the per-file Write turns, and still fixes gate finding 1 (the
  wrong-shaped decision file) BY CONSTRUCTION -
  the daemon holds the pen, which is the whole v3 direction. **This adds per-line rulings to the
  MAPPED schema - a THIRD schema delta, RATIFIED BY BRAD 2026-08-24** (the "only two deltas" rule
  bends here by his order, and this sentence is the dated record). D8's `-Verify` remains the
  downstream check that the assembled file is buildable.
- **A2. Inline the residual dossier; forbid estate re-reads.** map_prompt already carries the
  residual lines; it must also carry the table's near-miss evidence per line (already computed -
  "White Wine Vinegar, DIFFERENT FORM: vinegar" is sitting in the table) and restrict Reads to
  genuine label lookups for NEW foods. Phase 1 measured inline beating tool-call reads; 30 turns
  should land near 10-12.
- **A3. Strip `Agent` from the mapper's tool list** (D11's minimal-tools rule, applied early). The
  phase-5 batch spawned a 21-turn Opus subagent that appears in NO lane stamp - $1.64 of invisible
  spend. Delegation ends; the work happens in-line, stamped.

**B. The pricer (~50-60% cut, all four items small and certain):**
- **B1. The re-ask defect, hunt_dispatch.py ~line 395: no schema + no validator must mean PROSE IS
  THE ANSWER.** Today `extract_payload` returning None triggers a full second session on every
  single pricer call ("the answer carried no JSON object at all" - but nobody wants one; the price
  lane derives state from the queue, never from the payload). Measured: 15 turns and ~$0.61 per
  batch, 15% of the lane, for nothing. Must-fire: a schema-less dispatch answering pure prose is
  accepted without a re-ask, proven by neutering; clean twin: a schema'd dispatch still re-asks.
- **B2. `-RecordBatch` on ingredient-queue.ps1.** 7 stores x 5 terms = ~35 separate `-Record`
  invocations = ~35 turns, the single largest turn sink in the lane. One call carrying N records as
  a JSON file, the script enforcing the evidence contract PER ROW exactly as it does per call
  (carried-requires-a-price, exact store names, PENDING-never-promotes) - the pen stays with the
  pricer, the enforcement stays at the script layer. Fixture: a batch with one contract-violating
  row rejects that row with it named, and the mutex still guards the whole write.
- **B3. price_prompt tells the dispatched pricer the truth about its hands** (gate finding 2's
  remediation): a daemon dispatch is headless, so the prompt says NO browser exists in this
  session, instructs one batched `blocked - no browser in this session` record for
  Hy-Vee/Walmart/Aldi, and forbids re-probing any store the evidence already marks
  UNUSABLE-throttled (Family Fare ate 3 futile retries). Kills the discovery turns and closes the
  fabrication window in the same edit. The agent definition keeps the attended-run instructions for
  when a HUMAN runs the pricer interactively - two entry points, one agent.
- **B4. The hyphen ladder fix in search-verdict-lib** (gate finding 4): count words on `[\s\-_]+`
  and make the hyphen-to-space swap one real rung. 110 probe requests for one term becomes ~15,
  and the pre-pass gets faster for free.

**C. Estate-wide (from the whole-pipeline review):**
- **C1. Turn and cache telemetry in the lane stamps.** Today's analysis required transcript
  archaeology with per-message-id dedup. DispatchResult ALREADY carries cache_read /
  cache_creation / calls; lane() just does not stamp them. Add turns, cache split, and the
  modelUsage-derived subagent-inclusive total to every end stamp, so every future run measures
  this for free. (The unstamped-subagent gap is real: the mapper's $1.64 appeared in no ledger.)
- **C2. The N-shell-calls audit across every agent prompt.** The -Record pattern generalizes: any
  instruction that implies N serial script invocations is N turns. The pricer was the worst; check
  the writer's in-place field fills (instruct ONE edit pass over the fillable set, not one Edit
  per field) and any registrar/consult loops. QA writes one verdict file and is fine.
- **C3. Seed FULL batches.** MAP_BATCH=5 and PRICE_BATCH=10 amortize the fixed working set per
  recipe; the gate ran 4 and 5. Free money at scale - the seeding side just needs to prefer full
  slices when the backlog allows.
- **C4. MEASURED 2026-08-24, AND CLOSED: the pen does not move.** The estimate here was ~1s per
  spawn and "potentially tens of minutes" at 200 recipes. Measured on the box, five samples:
  **310 ms**, not 1,000. The 6b run logged 80 lane events across 9 accepted recipes - 8.9 per
  recipe - for **24.8 s summed, 0.65% of a 63.5-minute run**. Projected at 200 recipes that is
  ~1,778 events and **9.2 minutes SUMMED**, and because lanes run concurrently the wall-clock
  cost is less than the sum rather than equal to it.
  So the tax is real and small, and moving the pen would cost more than it saves: hunt-run.ps1 is
  both the contract owner and the reader, and a daemon that appends lane lines directly makes TWO
  writers of one format - the drift this estate keeps designing out. Brad closed it 2026-08-24.
  The measurement is the deliverable; C4 asked for one and the answer is no.
- **C5. D11 early wins now instead of later:** minimal tool lists per agent (A3 is the first), and
  standing constants OUT of per-call prompts INTO agent definitions where the prefix cache pays
  once per session instead of per dispatch.
- **C6. Effort tuning is measure-first and per-lane. STILL OPEN 2026-08-24.** The mapper stays
  `high` through the pin change (accuracy stage). Writer/QA at `medium` are candidates ONLY with
  an A/B against a baseline - the residue principle in 4.4a applies to effort exactly as it does
  to tiers. Reviewed 2026-08-24 and deliberately NOT settled: unlike C4 this cannot be answered
  by a measurement anyone can take alone. It needs the same corpus run twice and compared on the
  AUDITOR'S VERDICTS rather than on token counts, because a cheaper stage that changes what the
  auditor says is not cheaper. That is a run's tokens, so it is Brad's to order.
- **C7. Do NOT batch QA.** Fidelity is per recipe and accuracy-sensitive; the per-dispatch
  overhead is the price of the verdict being about ONE recipe. Reviewed and rejected, recorded so
  nobody re-derives it as an optimization.
- **C8. Pricing self-shrinks at scale - no work, just the note:** 4 of the gate's 5 terms are now
  CARRIED in carriage.json forever, and the queue dedupes by term across recipes and runs. The
  marginal new-term rate falls as the vocabulary saturates, so the $82/200-recipes pricing
  estimate is a ceiling, not a run rate.
- **C9. The already-lean lanes were reviewed and left alone:** harvest/pool and decide are
  mechanical-plus-one-dispatch by construction (phase 1 measured the dossier inlining at a 37%
  token drop; DECIDE_BATCH=10 amortizes); extract is local-first with Claude only on escalations
  (phase 2's whole point); the wave lane's auditor reads residue + report (S8). No items.

*Sequencing for the phase-6 builder (CORRECTED by the cold read):* phase 6 is TWO halves - 6a the
fix batch, 6b the proving run - and 6a lands FIRST so 6b measures the improved pipeline, not the
old one. Order inside 6a: B1 and B4 (one-liners with fixtures; every later gate run gets cheaper),
then B5 (the reseed - without it any resumed run parks everything), then the A-package (A1+A2+A4
together: one contract, one prompt, one assembler, one registrar road), then B2+B3 together (one
script surface, one prompt), then C1. C2-C9 as 6b's own measurements justify. The mapper pin is
ALREADY LIVE (frontmatter edited 2026-08-24); its compare-batch checkpoint is FOLDED INTO the 6a
gate (pin P11). llama-server is NOT needed for 6a (no extraction) and IS needed for 6b (fresh
recipes enter at the extraction ladder) - Brad hand-starts it, per section 4.4, as always.

**PHASE-6 COLD READ (2026-08-24, Fable, against the code and the v2 artifacts on disk - eleven
guess-traps closed before Opus builds the addendum above). Each pin below exists because the
addendum's prose, read cold, would have let a builder guess - and in three cases the obvious guess
is measurably WRONG.**

- **P1. B1's obvious implementation BREAKS THE PRICE LANE - the payload trap.** `DispatchResult.ok`
  is `payload is not None` (hunt_dispatch.py ~line 172), `Daemon.dispatch` returns `res.payload`,
  and `with_retry` treats None as NO VERDICT: up to MAX_STAGE_RETRIES fresh pricer sessions, then
  STUCK, with the breaker counting every one as a failure. So "skip extraction when schema-less"
  turns every prose answer into a retry storm costing MORE than the re-ask it removes. THE FIX:
  when `schema is None and validator is None`, the text IS the verdict - set
  `res.payload = {"text": res.text}` and return before the problems check. `ok` stays
  payload-based; nothing upstream changes. Fixtures live in hunt_dispatch's own suite (FakeRunner
  is already there): must-fire - a schema-less dispatch answering pure prose returns ok with ONE
  call and `reasked` False, proven by neutering the branch; clean twin - a schema'd dispatch with a
  malformed answer still re-asks exactly once.
- **P2. A1's scope: the mapper speaks on every purchasable line, because of the `buy` string.**
  Measured against `hunt-2026-08-15-lowcarb-100\mapped\baked-cauliflower-mac-smoked-sausage.json`:
  every line carries a mapper-authored `buy` ("an 8 oz brick minus 2 tbsp") that D8 LOCKS into the
  intake, and locked-means-locked is the prose-number defect's grave - it cannot move to the
  writer. So the ruling payload is TWO arrays per slug: `lines` - `{raw, buy, notes}` for EVERY
  purchasable line (compact; this is where the buy strings live) - and `rulings` -
  `{raw, term, canon_item, bid, decision, grams, evidence}` for the RESIDUAL lines only.
  Everything else (title, source_url, servings block, scaling, decisions for pre-resolved lines,
  the report blocks) is assembled mechanically. Freeze the exact payload shape against the v2
  files at build time and fix this paragraph in the same commit if reality disagrees again.
  **CORRECTED 2026-08-24 AT BUILD TIME, exactly as that last sentence instructs, and measured
  against the frozen v2 file: `lines` ALSO carries an optional `grams`, and the ruling field is
  `grams` rather than `grams_source`.** Two of that file's seven lines do not carry the exact
  3.5x weight, both because the mapper QUANTIZED its own printed measure (14 oz x 3.5 = 1389 g
  shipped as "3 lb" = 1361 g), and the file's own `conventions` field says grams are derived
  FROM the printed measure so the two agree by construction. A shape with no grams on `lines`
  would therefore have shipped a buy string and a weight that disagree on every quantized line.
  Section 4.5 carries the frozen field set and the precedence rule.
- **P3. Grams: the table has none today, and the file's are TARGET-scaled.** The pre-resolve rows
  carry no `grams` field; map-preresolve's macro_precheck engine already computes per-line grams
  internally (it could not compute per-serving macros otherwise) - EMIT them per row, at
  SOURCE-recipe basis. The mapped file's grams are TARGET grams: v2 measured, 16 oz at 4 source
  servings = 454 g x scale_factor 3.5 = 1588 g on disk. The assembler applies
  `14 / source_servings` EXACTLY ONCE, writes `source_servings` / `target_servings` /
  `scale_factor` top-level, and that v2 row is the frozen fixture vector. A purchasable line with
  no grams from either the engine or a ruling is STUCK, named - never a silent zero (a zero-gram
  line is the fabricated-band defect from the D8 header, upstream).
- **P4. The decision vocabulary is Get-LineClass's, and nothing else's.** build-intake-skeleton.ps1
  ~line 166 enumerates the classes measured from v2's own shipped intakes (INCLUDED: `mapped`,
  `mapped-optional` variants, `mapped-pending-price`, `mapped-ruled-addition`...; UNSETTLED:
  anything matching `unresolved`; UNKNOWN: everything else). The assembler emits ONLY strings that
  class as included / optional / not-purchased, and its fixture DOT-SOURCES THE REAL Get-LineClass
  to prove it - a string classing `unknown` or `unsettled` out of the assembler is a must-fire.
  Free-texting decisions is what produced 21 distinct values across 550 lines in v2.
- **P5. The assembler lives in map-preresolve.ps1 as `-Assemble`, not in Python.** The grams
  engine, the qty parser and the five-PS-trap discipline are already there; a Python re-derivation
  is the forked-taxonomy defect with a .py extension. `-Assemble -Slug <s> -RulingsFile <payload>`
  writes `mapped\<slug>.json`. ONE writer per slug file (the map lane's workers never share a
  slug), so NO mutex - say so in the header, exactly as the evidence writer does. The minimal
  field set is not guessed either: grep build-intake-skeleton.ps1 AND wave-preaudit.ps1 for every
  `$Mapped.`/mapped-file read, freeze the union in section 4.5, and fix 4.5's row in that commit.
- **P6. A3 severs the registrar road unless A4 rebuilds it daemon-side.** The mapper's def orders
  new ids "through the commodity-registrar gate" - a consult that today rides the Agent tool, the
  very tool A3 strips (frontmatter `tools:` cannot scope WHICH subagents are reachable). A4: the
  ruling payload's new-id proposals go to the DAEMON, which dispatches commodity-registrar itself
  (fable/medium per its pin) with the proposal + evidence, schema'd
  `{verdict: approve|reject|alias, bid, reason}`; only an approve lets the assembler mint the
  decision, a reject leaves the line unsettled and the recipe STUCK with the registrar's own
  sentence. That schema is a NEW dispatch, not a delta to the inherited set - name it in the A1
  commit as part of Brad's 2026-08-24 ratification. Must-fire: with the registrar returning
  reject, the assembled file NEVER carries the proposed bid.
- **P7. B5 (gate finding 3, absent from the original worklist): seed() repopulates absent_terms
  from the QUEUE, the durable handoff that already knows.** After seed()'s existing -Derive pass:
  for recipes still `pricing`/`parked`, call `ingredient-queue.ps1 -List -Status pending -Json` -
  and VERIFY FIRST what `-List -Json` actually emits (if items lack `recipes` or -Json does not
  bind to -List, extend the script rather than parsing prose). absent_terms := pending terms whose
  `recipes` intersect the run's pricing slugs, queue order. Fixtures against a scratch -QueueFile
  with 3+ items (two pending, one resolved): must-fire - the resumed daemon dispatches the pricer
  with exactly the two pending terms, proven by neutering the reseed (everything parks); clean
  twin - resolved terms are never re-dispatched.
- **P8. B2 is ATOMIC.** `-RecordBatch -File <json array of {term, store, state, price, size, item,
  evidence}>`: every row validated FIRST under exactly -Record's rules (exact store names,
  carried-requires-a-price, the state enum), and ANY invalid row means NOTHING is written, exit 1,
  every violation named with its row - the pricer gets one correction pass instead of a silent
  hole in its evidence. One mutex take for the whole batch. `-Verdict` and `-Promote` stay
  per-term, unchanged. Fixture per the estate rule: a 3-row batch with one bad row writes zero
  rows, proven by neutering the validation.
- **P9. B3 needs NO flag plumbing: price_prompt is daemon-only by construction.** The attended
  path is a human invoking the agent interactively, and no human path ever renders price_prompt.
  So the prompt states the headless truth UNCONDITIONALLY: no browser exists in this session;
  record Hy-Vee/Walmart/Aldi as `blocked - no browser in this session` inside the same
  -RecordBatch; never re-probe a store the evidence marks UNUSABLE-throttled. The agent definition
  keeps its attended instructions for the human entry point - two entry points, one agent, zero
  conditionals.
- **P10. C1's stamps: extend, verify the envelope, do not guess key names.** hunt-run.ps1 -Lane
  gains optional `-CacheRead` / `-CacheCreation` / `-Calls` (int, default -1) emitted into the
  jsonl line; the daemon passes them from DispatchResult, which ALREADY carries all three. For the
  subagent-inclusive total, `res.model_usage` holds the CLI envelope's `modelUsage` map - READ ONE
  REAL ENVELOPE from a gate transcript to confirm its per-model key names before coding, then
  stamp the summed totals beside the main-agent numbers. Fixture: a FakeRunner envelope carrying
  TWO models proves the subagent's tokens land in the stamp (the class of the mapper's invisible
  $1.64).
- **P11. The 6a gate is ONE combined drill, and it already has a corpus.** Re-map the same four
  phase-2 recipes on a fresh COPY of the phase-1 mini run dir (short scratch root; db-side writes
  land live by design, and they are idempotent here - the food-DB rows already exist). That single
  run is simultaneously: (i) the 4.4a pin checkpoint - ruling-level diff, Opus vs the committed
  Fable batch, same pre-resolve inputs, reviewed by Brad; (ii) A1's end-to-end proof -
  build-intake-skeleton.ps1 exits 0 over every ASSEMBLED file, which is gate finding 1 dying on
  the same corpus that exposed it; (iii) the cost measurement - turns, cache split and wall clock
  via C1's stamps, recorded against the baseline table above. The B-package gate rides the same
  session: one real price batch (korean-rice-cakes plus whatever the re-map enqueues), lane log
  showing NO `re-asked`, exactly one -RecordBatch write in the queue history, turns counted. 6b's
  success criteria are then written BEFORE the proving run, per row 6's own rule.

**Stop-rules.** Re-measure with lane-tokens/harvest-lane-tokens after phases 1, 3 and 6; if the
remaining spend concentrates somewhere this plan did not predict, the measurement wins and the order
changes. If phase 3's parity gate cannot be made green, ship the §4.2 fallback and stop there - the
plan still captures the large wins.

**PHASE-6A GATE RECORD (2026-08-24, PASSED). Evidence, so the next session does not re-earn it.**

*The drill.* Two live runs on short scratch roots, off fresh copies of
`meal-prep\runs\hunt-2026-08-23-v3-phase1-mini` (the original still holds its recipes at `extracted`;
phase 5's `C:\tmp\p5` copy is spent). Run one mapped two recipes and exposed the defect list below;
run two, after the fixes, mapped one recipe end to end and drove the registrar and the price lane.
Db-side writes landed live by design. Scope was trimmed from pin P11's four recipes to two-then-one by
Brad's order (weekly budget at 65%), which is recorded here rather than glossed: the pin diff is over
37 lines rather than ~70, and the other two mini-run recipes are still at `extracted` for 6b.

*The three things the one run proves.*
- **(i) The 4.4a pin checkpoint: CLEAN.** 37 of 37 identity rulings agree with the committed Fable
  batch over the same pre-resolve inputs - `0 differ`, `0 dropped`. Opus additionally argued two
  rulings in writing that Fable had settled silently (refusing to bridge dry mustard powder onto the
  prepared-mustard id, and refusing to propose `brown-lentils` as new because it is already a live
  board id). The pin stands at `claude-opus-5`.
- **(ii) Gate finding 1 is dead by construction.** `build-intake-skeleton.ps1 -RunDir <copy> -Slug
  chicken-broccoli-ziti` exits **0** with zero findings over the daemon-assembled file - the same
  script, the same recipe, that exited 1 with "the mapper decision file names no mapped ingredient" on
  the phase-5 run. Macros 505 cal / 41.6 g protein / 46.4 g carbs at 14 servings, in band, and within
  1.7% of the 514 cal the source page publishes.
- **(iii) The cost measurement, read straight off C1's stamps** (which is what C1 bought - phase 5
  needed transcript archaeology with per-message-id dedup for the same numbers):

| dispatch | model | turns | uncached in | cache write | cache read | out | wall |
|---|---|---|---|---|---|---|---|
| mapper, 1 recipe | opus-5 | 2 (one re-ask) | 12 | 30,287 | 120,152 | 30,806 | 6m02s |
| commodity-registrar | fable | 1 | 11 | 27,862 | 115,164 | 3,026 | 0m44s |
| pre-pass, 1 term | none | n/a | 0 | 0 | 0 | 0 | 0m19s |
| pricer, 1 term | opus-5 | 1 | 14 | 26,797 | 136,455 | 4,115 | 1m04s |

  Against the phase-5 baseline, per recipe: **input tokens 1,034,924 -> 122,903 (8.4x lower)**, **turns
  8 -> 1 (7.5x lower)**, cache read 950,718 -> 79,650 (12x lower). Output rose 23,476 -> 38,364, and
  that number is honestly re-ask-inflated (the whole answer was produced twice) and prose-inflated;
  the per-line `evidence` bound landed after this measurement and is 6b's to verify. The price lane
  went from 13 turns and 161 s per term to **1 turn and 64 s**.

*The B-package, on the same session, against the live queue.* One real batch on `grated Parmesan
cheese`, the term the re-map enqueued. Lane detail `ok` and **not** `re-asked` (B1 live - phase 5's
pricer re-asked on every batch). All seven store records carry the **identical** `checked` timestamp,
which is one `-RecordBatch` take of the write lock (B2 live). Walmart recorded
`blocked - no browser in this session`, verbatim (B3 live). Verdict CARRIED, 6 of 7 checked.

*And the B-package gate found something worth keeping.* For Hy-Vee and Aldi the pricer did NOT record
`blocked` as the prompt instructed - it recorded `carried` with "no browser this session; ruled from
disk instead - price-ingredient.ps1 ...". That is the exact shape of gate finding 2's fabrication, so
it was checked: `price-ingredient.ps1 -Name 'grated Parmesan cheese'` really does return
`Aldi $2.79 8 oz Reggano Grated Parmesan Cheese` and `Hy-Vee $3.49 8 oz Hy Vee Grated Parmesan Cheese`
in today's captures. The claim is true, cited and re-runnable, and it is strictly better than
`blocked`. **So the prompt was wrong, not the pricer**, and it now names that road: a capture HIT at
one of the three browserless stores may support `carried` with the product and price cited; a capture
MISS is NEVER `not-carried`, because the captures are a weekly publish sweep and not a shelf audit.
This materially softens the phase-6 pickup's biggest structural worry - that under the daemon only the
FOUR pre-pass stores can ever answer and every other term parks forever.

*Aftercare, same day:* the 6b criteria's own reader was then audited and found blind -
`hunt-run.ps1 -LaneSummary` aggregated tokens from START lines and skipped END lines whole, so it
reported zero tokens over any daemon run (the stamps live on the end lines). Corrected, extended with
`turns`/`re-asks`/cache-split/`[+N delegated out]` columns, fixtured with both writer conventions and
neuter-proven (reverting the end-line merge kills 3 must-fires); and the pricer's agent definition
gained the capture road its dispatch prompt already carried, so the two entry points cannot disagree.

*The eight defects the drill found, none of which a fixture could have.* All fixed, fixtured and
committed the same day. 1. The grams basis: the mapper returned SOURCE grams in a field specified as
TARGET on ten of ten lines, the ratio exactly each recipe's own scale factor, and split the two bases
WITHIN one answer. Field renamed `grams_source`, every road source basis, scale applied once, and an
engine cross-check now names any disagreement past 50%. 2. `say()` died on U+FFFD from a mojibake'd
source line and killed a run after a paid dispatch. 3. The `raw` join key: 32 of 33 copied exactly,
one truncated - now falls back to the term where it is unique in both payload and table, and every
fallback is named in the file. 4. The registrar gate read the recipe VOCABULARY instead of the three
COMMODITY namespaces and refused a live board id. 5. It was skippable by omission; `-NewBids` now
derives the proposal list. 6. A sub-half-gram line rounded to zero past the never-a-silent-zero
refusal, floored at 1 g. 7. A `mapped-null` ruling nulled the food's NAME along with the id. 8. The
schema constrained two report fields to strings that the model naturally returns as objects, buying a
whole second session; and the delegation finding fired on every dispatch at deltas of 18-37 tokens,
which is the CLI's own housekeeping haiku call, not delegation.

**PHASE 6B SUCCESS CRITERIA (written 2026-08-24, BEFORE the proving run, per gate row 6's own rule -
"success criteria written before the run" - and against the phase-6a gate's measurements rather than
against an impression).**

*What the run is.* ~20 recipes, wave size 10, Brad-directed conditions, on the pipeline as 6a left it.
llama-server IS needed (fresh recipes enter at the extraction ladder) and Brad hand-starts it, per
section 4.4. 6a's fix batch has already landed, so this measures the improved pipeline - which was
the whole reason phase 6 was split in two.

*THE RUNBOOK (added 2026-08-24 aftercare cold read, so the 6b builder starts from commands rather
than from guesses). Every path below exists today; nothing is to be invented.*

- **Before anything:** `git pull`. Ask Brad for the weekly usage % (the 80% stop rule) and for the
  run's conditions and stop condition. Other sessions write `grocery\*` and `graph\*` - normal
  noise, never chase it, never `git add -A`.
- **The GPU, per sections 4.3/4.4 and not re-derived:** Brad hand-starts llama-server. The
  extraction sweep is TWO passes on TWO server shapes - rung 1 fanned at the default `-Slots 4`,
  rung 2 narrow at `-Slots 1` (same `-c 16384`; the 1-slot shape measured LESS VRAM, 14,688 MiB) -
  and `extract_sweep.py --from-report` exists precisely so pass 2 targets only what pass 1
  escalated. Brad restarts the server between shapes; nothing in the daemon ever starts or stops it
  (a fixture enforces this). The run must be off the card before the 07:00 ad pull and 08:00
  capture, and the nightly chain owns 21:30-06:30.
- **Mint the run dir with `hunt-run.ps1 -Init -RunDir <dir> -Conditions '<Brad's>' -Stop
  '<Brad's>' -WaveSize 10`,** then drive it with
  `C:\Codex\Python312\python.exe meal-prep\pipeline\hunt-daemon.py --run-dir <dir> --run <id>
  --wave-size 10 [--target N]`. The flag decisions, spelled out: a PROVING run uses the LIVE
  ledger, spec store and costed.json, which means LEAVING `--ledger`, `--specs` and `--costed`
  EMPTY (the scratch seams exist for drills; a scratch spec store means an UNCOSTED spec).
  `--publish` is Brad's call at run start: without it the wave lane runs `wave-publish -DryRun`,
  which still exercises the auditor and is a legitimate first wave; with it, publishes are real.
  `--lanes` defaults to all seven - do not trim it for a proving run.
- **The measurements come from ONE reader:** `hunt-run.ps1 -LaneSummary -RunDir <dir> [-Json]`,
  which since 2026-08-24 reads the daemon's end-line stamps (calls/invocations, `turns`, the cache
  split, `re-asks`, and the `[+N delegated out]` note from the subagent-inclusive totals). Do NOT
  hand-roll a lane-log reader - the previous one silently reported zero tokens on every daemon
  lane, and that class of quiet wrongness is exactly what the fixture now pins. Published counts
  and per-recipe states come from `hunt-run.ps1 -Status -RunDir <dir>`; the two re-ask and
  delegation FINDINGS are printed in the daemon's own status report and match the strings quoted
  in criteria 4 and 5 below.
- **THE C3 TRAP, pinned before somebody builds it wrong:** the addendum's C3 ("seed FULL batches")
  is a MEASUREMENT note, not a build item. `Chan.take_batch` already sweeps up to MAP_BATCH /
  PRICE_BATCH greedily, and its docstring records why it must NEVER wait to fill a quota: the
  wait-for-full-batch policy was measured (B3) deadlocking against the WIP limit and adding 8-10
  minutes to first flow. If 6b's batches run small, the lever is seeding order and backlog depth,
  never a fill-wait in the channel.
- **The corpus on disk, so nobody re-derives it:** the ORIGINAL
  `meal-prep\runs\hunt-2026-08-23-v3-phase1-mini` still holds all four phase-2 recipes at
  `extracted`, untouched - a future drill corpus, NOT part of 6b's ~20. The `C:\tmp\p5`,
  `C:\tmp\g6a` and `C:\tmp\g6b` copies are all spent (g6a's saved rulings payloads predate the
  `grams_source` contract and must not be re-assembled). 6b sources its recipes fresh through
  harvest/decide under Brad's conditions.

*The five numbers, and every one is read off C1's lane stamps rather than reconstructed from
transcripts. That is what C1 bought and 6b is the first run to spend it.*

1. **Claude invocations per PUBLISHED recipe: <= 5**, against the 27 front-end + ~10 downstream
   measured in v2. Row 6 asks for >=5x fewer than 27; 5 is that. Count INVOCATIONS from
   -LaneSummary's `calls` column (one start/end pair = one invocation; the fixture pins this) and
   keep TURNS separate - they are its `turns` column, summed from the end lines' own `calls` field.
   An invocation that re-asked is one invocation with two turns, and conflating the two flattered
   the number in v2's accounting.
2. **Billed tokens per published recipe: <= 150k median**, section 7's target, measured as
   lane-tokens.ps1 measures it (uncached input + cache read + cache write, plus output). Report the
   MEDIAN and the spread, not the mean: one pathological recipe should be visible as a tail, not
   averaged into a pass.
3. **Steady-state wall clock per published recipe**, reported against section 7 and against 6a's own
   map measurement (453 s/recipe on a re-asked 2-recipe batch, ~227 s/recipe with the re-ask
   removed). "Steady state" excludes the first wave: the pool, the vocabulary and the prior-rulings
   ledger all warm up.
4. **Re-ask rate: <= 10% of dispatches, and every one of them named.** 6a's own gate drill re-asked
   on its single mapper batch - a whole second session, at the price of the first - and the violation
   ("payload is missing required field `results`") existed only in a headless transcript nobody keeps.
   The daemon now records it as a finding, so this is countable for the first time - TWO
   instruments, and they must agree: -LaneSummary's `re-asks` column (end-line `detail` beginning
   `re-asked; `) and the daemon findings matching `RE-ASKED and then succeeded`, which quote the
   violations verbatim. A run whose mapper re-asks every time has not halved its cost; it has
   doubled a smaller one. 6a's two re-asks were both SCHEMA bugs on our side (a missing top-level
   `results` wrapper once, over-constrained report fields once, both fixed) - so a 6b re-ask is
   evidence about the contract before it is evidence about the model.
5. **Zero unstamped delegation.** Every dispatch where `all_out` exceeds `out` by more than
   max(500 tokens, 5%) must carry the daemon's `output tokens MORE than its own session` finding and
   an explanation - that threshold is the code's own (hunt-daemon lane()), because the CLI bills an
   auxiliary haiku call of ~18-37 output tokens alongside EVERY headless dispatch and flagging those
   is noise that buries the real thing. -LaneSummary shows the per-lane delta as `[+N delegated
   out]`. The phase-5 mapper's 21-turn Opus subagent cost $1.64 that appeared in no ledger; A3
   removed the tool and C1 made the gap visible, and 6b is where that stays true under load.

*The four gates that may not move, restated because a proving run under time pressure is exactly when
one gets softened.*

- **Zero gate weakened**, per row 6. Specifically: Rule B (unchecked is never not-carried), the
  pre-write band gate ruling on hunt_lib.in_band, D8's locked-field postcondition, the wave auditor's
  GO, and the commodity-registrar's approve-or-alias before any new id. A gate that could not be met
  is a STOP and a conversation, never an edit.
- **The band gate must be shown FAILING CLOSED at least once, and every closure inspected.** 6a's
  drill produced 212 and 217 cal per serving from a grams-basis error, and the band gate would have
  retired two good dishes on those numbers. It failing closed is correct; it failing closed on a
  FABRICATED number is D8's own named worse-than-no-gate case. So every `rejected-macros` in 6b gets
  looked at rather than counted.
- **Every honest PENDING stays PENDING.** Under the daemon the four pre-pass stores answer live, and
  since the 6a gate the pricer may also rule Hy-Vee/Walmart/Aldi from the estate's OWN CAPTURES via
  price-ingredient.ps1 - a capture HIT supports `carried` with the command cited, and a capture MISS
  is NEVER `not-carried` (a weekly publish sweep is not a shelf audit). Terms will still park on
  genuine gaps. That is a passing outcome (phase 5's gate pinned it) and rounding one up is the one
  thing that cannot be undone downstream. Spot-check at least one capture-road `carried` by
  re-running the cited command, exactly as the 6a gate did.
- **Every new defect class frozen as a fixture SAME-DAY**, per row 6, with a neuter proof - the estate
  rule that a fixture which cannot be made to fail proves nothing.

*The three things 6a measured but did not settle, which 6b inherits and must report on.*

- **The corrected `grams_source` basis under load.** 6a caught the mapper returning source grams in a
  target field on ten of ten lines, renamed the field and moved the scale to one place. 6b is the
  first run where that contract meets a batch it has not seen. The assembler's engine cross-check is
  the instrument; report how often it fires and on what.
- **Output size per dispatch.** 6a measured 38k output tokens on a two-recipe mapper batch, most of it
  per-line argument prose, and bounded `evidence`/`notes` to one or two sentences in the prompt and
  the agent definition. Whether that bound holds is a measurement, not an assumption - report output
  per recipe against 6a's 38,364.
- **C2's N-shell-calls audit across the remaining agent prompts** (the writer's in-place field fills,
  any consult loop). B2 fixed the worst instance; the pattern was never swept.

**CORRECTED 2026-08-24, BEFORE the run, by Brad's ruling and by measurement against the live pool.
THE MACRO BAND IS A RUN PARAMETER, AND PROTEIN IS PART OF IT.**

Asked for 6b's conditions, Brad answered that they change every run - calories, carbs and protein all
move - and that the system must ASK for them before a run rather than carry them as constants. Three
things were then measured, and all three are now code:

1. **The pop was deaf to the run's band, and it would have wrecked criterion 1.** `hunt-daemon`'s
   `--cal-min/--cal-max/--carb-max` reached only the decide PROMPT TEXT and the two band gates.
   `pop_dossiers` popped from `status == "available"` in `dossier_rank` order and never looked at the
   band at all - and `available` means "passed the band HARD-CODED IN harvest.py at ingest", 400-650
   cal and <= 35 carbs. Measured against the live 661-candidate pool under Brad's 6b band: **2 of the
   first 10 pops qualified, and 3 of the first 20**, so reaching 20 acceptances meant paying an Opus
   decider roughly 66 times to reject candidates one line of arithmetic kills. Section 2's PLANE 1
   already says band filtering is mechanical and instant; the pop now filters there. It is
   deliberately STRICTER than the gate: an unverified or unreported macro cannot CONFIRM the band, and
   a selection filter over a backlog of hundreds should pass over what it cannot confirm, while a
   RETIREMENT gate must never retire a dish on a number nobody read.
2. **No protein floor existed anywhere in the estate.** Not in `harvest.in_band` (cal and carbs only),
   not in `hunt_lib.in_band` - which IS both band gates - and not as a daemon flag. A run whose stated
   conditions read "50 g protein or more per serving" was enforced by nothing. `in_band` /`inBand` now
   take an optional `proteinMin` plus the recipe's protein, in all three implementations, with five
   new shared parity vectors. The clause is LAST, so every pre-existing band vector's reason string is
   byte-identical; a band that states no floor does not invent one; and an unread protein number
   passes and SAYS SO (`"protein not reported"`), which the daemon raises as a finding at both gates
   rather than swallowing. Both roads carry the number already - the skeleton's
   `macros_per_serving.protein_g` and the built spec's `stat.protein`.
3. **`hunt-run.ps1 -Init` now REFUSES to mint a run dir until the band is typed** (`-CalMin -CalMax
   -CarbMax -ProteinMin`, where `-ProteinMin 0` is how "no floor" is said out loud) and writes it into
   `run.json`; the daemon reads it back and CANNOT RUN when nothing states it. That is the enforceable
   form of "ask me before a run": the band a run was judged under is now readable off the run dir
   months later instead of inferred from whatever the constants happen to say that day.

Every one of these is fixtured with a neuter proof (removing the pop filter revives all four bad
pops; removing the protein clause kills two must-fire vectors; defaulting the band in `resolve_band`
kills the refusal; neutering the `-Init` guard mints a run dir reading `band: -1--1 cal, carbs <= -1`).

*Two things this correction does NOT do, both deliberately.* **The ingest pre-filter was left alone.**
harvest.py still qualifies at its own 400-650 / <= 35 constants, which are NARROWER than a run band may
be, so a candidate the run's band would admit can sit at `ruled:out-of-band` and never be reachable -
measured: 3 candidates at 36-40 carbs meet the 6b band and are unreachable. It does not block 6b (21
qualifying candidates remain available) and the fix is a re-qualify pass over stored numbers, so it is
recorded here as a PROPOSAL for Brad, not a build. **And "add more meat to hit the protein target" was
not built.** No stage modifies a sourced recipe; it collides with section 10's "extraction is
transcription" and with source-QA's whole purpose, and it proved unnecessary - 21 pool candidates
already publish >= 50 g protein inside 500-650 cal and <= 40 g carbs with nothing added.

*What would make 6b a NO.* Any of: invocations per published recipe above 8; a gate weakened to make a
number; a recipe published whose macros were computed over a partial line set; a fabricated store
visit of any kind; or a defect class found and not fixtured the same day.

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
