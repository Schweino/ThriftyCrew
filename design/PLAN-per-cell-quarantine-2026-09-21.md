# Plan: a bad cell holds itself, not the board

Written 2026-09-21 after Brad's instruction, verbatim: *"The ENTIRE board shouldn't be held hostage because
of one (or a few) bad items. Each item is unique/individual."* Read and edit before anything is built.

## What happened today, measured

`guards.ps1` held the whole board at 08:12 on one hard failure, the band-censorship ratchet
(`audit-band-censorship.ps1` against `out\band-censorship-baseline.json`). The ratchet holds 13 baseline cells.
Today it flagged 13, of which exactly **ONE was new**:

| cell | published | refused | why refused |
|---|---|---|---|
| vegetable-oil / Sam's Club | $0.0723/fl oz, *Member's Mark Vegetable Oil, 192 oz* | $0.0373/fl oz | under band_min $0.04 |

The newest board carries about **2,705** priced cells. So one cell held roughly 2,700, and members saw
the 05:08 board all morning.

Worse, the one cell was very likely **not a defect**. The refused $0.0373 row fits the Sam's 35 lb oil jugs
whose size was derived from Sam's own wrong unit price (queue 2026-09-21-e291a1, fixed at cause today in
`build-sams-deals.ps1`). The band correctly refused a wrongly-sized row; the censorship guard read that
correct refusal as censorship. That needs confirming against the rebuilt capture, but either way the hold was
disproportionate.

This type ("GUARDS FAILED - board not published") fired on **15 of the last 30 days** (alert census). On
2026-09-20 one of the two hold reasons was `audit-json-readers`, a SOURCE-CODE lint ratchet with no board cell
behind it at all.

## The design

`guards.ps1`'s hard failures already fall into three families. Each gets the smallest blast radius that is
still honest.

### 1. Cell-scoped: QUARANTINE THE CELL, publish the rest

A defect attributable to one commodity-at-one-store. Today's list, from `guards.ps1`:
- a pin with no link, a wrong-product link, or not matching its link (guard 3)
- a cell off its linked product by a factor (guard 4)
- a multipack sized as one unit (guard 5)
- a stale undated discount published as a live sale
- a price the store is not charging (guard 10)
- ad-line price provenance
- the band-censorship ratchet
- a wrong-class product (a cleaner priced as food) and a unit-kind mismatch crown

The offending cells are quarantined, everything else publishes, and the alert names every quarantined cell.
**What a quarantined cell shows is Brad's ruling Q1 below.**

### 2. Store-scoped: DROP THAT STORE, publish the rest

A defect that makes a whole store's prices untrustworthy: store data collapsed, a store's prices past the
capture-policy carry, a wrong fulfilment mode. Precedent already in the code: `compare-deals.ps1`'s
price-mode gate "DROPS any Aldi/Fareway file not proving price_mode - surgical: drops just that store, board
still publishes" (memory `price-mode-in-store`). This family generalises it.

### 3. Board-scoped: HOLD, exactly as today

Conditions where nothing on the board can be trusted: the per-unit engine's own math regressed; a pricing
self-test regressed; the board was not built under the provenance contract; the board is stale against
today's ads; a guard errored or could not find its inputs. A hold is right here, because every cell went
through the thing that broke.

### A circuit breaker so quarantine cannot hide a systemic defect

Per-cell quarantine has one real failure mode: a systemic bug that hits hundreds of cells would be
quarantined cell by cell and the board would publish mostly empty. So if cell quarantines exceed a bar, the
run escalates to a hold. The bar is a control constant, stated with its reason and marked a first plausible
number, not the survivor of a sweep (`.claude\rules\ops-and-gates.md`): proposed **more than 2% of priced cells
board-wide, or more than 10% of one store's cells**. Today's case, 1 of about 2,705, sits far below it.

Note what it does NOT catch, stated honestly: the 2026-07-14 Aldi delivery markup put 293 of 364 Aldi cells
about 11% high with no single cell failing any check. Per-cell quarantine would never have seen it, and neither
does the current whole-board hold. That class is caught by store-level referent checks (`audit-price-mode.ps1`),
which stay in family 2.

### Two defects found while measuring, fixed in the same change

- **Code-quality ratchets do not belong in the board-publish guard.** `audit-json-readers` held the board on
  2026-09-20 with no board cell behind it. It moves to `ops\run-gates.ps1` (push time), where a source defect
  belongs. A mangled NAME in board data is still caught by `audit-board-mojibake`, which stays.
