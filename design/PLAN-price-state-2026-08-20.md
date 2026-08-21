# PLAN — Price state: the graph stops hoarding events and starts keeping answers

**Status: IMPLEMENTED 2026-08-20. All four phases (A-D) built, gated and pushed. See §7 for what each phase landed and graph/schema.md for the living definition.**

---

## 1. The problem, measured

The graph's `price_observations` table is an append-only event log:

| measured 2026-08-20 | value |
|---|---|
| observation rows | 128,162 over 37 days |
| rows per (commodity, store) cell | **40**, of which **1** is the answer |
| growth | ~6,500 rows/day, unbounded |
| DELETE/retention logic anywhere in `graph/` | **none** |
| graph.db | 142 MB and climbing |

The domain is not an event stream. A grocery board is a **state machine**: every
cell has a current everyday price, sometimes a current ad price, and freshness
rules for each. Everything else is either *evidence for the current answer* or
*a verdict we'd rather not re-litigate*. Neither requires keeping every
capture of "Diet Coke Fridge Pack" for all time — we hold 23 identical copies
of that question today.

## 2. Brad's design (the spec this plan serves)

> An item should be one row — that row should include columns for
> everyday_price and ad_price per store (sams_everyday_price, sams_ad_price,
> hyvee_everyday_price, …). Store last-update on everyday price (refresh every
> 90 days) and ad start/stop dates; on ad stop, trigger a pull to check the
> price reverted to everyday.

Three ideas in there, all kept:

1. **One current answer per item per store per price kind.** State, not log.
2. **Freshness as first-class data.** `everyday` carries its as-of date and
   dies at 90 days (this is exactly `capture-policy.ps1 MaxCarryDays` — the
   number is read from there, never copied; the estate closed three private
   copies of that window on 2026-08-20 alone).
3. **Ad expiry is an event that demands verification.** When `ad_to` passes,
   the cell owes us a re-pull confirming the shelf went back to everyday.
   Today nothing does this promptly; the quarterly rotation would catch it
   eventually, which is not the same thing.

## 3. Two amendments, with reasons

### 3a. Store long, render wide

Per-store *columns* (`sams_everyday_price`, `hyvee_everyday_price`, …) encode
the store dimension into the schema. That means: adding store #8 is a schema
migration touching every reader; every query grows N columns; and the guards
(`known_wrong_not_priced`, `row_age`, basis checks) would each need per-store
column awareness.

Stored shape — one row per **(commodity, store)**:

```
cell_state:
  commodity_id, store_id,
  everyday_price, everyday_unit_price, everyday_size, everyday_product,
  everyday_asof,                  -- refresh due at asof + MaxCarryDays
  everyday_evidence,              -- observation id that set it
  ad_price, ad_unit_price, ad_product,
  ad_from, ad_to,                 -- the window, from the store's ad cycle
  ad_evidence,
  reverted_checked_at             -- null => post-ad verification still owed
```

The file Brad described **still exists** — as the *rendered artifact*: one row
per item, a column pair per store. That is literally what `public/board.json`
and the deals page already are. The wide file becomes a cheap projection of
`cell_state`; the state table becomes the one place it's computed from. You
get the ergonomics of the wide row with none of its schema debt.

### 3b. Git is the price historian, not the database

`cell_state` is small enough (~3,217 observed cells; ~4,431 at full catalog)
to live as **tracked JSON** — roughly 1–2 MB, well inside git-bus doctrine.
Then every price change is a diff in a commit, and *price history costs
nothing*: `git log -p` on the state file IS the history, with dates, free,
auditable, and stored as deltas. No history tables, no rollups, no retention
policy for a history nobody queries yet. If a future feature needs queryable
history, it can be built by replaying the file's git log — the data is never
lost, it's just not paid for daily.

## 4. The three stores of record (and what each may grow with)

| store | one row per | size now | grows with |
|---|---|---|---|
| `cell_state` (tracked JSON + DB index) | (commodity, store) | ~3,217 rows / ~1–2 MB | **catalog only** — never time |
| `question_verdicts` (tracked, replaces re-adjudication) | (commodity, product_name) | 3,139 questions | **new products** — never time |
| `price_observations` (DB only, evidence) | newest per (commodity, store, product, price_type) | ~128k → est. 15–30k after supersede-prune | catalog × store assortment — never time |

The retention rule that makes the third row true — **supersede, don't
time-prune**:

> A newer observation of the same (commodity, store, product_name, price_type)
> **supersedes** the older one; the superseded row is deleted at import time.
> An observation referenced by `cell_state` as evidence is never deleted.
> A question's verdict lives in `question_verdicts`, not on the 40 rows that
> asked it — so deleting superseded rows destroys no adjudication work.

