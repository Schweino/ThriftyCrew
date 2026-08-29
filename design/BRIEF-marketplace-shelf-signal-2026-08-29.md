# The shelf signal the capture never records, and the three generations of rulings that stand in for it

Brad ruled on 2026-08-29 that the wrong-product bulk-seller class gets a rule-level fix rather than a
fourth round of per-product rulings, designed with the session working grocery triage. This is the spec.
**Nothing here has been built.** The 20 `known-wrong.json` rulings from that day's sweep stand as they are.

## What happened

Twenty per-product rulings were issued in two waves. Measured against the boards that followed them:

| generation | what held the cell | ruled | what took the cell next |
|---|---|---|---|
| 1 | Frontier Co-op, 16 oz bags | 5 cells | **27 Peaks Gourmet**, 12-19 oz bottles |
| 2 | 27 Peaks + Soeos + NY Spice + Genova + Al'Fez | 10 cells | **Badia 12-16 oz, 24 Mantra, Spice Hut, a 12-pack Mina** |
| 3 | not ruled | — | — |

`curry-powder` is the clean demonstration: blocked at Frontier's $0.7669/oz, it came back at 27 Peaks'
$0.7775/oz — one cent dearer — and after that ruling it came back again at Badia 16 oz, $0.9144/oz.
Seven of the ten wave-2 cells landed on the same class they were ruled off.

Per-product rulings do not converge because the ruling names a *product* and the defect is a *listing
kind*. There is always another one.

## Why every proxy tried so far fails

**Brand absence from the store-scoped catalogue** — the instrument that found waves 1 and 2. It gives a
false NEGATIVE on a brand that is genuinely shelved in one size and marketplace-only in another. Measured:
Badia has 5 rows in `walmart-regular-2026-08-11.json`, all 5-6.75 oz (Jerk, Complete, Sazon), while
`Badia Curry Powder, 16 Oz`, `Badia Ground Turmeric, 16 oz`, `Badia Cayenne Pepper, 16 oz` and
`Badia Ground Nutmeg, 16 oz` are absent. A brand test never flags those four.

**Exact-item absence from the store-scoped catalogue** — sharper, and it does separate the cases seen so
far. Two objections raised by the triage session, both correct and both unanswered:

1. *Staleness.* The catalogue is a single 2026-08-11 snapshot. A rule keyed to it starts refusing
   legitimately new shelf items the moment Walmart ranges one.
2. *Coverage.* "Absent" is evidence of not-shelved only where the pull actually covered that aisle. That
   run was 487 terms; recent runs are 7-9. Coverage would have to be measured per department before this
   gates anything.

**Size shape** (a spice in a 12-19 oz bottle/bag, or an N-pack) — necessary but **not sufficient**, and it
also mis-fires. `Great Value Parsley Flakes, 2.7 oz` is shelf; `powdered-sugar` is a legitimate 32 oz
Great Value cell; `black-pepper` is a legitimate 8.75 oz McCormick cell. A rule tuned to size alone
refuses real cells and still admits a 5 oz marketplace jar.

## The root cause: the signal is not captured

Every proxy above is standing in for one fact — **is this listing purchasable at the L St store, or is it
a third-party listing that only ships?** That fact is visible on the page and is not in our data.

Read live on 2026-08-29, the discriminator is unambiguous and the page carries its own control:

```
Great Value Oregano Leaves, 0.87 oz   $1.08   Overall pick   Delivery 14 mins | Pickup as soon as 12pm
Frontier Co-op Oregano Leaf, 16 oz    $15.12                 Shipping, arrives Mon, Aug 31
```

On the `garam masala` and `berbere seasoning` result pages, **no** result offered pickup or delivery while
unrelated "Buy it again" tiles on the same page showed "Pickup as soon as 1pm". That contrast is what makes
an absence evidence rather than a rendering failure, and any rule built here should preserve it.

