# PLAN — Confirm-match review: the reviewer lane that turns local-model leads into priced cells

**Status: NOT STARTED. This document is the spec — build from it, not from memory of it.**
Written 2026-08-20 for a fresh session. Assumes the full contested LLM run
(12,806 rows / ~3,139 questions, launched 2026-08-20) has COMPLETED; check
first (§6 step 0).

---

## 1. Why this lane exists

The resolver's layer 5 is **reject-only** (decision 2026-08-20, recorded in
`graph/prompts/model-selection.md` and `graph/schema.md`). The local model's
Phase-0 bench decomposed to 22/22 on gold MATCH but 5/8 on gold NO_MATCH, with
every miss a false MATCH at confidence 0.95–0.98 — so no threshold makes a
local MATCH safe to publish. A confident local MATCH is therefore written as
`match_status = 'llm_match_unverified'`, which **cannot price a cell**, and a
packet with `kind: "confirm_match"` is queued for review.

**Only this review lane may write `llm_confirmed`.** `llm_confirmed` means
*reviewer-confirmed*; it is one of exactly two statuses allowed to price a
board cell (`include_hit`, `llm_confirmed` — enforced by `v_current_cell` and
`verifier.check_no_unresolved_pricing`).

The payoff: board parity is 0.930 @ 0.838 coverage against a 0.99 gate, and
the contested rows barred from pricing are one of the three known coverage
gaps. Every confirmed packet returns rows to pricing eligibility; every
verdict also feeds the learning loop and the gold set.

## 2. Inputs and their shapes

- **Queue**: `grocery/escalation-queue.json` — gitignored on purpose
  (producer and consumer are the same PC; bodies carry raw store text).
  One entry per QUESTION, not per row:

  ```json
  { "observation": "<one representative observation id>",
    "commodity": "commodity:staple:black-pepper",
    "product": "Our Family Pepper, Black, Pure Ground 2 Oz",
    "reason": "llm MATCH (unverified): ...model's evidence...",
    "rows_settled": 23,
    "kind": "confirm_match",           // or "contested"
    "confidence": 0.95 }
  ```

- **The graph**: `graph/sqlite/graph.db`. All rows sharing
  (commodity_id, product_name) carry the same verdict; upgrading a question
  upgrades every row that asked it.
- **Domain rules**: the system prompt in
  `graph/pipeline/resolve.py::build_resolve_prompt` is the rubric the model
  judged under. The reviewer judges under the SAME rules (§4).
- **Evidence sources**: commodity node (label, unit basis, category, include
  patterns via `aliases`), sibling products already `include_hit` for that
  commodity, `known_wrong` rulings, and the live store page when a capture
  carries a URL.

## 3. What to build: `graph/pipeline/review_escalations.py`

Mirror the two-stage learning-loop pattern (`graph/learning/stage2_review.py`)
— mechanical packet-emit and verdict-ingest around a Claude review that is NOT
an API call from the pipeline:

```
python graph/pipeline/review_escalations.py --emit-packet      # queue -> review packet
python graph/pipeline/review_escalations.py --ingest verdicts.json
python graph/pipeline/review_escalations.py --status           # queue/verdict counts
```

### --emit-packet
Groups queue entries by commodity, enriches each with: commodity label + unit
basis + category, its include/exclude alias patterns, up to 5 sibling
`include_hit` product names (what "belonging" looks like), any `known_wrong`
names for the commodity, and the model's own reason + confidence. Writes
`grocery/escalation-review-packet.json` (gitignored). Sort commodities by
`sum(rows_settled)` descending — biggest coverage return first.

### The review itself (Claude, in-session)
For each question, exactly one verdict:

| verdict | meaning | effect on ingest |
|---|---|---|
| `CONFIRM` | this listing IS the commodity, under §4 rules | every row of the question → `llm_confirmed` (may price) |
| `REJECT` | it is NOT | rows → `llm_rejected`; if evidence is board-grade (wrong product seen on/near the board), ALSO add a known-wrong ruling via `grocery/add-known-wrong.ps1` (the legacy-canonical path — never hand-edit known-wrong.json) |
| `DEFER` | cannot rule without store-page evidence a later session must fetch | rows stay `llm_match_unverified`; entry stays queued with a `deferred_reason` |

Every verdict carries written `evidence` naming the deciding words — same
standard as `known-wrong.json` entries and the gold set.

