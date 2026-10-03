# PLAN: Family Fare rows the aisle check could not place (2026-10-03)

Status: PROPOSED. Nothing is built. Evidence: `design/MEASURE-ff-aisle-blind-2026-10-03.md` and its case files under
`design/aisle-blind-2026-10/`.

## In plain words

Family Fare tells us which aisle a product sits in, and the board refuses a product that sits in the wrong aisle
for what it claims to be (a pizza-sauce bottle priced as frozen pizza). On the newest board, **141 of Family Fare's
463 prices (30%) and 12 of its 26 "cheapest" wins never had an aisle to check**, so they went through on trust.
That is how Twisted Tea, Cinnamon Twirls and a Magic Eraser cleaner reached the board.

Two separate reasons:

1. **Everyday prices (112 of the 141).** Their product links were lost in two bad file writes (2026-08-23 and
   2026-09-05). The links are still in our own older files, so we can put them back without asking the store for
   anything. Rebuilding the whole board with them restored: Twisted Tea comes off, 106 prices gain the product
   link they were missing, 12 show a different product at exactly the same price, and **no price and no
   "cheapest" win changes**.
2. **Weekly Ad prices (29 of the 141).** The ad reader receives each product's id from the store and throws it away,
   so an ad row can only borrow an aisle by finding an everyday product with the exact same name, and it finds one
   a third of the time. Better name matching does not help (0 more found). The fix is to keep what the store sends.

Recommendation: restore the lost links (W2), keep the store's id and link on ad rows (W1), report what is still
unplaced on every build (W4), and review a short list of aisles the allowlist does not cover yet (W3). Do NOT
refuse unplaced rows: a could-not-look is never a pass and never a fail, and refusing would have removed 141
prices, 106 of which the check passes once it can look.

## Knowledge consulted

- `searched "aisle admission blind family fare department"` (estate) and `"carried row lost canonical_url identity"`.
- memory `aisle-test-built` (C--Codex): the aisle test gates crown flips on the store's own shelf department, not a
  semantic score. Why W1 keeps the store's own link rather than inferring a department from a similar name.
- memory `fence-vocabulary-vs-brand-name`: "A type-word exclusion cannot see a product whose retail name carries only
  BRAND + FLAVOR; the store's own shelf can." Cinnamon Twirls is this shape, and it held a crown with no shelf.
- `.claude/rules/ops-and-gates.md` og-32: "A BLIND case that gates a BLOCK is scored on the BLOCK. Count the cases
  the blind branch SUPPRESSED." W4 is this count.
- memory `fail-open-reads-as-empty` and `freshop-probes-share-the-production-budget`: Freshop answers a throttle
  with an empty 200 or a 400 carrying 429, and every probe spends the price pull's budget; run it after 10:30, in
  slices. Why W2 restores from history (0 requests) instead of re-searching 1,740 rows, and why W1 step 0 waits.
- `software-craft/applies-here.md` 81: "Test that the argument meant to change changed correctly AND that every
  argument not meant to change is unchanged." W2's restore asserts prices and dates unchanged (arm B did, by md5).
- `.claude/rules/grocery.md` gr-12: "Rotation and publish limit are both the quarter ... Never shorten them." Why
  aging out the URL-less rows early is rejected.
- `aisle-lib.ps1` header: the Kraft slug case, a real product refused "on a word the store never wrote". Why no
  fuzzy name join may supply a department.

## The rule this plan applies

Brad: a could-not-look is never a pass and never a fail. Today BLIND is silently a pass at admission
(`Get-AisleAdmissionRefusal`: `if (-not $Dept) { return $null }`). The plan does not turn it into a fail. It makes
the engine LOOK where the answer exists (W2: 107 of the 112 everyday cells; W1: the 29 ad cells, pending step 0),
and COUNTS the rest out loud (W4).

## Options considered

| option | what it does to the current board | verdict |
|---|---|---|
| Refuse BLIND for all Family Fare rows | 141 cells and 12 crowns withdrawn; of the 112 everyday ones, 106 pass the check once it can look | rejected: a could-not-look becomes a fail, and mostly refuses real product |
| Refuse BLIND for ad rows only | 29 cells, 7 crowns withdrawn, none checked | rejected, same reason |
| Age out carried rows with no URL | 112 cells, 5 crowns withdrawn ahead of their quarter | rejected: shortens the quarter (gr-12); 106 of 112 are real |
| Normalised or fuzzy name join for ad rows | normalised key finds 0 of 363; nearest names are often other products (`Halo Clementines` to `Halo Top` ice cream in freezer) | rejected: would refuse real products on a shelf the store never named |
| Re-search the 1,740 rows on Freshop | 1,740 to 3,480 requests against a wall of roughly 40 to 130 a window, shared with the price pull | rejected: history holds 1,718 of them for 0 requests |
| **Restore from history (W2) + keep the circular's identity (W1) + count the rest (W4)** | measured below | **recommended** |