This is stronger than "prune at 90 days": the table is bounded by the size of
the *catalog*, not by elapsed time, and it cannot delete the evidence behind a
live price. The 90-day rule remains what it already is — a *freshness gate on
the answer* (`row_age`), not a storage policy.

`question_verdicts` is also where the in-flight work lands: the contested-run
verdicts (llm_rejected / llm_match_unverified) and the confirm-match review's
CONFIRM/REJECT rulings (see `PLAN-confirm-match-review-2026-08-20.md`) each
become one durable row per question. Known-wrong stays exactly where it is —
it is already per-question and legacy-canonical.

## 5. Freshness semantics (Brad's rules, made mechanical)

**Everyday:** `everyday_asof + MaxCarryDays < today` ⇒ the cell is STALE:
`row_age` gate fails it, and it enters the next capture worklist. Both halves
already exist (`check_row_age`, `capture-policy.ps1` rotation) — the change is
only that they read/write `cell_state` instead of scanning 128k rows.

**Ad:** on import of a new ad book, matching cells get `ad_price/ad_from/ad_to`
and `reverted_checked_at = NULL`. Then a small daily step:

```
ad_to < today AND reverted_checked_at IS NULL
  ⇒ emit the cell's pull terms into grocery/out/worklists/ (existing mechanism)
  ⇒ on the next capture of that cell: clear ad_*; if shelf price ≠ everyday,
    update everyday_* with the new price and stamp everyday_asof;
    stamp reverted_checked_at either way
```

No new machinery — it rides the capture-policy worklist system that already
paces every store. The verifier gains one check: `ad_reversion_owed` (cells
whose ad ended > N days ago and were never re-checked), so an unverified
reversion is a visible red gate, not a silent stale price.

## 6. What this deletes, and what it refuses to delete

Deletes: superseded candidate copies (~100k rows today), and — after the state
migration proves out — the unbounded growth path entirely.

Refuses to delete: evidence rows behind current answers; question verdicts;
known-wrong rulings; provenance/decision logs (tracked JSONL, already the
audit trail); anything the confirm-match review has not yet ruled on
(`llm_match_unverified` rows are open questions, not stale data).

Out of scope, flagged for its own decision: the **legacy** estate's untracked
intermediates (`grocery/out/candidates-*.json`, 408 MB, ~19 MB/day; old
captures ~831 MB). They belong to the PowerShell pipeline, not the graph;
their retention should be decided inside capture-policy, the file that already
owns pull cadence.

## 7. Migration, phased and non-breaking

The graph is a non-authoritative shadow, so this restructures freely without
touching the live board. Each phase ends green (all gates + gold scores) and
pushed, or it doesn't end.

- **Phase A — build state from what exists.** Derive `cell_state` from
  `v_current_cell` + ad cycles; derive `question_verdicts` from current
  match_status rows. Export both to tracked JSON. Nothing reads them yet.
  *Gate: `cell_state` reproduces `board_matrix()` cell-for-cell.*
- **Phase B — readers move.** `board_parity`, `verifier` (row_age,
  known_wrong_not_priced, no_unresolved_pricing), and `status` read
  `cell_state`/`question_verdicts`. Resolver consults `question_verdicts`
  before layers (a banked verdict is layer 0) — the model is never asked a
  question twice across runs, not just within one.
  *Gate: parity/verifier outputs identical before vs after the move.*
- **Phase C — writers move + supersede-prune.** Importers update `cell_state`
  directly; the supersede rule deletes at import time; one-time prune of the
  current backlog inside a transaction, gold re-scored after.
  *Gate: observation count drops to bounded steady state with parity and
  gold metrics unchanged.*
- **Phase D — ad-reversion trigger.** The worklist emitter + the
  `ad_reversion_owed` verifier check.
  *Gate: an ad that ended yesterday produces a worklist entry today.*

Sequencing with in-flight work: Phase A starts only after the running
contested adjudication completes and its verdicts are banked (they seed
`question_verdicts`); the confirm-match review session can run before or
during — its rulings land in the same table.

## 8. The numbers, before and after

| | today | after |
|---|---|---|
| answer store | 128,162 rows, unbounded | ~3.2k state rows, **flat** |
| adjudication memory | duplicated 40× across rows | 3,139 questions, one row each |
| evidence rows | 128k, growing 6.5k/day | 15–30k, catalog-bounded |
| price history | none queryable, all paid for | free via git diffs on `cell_state` |
| model re-asks across runs | possible | impossible (verdicts are layer 0) |
| ad-end verification | eventually, by rotation luck | owed, tracked, gated |
