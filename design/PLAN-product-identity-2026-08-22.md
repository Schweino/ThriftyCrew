# PLAN: Product Identity as the spine of the grocery estate

**Status:** approved design, not yet built. Brad's rulings 2026-08-22 are recorded in §2.
**Builder:** an Opus session. **This document is the spec.** Build from it, not from the SKILL card or a summary of it.
**Scope:** the commodity-matching system and the audit chain around it. NOT the browser capture lanes (a separate session owns those), NOT the Recipe Hunter.

---

## 0. Why this exists (the measured problem)

On 2026-08-22 the end-to-end review measured the daily chain at 27–42 minutes on a 32-thread machine idling at 14% CPU. Three diagnoses were tried and two were wrong; the numbers below are the ones that survived measurement:

| claim | measured | verdict |
|---|---|---|
| "60 processes re-parsing 40 MB" | every major JSON parses in 0.1–0.4 s; all of them ≈ 1 s | wrong |
| "process startup overhead" | 107 ms per `powershell` spawn; 1.5 s across 14 | wrong |
| regex volume | 67,200 patterns (1,458 include / 65,742 exclude), **2,290 distinct excludes**, `\bwipes\b` stored 533× | real but already neutralised by the compiled matcher |
| **one rule, twenty interpreters** | `match-lib.ps1` (compiled C#, inverted index) matches the whole corpus in ~1 s and is used by 2 scripts; **20 other scripts carry their own interpreted copy** of the decision (`audit-match-soundness` 111 s, `audit-household-in-food` — a HARD gate — `coverage-gaps`, `aisle-test`, `discover-hyvee`, `audit-semantic-identity` ~90 s corpus prep, `build-deals-page`, `sale-fallback`, …). Five of them `Invoke-Expression` the function's source text scraped out of `compare-deals.ps1`. | **the real problem** |
| daily churn | under the quarterly rotation a store's product names change by ~0–14/day (Family Fare +2, Hy-Vee +0, Fareway +4 on 08-22) | the answer is stable; we recompute it 20× daily |

The underlying idea, which every part of this plan follows from:

> **A product is an immutable fact.** "Great Value Cinnamon Applesauce, 48 oz Jar" at Walmart means the same thing tomorrow. Its commodity assignment changes only when a *rule* or a *ruling* changes. Store the fact once; make everything else a lookup or a query.

What grows, and what the plan must survive: more **products** (10× is fine today), more **commodities** (today each new one is hand-written regex plus 110 cloned excludes), more **stores/cities**, more **audit stages** (today a 2,200-line serial chain), and **accuracy** (the #1 defect class is identity — the wrong product wearing a crown — defended by regex with no confidence and no memory).

---

## 1. What must NOT change (invariants)

These are the estate's load-bearing rules. A step that violates one is wrong even if it is faster.

1. **The matching answer is byte-identical.** First-match-wins in `commodities.json` file order; excludes tested on the RAW lowercase name; includes on raw + the normalised variant (`Get-MatchTexts`); `relax_global` by exact pattern-string equality; `category-excludes.json` and `recipe-commodities.json` semantics unchanged. Proven on the full live corpus by `test-match-lib.ps1` / `test-matcher-parity.ps1` on every change — not reasoned about once.
2. **Advisory never blocks; BLIND is not a pass.** Exit 3 = could-not-evaluate. A check that examined zero rows says so. (`lib\guard-contract.ps1`, `audit-guard-contract.ps1`.)
3. **Guards must still be able to fail.** `test-guards.ps1` (hermetic, via `run-test-guards-weekly.ps1`) breaks each invariant in a scratch tree and asserts `guards.ps1` exits 2 with that guard's own text. Every case must pass identically after every step.
4. **Single-writer rule for `product-urls.json`** (README §SINGLE-WRITER). Nothing in this plan adds a writer.
5. **Provenance-first** in `graph/` (`graph/schema.md` commitment 1): every node/edge/assertion carries a `provenance_id`; `record_provenance()` is the only minting path; the verifier fails on an orphan.
6. **Truth is tracked JSON; `graph/sqlite/graph.db` is a rebuildable index** (schema commitment 3). Nothing may exist only in the DB.
7. **No `2>&1` / `2>$null` on a native child under `$ErrorActionPreference='Stop'`** (`test-native-stderr-eap.ps1` scans for it). Capture by file or read `$LASTEXITCODE`.
8. **No library declares `param()` at file scope** (`capture-policy-lib.ps1` header, `browser-feeds-lib.ps1`). Extract functions by AST/sentinel; never dot-source a CLI script.
9. **PowerShell 5.1 edits are made directly, never via generated string patches.** Three production defects on 2026-08-22 came from Python `\n`/`\b`/`\a` escapes silently mangling `.ps1` text. "Parse ok" proves syntax, not that a comment is still a comment.
10. **Anything that iterates products × rules runs in compiled code** (C# `Add-Type`, as `match-lib.ps1` does) **or in Python/SQLite. PowerShell orchestrates.** This is the compute-placement rule; the 139-second categorize loop is what violating it looks like.

---

## 2. Decisions already made (Brad, 2026-08-22)

| decision | ruling |
|---|---|
| Where the identity table lives | **graph's SQLite** as the index; tracked JSON as truth (per invariant 6) |
| What a product IS (the key) | **(store, product_id)**, with normalised name as the fallback key for rows without an id |
| Scope of this build | **All five steps** (§4) |
| Sidecar/ML verdicts once in the table | **Advisory only; a human confirms.** Scores rank the escalation queue; nothing moves a crown without a human ruling or an existing adjudicated verdict |

Also standing: the 90-day quarterly capture policy is the only carry window (no 14-day concept anywhere); Walmart rollbacks carry a 30-day TTL from detection; alerts are queued to `triage-queue.json` and email is muted.

---

## 3. Target architecture

```
                 commodities.json / recipe-commodities.json / category-excludes.json
                                        │  (rules; hashed -> rules_hash)
                                        ▼
   store captures ──► match-lib (C# core) ──► PROPOSALS ──┐
   (out\regular, ads)                                      │
                                                           ▼
   rulings: known-wrong, verdict-suppressions,      ┌─────────────────────┐
   discovery-verdicts, graph question_verdicts ───► │ PRODUCT IDENTITY    │ ◄── sidecar scores (advisory)
   (one precedence order)                           │ (store, product_id) │
                                                    │ → commodity,        │
                                                    │   how, confidence,  │
                                                    │   rules_hash, dates │
                                                    └─────────┬───────────┘
                                                              │ (tracked JSONL truth → graph.db index)
              ┌──────────────────┬──────────────────┬─────────┴───────────┬────────────────────┐
              ▼                  ▼                  ▼                     ▼                    ▼
        compare-deals      audits as QUERIES    provenance line     escalation queue     rule-change impact
        (board build)      (soundness, gaps,    on every board      (new/contested       (= table diff across
                           household, aisle…)   cell                only)                rules_hash)
```

Daily work is proportional to **new (store, product_id) pairs**, not to the catalog. Everything else is a lookup.

---

## 4. The five steps

Each step ships alone, is reversible, and ends with a clean green `check-ad-cycles` run on the main tree. Do not start step N+1 until step N has run on at least one real morning.

### Step 1 — The identity table, emitted by the engine, with a parity gate

**What.** `compare-deals.ps1` already computes every product's assignment via `match-lib`. Make it *emit* that as a first-class artifact.

- **Truth file:** `graph/identity/<store>.jsonl` — tracked, append-only assertions, **one per (store, product_id, namespace)**. Fields: `store`, `product_id` (or `name_key` when no id — see §5.1), `key_kind`, `name`, `name_key` (the normalised name the rules actually saw), `namespace` (`staple` | `recipe` — see §10.1), `commodity` (namespaced id as graph uses: `commodity:staple:<id>`, or null = "no commodity under these rules"), `how` = `rule`, `include_hit` (the exact pattern text that fired), `excludes_tested` (count), `candidates` (every other commodity in this namespace whose include hit AND whose excludes all missed — this is what `match-soundness` calls "contested"), `rules_hash`, `first_seen`, `provenance_id`. **No `last_seen` in the truth file** — it would turn append-only into rewrite-daily; last-seen is derived from captures in the index.
- **Index:** `graph/import/import_all.py` gains an importer that upserts these into `graph.db` as `ProductSKU` nodes + `instance_of` edges (3,443 / 3,412 exist today from `product-urls.json`; this supersedes and widens that source). Deterministic ids per `graph/lib/ids.py`.
- **`rules_hash`** = SHA-256 over the byte content of `commodities.json`, `recipe-commodities.json`, `category-excludes.json`, and `match-lib.ps1`'s `$GLOBAL_EXCLUDE` source. Same hash → assignment is reusable. Different hash → full rematch (see step 1c).
- **Incremental:** on a run whose `rules_hash` matches the table's, only names not present in the table are matched. Measured churn makes this tens of names/day.
- **Parity gate (HARD, in `guards.ps1`):** for every board cell in today's comparison, the product's `instance_of` in the table must equal the commodity `compare-deals` priced it under. Zero disagreements or the publish holds. This replaces `audit-match-soundness`'s self-check with something that cannot drift, because there is no second implementation.
- **Provenance line:** `build-deals-page.ps1` renders, per cell, `matched by <include_hit>; <n> excludes tested` (hidden until a row opens, like the chips). Today "why is this the crown?" has no answer anywhere.

**Acceptance.** (a) identity table byte-identical across two runs with no rule change; (b) parity gate: 0 disagreements on the live board, and a fixture that forces one disagreement makes guards exit 2; (c) `test-match-lib`, `test-matcher-parity`, `test-guards`, `test-auditors` pass identically; (d) ship-path time not worse than before (the write is small).

### Step 2 — One verdict store with one precedence order

**What.** Four files today hold adjudicated negatives/positives, and four scripts re-implement "is this product banned here?": `grocery/known-wrong.json`, `grocery/verdict-suppressions.json`, `grocery/discovery-verdicts.json`, and graph's `question_verdicts` (4,141 rows, the LLM-rejected / human-confirmed set). Fold them into the identity table as rulings with `how ∈ {human, llm_rejected, cross_encoder, rule}` and an explicit precedence:

`human ruling > adjudicated verdict (known-wrong / suppression) > rule proposal > sidecar score (advisory, never decides)`.

- The existing writers (`add-known-wrong.ps1`, `record-sample-verdict.ps1`, `promote-verdicts.ps1`, graph's `review_escalations.py`) keep their CLIs and write through one library function, so no human workflow changes.
- The legacy JSON files are kept in lockstep by the same write (additive), then retired only when every reader has moved (step 3).
- **Precedence tests:** a fixture where a rule proposes A, a known-wrong forbids A, and a human rules B must yield B; remove the human ruling → no assignment (not A); remove the known-wrong → A.

**Acceptance.** Every row in the four legacy files is present in the table with its source; `test-auditors` fixtures for known-wrong (`audit-known-wrong`) and suppressions still fire; the board is byte-identical before/after.

### Step 3 — Audits become queries; the twenty copies are deleted

**What.** Migrate each script that re-implements matching to read the table (SQLite via the existing `graph/lib/graphdb.py`, or the JSONL for PowerShell readers — pick per script, say which and why). One script per change, each proven against its own previous output on the live tree before its copy is deleted.

Order (cost first): `audit-match-soundness` (111 s → a diff of two rules_hash snapshots: MOVED/DROPPED/contested fall out of a join); `audit-semantic-identity` corpus prep (~90 s → a read); `audit-household-in-food` (HARD gate — becomes a query over `commodity` × product class; migrate with a must-fire fixture proving it still exits 2 on the founding Lysol/mango case); `audit-coverage-gaps`; `aisle-test`; `discover-hyvee`; `audit-sale-fallback`; `build-deals-page`; then the long tail (`apply-coverage-batch`, `triage-coverage-gaps`, `explain-coverage-gap`, `validate-fills`, `notify-item-added`, `resolve-*`, `diag-ff`, `export-identity-eval`, `promote-verdicts`, `audit-match-contested`, `audit-ff-carry`).

- Delete the five `Invoke-Expression`-over-scraped-source sites (`audit-household-in-food.ps1`, `audit-match-contested.ps1`, `audit-match-soundness.ps1`, `validate-fills.ps1`, and the one in `check-ad-cycles.ps1`). Also the same class in `build-walmart-deals.ps1:83-88`, `build-sams-deals.ps1:56-61`, `import-walmart-batch.ps1:40-54`, `import-instacart-batch.ps1:64-69`, which lift `Get-UnitPrice`/`Get-PackCount`/`Convert-ToUnit` out of `compare-deals.ps1` by regex — extract those into `pricing-lib.ps1` and dot-source it (coordinate: the browser-lane session owns the Walmart/Sam's builders; land `pricing-lib.ps1` first, let them adopt it).
- `audit-guard-contract.ps1` must still see every detector called (its DEAD/HALF-COVERED checks). A migrated audit keeps its completion marker.
- The coverage ratchet (`audit-coverage-ledger.ps1`) reads receipts each check writes; a migrated check keeps writing its receipt with `examined`/`eligible` counts, or the ratchet reports it BLIND.

**Acceptance.** Per migrated script: identical findings on the live board vs. the pre-migration copy (diff the output JSON); its `test-auditors` fixtures pass; the guard-contract roster is unchanged. Overall: `audit-match-soundness` < 5 s; semantic prep < 5 s; zero `Invoke-Expression` of scraped source anywhere in `grocery\`.

### Step 4 — Product classes replace cloned exclude blocks

**What.** The ~110-pattern boilerplate that `new-commodity.ps1` clones onto every commodity (pet, baby, household, candy, supplement, prepared, beverage, …) is a **classifier**, not 533 exclude lists. Make it one.

- **Classes** live in `grocery/product-classes.json`: `{class: [patterns...]}` — built by de-duplicating the 65,742 excludes into their 2,290 distinct patterns and grouping the shared ones (`category-excludes.json` already names twelve such classes; reconcile, do not duplicate).
- Each product gets its **class(es)** computed once (compiled code, same engine) and stored in the identity table.
- Each commodity declares `accepts_classes` plus its genuinely commodity-specific excludes. **The default is NOT "food only"** — the board has a `household` category (`laundry-detergent`, `furniture-polish`, `all-purpose-cleaner` are live commodities) and `recipe-commodities.json` deliberately *relaxes* sauce/canned/frozen/juice via `relax_global`. The default `accepts_classes` is derived per commodity from `categories.json` plus a migration rule (§10.4), never assumed. The per-commodity exclude array shrinks from ~110 to the handful that are actually about that commodity.
- `new-commodity.ps1` stops cloning: a new commodity is includes + class names. `add-commodity-rule.ps1` gains `-Class`.
- **Semantics preserved exactly:** "product P is excluded from commodity C" ⇔ "P's class ∉ C.accepts_classes OR a C-specific exclude matches P". Prove by: identity table byte-identical before and after the migration, on the full corpus, under the old and new storage.

**Acceptance.** Identical table; `commodities.json` exclude count drops from 65,742 to the specific remainder (report the number); `audit-household-in-food` becomes a one-line query (`class=household AND commodity is food`); fixing a boilerplate pattern is one edit.

### Step 5 — Declared stages and a dependency-aware runner

**What.** `check-ad-cycles.ps1` is ~2,200 lines of serial orchestration; adding a stage is a line in the middle, and the naive parallelism attempted on 2026-08-22 made it 35% slower because stage independence was guessed. Replace guessing with declaration.

- **`grocery/stages.json`:** one entry per stage — `name`, `script`, `args`, `reads` (repo-relative globs), `writes`, `phase ∈ {ship, inspect}`, `budget_sec`, `gate` (ship-critical / advisory), `cadence` (optional; subsumes today's `Test-CadenceDue` timers).
- **Runner** (`grocery/run-stages.ps1`, orchestration only — invariant 10): topologically orders by reads/writes; **skips a stage whose declared inputs are content-unchanged since its last successful run** (fingerprint = hash of inputs, recorded per stage); **runs provably-independent stages concurrently** (disjoint writes, no read-after-write edge) with the existing bounded-child helper (`Invoke-Bounded`: Start-Process, tree-kill on timeout, rc 3 = BLIND); emits `out/logs/run-manifest-<date>.json` — what ran, why (or why skipped), duration, inputs hashed, exit code.
- **Incremental adoption:** stages declared in `stages.json` run through the runner; undeclared ones run exactly where they are today. Migrate the INSPECT phase first (advisory, low blast radius), SHIP last.
- **The known orderings from the 2026-08-22 dependency map are declared, not remembered:** `audit-name-drift` before `prune-bad-links` AND re-run after it (the cycle that blocked publish three times); `discover-hyvee` → `build-arrivals-docket`; `audit-sale-fallback` → `resolve-worklist`; `export-feed` → `compute-v2-perserving`; `audit-capture-eviction` after the consistency republish; `prune-out` after every reader of "newest comparison"; `audit-coverage-ledger -Phase cycle` strictly last.
- `capture-watchdog.ps1` reads the manifest (it already reads `capture-run-status.json`).

**Acceptance.** Run manifest present for every run; a stage with unchanged inputs is skipped and the manifest says so; `test-guards`, `test-auditors`, `audit-guard-contract`, `test-native-stderr-eap` pass; the invocation census (every `.ps1` stage invoked the same number of times on a full-inputs-changed run) is unchanged; the SHIP phase is not slower than the serial baseline (measure, don't assume — the 2026-08-22 parallel attempt failed this exact test).

---

## 5. Design details the builder will need

### 5.1 The identity key
- `product_id` sources: Kroger `product_id` (Baker's, 7,289/7,289 rows carry it); Hy-Vee `product_id` (GraphQL); Walmart/Sam's item ids from `__NEXT_DATA__`; Family Fare Freshop `id`/`canonical_url`. Aldi and Fareway rows may lack a stable id → fallback `name_key` = the normalised name from `Get-MatchTexts` `[1]`, prefixed `name:`. Record which key form was used (`key_kind`).
- A product whose name changes under the same id keeps its rulings. A product with only a name key that is renamed is a new unknown — accepted cost, documented.

### 5.2 Sidecar integration (step 3 onward)
`sidecar/sweep.py` today re-scores the whole corpus and re-emits the same findings daily (51 on 08-22) for a human to re-triage; the on-disk score cache (`sidecar/score_cache.py`, added 08-22) makes a warm run ~4 s. Pointed at the identity table it scores only rows with `how=rule` and `last_scored_rules_hash ≠ rules_hash` or no score, writes `cross_encoder_score` + `scored_at` into the row, and **never sets `commodity`** (Brad's ruling). `audit-semantic-identity.ps1` becomes a query: rows where the score contradicts the rule proposal above the calibrated threshold → escalation queue, ranked by score × board impact (a contested crown outranks a contested runner-up).

### 5.3 Rule-change impact
Today `apply-coverage-batch.ps1` re-runs the categorize loop 3–4× per attempt (~10 min) to see what a rule edit moved. With the table: compute proposals under the new `rules_hash` for the whole corpus (~1 s in the C# core), diff against the stored assignments → MOVED / DROPPED / GAINED per commodity, with the include that fired on each side. That diff IS the review artifact; `-Accept` writes the new hash. `audit-match-soundness`'s baseline file (`out/audit/match-baseline.json`) is retired in favour of the table at the previous hash.

### 5.4 Migration order inside step 3 (why this order)
Cost first, risk last: the two 100-second advisories first (pure speed, nothing blocks); then the HARD gate (`household-in-food`) with its must-fire fixture; then the builders that render (`build-deals-page`) last, because they are on the ship path.

### 5.5 Coordination with the browser-lane session
That session owns `pull-browser-stores.py`, `build-walmart-deals.ps1`, `build-sams-deals.ps1`, `build-fareway-regular.ps1`, `build-aldi-regular.ps1` and carry-forward for the walled stores. This plan must not edit those files. Where step 3 needs them to stop scraping `compare-deals` (5.3 above), land `pricing-lib.ps1` and hand them the one-line adoption.

---

## 6. Verification discipline (applies to every step)

- **Before touching a file, measure.** Record the stage's wall clock and output on the live tree; the same after. Report both. An improvement claimed without the before number is not a result.
- **Proven identical, not reasoned identical.** Every matching change runs `test-match-lib.ps1` + `test-matcher-parity.ps1` over the full live corpus.
- **Gates can still fail.** `test-guards.ps1` hermetically, case-for-case identical. One run per step is enough — do not run before-and-after of a 15-minute suite to verify a 60-second change (2026-08-22 lesson: verification cost 30 min for a 1-min win).
- **Census.** `test-auditors` + a grep census that every stage script is still invoked the same number of times after a reorder.
- **Commit per step, push when green.** Bot-commit paths only (`capture-run.ps1` publish stage); never `git add -A` in the shared working tree.
- **Work in a worktree; merge to main; verify on main.** Gitignored `out\` data is absent in worktrees, so suites that read the live board must be run on main after merge.

---

## 7. Risks and what to do about them

| risk | mitigation |
|---|---|
| Two truths: table vs `commodities.json` | the table is DERIVED (rules_hash) + OVERRIDDEN (rulings); a rules_hash mismatch invalidates derived rows automatically; the parity gate hard-fails any board cell that disagrees |
| A ruling silently outranking a correct rule | precedence tests (step 2); every ruling carries `ruled_by`/`ruled_on`/`evidence`; `decision_log` in graph records the change |
| Name-keyed products losing rulings on rename | documented; `key_kind=name` rows reported in the escalation queue when a near-identical new name appears (the sidecar's job) |
| Ratchet blinded by migrated audits | every migrated check keeps its receipt; `audit-coverage-ledger` is run after each migration and must show no BLIND |
| Runner parallelism re-creating the 08-22 regression | parallel only on declared-disjoint stages; the acceptance test is "SHIP phase not slower than serial", measured |
| `graph.db` lock contention (resolver, local_triage, the chain) | writers go through `graph/lib/graphdb.py`; the chain is the single daily writer; ad-hoc tools open read-only (`mode=ro`) as `local_triage.py` already does |
| Escapes mangling `.ps1` | invariant 9: direct edits only; after any edit, a sweep for orphaned lines/control characters (the 08-22 sweep script is in the session scratchpad and trivial to recreate) |

---

## 8. What is deliberately NOT in this plan

- Porting the matcher to Python. The C# core is the fastest component in the estate; the problem was never the engine.
- Replacing the regex proposer with graph's resolver. Its missed-merge is 0.359 against a ≤0.10 gate. It can propose into the table later, as another `how`, once it clears its own bars.
- Changing any matching semantics, sale/TTL policy, or the 90-day carry.
- Touching the browser capture lanes.

---

## 9. Expected outcome (to be measured, not promised)

| | today | after |
|---|---|---|
| matching work per run | ~20 full recomputations | 1 incremental pass over new names |
| `audit-match-soundness` | 111 s | ~2 s |
| `audit-household-in-food` | copy that can drift (hard gate) | query; cannot drift |
| semantic corpus prep | ~90 s | ~1 s |
| rule-change impact | ~10 min per attempt | seconds |
| "why is this the crown?" | unanswerable | one line per cell |
| fixing a boilerplate exclude | 533 edits | 1 |
| adding a commodity | regex + 110 cloned excludes | includes + class names |
| adding a stage | a line in a 2,200-line chain | a `stages.json` entry |
| daily chain (after steps 1–5, excluding store API time) | ~14 min + captures | single-digit minutes + captures |

Store API time (Freshop pacing, browser-driven stores) is not addressed here and is not reducible by this plan.

---

## 10. Pre-build review: gotchas found re-reading this plan (2026-08-22, same day)

Each of these would have cost the builder a day or produced a wrong table. They are ordered by how badly they would have hurt.

### 10.1 The table is per NAMESPACE, not per product — the first draft had this wrong
`graph/schema.md` is explicit: the `staple` and `recipe` commodity namespaces are NOT merged, because staple `ground-turkey` and recipe `93-7-ground-turkey` are different purchases. `compare-deals` is run a second time with `-CommoditiesFile recipe-commodities.json` (by `recipe-overlay.ps1`), so **one SKU legitimately carries one assignment per namespace, and they differ**. The key is `(store, product_id, namespace)`; the parity gate compares each board against its own namespace; rule-change diffs are per namespace. A table keyed on product alone would have overwritten the staple answer with the recipe answer every run.

### 10.2 The tracked truth file must be on the bot-commit path, or it never leaves this PC
`capture-run.ps1`'s publish stage stages an explicit `$inputPaths` list (never `add -A`). `graph/identity/` must be added to that list in step 1, or the table is regenerated daily and never committed — which is exactly the last-mile failure found on 2026-08-22 (`public/board.json` rebuilt every morning, last bot commit four days old). The cloud backup (`daily.yml`, clean clone) rebuilds `graph.db` from tracked JSON, so this is also what makes the table exist there at all.

### 10.3 Invalidate on NAME change, not only on rules change
A Kroger/Hy-Vee `product_id` is stable across a size or label variant; the rules match the *name*. So a row is reusable only when BOTH `rules_hash` matches AND the stored `name_key` equals today's `Get-MatchTexts` normalised name. Otherwise re-match. (Guards already see this class: "REFUSED (productId is a different size than our row)".) Also: `name_key` must be computed AFTER `heal-mojibake` normalisation, or the same product appears twice.

### 10.4 Product classes: a boilerplate pattern is deliberately ABSENT from some commodities
`detergent` is in 530 of 588 exclude lists — it is missing from `laundry-detergent`; `\bcleaner\b` is missing from `all-purpose-cleaner`. A class may be attached to commodity C **only if every pattern of that class is present in C's current exclude list**; any class with a pattern C lacks stays expressed as C-specific excludes (or C declares the class with an explicit `except:` list — builder's choice, but it must be mechanical). The identity table byte-identical before/after is the proof, but the migration must be an algorithm, not a hand edit of 588 entries. Reconcile with `category-excludes.json`, which already names twelve classes and is *baked* into `commodities.json` by `apply-category-excludes.ps1` — the `rules_hash` must therefore be taken over the **post-bake** `commodities.json`, and the bake step must run before the hash is computed in the chain.

### 10.5 Rulings are negatives; first-match-wins must be re-examined, not assumed
`known_wrong_for` is "an adjudicated negative, absolute". When a known-wrong forbids the commodity the rule proposed, does the product today **fall through to the next matching commodity** or **drop**? Read `compare-deals.ps1`'s known-wrong handling and `known-wrong-lib.ps1` and preserve that exact behaviour in the precedence logic (step 2), with a fixture for each branch. Precedence is therefore two ladders — *forbid* (human forbid > known-wrong > suppression) and *assign* (human assign > rule) — not one.

### 10.6 `candidates` requires a small, parity-checked engine change
The C# core stops at the first match (and its inverted-index prefilter skips entries that cannot match). Recording `candidates` means continuing past the first hit to evaluate every include-eligible entry's excludes. This is cheap in compiled code but it is an engine change: the first-match answer must remain identical (`test-match-lib`), and the prefilter's soundness (`RequiredLiteral`) must hold for the continued scan too.

### 10.7 The parity gate must fail closed on a MISSING row only once the table exists
First run: the table is empty. An absent row is "table not populated" → BLIND (exit 3, publish proceeds), never a HARD FAIL — otherwise step 1 can never go live. After the first full population, absent = hard fail. Compare only rows at the **current** `rules_hash`; rows under an old hash are stale by definition, not disagreements.

### 10.8 Keep Python off the SHIP path
The importer into `graph.db` (`import_all.py`) runs in INSPECT (it already does, inside `audit-graph-gates`, ~1 s). `guards.ps1`'s parity gate reads the tracked JSONL directly in PowerShell — a keyed lookup over ~40k rows is sub-second with a hashtable. Do not put a Python call in front of publish.

### 10.9 Write the table atomically, and only from the board-building invocation
`compare-deals.ps1` is also run ad hoc (`-Explain <commodity>`, `-SelfTest`, by `apply-coverage-batch`). Only the chain's board-building run emits assertions; temp + move + re-parse before the swap (the pattern in `purge-verdict-lows.ps1` and `rollback-ttl-lib.ps1`), never a truncating write — the 13 MB `price-history.json` tear window of 08-22 is the precedent.

### 10.10 Step 5 must keep what `capture-run.ps1` already guarantees
The machine-wide mutex (`Global\tc-capture-run`), the run record (`out/logs/capture-run-status.json`), the SHIP/INSPECT boundary log line, the verdict file (`out/chain-verdict.json`) and the publish gate on it. The runner replaces the *ordering* of stages, not the run's contract with the watchdog.

### 10.11 The twenty copies are not all the same copy
Some "copies" are *loosened* matchers on purpose — `audit-coverage-gaps` scans with a deliberately broader include to find products the strict rules miss. That is a different question ("what *could* match?"), not a drifted copy of "what *does* match?". Classify each of the twenty before migrating: faithful replicas become table reads; deliberate variants keep their own logic but take the table as their "current assignment" input instead of recomputing it.