## W2. Put back the identity the carry lost (everyday rows) - first

**What.** In `grocery/pull-regular-familyfare.ps1`, the carry loop (the `if ($prevF)` block):

- **W2a, the guard (stops a recurrence, whatever the cause).** A carried row may not come out of `Norm-Row` with less
  identity than its source row had: if the source row carried `canonical_url`/`product_id` and the output does
  not, copy them across, recompute `dept`/`aisle` through `Get-AisleDept`/`Get-AisleShelf`, and count it as
  `identity_dropped_in_carry=N` on the run line (expected 0). The 08-23 and 09-05 losses have no reproduced cause,
  so the guard is placed on the outcome, not on a guessed mechanism.
- **W2b, the one-time restore (self-retiring).** When a carried row still has no `canonical_url`, look it up in the
  dated history by exact item + size + regular price, newest file first, stopping when every such row is resolved
  or the files run out. Restore only when the key resolves to exactly ONE URL (1,717 rows; the 4 with several URLs
  and the 19 with none stay as they are). Stamp `identity_restored_from: <file date>` on a restored row and
  `identity_lookup: none` on a row that found nothing, so neither is looked up again; `Norm-Row`'s preserved-field
  list gains both. Prices, `as_of` and `carried_forward` are never touched.

**Why here.** The pull is the only writer of `out/regular/family-fare-regular-*.json` and runs in the main
checkout, where the file lives. A separate repair script would have to write the main tree from somewhere; the
pull already does. No new script, no new schedule.

**Cost.** 0 store requests. W2a: one hashtable read per carried row. W2b: one walk of the dated history on the first
run (76 files, about 340 MB; to be timed in the first run and stated in the commit), then nothing, because every row
is stamped. Seconds per push: 0 (the self-test is hermetic, below).

**Blast radius, measured (arm B, over the inputs of the 2026-10-02 08:10 board).** Of 2,911 cells across every store:
1 lost (Family Fare iced-tea, Twisted Tea, already ruled in `known-wrong.json`), 0 prices moved, 0 crowns changed,
106 Family Fare cells gain a product link, and 12 Family Fare cells show a different product at the identical
per-unit price (equal-price ties; 2 of them go from sale to everyday at the same price: ground-turkey, tomatoes).
The engine's aisle refusals rise from 27 to 45; the 18 new ones hold no cell. About 7 of the 18 look like real
product the allowlist does not cover (W3).

**Acceptance bar (written before the build).**
- Everyday file: rows with no `canonical_url` fall from 1,740 to at most 23 (the 4 + 19 unresolved), with 0 rows
  whose item, prices, size, `as_of` or `carried_forward` changed (byte comparison of those fields, before and after).
- Board, measured with the committed probe on the first board built after it: no-department everyday cells fall
  from 112 to at most 5; every cell that changes is listed in the landing commit with its old and new product, and
  any crown change is hand-checked before the push.

