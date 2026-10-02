# MEASURE: Walmart in-store rows with no unit price (W2 step 1)

Plan: `design/PLAN-browser-refresh-hardening-2026-10-02.md`, W2 step 1. A measurement only. No pricing code changed.
Harness: `grocery/measure-walmart-missing-unitprice.py` at blob 256b189e5bf2dcdb20499e7af951505f440a13a9, run 2026-10-02
(and re-run the same day by the implementation session: exit 0, the same verdict).

## Question

Over the last 14 days of Walmart captures, how many in-store rows (pickup at storeId 5361) carry a line price but no
Walmart unit price? For how many does a size parse unambiguously from the product's own name? And how many board cells
would a per-unit price worked out from that size have changed the winner of?

## Bar (written before the run, verbatim from the plan)

> build W2 step 2 only if at least 5 distinct board cells over the 14 days would have changed winner.

Unit: distinct board cells (commodity ids) over the window, read on the **same-day** arm. "Changed winner" means the
derived row would have been the cell's cheapest row: strictly below the board's published `cheapest_price`, or the cell
had no priced winner.

## Harness and inputs

- Harness: `grocery/measure-walmart-missing-unitprice.py`, blob `256b189e5bf2dcdb20499e7af951505f440a13a9`.
  Run: `C:/Codex/Python312/python.exe grocery/measure-walmart-missing-unitprice.py` (defaults: newest capture as the
  end date, 14 days). Exit 0, last line `MEASURE-WALMART-MISSING-UNITPRICE-COMPLETE exit=0`.
- Cases: `design/MEASURE-walmart-missing-unitprice-2026-10.jsonl`, blob `8bdedefd7b631154a09f9617b41aa6dd489d578e`.
  One row per case per arm (314 rows = 157 cases x 2 arms).
- Tracked inputs: `grocery/commodities.json` blob `74126abde9b4b06dbb5208dca6323d947ed4dfca` (599 commodities, the
  same as origin/main at run time); `grocery/global-exclude-lib.ps1` blob `8b35074860111b928f2cd818b509c929c338f8a2`
  (87 global patterns, parsed out of the file at run time).
- Untracked inputs (gitignored, read only from the main checkout's `grocery/out`, sha256 first 12 hex):
  captures `walmart-capture-2026-09-19.csv` 7ebead573a2e, `-09-20` d6422691e6c4, `-09-21` cb44adf71257, `-09-22`
  24c43085c169, `-09-23` a3c17c6d4bae, `-09-24` 4c97316bd593, `-09-25` 0932c87d6b5e, `-09-26` 0c1f9b782772, `-09-27`
  2f467f3a810a, `-09-28` 5193c1fb7c0e, `-09-29` c76e03d34070, `-09-30` 74baa8d86b31, `-10-01` e9f9237da362, `-10-02`
  b3d1cd33203f; boards `comparison-2026-09-20.json` a170ad6cce86, `-09-21` 641769d86d8a, `-09-22` 6efc39a2ae9e,
  `-09-23` 7a8292f78637, `-09-27` 9bf02711404e, `-09-28` c35596aaadb7, `-09-29` efd517ec1c22, `-09-30` d3c47b7615dc.

Method, in short (the harness header has it in full): Build-Row's own line-price and unit-price patterns; in-store
means the `#tc-store` line reads 5361 and `ff` is `STORE;av=IN_STOCK;pk=` naming 5361, with no "(N pack)" title; one
case per (date, item id, line price). Size from the name is strict: exactly one weight or volume size, refused for any
count or pack token, a range, a variable-weight cue, or two sizes. Commodity mapping is compare-deals' `Match-Category`
ported (0 of the patterns failed to compile in Python). Units are converted only within weight or within volume;
anything else is UNCOMPARABLE.

Cross-check: on 2026-10-02 the harness counts 789 rows, 343 with no unit price and 19 in-store at 5361 with none. The
plan's own re-measure reports the same three numbers.

## Totals (derived from the jsonl)

Days: captures exist for 14 of 14 days (2026-09-19 to 2026-10-02). No day is skipped for want of a capture.

- **2026-09-19 has no evaluable rows**: that capture's 23,034 rows predate the shelf signal (`ff` is a bare `STORE`
  with no `av=`/`pk=`). 8,174 of them have no unit price, but none can prove pickup at 5361, so they are counted and
  are not cases.
