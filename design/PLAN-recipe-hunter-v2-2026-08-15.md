# PLAN: Recipe Hunter v2 - Streamed Hunt, Waved Auto-Publish

Date: 2026-08-15. Author: Fable (design review session with Brad). Implementer: Opus.
Status: APPROVED by Brad. Auto-publish after a green batch audit is explicitly authorized.

## 0a. CORRECTIONS APPLIED DURING IMPLEMENTATION (2026-08-15, same day)

This plan was written against the r300-era run pipeline. Reading the engine before coding showed that
path is retired, and two of the plan's instructions were wrong in ways that would have shipped defects.
Both are corrected in the built code; they are recorded here because the plan is the artifact people
re-read.

1. **PUBLISHING. The plan said `publish-recipe.ps1` per slug with `visibility` defaulting to paid.
   WRONG.** That script hardcodes visibility on an upsert, and `rotate-free-dinners` owns visibility:
   publishing that way would silently RE-PAYWALL every hand-freed free dinner. The sanctioned path is
   `engine\publish.ps1` (visibility-PRESERVING, 404-vs-error aware so it cannot mint a paid `<slug>-2`
   orphan, per-slug failure isolation, live verify), reached through `pipeline\propagate-recipes.ps1`,
   which is the estate's one command after any spec edit: recipes-db sync -> `audit-db-agreement` hard
   gate -> planner data -> `build-cards -Slugs` -> hash-gated publish, with stamps advancing only after
   every stage succeeds. `wave-publish.ps1` calls that chain instead of re-implementing it.

