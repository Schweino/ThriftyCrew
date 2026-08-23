# The ThriftyCrew knowledge graph

Graph-native redesign of the Omaha grocery + meal-prep system. Built to the
implementation plan's Phases 0-6, with the plan's own gates enforced in code
rather than asserted in prose.

**Status: the graph is NON-AUTHORITATIVE and reads nothing in any serving path.**
The legacy PowerShell estate runs the live board exactly as before. This runs in
shadow beside it and will keep running in shadow until its numeric exit gates
pass. That is deliberate — the V3/V4 platform (built 2026-08-09, deleted
2026-08-14) died having declared readiness at 1 of 14 required parity days, and
served a stale wrong blueberries price for two days while returning HTTP 200.
Gates are numbers here, not opinions.

---

## Quick start

```bash
# 0. bring the local model up (once per boot; ~40s to load 13 GB into VRAM)
pwsh tools/local-llm/serve.ps1

# 1. build the graph from the legacy estate. With --observations this is the
#    whole refresh: import -> re-apply learning patches -> retro-apply
#    known-wrong rulings -> resolve -> rebuild cell_state + question_verdicts
#    -> state gate -> supersede-prune -> export tracked state. ~25s.
python graph/import/import_all.py --observations

# 1b. price state on its own (rebuild, gate, prune, ad-reversion worklist)
python graph/pipeline/state.py                  # rebuild + gate + export
python graph/pipeline/state.py --verify         # migration gate only
python graph/pipeline/state.py --ad-reversions  # cells owing a post-ad check

# 2. adjudicate candidate rows (deterministic layers only, ~9s for 119k rows)
python graph/pipeline/resolve.py
python graph/pipeline/resolve.py --llm      # + local model on the contested set
python graph/pipeline/resolve.py --emit-contested sidecar/data/contested-pairs.json
                                            # the contested questions, for the sidecar to score.
                                            # READ-ONLY: writes one file, no verdict, no event.

# 3. score against the gold set
python graph/gold/seed_gold.py              # (re)build the gold set
python graph/eval/score.py                  # the four first-class metrics

# 4. gates
python graph/agentic/verifier.py            # Omaha identity, ad window, known-wrong, ...
python graph/eval/board_parity.py           # graph vs the live published board

# 5. the daily pipeline as a state graph (SHADOW by default)
python graph/agentic/executor.py --save-plan

# 6. the learning loop
python graph/learning/stage1_analyze.py         # local -> Learning Proposals
python graph/learning/stage2_review.py --emit-packet
python graph/learning/stage2_review.py --ingest verdicts.json
python graph/learning/stage2_review.py --apply  # shadow-eval, then apply

# 7. the escalation review lanes — the ONLY writer of llm_confirmed
python graph/pipeline/review_escalations.py --emit-packet                    # confirm a model MATCH
python graph/pipeline/review_escalations.py --emit-packet --kind contested   # adjudicate from scratch
python graph/pipeline/review_escalations.py --emit-packet --deferred-only    # store-page evidence pass
python graph/pipeline/review_escalations.py --ingest verdicts.json           # runs flag_outliers itself
python graph/pipeline/review_escalations.py --status

# 8. absorbing confirmed matches into the deterministic layers
python graph/learning/alias_blast_radius.py       # corpus evidence the gold set cannot give
python graph/learning/stage2_review.py --requeue-stuck   # BEFORE widening resolve_target
python graph/learning/stage2_review.py --emit-packet     # packet now carries the blast radius
python graph/learning/stage2_review.py --ingest verdicts.json
python graph/learning/stage2_review.py --apply           # shadow-eval, then apply
```

The SQLite file is a rebuildable INDEX. Deleting `graph/sqlite/graph.db` and
re-running step 1 is always safe.

---

## Layout

