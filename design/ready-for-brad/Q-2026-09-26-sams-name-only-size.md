# Q-2026-09-26-sams-name-only-size: may a Sam's Club size come from the product name alone?

**The question.** When Sam's prints no unit price and the item has never been proved by one, may the board size it
from the name ("Campbell's Cream of Mushroom Condensed Soup 50 oz." at $4.98 read as 50 oz), or stay refused?

Raised by queue item 2026-09-26-samsunit. Source: `grocery/triage-plans/plan-2026-09-26-3.json`.

## What I checked

Read `grocery/out/sams/sams-rejects-2026-09-2{4,5,6}.json` and counted distinct names refused with the plain
`no unitPrice` reason (not the "earlier proof" variants). Then counted names with exactly one measure (oz, lb, fl oz,
g, ml, gal, qt) and no count, or exactly one count (ct, pk, pack) and no measure, with no per-pound or approx marker.
The classifier is my own regex in a scratch script, not the builder's.

| Day | Distinct plain no-unitPrice | One measure | One count | Admissible under A | Triage said |
|---|---|---|---|---|---|
| 09-26 | 94 | 19 | 17 | 36 of 94 | 36 (20 + 16) |
| 09-25 | 211 | 73 | 38 | 111 of 211 | 32 |
| 09-24 | 108 | 48 | 13 | 61 of 108 | 19 |

**09-26 matches** (36; my split is 19/17 against 20/16, one name classed differently). **09-25 and 09-24 do not
match**: my count is 3 to 3.5 times the triage's. I do not know which rule the triage used for those days, so treat
the older-day numbers as unqualified on both sides. Either way it is tens of products a day, and 09-25 was a bigger
sweep (438 reject rows against 179 on 09-26).

Also true: Walmart's builder refuses the same shape (`walmart-row-lib`, "no unitPrice"), so admitting it is a new
estate rule, not a Sam's patch. Hy-Vee and Family Fare rows already take size from the name, but their names come
from a store API, and Sam's rejects file shows the name-conflict class is real (12 rows on 09-26 where the name says
"8 ct" and nothing else agrees).

## Options

- **A. Admit a name with exactly one measure or one count and no per-lb or approx marker,** marked
  `qty_basis 'package; qty name only'`. About 36 more Sam's products a day reach the board. A name that states the
  pack wrong (a known Sam's failure, see the name-conflict rows) publishes a wrong per-unit price with nothing to catch it.
- **B. Keep refusing** until Sam's prints a unit price, as today. Those products stay off the board; the existing
  proof carry already admits any item that was once proved by a printed unit price.
- **C. Fetch the unit price from the store instead.** Keep refusing name-only rows, and teach the Sam's sweep to read
  the product page (or the JSON call behind it) for items the listing shows without a unit price, so the size comes
  from Sam's own number. Same pipeline-fetched rule as every other price.

## Recommended (best long-term): C

Your 2026-09-21 ruling is that every price comes from the store, fetched by the pipeline. C keeps that true for the
size as well as the price, and the proof carry then covers the item on every later day. A is cheap today but makes
the product name the only evidence of pack size, which is exactly where Aldi's pack basis went four times wrong on
09-19. B is safe but leaves the gap open for good.

## What executes once ruled

- **C:** a Sam's sweep change that reads the product-level unit price for rows the listing leaves blank, with a
  fixture on today's refused names, then the builder admits them through the normal unit-price road. Refusals stay
  as they are until it lands.
- **A:** a builder change in `grocery/build-sams-deals.ps1` (and the same decision for `walmart-row-lib`), fixtures
  for one-measure, one-count and a two-size must-not-admit, then a board rebuild.
- **B:** nothing; the question closes.

## Ruling (Brad, in chat, 2026-09-26)

"C: read unit price from page"

## After the ruling (2026-09-26): the premise of C did not hold

Before building the page read, the product pages it would read were measured: 30 of the 181 distinct item ids the
09-26 capture carried with a blank unit price (every 4th id in sorted order), fetched same-origin from the signed-in
Omaha club at Sam's own pacing (2.6 s + up to 1.4 s). **0 of 30 pages carry a unit price** (`product.priceInfo.unitPrice`
null, and null in every `channelLevelPriceInfo` entry); 30 of 30 answered HTTP 200 with the product and its price, 0
walled. The control, an item whose listing does print one (4Z2IZ92W3ADE, 20.8 c/oz), carries it on its page too, so
the read works where Sam's has the number. The rendered page shows no per-unit text and no size specification either.
So the page read the ruling asks for would admit nothing, and it is NOT built: it would add a paced fetch per blank
row (about 8 minutes a sweep, more exposure to the wall) for zero rows. Name-only rows stay refused, as the ruling
says, "until that is live". Rows and method: `design/MEASURE-sams-page-unit-price-2026-09-26.md`. This needs a
new ruling: keep refusing (B), or another Sam's-own source of the size.

## Ruling (Brad, in chat, 2026-09-26, after the page measure)

"Keep refusing"

Option B. Name-only Sam's rows stay refused; no page read is built. **Status: CLOSED 2026-09-26.**
