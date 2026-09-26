# MEASURE: does a Sam's Club product page carry the unit price its search listing leaves blank? (2026-09-26)

For Brad's ruling on `design/ready-for-brad/Q-2026-09-26-sams-name-only-size.md` ("C: read unit price from page").
Before building the page read, this measured whether the page has the number to read.

## The bar, written before the run

C is buildable as ruled only if **at least 15 of the 30 sampled pages (50%)** carry a unit price. Below that the page
read would add a paced fetch per blank row for too few admitted rows, and the ruling goes back to Brad.

## Method

- **Sample:** the 181 distinct item ids that `grocery/out/captures/sams-capture-2026-09-26.csv` (sha256 prefix
  57ac3ec358429a75) carries with a blank `up`, sorted, every 4th, first 30. Systematic, not hand-picked.
- **Read:** `fetch('/ip/<id>', {credentials: 'include'})` from a samsclub.com tab in Brad's signed-in Chrome, club shown as
  "Omaha Sam's Club", paced 2.6 s plus up to 1.4 s jitter (stores.json -> Sam's Club -> pull_profile). Parsed
  `__NEXT_DATA__` -> `props.pageProps.initialData.data.product`; read `priceInfo.currentPrice.priceString`,
  `priceInfo.unitPrice`, and `unitPrice` inside every `channelLevelPriceInfo[].channelPriceInfo`.
- **States:** WALL (are-you-human or px-captcha), NO-NEXTDATA, NO-PRODUCT, UP (a unit price anywhere), NO-UP.
- **Harness:** a one-off console script (not committed: the question does not recur unless Sam's changes its page).
  The builder the rest of this document counts with is `grocery/build-sams-deals.ps1`, blob
  88f9ba6fcc0ac69bfb8f916dd80ed74ac768f8dc.

**Harness and commit.** Page probe: the one-off console script above, run 2026-09-26. Counts: `grocery/build-sams-deals.ps1`
at blob 88f9ba6fcc0ac69bfb8f916dd80ed74ac768f8dc, run 2026-09-26.

## Result

**0 of 30 pages carry a unit price.** 30 of 30 answered HTTP 200 with the product and a current price; 0 walled, 0
unparseable. Against the bar of 15 of 30, C as ruled cannot admit rows.

Checks around it:
- **Control (the read is not broken):** 4Z2IZ92W3ADE, whose listing prints `20.8 c/oz`, carries
  `unitPrice.priceString "20.8 c/oz"` on its page. So the page has the field and the read finds it when Sam's fills it.
- **By hand, 4 more blank-listing ids** (4AS4VTWB0QZO Campbell's 50 oz, 3C83QLWE28G0, 6Y0JPZWQUDK1, 5IIDZKQUWLYD): unitPrice
  null on all 4. On the Campbell's page, `comparisonPrice` is null, every channel's unit price is null, the rendered text
  carries no per-unit figure, and "Product details" is empty: no size specification to read either.
- Coverage: 30 of 181 distinct blank ids (17%), one day, one club. It is a sample, but 0 of 30 against a bar of 15 is
  not a close call.

One row per case:

| id | listing price | name (from the capture) | http | page unit price | state |
|---|---|---|---|---|---|
| 0SF302EDGGNT | $12.98 | Marie Callender's Chicken Pot Pies, Frozen, 10 oz., 8 pk. | 200 | null | NO-UP |
| 0YFW6F4VYYCW | $12.98 | Auto Joe Multi-Purpose Surface Cleaning Gel, 4-Pack | 200 | null | NO-UP |
| 15VHXVLPCJ9G | $22.98 | Invisible Glass Cleaner Ultimate Glass Cleaning Kit | 200 | null | NO-UP |
| 1E0P4J5ES4OY | $13.46 | Member's Mark Fully Cooked Bacon, 10.5 oz. | 200 | null | NO-UP |
| 1GR54ZHJWFQA | $47.46 | Marathon Automated Hardwound Paper Towel Dispenser, Black | 200 | null | NO-UP |
| 1KNK94ZHAGFK | $10.48 | Rians French Chocolate Mousse 3.17 oz., 6 pk. | 200 | null | NO-UP |
| 1PMCG89UODQT | $59.00 | Angi Partial Furniture Assembly Service | 200 | null | NO-UP |
| 21GPQY0OY9X1 | $6.98 | Member's Mark Cheese and Cracker Snacks, 12 pk. | 200 | null | NO-UP |
| 26TN3MQIQL2Z | $21.58 | Zipfizz Energy Multi-Vitamin Hydration Drink Mix, Fruit Punch, 20 ct. | 200 | null | NO-UP |
| 2GCXAVTV81AX | $7.88 | Boscoli Italian Olive Salad, 32 oz. | 200 | null | NO-UP |
| 2IBDXR3NAHXO | $19.98 | The Good Charcoal Lump Charcoal - 27.5 lbs. | 200 | null | NO-UP |
| 2LCGO2IAWJRE | $13.56 | Creepy Pair of Underwear!, Hardcover | 200 | null | NO-UP |
| 2SB1RKOA3GYU | $21.98 | GE Soft White LED 60W Equivalent General Purpose A19 Light Bulbs 12-Pack | 200 | null | NO-UP |
| 2U8SIOWN0RJ7 | $5.87 | Red Seedless Grapes, 3 lbs. | 200 | null | NO-UP |
| 2ZGZD9TNO27M | $348.98 | Good Ideas Garden Wizard Eucalyptus Garden Bed | 200 | null | NO-UP |
| 372WKMJX4E21 | $10.87 | Jimmy Dean Fully Cooked Original Pork Sausage Links, 48 ct. | 200 | null | NO-UP |
| 3AJ2HVB0PFIV | $21.98 | GE Soft White LED 60W Equivalent General Purpose A19 Light Bulbs (12-Pac | 200 | null | NO-UP |
| 3F1PEM8WKV6B | $22.98 | Invisible Glass Cleaning Reach & Clean Tool with Glass Cleaner and Water | 200 | null | NO-UP |
| 3JC7CUVWH8AR | $10.98 | Activia Probiotic Dailies Yogurt Drink Variety Pack, 3.1 fl. oz., 24 ct. | 200 | null | NO-UP |
| 3WR3CM6MKFPY | $12.44 | Jimmy Dean Original Pancake and Sausage on a Stick, Frozen, 20 ct. | 200 | null | NO-UP |
| 40NRFT0CZIXO | $9.98 | Peak Great Northern Beans 10 lbs. | 200 | null | NO-UP |
| 433FG8DZ6APH | $17.98 | Gatorade Sports Drinks Variety Pack, 20 fl. oz., 24 pk. | 200 | null | NO-UP |
| 49S97VEW3WI9 | $12.84 | Member's Mark Everyday 1-Ply White Napkins 4 pks., 300 napkins/pk. | 200 | null | NO-UP |
| 4DUYZXTGLKQR | $7.98 | House Autry Chicken Breader Mix, 5 lbs. | 200 | null | NO-UP |
| 4IKZYTJ1YIH2 | $9.87 | Honey Smoked Fish Honey Salmon Stackers, 3 oz., 3 pk. | 200 | null | NO-UP |
| 4NGQ5VHSR3QO | $29.98 | Spa Sciences NURI Facial Skincare and Mask Infuser, Pink | 200 | null | NO-UP |
| 4TJQO3WY6EFA | $9.98 | Prestone 3pk BugWash Windshield Washer Fluid | 200 | null | NO-UP |
| 4XCG6EO7FJQX | $12.84 | Member's Mark Cheeseburger Sliders, Frozen, 2.3 oz., 16 ct. | 200 | null | NO-UP |
| 51JIY152U6FR | $11.98 | Ocean Spray Jellied Cranberry Sauce, 14 oz., 6 pk. | 200 | null | NO-UP |
| 58RZ4IUFRJ15 | $22.98 | Member's Mark Dutch Iris Blend Dormant Bulbs, 70pk | 200 | null | NO-UP |

## What was not built, and why

The ruling's executing step was a sweep change that reads the product-level unit price for rows the listing leaves
blank. On this evidence it would admit 0 rows, at the cost of one more paced Sam's fetch per blank row (181 distinct on
09-26, so about 8 minutes a sweep at the pull profile's mean 3.3 s) and that much more exposure to the wall Sam's is the
only store here to CAPTCHA on. A lane that reads nothing is dead code with a cost, so it was not built, and the
refusals stay exactly as they are ("rows whose size is only in the name stay refused until that is live"). The ruling
file now says so and asks for a new ruling.

## The refused-row counts, reconciled (the second half of the brief)

The ruling file's table said the triage's 36/32/19 (09-26/25/24) disagreed with a scratch regex's 36/111/61. Both were
counted over `grocery/out/sams/sams-rejects-2026-09-2{4,5,6}.json`, and those files were not written by the same rule:
the 09-24 and 09-25 files were written on 2026-09-25 (09:51 and 08:02), **before** the blank-unit-price proof carry
landed, and the 09-26 file after it (13:04). The carry admits a blank row whose exact id and name were proved on an
earlier day, so the older files hold rows today's builder would not refuse.

Recount under ONE rule: each day's capture rebuilt with today's builder (blob above) into a temp directory holding that
day's earlier `sams-deals-*.json` proofs, `-NoCursor`, `-LedgerRoot` temp; all three builds exit 0. Then counted with the
builder's own reason string: a reject whose reason is exactly `no unitPrice` (not the `no unitPrice (...)` carry
variants). Then the ruling file's "admissible under A" classifier (one measure xor one count, no per-lb or approx
marker), re-implemented in a scratch script, over those names.

| Day | Capture sha256 | Rejects (all) | Plain `no unitPrice` rows | Distinct names | Carried and published | Admissible under A | Triage said | Old scratch |
|---|---|---|---|---|---|---|---|---|
| 09-24 | f2f1c2ef63e6e072 | 125 | 49 | 43 | 64 | 19 of 43 (16 measure, 3 count) | 19 | 61 of 108 |
| 09-25 | 2a5dd377fee047b5 | 291 | 129 | 101 | 108 | 34 of 101 (26 measure, 8 count) | 32 | 111 of 211 |
| 09-26 | 57ac3ec358429a75 | 179 | 101 | 94 | 84 | 36 of 94 (19 measure, 17 count) | 36 | 36 of 94 |

**The triage's numbers are the right ones** for "what today's builder refuses": 19 and 36 match exactly and 32 against
34 on 09-25 is two names the two classifiers read differently (the classifier is a scratch regex on both sides, so that
split is unqualified). The 61 and 111 counted the pre-carry reject files, which included 64 and 108 rows the carry now
publishes. Re-reading the old files with the old scratch script reproduces 61 of 108 and 108 of 211 (the ruling file
said 111; 3 names differ between that script and this re-implementation, not chased).

## Knowledge consulted

Searched "sams unit price product page sample" and "flyer line product link verify". Used:
- `.claude/rules/grocery.md`: "Sam's Club joined them on 2026-09-18 (backlog I124): samsSweepToCsv opens with a
  #tc-store line naming the club each row was read at" (the club was read off the same signed-in page here).
- `.claude/rules/grocery.md`: "open the Network tab ... read the URL the page's own JavaScript calls" (the page's own
  `__NEXT_DATA__` product payload was read, the same source the search probe uses).
- `.claude/rules/measurement.md`: "Write the ACCEPTANCE BAR before the run" and "one row per case per arm" (the bar
  above, the table above).
- memory `browser-pull-js-lane-has-a-harness`: node is off PATH; the lane's harness is `grocery/test-pull-agent-lib.ps1`.
  Unused here because no lane code changed.
