# Board accuracy: why 36 of 100 were wrong, and the fix (2026-09-19)

Brad, 2026-09-19, on the verification alert (37.1% whole-board, 95% CI 24.2% to 52.0%, 36 defects in 100
verified, against 18.2% on the 2026-08-15 board): *"Triage WHY ... find out what scheduled task or process
is causing this ... fix ... future proof ... correct the entire board."*

## Knowledge consulted

- `knowledge-search` over the skills store for stale price, carry, ship-only, pickup, known-wrong and
  verification defect: nothing applicable (the hits were general data-quality sections, none on price age).
- Memories: `walmart-marketplace-rows-pollute-the-union` (the channel hole was known on 2026-08-29 and left
  open for any item seen only before the field existed), `known-wrong-is-the-main-board-corrector`,
  `a-could-not-look-must-not-settle-the-question`, `recommend-the-best-long-term-solution`.
- `.claude/rules/grocery.md`, `ops-and-gates.md` (fail loudly, ratchets not red-on-day-one gates, a floor
  for a producer that stops), `measurement.md` (bars before the run, denominators).
- `docs/RUNTIME-MAP.md` (the daily capture takes "total terms / 90 days, per store").

## 1. What broke: no scheduled task failed. A policy change did it

Every TC scheduled task is green. What changed is **commit 8f2c29a83 (2026-08-20)**, which moved everyday
price rows from a 14-day life to a **90-day carry** so items would not fall off the board while waiting for
their quarterly re-capture, and 2026-08-22, when Baker's (which re-priced all 598 terms daily) joined the
same 7-terms-a-day rotation. The commit measured coverage ("went UP everywhere") and never measured accuracy.
The 18.2% board predates it; the 37.1% board postdates it.

What the rotation actually delivered, 2026-08-19 to 2026-09-18 (`out/capture-cursor-log.jsonl`):

| Store | Terms re-priced per active day | Days the cursor moved (of 31) |
|---|---|---|
| Walmart, Sam's, Aldi, Fareway, Baker's | about 7 | 17 to 25 |
| Hy-Vee, Family Fare | about 21 to 22 | 16 to 26 |

About 600 terms per store at 7 a day is an 86-day cycle. On the 09-17 board only **25% of the 3,189 priced
cells were read in the last 7 days; the median price was 17 days old, the oldest 65**. Fareway's cursor had
not moved since 09-12.

**Defect rate climbs with the age of the price behind the cell** (the 100 verified cells):

| Age at board build | Defects |
|---|---|
| 0 to 7 days | 6 of 26 |
| 8 to 30 days | 15 of 44 |
| 31 to 60 days | 13 of 27 |
| over 60 days | 2 of 2 |

Age is the largest driver but not the only one: fresh prices still failed 6 of 26.

## 2. Every defect, by cause

| Cause | Count | Cells |
|---|---|---|
| **A. Stale**: the shelf moved or the product left, and the row was 10 to 64 days old | 11 | FF ancho, leeks, mango, cantaloupe; Fareway turkey, drumsticks, fresh green beans; Sam's cheddar, kielbasa; Walmart gelatin, razors |
| **B. Wrong source**: read at the retired Hy-Vee store or copied off our own board | 4 | Hy-Vee olives, eggs, gold potatoes; Fareway bell pepper |
| **C. Not buyable at the store**: ship-only, out of stock at the pinned store, online multipack, out of season | 9 | Sam's honey mustard, sesame, condensed milk, baby food; Walmart five spice, baby food, baked beans 12-pack, frozen Brussels sprouts, apricots |
| **D. Wrong product**: the matcher reads only the name | 4 | Aldi aioli as green chilli, half & half as coffee creamer; Hy-Vee frozen as fresh Brussels sprouts; Fareway canned as fresh bean sprouts |
| **E. Not cheapest**: a rule or parse bug hid the cheaper product | 7 | Baker's coconut aminos (global `sauce`), Sam's sponges (global `wrapped`), Sam's wipes (process id stamped as a product id, fixed by I191 after this board), Fareway hand soap (bogus 221 fl oz size), FF relish ("4 for $5" parsed as $45), Hy-Vee apple juice (shelf-tag refusal deletes the row), Walmart floor cleaner (a deliberate exclude, needs a ruling) |
| **F. Size basis** | 1 | Fareway canned green beans (ad size range read at its largest end) |

**24 of 36 (A, B, C) are one design flaw: the board publishes a price unless something proves it wrong.**
Nothing requires a price to prove *when* it was read, *where* it was read, or that a shopper *can buy it
there*. The evidence that it is fail-open, from the four investigations:

- **When**: no publish-time age check exists. Guard 9 only fails a store whose newest FILE is over 90 days.
  Hy-Vee's carry has no age limit at all (612 rows still dated July). Nothing re-captures the oldest cells
  first; the order is a cursor.
- **Where**: nothing retires rows when a store's pinned identity changes. **202 of 462 Hy-Vee cells and 21
  of its 36 crowns** still come from Omaha #01 (retired 2026-08-21) or undated pre-switch rows; the puller
  copies the old label forever. 20 Walmart cells (12 crowns) come from **Bellevue 68123** batch captures.