**Fixtures** (in the pull's `-SelfTest`, named per og-05):
- MUST FIRE: a carried row whose source has `canonical_url` comes out of a stripping `Norm-Row` stand-in with none;
  the guard restores it and counts 1.
- MUST FIRE: a URL-less carried row whose exact key appears once in a fixture history file gets that URL, its
  `product_id`, `dept`, `aisle` and the stamp.
- MUST NOT FIRE: a key that resolves to two URLs restores nothing and is stamped `identity_lookup: none`.
- MUST NOT FIRE: a key that matches by name but not by size or price restores nothing.
- CLEAN TWIN: the restored row's price fields and `as_of` are byte-identical to the input row's.
- CLEAN TWIN: a stamped row is not looked up again (the history reader is a seam; the second pass calls it 0 times).

## W1. Keep the store's identity on Weekly Ad rows - after step 0

**Step 0, a measurement (after the 10:30 window, one slice).** Read ONE page (100 rows) of the current circular with
`fields=id,name,size,base_price,sale_price,canonical_url`. Bar, written now: at least 90 of the 100 rows carry a
`canonical_url` whose shelf path reduces to a department through `Get-AisleDept`. If the bar fails, W1 ships the id
alone (below) and the ad rows that match no everyday id stay BLIND and counted (W4). One request; record it beside
this plan as a MEASURE row with the date and time.

**What.**
- `grocery/pull-grocery-ads.ps1` (`Pull-FamilyFare`): add `canonical_url` to the circular's `fields=` and emit
  `product_id` and `canonical_url` on each Family Fare ad row. 0 extra requests: same calls, two more fields.
- `grocery/compare-deals/identity.ps1:135`: pass `-ProductId (Get-RowProductId $d) -SrcRow $d` for Family Fare ad
  rows, as the everyday rows already do, so the id and the row's own link reach the deal.
- `grocery/aisle-lib.ps1`: `Get-AisleShelfDept` takes the row's OWN `canonical_url` and reads it first, then the id
  index, then the exact name. Only the row's own link: a link the board resolved from elsewhere
  (`url-inputs`, `resolve-familyfare-urls.ps1`'s `resolved-commodity`) may be a different product and never
  supplies a department.

**Blast radius.** Not measurable until step 0: 363 admitted ad pairs, 29 cells and 7 crowns become judgeable, and
only the store's answer says how many pass. After the build, before landing: run the committed probe on a scratch
rebuild with a fresh ads file and list every ad cell and crown that moves. Bar: no-department ad pairs fall from
363 of 534 (68.0%) to at most 10% of admitted ad pairs; every newly refused ad cell is hand-checked against the
store page, and a refused real product is an allowlist entry (W3), never a revert of W1.

**Fixtures.** `pull-grocery-ads -SelfTest`: MUST FIRE, a circular row with `id` and `canonical_url` is emitted with
both; CLEAN TWIN, a row without them is emitted exactly as today. `aisle-test -SelfTest` (it drives aisle-lib):
MUST FIRE, an ad row whose own URL says `beer_wine_spirits` is refused from iced-tea with no everyday twin;
MUST NOT FIRE, a row whose BOARD link (not its own) carries a shelf path stays BLIND.

## W4. Count what is still unplaced - with W2

compare-deals already prints `aisle-admission: refused N`. Extend that same line with the blind count, split as the
measurement is: `blind <n> of <admitted> admitted Family Fare rows (everyday a/b, sale c/d)`, and record the same
numbers in the board's `health` block. `aisle-test.ps1`, the live-board outcome watch, prints the BLIND cells and
crowns it already sees. No refusal, no new alert, no new gate: the number is spoken on every build, so a regression
like 09-05 (identity lost on 4,500 rows) shows up the next morning as a jump, not as wrong products a month later.
Cost: one line, 0 seconds. Fixture: compare-deals `-SelfTest` gains a CLEAN TWIN that the line names both halves.

## W3. Allowlist entries the restored aisles exposed - independent, no cell held today

Arm B refused these rows, none of which holds a cell. They look like real product in an aisle the allowlist does not
yet allow; each is a per-commodity entry in `$AISLE_COMMODITY_DEPT` after a look at the store page, never a wider
category (adding `beer_wine_spirits` to `snacks` would re-admit Twisted Tea under iced-tea):
onion-powder, italian-seasoning, ground-nutmeg, ground-cloves, cajun-seasoning, cumin-seeds (spices shelved in
`fresh_fruits_vegetables`, the shape `chili-powder` and `garlic-powder` already have); salsa (fresh salsa in
produce); tortilla-chips (Calidad in `bakery`); english-muffins (gluten-free in `freezer`); chicken-noodle-soup and
tomato-soup (fresh soups in `deli`); potato-gnocchi and cheese-tortellini (Rana in `deli`); dinner-rolls, muffins,
egg-noodles (Reames frozen noodles; a ruling on whether frozen noodles are `egg-noodles` is Brad's).
The rest of the 45 are wrong products and the refusal is the point (Iams puppy food, croutons, a coconut-oil butter
spread, a pineapple body moisturiser under honey, Birds Eye frozen vegetables under canned).

## Order and landing

W2 + W4 together (zero requests, measured), then W1 step 0 after a 10:30 window, then W1, then W3 as the store pages
are checked. Each lands through `ops\push-main.ps1` from its own branch; the board-changing ones (W2, W1) state their
measured cell list in the commit.

## Decisions

None blocks W2 or W4. One question rides with W3: are Reames frozen egg noodles `egg-noodles`? Default if unanswered:
leave them refused (BLOCK costs a price we would publish; it does not publish a wrong one).