- In-store rows at 5361 with a line price and no unit price, days 09-20 to 10-02: **169 rows**, de-duplicated to
  **157 cases** (67 distinct names, 68 distinct item ids; the same products recur day to day).

**Same-day arm (the verdict arm).** A board named for the capture date exists on 8 of 14 days. The 6 skipped days
(counted, never guessed) are 09-19, 09-24, 09-25, 09-26, 10-01 and 10-02.

| Outcome | Cases |
|---|---|
| SIZE-REFUSED | 143 of 157 (91%) |
| NO-BOARD (size parsed and mapped, no same-day board) | 9 of 157 (6%) |
| UNMAPPABLE (size parsed, no commodity matched) | 4 of 157 (3%) |
| COMPARED | 1 of 157 (1%) |
| UNCOMPARABLE / NOT-ON-BOARD | 0 of 157 |

- Size parsed: 14 of 157 cases (14 distinct names).
- On board days only: 65 cases, of which 64 SIZE-REFUSED and 1 COMPARED.
- Would change the winning row: **0 of 1 compared**. Winning store changes: 0 of 1.
- **Distinct board cells that would have changed winner: 0.**

**Latest-prior arm (context only).** The newest board on or before the capture date, at most 7 days back. Every case
gets a board (09-24 to 09-26 use 09-23; 10-01 and 10-02 use 09-30).

- COMPARED 10 of 157, SIZE-REFUSED 143 of 157, UNMAPPABLE 4 of 157.
- Would change the winning row: **0 of 10 compared**. Distinct cells: **0**.
- The plan's named examples all landed on 2026-10-02 and all lose to the prior board's winner: Gold Medal flour 5 lb
  $0.794/lb against Aldi $0.39; Pine-Sol 60 fl oz $0.150/floz against Sam's $0.052; Northland cranberry 64 fl oz
  $0.057/floz against Aldi $0.041; Del Monte green beans 14.5 oz $0.119/oz against Aldi $0.051; Old El Paso and
  La Costena jalapenos $0.219 and $0.098/oz against Sam's $0.078. The one same-day comparison, Green Gobbler drain
  opener 1 gal, came to $0.147/floz against Walmart's own $0.046.

What the size refusals are: of the 67 distinct names, 38 have no size at all (meal bundles, rotisserie meals, deli-sliced
meat, produce sold "Each" or "Bunch", plates, a spatula). 13 carry a count or pack token (toothbrushes, "2 Count"
zucchini, "1ea" celery, "12ct" eggs, a "3 pack" Lysol, Clorox wipes). 2 are ham listings that state two sizes
("10g Protein per 2 oz").

## Verdict

**NOT MET.** 0 distinct board cells would have changed winner against a bar of at least 5, on the same-day arm. The
latest-prior arm, which judges every case, also finds 0. Every compared row is a name brand, and the board's winner
beats each one: the derived prices run 25% to 220% dearer. W2 step 2 should not be built on this evidence.

Caveats:
- `would_change_winner` is an upper bound, because the engine's bands, guards and provenance contract are not run here.
  The bound is already 0, so this cannot change the verdict.
- 6 of 14 days have no same-day board. The latest-prior arm covers them and agrees.
- `commodities.json` is read at the harness's checkout, not at each board's build time. It matched origin/main at run
  time.
- Variants tried: one harness version and one run. The size rule was not tuned.

## Outside the bar: each-sold produce (a separate question, not W2)

A one-off side-look (scratch script, not committed) at the latest-prior arm's size-refused rows that map to `each` or
`dozen` cells. It priced each row's line price as one unit. Three cells would have been cheapest:
- artichokes: $3.12 to $3.27 against Baker's $3.49
- collard-greens: $1.57 a bunch against Baker's $1.99
- chayote: $1.17, where the 09-23 and 09-30 cells have no priced winner

These rows have no size in the name, so W2 step 2's rule as written could never reach them. Pricing a Walmart "Each" or
"Bunch" line as one each is a different rule and needs its own ruling. It is listed here as an open question, not as
evidence for W2.