- **Self-sourced**: 7 `hunter-*-regular-2026-08-16.json` files never expire and supply **36 cells, 9
  crowns**. 12 of their 83 rows were copied off the engine's own board and labelled "in-store verified" (the
  $0.77 bell pepper, live shelf $1.17).
- **Buyable**: the channel gate admits `NO-SIGNAL`. Sam's captures record no fulfilment at all; Walmart
  only since 2026-08-30; no store records in-stock at the pinned store.
- **The page says "Seven stores, checked every morning"** (`build-deals-page.ps1:471`). The median cell was
  17 days old. That line is a claim to paying readers that the data did not support.

## 3. The design principle for the fix

**Invert the admission rule: a price is published only when it carries positive proof, and missing proof
withholds the cell and queues its re-capture.** Every class above becomes a refusal by construction rather
than a blocklist entry after a reader finds it. This is the same shape the estate already trusts for the
store line (`#tc-store`: a capture that cannot name its store is refused), extended from files to every
published cell.

The contract a published everyday cell must satisfy (one library, one function, self-tested):

1. **Read date** (`as_of`) present and no older than the **publish limit**.
2. **Read store** equals the store's pinned identity in `stores.json` (or the store's identity is a request
   parameter of the capture that produced it, stamped by that capture).
3. **Channel**: a store read, buyable in-store or for pickup at that store. Walmart `fulfillment=STORE`;
   Sam's in-club/pickup availability; Instacart stores already prove in-store mode. `NO-SIGNAL` refuses.
4. **Origin**: a store read. A row derived from our own board, or from a file no capture refreshes, refuses.

A withheld cell is not a silent gap: it is counted, printed with its denominator, and put at the head of
the next capture worklist (the `Get-WalmartRulingOwed` shape: derived, self-emptying, never hand-discharged).

## 4. The fixes

### 4a. Provenance gate (the future-proofing core)
- `grocery/provenance-contract-lib.ps1`: `Test-CellProvenance` implements the four checks above and
  returns a named refusal (`STALE`, `WRONG-STORE`, `UNPROVEN-CHANNEL`, `SELF-SOURCED`). compare-deals calls
  it in admission, after identity and before ranking. Self-test with one MUST FIRE per founding bug in this
  document, MUST NOT FIRE for a legal fresh row, and a CLEAN TWIN at exactly the publish limit and one day
  past it (the I196 rule).
- The publish limit is **single-sourced in `capture-policy.ps1`** as `MaxPublishAgeDays`, and the board
  carries each cell's `as_of` so every downstream reader can see it.
- **The capacity gate that would have stopped 8f2c29a83:** `capture-policy.ps1`'s self-test asserts that
  for every store, board terms / daily budget is no more than the freshness target. A policy change that
  makes the rotation slower than the SLO now fails at push, with the arithmetic in the message, instead of
  going live and being found by a reader six weeks later.

### 4b. Capacity sized to the SLO, oldest first
- Daily budget per store = ceil(terms / freshness target), not ceil(terms / 90), capped by each store's
  measured limit. This is ONE rule for every store, which keeps Brad's 2026-08-22 ruling ("Baker's should be
  following the SAME logic as literally everyone else") while restoring the capacity it cost.
- The worklist takes the OLDEST cells first (crowns first within a tie), not the next cursor position, so a
  missed day heals itself instead of pushing every term's turn back.
- Family Fare is the one server store with a measured limit (about 40 calls per window): it gets more
  windows, not a bigger window.

### 4c. Store identity on every row
- Hy-Vee rows are stamped with the storeId that answered them; carried rows keep it; the contract refuses
  any row whose store differs from the pinned identity. Same rule for Walmart (5361) and Fareway (531573).
  A pinned-store change then retires the old store's rows automatically, which is the step that was done by
  hand for Walmart twice and never for Hy-Vee.

### 4d. Retire the self-sourced files
- The `hunter-*-regular-*.json` rows stop being an everyday source. `promote-ingredient-queue.ps1` refuses a
  row whose evidence is the board itself.

### 4e. Channel proof
- Sam's lane (`pull-sams-instore.js`) captures in-club/pickup availability from the search payload and
  `build-sams-deals.ps1` writes it per row, and writes `store_location` from the capture rather than a
  literal. Walmart `NO-SIGNAL` refuses.

### 4f. Identity and parse defects (class-level, not one-off)
- Form words from the store's own department: a row whose store department says Frozen or Canned cannot
  match a commodity whose rule excludes that form (Hy-Vee carries the department today; it is not read).
- Condiment fence for produce commodities (aioli, squeeze, mayo) and a half & half fence on coffee-creamer.
- Global-exclude relaxes where the global token hides the real product: `sauce` for coconut aminos,
  `wrapped` for sponges.
- Family Fare multi-buy parse ("4 for $5.00" is $1.25 each); Fareway selector refuses a size that
  contradicts its own link slug; Hy-Vee shelf-tag refusal re-queues the row instead of deleting it.