| path | what |
|---|---|
| `sqlite/schema.sql` | the schema. Provenance-first: nothing asserts a fact without a provenance row |
| `lib/ids.py` | deterministic ids + store-name canonicalisation |
| `lib/graphdb.py` | the store layer (upserts, provenance, decision log, export) |
| `lib/llm.py` | local model client + Claude escalation packets |
| `lib/units.py` | size parsing, per-unit normalisation, basis reconciliation |
| `import/` | the 10 seed importers (legacy JSON -> graph) |
| `pipeline/resolve.py` | the layered resolver — the highest-risk component |
| `pipeline/nightly.ps1` | the nightly chain, and the ONLY scheduled thing that may start llama-server: emit -> sweep -> sidecar exits -> llama-server -> resolve -> Stage 1 -> card handed back in a `finally`. `-SelfTest`, `-WhatIfOnly`, `-StopOnly` |
| `pipeline/install-nightly-task.ps1` | the only thing that may schedule that chain (`-Show`, `-Uninstall`) |
| `pipeline/scorecard.ps1` | the standing weekly scorecard (plan §9), including the local lane and tokens per Claude ruling |
| `pipeline/review_escalations.py` | the escalation review lanes (confirm-match + contested); the only writer of `llm_confirmed` |
| `learning/alias_blast_radius.py` | what a proposed include alias would touch across the whole corpus — the non-circular half of an alias review |
| `gold/` | the evaluation gold set and its seeder |
| `eval/score.py` | entity/relation P/R, false-merge, missed-merge |
| `eval/board_parity.py` | Phase 2 exit gate: graph vs `public/board.json` |
| `agentic/` | immutable plan, Executor, Verifier (Phase 3) |
| `learning/` | two-stage learning loop (Phase 5) |
| `prompts/` | versioned Extract/Resolve prompts + the model-selection record |
| `provenance/` | per-run decision-log JSONL — the audit trail (tracked) |

---

## The two ideas that carry the design

### 1. Resolution is layered, cheapest and most certain first

`pipeline/resolve.py` decides whether a store's product listing IS a commodity:

1. **known-wrong** — an adjudicated negative with written evidence. Absolute.
2. **category-exclude** — wrong-CLASS guardrails, *scoped by category*.
3. **exclude regex** — the commodity's own negatives. Absolute.
4. **include regex** — the commodity's own positives. A hit is a match.
5. **LLM** — only for rows with no include hit and no exclusion — and it may
   **only reject, never mint a price**. A confident local NO_MATCH prunes the
   candidate (`llm_rejected`); a confident local MATCH becomes
   `llm_match_unverified`, which cannot price a cell and queues for the Claude
   reviewer to confirm. Decomposing the Phase 0 bench showed why: 22/22 on gold
   MATCH cases but 5/8 on gold NO_MATCH, all three misses being false MATCHes
   at confidence 0.95–0.98 — no escalation threshold catches those. With the
   LLM enabled, `resolve.py --llm` targets the contested set
   (`unadjudicated` + `no_include_hit`), so the layer is reachable without
   `--reset`.

