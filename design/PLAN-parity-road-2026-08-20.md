# PLAN — The road to 0.99: what the parity gap actually is, measured cell by cell

**Status: DIAGNOSIS COMPLETE 2026-08-20, evening. Every conflict and every
uncovered cell assigned a cause; counts sum to the gate's own totals. Awaiting
Brad's go on the phase order.**

## 0. Why this document exists

Two parity theories failed today: adjudicating all 12,806 contested rows moved
agreement 0.930→0.929, and importing the missing lanes moved it 0.918 with
coverage up. Each fix *lowered* agreement while raising coverage, because every
newly-priceable cell is a new chance to disagree. Chasing the blended number
without a causal map was guesswork. This is the map (built by
`scratchpad/decompose.py` against the same selection logic the gate runs).

## 1. The measured decomposition

State at diagnosis: **coverage 0.876, agreement 0.899** — 2,853 shared cells,
2,564 agree, 289 conflicts, 405 live cells uncovered.

### Conflicts (289)

| direction | n | cause |
|---|---|---|
| higher | 115 | same product, different derived per-unit |
| higher | 99 | board picked a different (cheaper) product the graph lacks |
| higher | 20 | board cell is an AD price the graph lacks |
| LOWER | 28 | same product, graph's number is lower |
| LOWER | 25 | different product (selection) |
| LOWER | 2 | graph crowned an ad/sale row |

### Uncovered (405)

| n | cause |
|---|---|
| 248 | `::r` RECIPE-namespace rows — priced on the live board via ingredient mapping, a mechanism the staple parity gate does not model |
| 116 | no surviving rows for that store (sams 45, hyvee 44, aldi 13, …) |
| 41 | rows exist but every one refuses a per-unit (basis/size) |

## 2. The four root causes behind the buckets (each verified, not inferred)

**RC1 — The graph models "cheapest EVER observed"; the board models "current
price".** The graph's crown takes the minimum over all history, so any old
lower price wins forever: Aldi cucumbers crown at $0.65 (obs 08-09) against the
board's current $0.75 (08-15 file, which the graph also has). This is most of
LOWER/same-product (28) and, mirrored, much of higher/same-product (115, where
the board shows a current sale the graph outdates). Verified: 2,342 ad/sale
rows older than 10 days are still crown-eligible; the expired 07-23 blueberries
sale still crowns its cell. **This is precisely the defect Brad's ratified
price-state design (PLAN-price-state-2026-08-20.md) exists to kill**: state =
current price per cell, ad rows carry ad_from/ad_to and die at ad_to,
superseded rows are deleted at import.

**RC2 — Known-wrong rulings do not retro-apply.** Layer 1 consults rulings only
when a row is adjudicated; a row already `include_hit` is never re-litigated,
so today's strawberry-syrup ruling demotes nothing already in the graph — the
syrup STILL crowns the graph's walmart cell (verified: status=include_hit,
and the KnownWrong node isn't even imported yet since the ruling postdates the
last import). A ruling that cannot reach existing rows is half a ruling. This
is a SAFETY defect independent of parity.

**RC3 — The parity denominator includes 248 recipe-board cells the staple
mechanism will never price.** `::r` rows are priced on the live board through
recipe→ingredient mapping. Scoring them against direct staple pricing measures
a mechanism that isn't under test. Staple-only coverage is **0.948** today, not
0.876. (Recipe-row parity deserves its own gate through the `maps_to` edges —
later, not never.)

**RC4 — Curated rows are immortal and stale.** product-urls observations from
July (Aldi strawberries at $1.89, verified 07-16) take precedence over fresher
sweep rows; entries deleted from product-urls.json live on as observations
because nothing supersedes at import. Same family as RC1; also explains why
the removed daiquiri-mixer row still prices the graph's fareway cell.

## 3. The phases, in dependency order, with projected effect

| phase | work | fixes | projected after |
|---|---|---|---|
| **P0** | Scope the Phase-2 gate to staple rows; report recipe rows as their own (initially informational) number | RC3 | coverage 0.876→**0.948**, agreement unchanged |
| **P1** | Currency semantics: crown = newest surviving row per (store, product); ad/sale rows crown only inside their window. Implement as the crown rule now; full supersede-at-import lands with price-state Phase C | RC1, both `same-product` buckets, both LOWER-ad cells | agreement 0.899→ ≈0.94 |
| **P2** | Retro known-wrong sweep: on import of a ruling, re-adjudicate every row whose (commodity, normalized name) matches; add a verifier check that no include_hit row matches a KnownWrong name | RC2 + several LOWER-selection cells (syrup, mixer, fruit-spread) | LOWER 55→~35; safety gate honest |
| **P3** | Curated freshness: a curated row loses precedence to any newer sweep row for the same product; deleted curated entries superseded at import | RC4 | removes the immortal-July prices |
| **P4** | Human-eye review of the residual LOWER-selection list (~20: grapefruit crowned by a Lime, ribeye by steak BURGERS, dog-treats basis) → known-wrong rulings or include fixes | the real false merges | LOWER→ single digits |
| **P5** | Close the higher/99 bucket: per-store completeness vs the board's current files (the graph reads the same captures — these are import/freshness gaps, enumerable per cell) | remaining benign gap | agreement → 0.99 territory |

Order matters: P1 before P4, because a third of today's "dangerous" list is
stale-currency noise that P1 deletes — reviewing it first wastes the eye on
cells that were never wrong, only old.

## 4. What this says about the estate

The graph's failure classes are the live estate's own past incidents, replayed:
stale prices outliving their window (the V4 blueberries), rulings that don't
reach every copy (today's curated-links hole), min-over-history crowns (the
fullpull watch's union-window bug). The redesign Brad ratified — state, not
log; freshness as data; ad windows that expire — is not adjacent to the parity
problem. It IS the parity problem. Option 3 (chase 0.99) and the price-state
plan are the same road.