### 4g. Honest page copy
- "Checked every morning" is replaced with what is true: each store line states how recently its prices
  were read (the newest and the share within the SLO). Layout change, so it gets the 375px check.

### 4h. Detection that cannot go quiet
- A daily freshness line per store in the chain, with its denominator (`cells within SLO / priced cells`),
  alerting on a FALL (the producer-stops floor the ops rules require), not only on a breach.
- The 14-day blind verification stays as the independent check, and the alert registration and credential
  defects it hit today are the separate I232 follow-up already running.

## 5. Correcting the whole board

1. Land 4a to 4f, gated.
2. **Full fresh capture of every store**: Baker's and Hy-Vee by API in one run; Family Fare across several
   windows; Walmart, Sam's, Aldi and Fareway full pulls through Brad's Chrome.
3. Rebuild through the normal chain. The contract withholds anything the fresh capture did not re-prove,
   so the published board contains only cells read in the SLO window, at the pinned store, buyable there.
4. File the four wrong-product cells to `known-wrong.json` (Brad's ruling today authorises correcting the
   board) and publish.
5. **Re-verify with a new blind sample of 100 on the corrected board.**

## 6. Acceptance bars, written before the run

- **Coverage is reported, not hidden**: the corrected board prints `published cells / cells priced on the
  2026-09-17 board` per store. A cell withheld for missing proof is a smaller board, never a wrong price.
- **The re-verification passes** at **at most 10 defects in at least 90 verified cells**, and **zero**
  defects of classes B, C or D (the ones the contract and identity fixes exist to make impossible). With 100
  cells the interval is about plus or minus 9 points, so this bar can show a large improvement and cannot
  certify a small one; it is stated that way on purpose.
- **Freshness**: at least 95% of published cells read within the freshness target on the day of publish.

## 7. Decisions taken, which Brad can reverse

| Decision | Chosen | Why |
|---|---|---|
| Freshness target / hard publish limit | **7 days target, 14 days hard limit** | 14 is the regime that measured 18.2%; 7 is what "checked every morning" can honestly approximate for walled stores |
| Stale or unproven cell | **Withheld, not shown with a date** | "Understating is exactly as wrong as overstating": a withheld cell is a gap, a stale one is a wrong number |
| Walmart floor cleaner (a multi-purpose cleaner that says floor cleaner) | **Left as is, flagged** | It is a deliberate exclude, so it needs Brad's ruling, not mine |
| Baker's "same logic" ruling | **Kept**: one SLO-driven rule for every store | Restores the capacity without making Baker's a special case |

## Addendum, 2026-09-19 afternoon: what switching the contract on broke downstream, and what was found

### Fixed and landed with the contract
- **The recipe overlay resurrected withheld staples.** It dropped a July recipe-snapshot row only when its
  id was published on today's board, so every staple the contract emptied came back from the snapshot.
  The staple rule-set now owns its ids. 117 of 184 snapshot rows defer to the weekly board; the
  known-wrong audit, which failed on 6 resurrected rows, reads 0 of 309.
- **One unproven allowlist bid killed the whole recost.** cost-recipes threw on dried-guajillo-chiles and
  costed none of 584 recipes; the chain logged success because it never read the exit code. The bid is
  now refused on its own and named in cost-flags, and the chain pages "Recipe recost failed".
- **The recipe run overwrote the staple run's withheld list.** Named per run now.
- **Coverage alarm.** A transition ack, expiring 2026-09-23, for the five stores whose counts drop the day
  the contract switches on.

### Search-term quality is part of why commodities vanish
On 2026-09-19, 30 of 602 terms returned nothing at Baker's. A hand probe found products on the shelf for
several once a packaging word or plural went: beef chuck roast, pork tenderloin, minced garlic, fajita
seasoning, jasmine rice, guajillo. Baker's now retries an empty term once without packaging words and in the
singular, never dropping a form word. Dried arbol needed a spelling ("chili de arbol"), which no rule could
reach, so it carries two terms. The other 20 of the 22 emptied commodities are with a recovery lane that
checks each store for a real in-store listing or records not-carried with two wordings.

### Open, measured, not yet changed
1. **51 recipe lines across 42 recipes have no price basis on the gated board**, all 11 ingredients among
   the emptied commodities. Guajillo and arbol (22 lines) are covered by the Baker's fixes above from the
   next capture. An unpriced line makes a recipe read LOW. If the recovery lane cannot find an in-store
   price for an ingredient, the precedent (doubanjiang, 2026-08-22) is that its recipes become drafts until
   a real capture lands. That is a publishing decision for Brad.
2. **The recipe snapshot is undated.** After the overlay fix, 67 recipe-only rows remain in
   recipe-board-everyday.json (week_of 2026-07-06), and none of its 894 store cells carries a date, so the
   14-day rule cannot reach them. The daily recipe compare run already reads today's captures; the durable
   fix is to take its gated everyday cells as well as its sale cells and retire the snapshot.
3. **The recost reads yesterday's feed.** check-ad-cycles runs cost-recipes before export-feed, and
   export-feed reads recipe costs, so each day's carriage verdicts come from the previous day's feed. On the
   first gated day the recost judges carriage from the ungated feed.