`llm_match_unverified` leaves that state in exactly one way:
`pipeline/review_escalations.py`, the confirm-match review lane. It emits an
enriched packet per commodity (include/exclude patterns, sibling `include_hit`
names, known-wrong names, the model's own reason), a Claude reviewer rules
CONFIRM / REJECT / DEFER with written evidence naming the deciding words, and
`--ingest` writes the verdict to every row that asked the question, with
provenance and one `decision_log` row each. It refuses to overwrite a question
someone else already ruled, files an include-alias learning proposal for each
confirmed pattern (through the normal Stage-2 shadow gate, never around it), and
turns every ruling into a gold case in `gold/escalation-review.jsonl`, which
`seed_gold.py` merges so a rebuild cannot erase the reviewer's judgements.

On 119,029 real capture rows the deterministic layers settle **~89%** in ~9
seconds, so a model is only ever asked about the genuinely contested remainder.
That is the "blocking before expensive resolution" the plan requires, and it is
what keeps both cost and false-merge rate down.

**The bias is explicit: prefer a MISSED merge over a FALSE merge.** A missed
merge costs one empty board cell. A false merge publishes a wrong price, which is
what the 2026-07-14 blueberries-as-Bai-beverage and 2026-07-28
coconut-oil-as-Epsom-salt incidents both were.

### 2. Provenance is structural, not aspirational

`record_provenance()` is the only way to mint a provenance id, and every
fact-writing method demands one. `check_provenance_complete` fails the run if an
observation ever lacks one. "Why does this price appear?" is answerable from
`v_price_why` alone.

---

## Gate status (2026-08-20)

| gate | target | actual | |
|---|---|---|---|
| Phase 0 valid strict JSON | ≥0.95 | **1.000** (n=40) | PASS |
| Phase 0 resolution agreement | ≥0.90 | **0.900** (n=30) | PASS |
| Phase 0 decode | ≥15 tok/s | **46.1 tok/s** | PASS |
| gold-set false-merge rate | ≤0.02 | **0.0000** | PASS |
| gold-set missed-merge (SYSTEM, gated) | ≤0.10 | **0.0156** | PASS |
| gold-set missed-merge (deterministic, work indicator) | — | 0.3590 | not gated |
| Phase 2 board parity — UNVERIFIED graph-LOWER | ≤0.01 | **0.0021** (6 of 2,884 shared cells) | PASS |
| Phase 2 board parity — coverage | ≥0.90 | **0.949** | PASS |
| blended agreement | — | 0.914 | reported, not gated |
| ad timing | every weekly-ad store inside its current window | all 5 in-window | PASS |
| 90-day timer | no everyday row older than `MaxCarryDays` | reads `capture-policy.ps1` | PASS |
| ad reversion owed | every closed ad window re-checked | 0 owed | PASS |
| price-state migration gate | state ≥ observations vs live board | 0.8968 vs 0.8964 | PASS |

Phase 0 and the Phase 1 evaluation discipline are complete. Phases 2-6 are built
and runnable; the parity gate has not been earned yet.

### Why missed-merge moved 0.0188 -> 0.5831 -> 0.2211 on 2026-08-20

**None of it is a resolver regression, and false-merge never moved off 0.0000.**

The confirm-match review added 745 gold cases (gold 547 -> 1301, commodities
covered 379 -> 475), 517 of them reviewer-CONFIRMED matches. Every one is by
construction a listing **no include pattern matches** — that is precisely why the
model was consulted and the reviewer asked. `score.py` scores the deterministic
layers only, so on arrival each read as a missed merge:

| gold source | gold MATCH cases | missed by the rules | rate |
|---|---|---|---|
| `product-urls.json` (pre-existing) | 373 | 2 | 0.0054 |
| `escalation-review`, before absorption | 517 | 517 | 1.0000 |

The old 0.0188 was flattering: gold was seeded largely from curated per-commodity
product links the patterns already matched. The set is now honest about what the
rules alone can do.

Then **153 include aliases were absorbed** in two reviewed rounds, dropping the
rate to 0.2211 (recall 0.417 -> 0.779) with zero gold regressions. The residual
is ~197 cases, roughly half of them long-tail listings worth no rule at all. The
gate is not met and is not being chased: loosening patterns to reach a number is
how a false merge gets published.

#### Aliases are reviewed against the CORPUS, not just the gold set

`learning/alias_blast_radius.py` exists because the shadow gate had a blind spot
that became load-bearing here: **each review-derived alias was derived from the
very gold case it would then be scored against**, so "no regression" meant
nothing. The tool sweeps a candidate pattern over every distinct captured product
name and buckets the hits, using the real `Resolver` so that layers 1-3 are
honoured — a name the commodity's own excludes already block is not a collision.

Two buckets are automatic rejects: a pattern matching a name adjudicated negative
**for that commodity**, and — the subtle one — a pattern matching a name the
reviewer REJECTED for that commodity, because include (layer 4) runs before the
model (layer 5) and would silently reverse the rejection on the next re-import.

It earned its keep immediately. Of 119 first-round aliases it killed 5 and warned
on 3, every one a genuine defect in a pattern written the same day:
`\bbrat\b` matched a hair gel ("Da **Brat** So So Slick Braid & Grip Gel"),
`pepper,?\s*black` matched whole peppercorns, `\bdawn\b...` matched Dawn dish
SPRAY, and `milk,...chocolate` matched Carnation Malted Milk. Round two dropped 9
of 46 before filing: `chicken\b.{0,40}\bin\s+water\b` matched canned **tuna**,
`chocolate\b.{0,30}\bmilk\b` matched yogurt and pudding cups, and
`\bred\s+raspberries\b` matched **fresh** raspberries. Each rejected pattern was
either tightened and re-tested, or dropped.

Two lessons are baked into the module's docstring rather than left to memory:
negatives must be scoped to the commodity that ruled them (a first cut matched
globally and produced 4 false kills in 9 — "Local Roots Organic Thyme" is
known-wrong for DRIED thyme and correct for fresh), and a reviewer-confirmed row
must be counted as something an alias ABSORBS, not as redundancy (collapsing
those two made 85 of 119 aliases read as "captures nothing new" when absorbing
them was the entire point).

### Why graph-LOWER is split (decision 2026-08-21)

Brad's question ended the argument: *"if the item is right, and it's in the
right commodity, and it fetched the correct price, why is it a defect to begin
with?"* It is not. The live board is the INCUMBENT, not ground truth — it held
the strawberry-syrup crown, it overpriced 745 multipacks by 6-18x, it linked ten
See-item tiles to the wrong products, and this estate fixed all of that in a
single day. So a cell where the graph is cheaper says nothing about who is
wrong until the graph's claim is adjudicated.

`adjudicate_lower` splits them. A cell is VERIFIED only when the crowning row's
identity survived adjudication (reviewer-confirmed, or a deterministic hit on a
commodity the gold set actually covers), its price is inside the capture
window, every guard had its chance to demote it, and the discount is within
reach of the rest of the market for that commodity.

That last clause was added after the first version passed a lie: brandy at
Baker's read $6.99 for 59.2 fl oz — a 1.75 L bottle — and cleared identity,
freshness and every guard, because each of those asks whether the PRODUCT is
right and none of them asks whether the PRICE is possible. It now fails at 4.3x
under the market median, alongside a garlic-bread cell at 8.9x.

VERIFIED cells are not defects and are not gated. They are written to
`grocery/out/board-gap-worklist.json` — 79 cells and a $45.94 per-unit gap
today — because they are the board being dearer than the shelf. The UNVERIFIED
residue is what gates, at 0.0021 of shared cells.

**Time-based gates are AD TIMING and the 90-DAY TIMER, nothing else** (decision
2026-08-20, Brad). The first build carried the V4 postmortem's
consecutive-clean-days counters (14 shadow days, 14 state-graph days, 4
Wednesday Chrome cycles) into this estate; they were removed on the owner's
call. The 90-day window is read from `grocery/capture-policy.ps1` `MaxCarryDays`
— the one canonical definition — never copied, which is also how this estate's
own `row_age` check was caught asserting a private 21-day window while the
engine ran the 90-day quarter.

### What Phase 2 still needs

See the gate table above for the current parity figure. Note that the parity
harness was rescoped on 2026-08-20 (staple-only, recipe cells measured
separately) in the same window as this work, so **numbers either side of that
change are not directly comparable** — do not read a delta across it.

The third gap — the contested set — has been WORKED for the confirm-match half:
`no_include_hit` is 0, every `confirm_match` question has a verdict, and 3,658
rows reached `llm_confirmed`. That returned less parity than expected, and the
reason is worth recording: only ~30 cells ended up actually held by a
reviewer-confirmed row, because most confirmed rows sit in cells an `include_hit`
row already covers with a newer or cheaper candidate. The contested set was a
real coverage gap but a thin one at the cell level. The other half — 205
`contested` questions / 829 `escalated` rows — has a lane now
(`--kind contested`) but has not been adjudicated.

One defect the review surfaced: a correctly-matched row can still carry a
nonsense per-unit price, and upgrading rows to priceable is what exposes it.
"Boulder Everyday PaperTowel" ($5.39, size `660 ct`) divided a SHEET count as
though it were rolls and produced $0.0082 each — 345x below the commodity median
— instantly the cheapest paper-towels cell. `pipeline/flag_outliers.py` caught and
barred it, but only because it was re-run by hand. The basis sweep now runs
**inside** `review_escalations.py --ingest` whenever a CONFIRM lands: printed
advice is not a control, and the review is the step that makes new rows able to
crown.

**A known-wrong ruling does not retro-demote already-resolved graph rows until
the next import.** Three products adjudicated wrong on 2026-08-20 (a Sparkling
Ice PEACH beverage under `peaches`, a Simply Asia stir-fry SAUCE under
`five-spice-powder`, a Prego meat SAUCE under `italian-sausage`) were still
crowning cells afterwards: they were resolved `include_hit` before the ruling
existed, `resolve.py` only re-selects `unadjudicated` rows, and
`check_known_wrong_not_priced` matches against KnownWrong NODES that the JSON
ruling had not yet been imported into — so the gate correctly passed while the
rows still priced. Run `import/import_all.py --observations` after adding
rulings; the import sweep is what retro-applies them.

The other two gaps: 

1. **Lane coverage.** Only the `regular` and `throttled` capture lanes carry a
   parseable `deals` array. Baker's (`out/bakers/`, page-structured), Sam's and
   Fareway (`out/*/`, list-shaped, and some files are worklists rather than
   captures) use different shapes and are not imported. The graph therefore
   cannot see the products that won many live crowns, which is most of the
   remaining disagreement.
2. **Per-lane unit prices.** Only Walmart rows carry the engine's verified
   `wm_unit_price`/`engine_check`. Other lanes fall back to deriving a unit price
   from the size string, and `units.reconcile_unit` refuses anything it cannot
   convert exactly — correctly, but that costs coverage.

Disagreements are reported by DIRECTION, because the two are not equally
alarming: *graph higher* means it is missing a cheaper row (a coverage gap, and
benign); *graph lower* means it believes something is cheaper than the published
board, which is the false-merge direction and is reviewed individually.

---

## Known limitation of the learning loop's safety gate

The shadow gate scores every accepted patch against the gold set and drops any
that regresses. **It can only catch a regression the gold set can see.**

254 of 633 commodities have no gold coverage at all; patches touching those are
now HELD for a human rather than auto-applied. But coverage is not the same as
*discriminating* coverage. A live example from this build: the loop proposed
alias `vanilla\s+flavor` for `vanilla-extract`, which would let "McCormick Clear
Vanilla Flavor" — an imitation product — price the extract row. The gold set has
one vanilla-extract case ("Hy-Vee Imitation Vanilla Extract", NO_MATCH), so it
*knows* imitation is not extract, but nothing in it discriminates on the word
"flavor", so the patch scored a clean delta of 0.0.

This is why `add_gold` proposals are never auto-applied: they change what
"correct" means, and a model may not edit the thing it is graded against.

---

## Known limitation of layer-1 known-wrong matching

A KnownWrong ruling matches by exact normalised product NAME (one node per
surface form in the ruling's `names` list — the importer covers all of them).
If a store restyles a name, layer 1 misses that restyled row; layers 2-4, the
reject-only LLM layer, and the legacy `audit-known-wrong.ps1` gate (which also
checks `product_id`) all still stand behind it. This is deliberate: loosening an
ABSOLUTE layer to fuzzy matching trades a bounded miss for unbounded false
rejections. `price_observations` carries no store product id today; if one is
ever added, extend layer 1 to match on it before touching name semantics.

## Rules for changing anything here

- **Dual-write only.** Nothing writes back to the legacy estate.
- **Never weaken a gate to make it pass.** Fix the cause or leave it failing.
- The three commodity id namespaces stay separate. Collapsing staple
  `ground-turkey` into recipe `93-7-ground-turkey` is a false merge.
- Add a store surface form to `ids.STORE_CANON`, never "fix" it at a call site.
- Re-score the gold set after any prompt, model, or resolver change, and record
  the run — `eval_runs` keeps model + prompt version so a regression can be
  attributed.
