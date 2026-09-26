# Q-ab11be-flyer-line-road: sale cells that name a flyer line, not a product

**The question.** Some sale cells are flyer LINES, such as "Hy-Vee aluminum foil, 50 or 75 sq. ft., $4.49": a product
family, a size range and a price in one string. No store read can ever verify one. Build a line-to-product link,
accept them as published and unverifiable, or stop publishing them?

Raised by queue item 2026-09-26-ab11be. Source: `grocery/triage-plans/plan-2026-09-26-3.json`; the detector is
`Test-TcFlyerLineNamesNoProduct` in `grocery/flag-verify-lib.ps1` (a sale row with no `as_of` of its own whose item
text carries a price).

## What I checked

Applied that same structural test to `grocery/out/comparison-2026-09-23.json`:

- Ad-read sale cells (sale, no `as_of`): **151** (Family Fare 58, Hy-Vee 53, Fareway 37, Aldi 3). The detector's
  header says 155; my count is 4 lower, reason not chased.
- Flyer lines among them: **56 of 151**, Hy-Vee **53 of 53**, Fareway **3 of 37**. This matches the triage exactly.
- 3 of the 56 hold their commodity's crown (cheapest cell on the board), by my loose check.
- The triage records 0 of these flagged since the verifier went live on 2026-09-21. I did not re-read the flag log.

So every Hy-Vee sale on the board today is unverifiable by construction.

## Options

- **A. Accept it (shipped today).** They stay published and the verifier says "unverifiable" every run. Nothing
  moves. If a Hy-Vee flyer line is mis-parsed, nothing after publish can catch it.
- **B. Build a line-to-product linker in the Hy-Vee ad ingest,** so the in-window Aisles Online read can verify each
  line against a real product. Matching work in the money lane, with a risk that a bad link flags a real sale as
  wrong and withholds it; needs its own fixtures and a measured precision before it can hold a cell.
- **C. Stop publishing a flyer line whose product cannot be named.** Up to 56 fewer sale cells (all of Hy-Vee's
  sales), including 3 crowns.

## Recommended (best long-term): B

All 53 Hy-Vee sale cells sit outside verification today, and the flyer has already mis-parsed once (the 2026-09-07
laundry pods). Hy-Vee's product API is already how the everyday Hy-Vee cells are read, so linking the flyer line to
that product is the road that makes these cells as trustworthy as the rest. A keeps a permanent blind spot; C throws
away real sales readers use. Keep A in force until B is live and measured.

## What executes once ruled

- **B:** a plan in the money lane: the linker in the Hy-Vee ad ingest, a corpus of today's 53 lines with the product
  each should link to (one row per case), an acceptance bar written before the run, then verification switched on for
  linked lines; unlinked lines stay under A.
- **A:** nothing more; the question closes and the verifier keeps naming them.
- **C:** a publish-side refusal for the flyer-line shape, with fixtures, and a board rebuild.

## Ruling (Brad, in chat, 2026-09-26)

"Build link"

Option B, with A kept in force meanwhile (the lines stay published and the verifier keeps naming them unverifiable).
The plan is `design/PLAN-flyer-line-product-link-2026-09-26.md`; nothing is implemented until Brad reads it.
