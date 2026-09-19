# Adjudication standard applied, 2026-09-17 sample

Read with `verification-decisions-2026-08-15-notes.md`, whose rules this run applies unchanged: a live
markdown the board does not carry is `ok`, a flavour sibling at the identical size and price is `ok`, a
near-tie inside 1% is `ok`, not-cheapest is `wrong-price`, and an online multipack is `wrong-size`.

## Coverage
100 of 100 sampled cells answered by seven blind store agents on 2026-09-19, all reachable. The blind
findings were committed at 3459d590c on claude/verify-2026-09-19 before the sealed key was opened (that
hash is the branch commit; the push rebases it). The adjudicator auto-scored 54 ok and 5 missing and sent
41 to review. Where a review row turned on the board's own product, a second, SIGHTED agent opened that
product at the store after the freeze: 17 rows across Family Fare, Fareway, Sam's Club, Hy-Vee, Aldi and
Walmart.

## Rules applied that the 2026-08-15 notes do not state

**The board was two days old when checked.** The board is dated 2026-09-17 (a Thursday) and the look ran
on 2026-09-19 (a Saturday). Where today's shelf is HIGHER than the board for the same product and the
page shows no sale, I scored `wrong-price`. The board's number may have been an ad or a price that
changed in those two days, and nothing on the page can tell those apart. 11 of the 25 `wrong-price`
verdicts are this subclass: the same product at a different price with no sale either way (Family Fare
mango and leeks; Fareway drumsticks, bell pepper and turkey breast; Hy-Vee olives, eggs and B-size gold
potatoes; Walmart gelatin and razors; Sam's cheddar). The potatoes and the cheddar are also no longer the
cheapest qualifying product. They are reported separately so that
drift does not read as a matching failure. The Hy-Vee olives go the other way: the board is $0.22 above a
regular shelf price.

**A product that cannot be bought at the store is not its shelf price.** This extends the multipack rule
from 2026-08-15. The board's stated basis is the in-store or in-club price, so a product that is
shipping-only from that store does not count:
- **`missing`, where no in-store product exists at all:** Walmart Chinese five spice (the board's
  McCormick is ship-only), Sam's honey mustard and Sam's sesame seeds (both ship-only at the Omaha club).
- **`wrong-price`, where the commodity IS sold in-store but the board's product is not:** Sam's sweetened
  condensed milk (Magnolia is ship-only), Sam's baby food (Gerber 30 ct is ship-only), Walmart baby food
  (the Parent's Choice 12 ct is out of stock at L St and ship-only), and Walmart frozen Brussels sprouts
  (the board's item is out of stock everywhere from L St, and a cheaper plain Great Value bag is on the
  shelf).

**A board product the store does not list, while the commodity is sold, is `wrong-price`.** Examples:
Sam's Eckrich 42 oz, not found; Family Fare Zamora ancho 1 lb and organic small cantaloupe, not listed.

**A size the store does not sell is `wrong-size`.** Fareway fresh green beans are priced on a 32 oz bag
the store does not list; only 12 oz exists. Fareway canned green beans take their per-unit from the
15.25 oz end of a "14.5-15.25 oz" corn/peas/beans ad range, while the green bean can is 14.5 oz. That is
a 5% error, and wrong-size rather than a tie.

**A multi-buy with no stated minimum counts as the unit price.** Family Fare's Pampa sweet relish reads
"4 for $5.00" in regular-price styling, with no must-buy wording, so it counts as $1.25 each. That makes
it cheaper than the board's Our Family relish. This is the least certain verdict in the run: if a single
jar rings up at more than $1.25, it flips to `ok`.

**Identity failures, each a candidate for Brad's known-wrong ruling (none filed):**
- Aldi "Green chilli": Burman's Green Chili Squeeze Aioli, a condiment.
- Aldi "Coffee Creamer": Friendly Farms Half & Half. Half & Half is its own commodity in
  `commodities.json`.
- Hy-Vee "Brussels Sprouts": That's Smart frozen. The fresh commodity's own rule excludes `frozen`, and
  frozen is a separate commodity.
- Fareway "Fresh Bean Sprouts": La Choy canned. Auto-scored `missing` because the store sells no fresh
  sprouts; either way the board prices a canned product as fresh.
- Walmart "Apricots": "Fresh Apricot, Each" priced per lb. Auto-scored `missing` because none are sold
  this week, most likely out of season.

**`ok` after a sighted check:** Aldi broccoli crowns are listed at exactly $2.09/lb; the blind agent missed
them. Fareway's Lysol Bam at its $6.99 regular is the cheapest qualifying product at regular prices, so
today's markdowns are live sales. Sam's Caesar kit and corn dogs carry instant savings, and the board holds
the regular price in both cases.
