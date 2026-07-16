# Quarantined Sam's captures

Files in here are **real data the engine cannot price correctly yet**. They are parked (not deleted) so the
work is visible and recoverable. `compare-deals.ps1` globs `out\sams\sams-deals-*.json` without `-Recurse`, so
nothing in this subdirectory is read.

## sams-deals-2026-07-15.json - Omaha club 68137, 428 rows, ~118 commodities

Quarantined 2026-07-16.

**This is better data than what the board uses.** It is club-specific Omaha pricing (`priceInfo.unitPrice`,
club 68137) where `sams-deals-2026-07-08.json` is *national warehouse pricing*. It is worth recovering.

**Why it cannot be used as-is:** it is a **unit-price** file. Each row carries the price *per unit of measure*
in `ad_price` with the bare unit in `size` (`"$0.47"` + `size:"oz"`, `"$2.88"` + `size:"lb"`). Every other feed
the engine reads carries a **package price** with the pack size (`"$7.55"` + `size:"16 oz"`). The two
conventions collide inside `Get-UnitPrice`:

- Weight units are fine by luck: `size:"oz"` -> amount 1 -> `$0.47/oz`. Correct.
- `each` is NOT: `Get-UnitPrice` reads the pack count out of the *product name* and divides. So
  `"Seedless English Cucumbers, 3 ct."` at `$1.09` per each became **$0.3633/each - wrong by 3x**.

This cannot be fixed inside the engine, because for every other feed `size:"each"` + `"24 Pack"` in the name
genuinely DOES mean "divide the pack price by 24" (asserted in `guards.ps1` guard 0 / `test-pu-lib.ps1`:
`size='each', name='Water 24 Pack', price=6.00 -> 0.25`). Both readings are correct for their own feed, so the
ambiguity has to be resolved at INGEST, not in shared math.

**How it was caught:** the `board-price-overrides.json` pins. Those pins were verified against the real stores,
so when the engine started disagreeing with them (`cucumbers pin=1.09 engine=0.3633`), `guards.ps1` hard-failed
and blocked the publish. The band guard had already been silently rejecting the worst of these rows, which is
why this capture yielded only ~118 commodities instead of the ~251 the national file covers.

## To recover it (worth doing - it is the only true Omaha pricing we have)

Convert at ingest, do not touch the shared math. Rewrite each row into a form the engine reads unambiguously:

1. `size = "$<unitPrice>/<unit>"` (the explicit unit-price form `pu-lib`/`Get-SizeAmount` already understand),
   or
2. multiply back out to a real package price + pack size (`$1.09/each` x `3 ct` -> `$3.27` + `size:"3 ct"`),
   which is exactly the shape of the national row and needs no engine change at all.

Then re-run `compare-deals.ps1`, and expect `guards.ps1` to flag the pins whose *product* changed (the engine
picks the cheapest row per store, and this capture adds products the national file never had - e.g. Organic
Blueberries at $0.33/oz undercutting the pinned Jumbo at $0.4719). Re-verify those pins against the store
before accepting them; a pin that is merely *outvoted* is not a pin that is wrong.