- **The censorship ratchet must not count a correct refusal.** A row the band refused that another guard
  independently proves wrong (a density conflict, a wrong-product ruling in `known-wrong.json`) is not
  censorship. Confirm today's vegetable-oil case against the rebuilt Sam's capture first.

## Open question for Brad

**Q1. What does a quarantined cell show a reader?**
- **A** - its last verified published price, with that price's date. The per-cell version of what the whole
  board does today ("left at its last good state"). Nothing is invented, and recipes stay costable.
- **B** - nothing for that store; the next store with a valid price takes the "cheapest" spot.
- **C** - the new price, marked "being re-checked".

Recommendation: **A**. It is exactly today's behaviour, applied to one cell instead of 2,700.

**ANSWERED 2026-09-21: A** (Brad). A quarantined cell shows its last verified published price with that price's date.
Built the same day to this ruling, with the three cases the ruling implies but did not name written down in
`grocery/cell-quarantine-lib.ps1`: a cell with no previously published value is WITHHELD, never invented; a previous
value that was a SALE, or is older than the board's publish window, is withheld too, because the published board
carries no end date for a sale and a stale price is a wrong price; and when a guard condemned the VALUE and the
previous value IS that value, it is withheld rather than republished. "Last published" means `public/board.json` as
committed on origin/main - the file the feed Worker serves - because `out\published-board.sig` is a hash and records
no values. The price's date is the day that board was committed, carried forward (the published row's `q` list) when
the same cell stays held on later days.

## What was built (2026-09-21, grocery/triage-plans/plan-2026-09-21-4.json)

- `grocery/cell-quarantine-lib.ps1` - the disposition (pass / quarantine required / quarantined / hold), the circuit
  breaker, the last-published reader and the applier. `grocery/apply-cell-quarantine.ps1` is its I/O.
- `grocery/guards.ps1` - every hard failure is scoped: guards 3, 4, 8 and 10b by their own cell, 5 and 10 by the
  published cells carrying the failing capture row, 6 and 9 by store, and a delegated audit by the
  `QUARANTINE-CELL`/`QUARANTINE-SCOPE` protocol (taught today: band-censorship, food-category, unit-basis-outlier).
  Everything else is board scope and holds. Exit 0 clean, 2 not publishable as it stands, 4 quarantined and verified.
- `grocery/check-ad-cycles.ps1` - `Invoke-GuardsGate` applies a requested quarantine, re-runs guards, re-exports the
  feed, writes the three-tier chain verdict and pages once under its own alert type.
- Family 2 was built at the same post-guard seam, not in compare-deals' loader: a store drop withholds that store's
  EVERYDAY cells and keeps its live ad cells, which is what the price-mode loader drop yields for the file it drops.
  Re-running compare-deals after guards would need the whole identity and link chain again ("compare-deals is not
  standalone"). The price-mode guard itself stays board scope: compare-deals already drops those files at load, so a
  guards-level price-mode failure means that gate failed, which is systemic.
- `audit-json-readers` left guards for `ops/run-gates.ps1`. The censorship-ratchet exclusion (a refusal another guard
  proves wrong) was NOT built: measured 2026-09-21, 0 of 23 band-censorship findings are named by a known-wrong
  ruling, and today's founding row is internally consistent (Sam's $7.16 checkout, current price $7.16 and own unit
  price 3.7 cents/fl oz all agree on 192 fl oz), so there was no case to build it from.

## Knowledge consulted

- memory `price-mode-in-store`: the surgical per-store drop that already exists in `compare-deals.ps1`, which
  family 2 generalises; and the 2026-07-14 Aldi case, the class a per-cell check cannot see.
- memory `conformance-guard-cannot-see-rule-bug`: guards check the board against the engine's own rule, so a
  wrong rule reads green; relevant to the censorship ratchet misreading a correct refusal.
- `.claude\rules\ops-and-gates.md`: a control constant records whether it is a first plausible number; do not
  add a gate that is red on day one.
- Read on disk: `grocery\guards.ps1` (every `HARD FAIL` site), `grocery\out\band-censorship.json` (23 findings,
  13 cells), `grocery\out\band-censorship-baseline.json` (13 counted cells), today's `ad-cycle-log.txt`.