**What the capture records today.** `build-walmart-deals.ps1` emits `store, item, ad_price, size, regular,
source_ad, price_type, current_price, source_checkout_price, as_of, wm_unit_price, item_id, found_by_term,
qty_basis, engine_check, taxonomy_path, link_url, image_url`. There is no fulfillment field and no seller
field. `taxonomy_path` and `link_url` exist in the schema but are **empty in both classes** — measured
across the 90-day union: 0 of 70 marketplace-shaped rows carry either, and only 2 of 8 known shelf rows do.
Neither can discriminate.

## Proposed fix

**Primary — capture the fact, retire the proxies.** Record a per-row fulfillment signal at pull time
(`pickup` / `delivery` / `shipping_only`), and a seller/marketplace flag if `__NEXT_DATA__` exposes one.
Then `compare-deals` refuses a `shipping_only` row for any commodity whose price basis is a shelf price.
This has no staleness (it is re-read every capture), no coverage dependency (it is a property of the row,
not of what else was searched), and it needs no size heuristic. It answers both objections outright.

The cost is that it changes the attended-Chrome capture page, which lives in the SKILL under
`~\.claude\scheduled-tasks\` and refreshes on the weekly browser run — so the field arrives for new
captures only, and the 90-day union keeps unflagged history until it rolls off.

**Interim, if something is wanted before that lands.** Exact-item absence from the newest FULL
store-scoped capture, AND a bulk/N-pack size shape, AND the commodity's term present in that capture's
`found_by_term` set. All three, because each alone mis-fires as above. It should be **advisory** — it
must not set an exit code or gate a publish until the per-department coverage in objection 2 is measured.

## Explicitly out of scope: the adobo class

The triage session found and fixed a second defect the same day that **no shape rule would catch**.
`ground-cumin` (include `\bcumin\b`) and `achiote-paste` (include `\bachiote\b|\bannatto\b`) both priced
off *Goya Adobo All Purpose Seasoning*, whose label honestly contains both words. Adobo is cheap salt, so
it undercut every real product and took both crowns.

Goya Adobo is genuinely shelved — it holds the `adobo-seasoning` crown at Sam's at $0.1332/oz. Right
product, right price, right size, right seller; simply not that commodity. Fixed with a `\badobo\b`
exclude on each, one row dropped from each.

A rule tuned only to listing-kind leaves this class live. They are two different defects and should not be
merged into one instrument.

## Measure before it gates anything

- Per-department coverage of the store-scoped catalogue (objection 2).
- How many currently-priced Walmart cells the interim rule would refuse, and how many of those are real.
- The ~8 cells already known to be in the bulk class and still live: `cayenne-pepper`, `ground-nutmeg`,
  `tahini` (crown), `red-curry-paste` (crown), `adobo-seasoning`, `cajun-seasoning`, plus the wave-2 cells
  that re-landed on Badia/24 Mantra/Spice Hut. `achiote-paste` has already re-landed on
  *Chef Merito Achiote Condimentado, 42 oz* at $0.3867/oz, which is this class again.

## A number that was wrong, kept here because it shaped the argument

The wave-2 cost impact was first reported as **+$184.68 net across 151 recipes**, on the assumption that
each blocked cell would fall to the Great Value shelf item. Seven of ten did not. Measured against the
board that actually resulted: **-$13.89 across 148 recipes**. The sign flipped.

`bay-leaves` alone was reported at +$172.58 and is +$13.26 — the assumed landing was Great Value Bay
Leaves 0.12 oz at $25.1667/oz, the real one is El Guapo Mexican Bay Leaves 0.5 oz at $3.26/oz. The
arithmetic and the basis were right (`util_cost`, per-gram; the rate backs out to $1.4243/oz against the
board's $1.4369, and no line charges a whole starter jar). Only the price input was wrong.

**There is no cost emergency.** The board came out slightly cheaper, not inflated. The live harm from this
class is card fidelity — shoppers sent to products the store does not stock — not money.