### --ingest verdicts.json
Mechanical, main-thread, single-writer:
1. For each verdict, update ALL rows matching (commodity_id, product_name) that
   are currently `llm_match_unverified`. Never touch other statuses.
2. `record_provenance(source_document="escalation-review", extraction_method=
   "claude-review", model="<reviewer model>", prompt_version="review-v1", ...)`
   and one `decision_log` row per question (etype `escalate`, decision
   `confirmed|rejected|deferred`, the evidence in detail). The question "why may
   this row price a cell?" must be answerable from `v_price_why` + decision log.
3. Remove ingested entries from `escalation-queue.json` (deferred ones stay).
4. Refuse to ingest a verdict for a question whose rows are no longer
   `llm_match_unverified` (someone else already ruled) — report, don't clobber.

## 4. Review rubric (the same law the model judged under)

From `build_resolve_prompt`, binding on the reviewer too:
- The board prices PACKAGED RETAIL PRODUCTS; brand is never a reason to reject.
- Package SIZE is never a reason to reject (per-unit normalisation handles it).
- REJECT: different food; different cut/grade; prepared/cooked vs raw;
  non-food that merely mentions the food.
- Variety differences REJECT when the commodity names the variety
  (Deglet Noor ≠ Medjool; 93/7 ≠ 85/15).
- **Bias: prefer a missed match over a false one.** A wrong CONFIRM can
  publish a wrong price — the one failure this estate exists to prevent. When
  genuinely torn, DEFER; never confirm on vibes.
- The three commodity id namespaces stay separate; staple ≠ recipe ids.

## 5. Side products (do not skip — they are half the value)

1. **Gold-set growth.** Every reviewed question is a labelled case with
   evidence. Append MATCH/NO_MATCH cases to `graph/gold/gold.jsonl` via the
   existing seeder's format (`source: "escalation-review"`). 254/633
   commodities have zero gold coverage; this is the cheapest supply of
   discriminating cases the estate has. (Reviewer-added gold is allowed —
   the prohibition is on the MODEL editing what it is graded against.)
2. **Learning proposals.** A CONFIRMed question is evidence the commodity's
   include patterns have a gap. File an include-alias learning proposal
   (`graph/learning/` pipeline) so the deterministic layers absorb the
   pattern and the model is never asked again. Proposals go through the
   normal Stage-2 shadow gate — this plan does not bypass it.

## 6. Sequencing for the session

0. **Preconditions**: background resolve run COMPLETE (`python
   graph/eval/status.py` — `no_include_hit` should be ~0); llama endpoint NOT
   required; **verify the import-clobber fix landed** (see below) before
   ingesting anything, else a routine re-import wipes every verdict.
   > 2026-08-20: `graphdb.add_observation`'s ON CONFLICT clause overwrote
   > `match_status` back to `unadjudicated` on re-import — fix was being made
   > in the lane-importer work stream the same day. Confirm
   > `git log --oneline -S "match_status" -- graph/lib/graphdb.py` shows it.
1. `--emit-packet`; review in batches of ~50 questions, biggest
   `rows_settled` first; `--ingest` after each batch (checkpoint discipline).
2. After ALL batches: re-run the gates in order —
   `python graph/eval/score.py` (gold gates must still pass: false-merge
   ≤0.02, missed ≤0.10), `python graph/agentic/verifier.py` (all six),
   `python graph/eval/board_parity.py` (record the new agreement/coverage).
3. Update `graph/README.md` gate table with the new parity numbers.
4. Commit + push (standing rule: no asking).

## 7. Done means

- [ ] Zero `confirm_match` entries left in the queue (DEFERs allowed, each
      with a written reason).
- [ ] Every upgraded row traceable: `v_price_why` + decision log answer "who
      confirmed this and why".
- [ ] Gold set grew by the reviewed cases; score re-run recorded in `eval_runs`.
- [ ] Include-alias proposals filed for confirmed patterns.
- [ ] Gates green; parity re-measured and README updated; pushed.

## 8. Explicitly out of scope

- Building the missing lane importers (separate work stream, same day).
- Changing the resolver, thresholds, or schema property order — measured
  2026-08-20: evidence-first ordering does not reduce false rejections
  (2.7% either way) and reject-only already neutralises false matches.
- Anything that lets a model (local or reviewer) bypass the shadow gate on
  learning patches or auto-apply gold edits.
