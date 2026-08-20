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

# 1. build the graph from the legacy estate (structure ~1s, +observations ~6s)
python graph/import/import_all.py --observations

# 2. adjudicate candidate rows (deterministic layers only, ~9s for 119k rows)
python graph/pipeline/resolve.py
python graph/pipeline/resolve.py --llm      # + local model on the contested set

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
| gold-set missed-merge rate | ≤0.10 | **0.0188** | PASS |
| Phase 2 board parity | ≥0.99 agreement | 0.917 @ 0.838 coverage (2026-08-20) | **NOT MET** |
| Phase 2 shadow days | 14 consecutive | 0 | **NOT MET** |
| Phase 3 state-graph days | 14 consecutive | 0 | **NOT MET** |
| Phase 4 Chrome cycles | 4 consecutive | 0 | **NOT MET** |

Phase 0 and the Phase 1 evaluation discipline are complete. Phases 2-6 are built
and runnable but **have not earned their gates**, which require elapsed calendar
time (14 daily cycles, 4 Wednesdays) that no amount of coding shortens.

### What Phase 2 still needs

Board parity is at 0.917 agreement over 0.838 coverage (2026-08-20). Three
concrete gaps — the third is the contested set itself: 12,808 `no_include_hit`
rows cannot price a cell until the reviewer confirms them (the local model may
only reject; see the resolution section above). Working the escalation queue and
letting the learning loop convert confirmed matches into include aliases is how
that coverage returns. The other two:

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