2. **SPEC VALIDATION. The plan said "spec-guards.ps1 exits 0 per slug TODAY". WRONG, and destructive.**
   `spec-guards.ps1` full mode CANNOT run against `db\recipes` specs: it merges prose from
   `specs\prose\prose-<slug>.json` files the engine no longer produces, and on pass it re-serialises the
   whole spec, which is the documented \uXXXX prose-corruption trap (NEXT-RUN-PLAYBOOK, "SPEC-GUARDS ON
   THE v2 PATH"). The v2 enforcers are build-v2-spec's write-time guards plus
   `audit-spec-contradictions.ps1`, `audit-store-integrity.ps1`, `test-guards.ps1` and
   `engine\audit-db-agreement.ps1`. `wave-publish.ps1` runs those.

3. **SPECS DO NOT LIVE IN THE RUN DIR.** `db\recipes\<slug>.json` is the only spec home. The run dir
   holds `intake\<slug>.json` (the writer's intake for `build-v2-spec.ps1`), not `specs\`. Cards are
   built by the engine into `db\built\`. The wave manifest therefore carries slugs, not Ghost post
   fields, because the engine publisher reads the spec.

4. **PROSE TOKENS.** New batches must run `migrate-prose-tokens.ps1 -Slugs <batch> -Apply` after specs
   land, or `reanchor-all`'s daily verify hard-fails on the money literals. `wave-publish.ps1` runs it
   as its first execute step (idempotent, and it only swaps a literal that provably equals the stat).

5. **`waved:<k>` is stored as `state: "waved"` plus a `wave: <k>` field**, not as a compound string.
   Same semantics, no string parsing.

## 0. What this is

An upgrade to the existing `recipe-hunter` skill (C:\Codex\ThriftyCrew\.claude\skills\recipe-hunter\SKILL.md).
Today the skill ends at "published-ready write-up; Brad approves, then publish runs separately."
v2 carries every recipe all the way to LIVE on thriftycrew.com with no human in the loop, while
keeping every existing gate. The flow, in one line:

    hunt -> select -> extract -> map -> price -> spec+write -> source-QA -> [accumulate into waves]
    -> batch audit (GO/NO-GO) -> AUTO-PUBLISH -> post-publish review -> ledger close

Per-recipe stages stream (a recipe in QA while another is still being extracted). Publishing is
the one deliberately batched step: QA-passed recipes accumulate into WAVES so the batch auditor
has a batch to audit. This is Brad's flow-chart proposal merged with the existing pinned-agent
estate; the design decisions and their reasons are in section 8.

## 1. What already exists and MUST BE REUSED, not rebuilt

| Piece | Where | Role in v2 |
|---|---|---|
| recipe-sourcer (opus 4.8) | .claude\agents\recipe-sourcer.md | hunt rounds; captures verbatim ingredients at verify |
| recipe-dedup-selector (opus 4.8) | .claude\agents\recipe-dedup-selector.md | per-round dedup + selection |
| recipe-hunter-extractor (fable) | .claude\agents\recipe-hunter-extractor.md | transcription of one page |
| recipe-ingredient-mapper (fable) | .claude\agents\recipe-ingredient-mapper.md | ingredient -> commodity id + food-DB entries |
| commodity-registrar (fable) | .claude\agents\commodity-registrar.md | rules on any proposed NEW commodity id |
| recipe-hunter-pricer (opus 5) | .claude\agents\recipe-hunter-pricer.md | CARRIED / NOT-CARRIED / PENDING per absent term |
| recipe-writer (opus 4.8) | .claude\agents\recipe-writer.md | prose + cards via existing generators |
| recipe-batch-auditor (fable) | .claude\agents\recipe-batch-auditor.md | pre-publish GO/NO-GO per wave |
| post-publish-reviewer (fable) | .claude\agents\post-publish-reviewer.md | live verification per wave |
| ingredient-queue.ps1 | income\grocery\ | durable pricing worklist. ALREADY does term-level dedupe across recipes (recipes[] per term), per-store evidence, Rule B verdicts, self-test. NO CHANGES NEEDED. |
| price-ingredient.ps1 | income\grocery\ | cheap tier-1 answer; reads BOTH boards |
| build-v2-spec.ps1 | income\meal-prep\pipeline\ | modern single-recipe spec intake (canonical db) |
| spec-guards.ps1 | income\meal-prep\pipeline\ | per-spec hard gate (incl. orphaned-ingredient check) |
| build-card2.ps1 | income\meal-prep\pipeline\ | card assembly |
| update-recipes-db.ps1 | income\meal-prep\pipeline\ | writes protein + item_id directly (has -DryRun) |
| publish-recipe.ps1 | .claude\skills\meal-macro\ | Ghost upsert by slug, lexical html card, paid default, -Draft switch |
| batch-ledger.ps1 | income\meal-prep\pipeline\ | transaction ledger; REQUIRED stages: select, map, write, build-specs, audit, recipes-db, build-cards, publish, post-publish-review |
| make-catalog-digest.ps1 | income\meal-prep\pipeline\ | dedup digest for sourcer + selector |

Invariants that do not move: Rule B (one store is enough); unchecked is never not-carried;
extraction is transcription; no stage mints a commodity id without the registrar; the mapper's
evidence gate and null-is-safe rule; writer never computes a number; no em dashes anywhere;
no seafood, no ground chicken; 14-serving scaling; never weaken a gate to pass a recipe;
push every commit immediately.

## 2. New architecture

### 2.1 Recipe state machine (the core of v2)

Every candidate gets exactly one state file: `<RunDir>\state\<slug>.json`. Single writer per
file (whichever stage advances it, via the new hunt-run.ps1 helper only). States:

    sourced -> selected -> extracted -> mapped -> pricing -> priced
            -> spec-built -> written -> qa-passed -> waved:<k> -> published -> verified

Terminal rejections (each carries a reason + evidence pointer):
    rejected-dupe | rejected-unreadable | rejected-not-carried | rejected-qa | rejected-audit

Hold state (NOT terminal, never counted as rejected):
    parked - at least one absent ingredient is PENDING (bot wall / unreached store).
    Parked recipes survive the run end and are listed in the final report for a later resume.

Transitions are append-only history entries: `{state, at, by, detail}`. A stage that finds its
output file already present skips the work (idempotence = resumability). The state file is
written temp-then-rename, with a 3x retry on file-lock (the logger-kills-pipeline lesson:
a transient lock must not kill a run).

### 2.2 Pending-count semantics (from Brad's chart, made race-free)

The recipe-level "pending count" is NOT stored as its own mutable counter (a counter written
after enqueue can race and a recipe could slip through at zero). It is DERIVED, every time it
is read, from ground truth:

    pending(slug) = count of the recipe's absent terms whose ingredient-queue verdict is PENDING
    failed(slug)  = count whose verdict is NOT-CARRIED (non-optional lines only)

    priced  <=> pending == 0 AND failed == 0
    rejected-not-carried <=> failed > 0 (any non-optional ingredient)
    parked  <=> pending > 0 AND failed == 0 AND every checkable store was attempted this run

hunt-run.ps1 computes this by reading `ingredient-queue.ps1 -List -Json` and the recipe's
mapped-ingredients file. The mapping stage enqueues terms with
`ingredient-queue.ps1 -Add -Term <t> -Recipe <slug>` BEFORE advancing the recipe to `pricing`,
so a recipe in `pricing` state always has its full term set on the queue already. Optional
ingredients (optional=true from the extractor) are never enqueued as blocking and never reject
a recipe.

### 2.3 Run directory

    C:\Codex\ThriftyCrew\meal-prep\runs\<run-id>\        run-id: hunt-YYYY-MM-DD[-suffix]
      run.json                conditions, stop condition, wave size, started, digest date, board date
      state\<slug>.json       state machine files (2.1)
      candidates\<round>.json sourcer output per round
      selected\<round>.json   selector output per round (existing selected.json shape)
      extracted\<slug>.json   extractor JSON (its exact output contract)
      mapped\<slug>.json      mapper decision table for the recipe (ids, nulls+reasons, new-id proposals)
      specs\<slug>.json       specs (build-v2-spec output + writer prose)
      cards\<slug>.html       built cards
      qa\<slug>.json          source-QA verdicts
      waves\wave-<k>.json     wave manifest: slugs + per-slug {title, excerpt, metaTitle, metaDesc, visibility, htmlfile}
      waves\wave-<k>.audit.md auditor report (verdict must be parseable: first line GO or NO-GO)
      report.md               final run report (three buckets)

The run dir is committed to the repo with each wave's publish commit. It lives under meal-prep\
(tracked), NOT at income root (the deny-by-default .gitignore would silently ignore a new
top-level dir).

### 2.4 Concurrency model (Workflow tool)

Global cap: at most 12 concurrent agents. Lanes:

- HUNT lane (1 agent at a time): recipe-sourcer rounds loop until Brad's stop condition.
  Each round's prompt includes the digest path AND `<RunDir>\accepted-slugs.json` (all slugs
  selected so far this run) so streaming cannot re-source what an earlier round already took.
- SELECT (1 per round): recipe-dedup-selector adjudicates the round's candidates against the
  catalog digest and against accepted-slugs.json + all prior rounds' pools. Round-internal
  barrier only; earlier rounds' recipes are already downstream.
- EXTRACT / MAP / SPEC+WRITE / QA lanes: per-recipe pipeline() stages, no barriers. Up to
  3 extractors, 2 mappers, 3 writers, 2 QA agents in flight.
- PRICE lane: SINGLETON. Exactly ONE recipe-hunter-pricer alive at any time. Each invocation
  takes a batch of up to 10 absent terms (across recipes - the queue already dedupes terms).
  Inside one invocation the pricer opens its proven-safe shape: 5 browser tabs, one per browser
  store, one search per term, plus the 2 server stores. One-at-a-time is the wall-safety rule:
  N pricers would mean N tabs per store domain and that is the sweep shape that got Walmart
  walled at 55 of 526. The lane loops: snapshot pending terms -> spawn pricer -> record -> repeat
  until the queue drains and no recipe upstream can add more.
- WAVE lane (serial): wave close -> audit -> publish -> post-publish review, one wave at a time.
  A wave being audited never blocks the per-recipe lanes from filling the next wave.

### 2.5 Wave rules

- Default wave size 10 (run.json `wave_size`, Brad can override per run).
- A wave closes when 10 recipes reach qa-passed, OR the pipeline has drained (hunt stopped,
  no recipe upstream of qa-passed can still arrive) and at least 1 recipe is waiting.
- Wave id = `<run-id>-w<k>`. Each wave is a batch-ledger batch: `-Start` at wave close with its
  slugs; stamp select/map/write/build-specs at close (detail: "streamed pre-wave"); then audit,
  recipes-db, build-cards (already built; stamp verifies files exist), publish,
  post-publish-review as they actually complete; `-Close` after review GO.
- Parked and in-flight recipes NEVER hold a wave open. They catch the next wave or the report.

## 3. Stage specs (what the orchestrating skill does at each step)

S0 PREFLIGHT (unchanged from v1, plus run setup):
   refresh catalog digest (make-catalog-digest.ps1, check its date); confirm today's
   grocery\out\comparison-<today>.json exists; run ingredient-queue.ps1 -SelfTest and
   hunt-run.ps1 -SelfTest; create run dir + run.json; ask Brad for stop condition if absent.

S1 HUNT (recipe-sourcer): unchanged contract. Output -> candidates\<round>.json. Orchestrator
   creates state files (state=sourced).

S2 SELECT (recipe-dedup-selector): per round, vs digest + accepted-slugs.json. Selected ->
   state=selected, slug appended to accepted-slugs.json. Rejected -> rejected-dupe.

S3 EXTRACT (recipe-hunter-extractor): one page per agent, exact existing contract. state=extracted.
   `state:"unreadable"` -> rejected-unreadable. The extraction JSON is preserved verbatim; it is
   the QA stage's ground-truth anchor.

S4 MAP (recipe-ingredient-mapper): micro-batches of up to 5 recipes. Exact existing contract
   (evidence gate, label-accurate DB entries, null+reason is safe). Terms that
   price-ingredient.ps1 cannot answer (it reads BOTH boards) are enqueued via
   ingredient-queue.ps1 -Add with the recipe slug, THEN state=pricing. Recipes whose every
   ingredient resolves from disk skip straight to state=priced. Any new-commodity proposal goes
   to commodity-registrar; its ruling is recorded in mapped\<slug>.json and in the final report.
   The run itself never edits commodity files; a registrar-approved new id is a flagged
   follow-up for the capture pipeline, and the ingredient maps with item_id=null meanwhile.

S5 PRICE (recipe-hunter-pricer, singleton lane per 2.4): exact existing contract, including the
   search-verdict ladder, both browser surfaces, per-store identity + In-Store mode proof, and
   ingredient-queue -Record / -Verdict. After each pricer invocation the orchestrator
   recomputes every affected recipe's derived counts (2.2) and advances states:
   priced | rejected-not-carried | parked.

S6 SPEC + WRITE: build-v2-spec.ps1 per recipe (machine fields), then recipe-writer fills prose
   and assembles the card through build-card2.ps1. spec-guards.ps1 must exit 0 for the slug
   before state=written. Writer data-smell flags go to a repair note in the state file; a
   repair pass runs before QA, exactly as r300 did.

S7 SOURCE-QA (NEW agent, recipe-source-qa): per recipe. Compares the built card + spec against
   (a) the extraction JSON, always, and (b) the live source page via WebFetch when the domain
   is fetchable (the sourcer's known-blocked-domain list applies; a blocked domain makes (a)
   the sole anchor and the verdict says so). PASS -> qa-passed. FAIL -> one repair cycle
   (routed to the stage that owns the defect: writer for prose/card, extractor for
   transcription, mapper for mapping), then re-QA. A second FAIL -> rejected-qa. Verdict JSON
   to qa\<slug>.json.

S8 AUDIT (recipe-batch-auditor): per wave, exact existing checklist (macros recompute, cost
   plausibility, mapping precedents, protein stamping via update-recipes-db -DryRun, card
   fidelity, voice + 375px, gates). Report -> waves\wave-<k>.audit.md, first line GO or NO-GO
   naming blockers. NO-GO handling: blocking slugs leave the wave (to repair, or rejected-audit
   after one failed repair); if the blocker is shared data (a map entry, a DB row), fix through
   the owning stage and RE-AUDIT the whole wave; if blockers were only recipe-local, the
   trimmed wave re-audits only the trimmed manifest. The auditor never gets overruled: no GO,
   no publish, no exceptions.

S9 PUBLISH (NEW wave-publish.ps1, then post-publish-reviewer): see D3. On success, dispatch
   post-publish-reviewer scoped to the wave's slugs (its existing concurrent-pipeline clause
   already covers later waves publishing mid-review), stamp post-publish-review on GO, ledger
   -Close. Reviewer findings route exactly as that agent already prescribes.

FINAL REPORT to Brad (report.md + chat): published waves with live URLs; rejected list with
reasons and evidence; parked list with exactly which stores are unchecked and why; registrar
rulings + follow-ups; auditor and reviewer verdicts; ledger status. The three buckets are
never rounded into each other.

## 4. Deliverables for Opus

### D1. income\meal-prep\pipeline\hunt-run.ps1 (NEW, ~350 lines)

The state-machine + wave helper. PS 5.1, follows guard-contract.ps1 conventions and the
ps51-json traps (always @()-wrap ConvertFrom-Json results, -Raw + UTF8 reads, no -AsHashtable).

    -Init -RunDir <p> -Conditions <s> -Stop <s> [-WaveSize 10]     creates run.json + dirs
    -Advance -RunDir <p> -Slug <s> -To <state> -By <stage> [-Detail <s>]
        validates the transition against the legal graph (illegal transition = exit 1),
        appends history, temp+rename write, 3x lock retry
    -Derive -RunDir <p> [-Slug <s>]
        recomputes pricing-derived states (2.2) from ingredient-queue -List -Json +
        mapped\<slug>.json; advances pricing -> priced | rejected-not-carried | parked;
        also moves parked -> priced when a resumed queue resolves
    -WaveClose -RunDir <p>
        collects qa-passed recipes up to wave_size into waves\wave-<k>.json (manifest fields
        from specs), advances each to waved:<k>, starts the batch-ledger batch, stamps the
        streamed stages. Refuses (exit 1) to include any slug not in qa-passed state.
    -Status -RunDir <p> [-Json]
        the whole run at a glance: counts per state, three buckets, open waves, queue summary.
        This is also the resume entry point.
    -SelfTest
        hermetic (temp dir), per the guard-fixture rule each check is a must-fire founding-bug
        fixture plus a clean twin. Minimum fixtures:
        (1) a recipe with one PENDING term derives parked, never rejected (the chart's
            0-stores-discard bug, our founding reason);
        (2) a recipe with one non-optional NOT-CARRIED term derives rejected-not-carried;
            optional-term twin stays priced;
        (3) -WaveClose refuses a slug in state written (not qa-passed); clean twin closes;
        (4) illegal transition (published -> mapped) refused;
        (5) state file round-trips with history intact through temp+rename.

### D2. .claude\agents\recipe-source-qa.md (NEW agent)

Frontmatter: `name: recipe-source-qa`, `model: fable`, `effort: medium`,
`tools: WebFetch, Read, Grep, Glob, Bash, PowerShell`.

Body must specify (write it in the same voice and rigor as the existing agent files):
- Mission: last per-recipe fidelity check before wave assembly. You verify the recipe we are
  about to sell matches the recipe we actually found. You check fidelity, not taste.
- Inputs: slug; paths to extracted\<slug>.json, specs\<slug>.json, cards\<slug>.html; source URL.
- Anchor rule: the extraction JSON is ground truth for what the page said. Re-fetch the live
  page as a second anchor when fetchable; if the fetch fails or the domain is on the known
  blocked list, say so in the verdict and judge from the extraction alone. NEVER treat an
  unfetchable page as a finding against the recipe.
- Checks: (1) every non-optional extracted ingredient appears in the card, and every card
  ingredient traces to an extracted line (scaling to 14 servings goes through one consistent
  ratio; flag any single-ingredient drift beyond rounding); (2) instructions preserve the
  method (no invented components, no dropped components, technique-changing rewrites flagged);
  (3) title names the same dish; (4) source credit present and pointing at the right URL;
  (5) servings/scale claims in prose are consistent with the spec; (6) prose numbers match
  spec numbers exactly (transcription check, the writer's own contract).
- NOT your job: macros, costs, mapping, voice, gates (the batch auditor owns those); never
  edit anything; never re-extract.
- Output: strict JSON verdict to qa\<slug>.json:
  `{slug, verdict: "pass"|"fail", anchors: ["extraction","live-page"], findings: [{check, severity, detail, owner: "writer"|"extractor"|"mapper"}], notes}`.
  Uncertain-but-material = fail with a question, never a shrug (same rule as the auditor).

### D3. income\meal-prep\pipeline\wave-publish.ps1 (NEW, ~200 lines)

The ONLY sanctioned path from a green audit to live posts. PS 5.1, guard-contract conventions.

    wave-publish.ps1 -RunDir <p> -Wave <k> [-DryRun]

PREFLIGHT (any failure = exit 1, nothing published; these are production-called gates, each
with a -SelfTest fixture per the guard-fixture rule):
 1. waves\wave-<k>.audit.md exists and its first line is exactly GO, and the batch-ledger has
    an `audit` stamp for `<run-id>-w<k>`. MUST-FIRE fixture: a NO-GO or missing stamp refuses.
 2. Every manifest slug's state is `waved` with `wave == k` (an already-published slug passes, so a
    resume works); the v2 spec exists in db\recipes. CORRECTED per 0a.2: NOT spec-guards.
 3. The v2 spec audits, re-run today rather than trusted from earlier: audit-spec-contradictions.ps1,
    audit-store-integrity.ps1, test-guards.ps1. Any red = refuse. (audit-db-agreement runs inside
    propagate at the point where the two recipe masters can actually be compared.)
 4. DEDUP ESCAPE GUARD: query Ghost by slug (lib\ghost-lib.ps1 admin JWT). A slug that already exists
    live and is NOT in db\published-hashes.json = hard stop: that is a dedup escape or a hand-made
    post, and upserting over it is how a hand-freed dinner gets clobbered. A non-404 error on the
    check is also a stop - could-not-look is never a clean bill on a collision guard.
 5. update-recipes-db.ps1 -DryRun (-SpecsDir db\recipes -SpecList <wave slugs>) for the delta.

EXECUTE, in order, ledger-stamped AFTER each step completes (checkpoint-before-durable):
 6. migrate-prose-tokens.ps1 -Slugs <wave> -Apply   (0a.4; idempotent, equality-gated).
 7. update-recipes-db.ps1 for real; stamp recipes-db.
 8. propagate-recipes.ps1 -DryRun to capture the dirty set, and REPORT any dirty spec outside this
    wave (propagate carries everything dirty by design; it must be said, not silently attributed
    to this wave). Then propagate-recipes.ps1 for real: sync-recipesdb-buy -> audit-db-agreement
    HARD GATE -> gen-planner-data -> build-cards -Slugs -> engine\publish.ps1 -Slugs (hash-gated,
    visibility-PRESERVING, live-verified). Require its COMPLETE line, not just rc=0. Stamp
    build-cards and publish.
 9. git add ONLY an explicit path list (run dir, recipes-db, the wave's db\recipes + db\built files,
    costed, published-hashes, ledger, propagate-stamps, v2-perserving, planner-data), then commit
    and push IMMEDIATELY (the push is the deploy; per the push-data lesson, NEVER `git add -A`).
10. Advance each slug to `published`, print the live URLs, and print the exact post-publish-review
    and ledger-close commands. Post-publish review is dispatched by the orchestrator, not this script.

### D4. Rewrite .claude\skills\recipe-hunter\SKILL.md

Keep: the two rules that decide everything (verbatim), the concurrency imperative, the
preflight, all five existing stage-notes lessons, the three-bucket reporting rule.
Change:
- Pipeline diagram: the v2 flow (section 0 above) with the state machine, the singleton price
  lane and its wall-safety reason, wave semantics, and hunt-run.ps1 / wave-publish.ps1 as the
  only sanctioned state and publish mechanisms.
- Add stage notes for source-QA (anchor rule; one repair cycle then rejected-qa) and for waves
  (a wave never waits on parked recipes; NO-GO handling per S8).
- REPLACE the "Do not publish" rule with: "Publishing is automatic and goes ONLY through
  wave-publish.ps1 after a wave's audit reads GO. Never call publish-recipe.ps1 directly from
  this flow. Brad is not a gate anymore; the batch auditor and the post-publish reviewer are.
  A wave that cannot get a GO is reported, never forced."
- Keep "do not write board cells" and "do not weaken a guard" verbatim.
- Resume section: `hunt-run.ps1 -Status` is the entry point; stages skip work whose output
  file already exists; the parked bucket is the resume worklist.

### D5. batch-ledger integration

No code change to batch-ledger.ps1. Convention only (documented in SKILL.md): one batch per
wave, id `<run-id>-w<k>`, stages mapped as in section 2.5. The existing -Verify daily catch
(open batch older than 24h = finding) now watches hunter waves for free.

## 5. Failure policy (single table, no ambiguity)

| Event | Policy |
|---|---|
| Source page unreadable | rejected-unreadable, listed in report |
| Duplicate (catalog or pool) | rejected-dupe with dupe_of |
| Non-optional ingredient NOT-CARRIED (all 7 checked) | rejected-not-carried, evidence in queue |
| Ingredient PENDING (wall/unreached) | recipe parked, run continues, report lists exact stores |
| Optional ingredient anything | never blocks, never rejects |
| spec-guards red | recipe held at spec stage; fix through owning stage; guard never weakened |
| Source-QA fail | one owner-routed repair cycle, re-QA; second fail = rejected-qa |
| Wave audit NO-GO | blockers leave wave (repair or rejected-audit); shared-data fix = full re-audit |
| Publish fail (one slug) | ledger shows partial; rerun wave-publish (idempotent); persistent fail = needs-brad in report |
| Post-publish findings | reviewer's own contract: fix via gated paths, or triage-queue needs-brad |
| Bot wall mid-pricing | that store = blocked for the batch, terms stay PENDING, singleton lane continues with other stores next invocation |

## 6. Acceptance tests (Opus runs all of these before calling it done)

 1. Self-tests green: ingredient-queue.ps1 -SelfTest (unchanged, must still pass),
    hunt-run.ps1 -SelfTest, wave-publish.ps1 -SelfTest, test-guards.ps1.
 2. Must-fire, live: create a throwaway run dir with a fabricated wave whose audit file reads
    NO-GO; wave-publish.ps1 must refuse (exit 1) before any Ghost call. Flip to GO with the
    ledger stamp present; -DryRun must walk all 8 steps and print the would-be calls.
 3. Transition audit: attempt hunt-run -Advance from written straight to waved (skipping
    qa-passed): refused.
 4. Resume drill: mini-run of 2 to 3 candidates through S3, kill the session, re-enter via
    -Status, confirm no stage re-runs (output files untouched by timestamp) and the run
    completes through S7 with publish in -DryRun.
 5. End-to-end shakedown (Brad-visible): one real micro-run, conditions "2 recipes, any
    protein", wave size 2, with wave-publish run WITHOUT -DryRun but manifest visibility
    forced to draft via publish-recipe's -Draft. Verify drafts in Ghost admin, run
    post-publish-reviewer against the drafts, then delete the two drafts and the state is
    clean. Only after this passes does the skill text drop any mention of drafts: production
    runs publish live.

## 7. Explicitly out of scope

- No changes to any existing pinned agent file (the 10 in section 1).
- No changes to ingredient-queue.ps1, spec-guards.ps1, build-card2.ps1, batch-ledger.ps1.
- No board cell writes, no commodity file edits, no capture-pipeline changes.
- No new Ghost surface: publish-recipe.ps1's lexical-card path is the only publisher.
- No parallelizing the price lane. If throughput is ever a problem, that is a measured
  decision for Brad (speed-measured-not-guessed), not a default.

## 8. Design decisions already made (do not relitigate in implementation)

- Auto-publish approved by Brad 2026-08-15; the human gate is replaced by audit + review + report.
- Waved publish over per-recipe publish: the batch auditor needs a batch; latency cost accepted.
- Pending counts derived, never stored: kills the enqueue/complete race by construction.
- Singleton pricer: wall-safety over throughput, per the 526-term sweep evidence.
- Discard requires 7 definitive answers: Rule B + unchecked-is-never-not-carried, both measured.
- QA gets one repair cycle: unbounded repair loops hide systemic defects; the second failure
  is signal, and rejected-qa recipes are cheap to revisit manually.
- Wave size 10: big enough for the auditor's cross-recipe checks, small enough that a NO-GO
  quarantines little. Configurable per run.
