# PLAN: The Ingredient Vocabulary - Closing the Namespace That Zeroed Costs We Already Had

Date: 2026-08-16, same day as the discovery. Status: PROPOSED, awaiting Brad's direction. Plan only -
nothing here is built.
Prereq reading: design\PLAN-token-efficiency-2026-08-16.md section 3 (B12), then this file. This plan
SUPERSEDES that file's characterization of the "23 unbid specs": most of those ingredients were never
missing. They were mis-named.

## 0. What actually happened - five failures, in order

The estate HAD the prices. `meal-prep\db\ingredients.json` carries 282 rows, 276 with bids, including
"1/3 Fat Cream Cheese", "Light Sour Cream", "Broccoli Florets", "Dried Parsley", "Green Bell Peppers",
"White Mushrooms". The blocked recipes wrote "Cream Cheese", "Sour Cream", "Broccoli", "Fresh Parsley",
"Yellow Bell Pepper", "Portobello Mushrooms". Same estate, same food (mostly), different strings - and
every layer below treated the string miss as a missing price.

1. **The mapper and writer mint canon names freely.** Nothing shows them the existing vocabulary and
   nothing binds them to it. The 542 live r300-era recipes work because they were built FROM that
   vocabulary; the new run's agents free-texted plausible names and diverged. An open namespace where a
   closed one was intended - the exact failure the commodity-registrar exists to prevent for commodity
   ids, never applied to item names. (bread-crumbs vs breadcrumbs cost 2.9x once; this is the same
   class, wearing item names.)

2. **The lookup is exact-match with a silent floor.** `build-v2-spec.ps1` resolves canon name ->
   ingredient row by `ContainsKey`. "Cream Cheese" misses "1/3 Fat Cream Cheese" by a word and the line
   silently costs $0.00. (Since 2026-08-16 it throws - but it throws the WRONG diagnosis: "no bid",
   when the truth is "wrong name, the bid is right there".)

3. **Every downstream layer inherited the wrong words.** The batch auditor reported "unpriced". My
   unbid sweep said "carry no bid". The efficiency plan said "wire the bids". The live-recipes task
   said "needs capture". Four layers repeated "the price is missing" when the dominant truth was "the
   name is wrong" - and nobody compared the failing names against the vocabulary, because no tool
   existed to do it.

4. **The verification tool lied and I believed it.** My first check parsed ingredients.json wrongly
   (read an array as a dictionary), reported 8 entries and 0 matches, and I treated that as
   confirmation. A 544-recipe estate cannot have an 8-entry ingredient map - the number was absurd on
   its face, and nothing (tool or discipline) enforced a plausibility floor. Brad caught it, not a gate.

5. **The mischaracterization is now stored as memory.** `ingredient-resolutions.json` was seeded with
   30 rows reading "no bid in db\ingredients.json as of 2026-08-16" - FALSE for most of them. Left
   uncorrected, the new memory system would feed the wrong fact to every future mapper. The remedy for
   bad institutional memory is the same as for bad prices: correct the record, never leave it plausible.

Net: 4 live pages understating cost, 10 recipes dead in wave 1, 17 in-flight recipes "blocked" on
ingredients we mostly own, and a day of remediation aimed at the wrong fix.

## 0a. DECISIONS - Brad, 2026-08-16

1. **Alias policy: CASE-BY-CASE on the worklist.** No blanket rule for form differences. Every
   form-difference line (full-fat vs 1/3-fat cream cheese, fresh vs dried parsley, portobello vs white
   mushrooms) is ruled individually by Brad. Consequence for V2: the alias mechanism ships, but it is
   populated only by rulings - never by a heuristic, never in bulk, and the worklist's DIFFERENT-FORM
   class carries no default remedy.
2. **Run recovery: RENAME-FIRST, then drain.** Nothing publishes until the vocabulary work lands. The
   two audit-clean recipes (turkey-zucchini-noodle-casserole, chicken-piccata-skillet) wait and ride a
   fuller wave rather than paying a whole-wave audit for two. The current run stays stopped.
3. **Adjudication: interactive, in small batches.** Brad rules each worklist line himself, prompted a
   few at a time with two suggested remedies and a free-text option. V5's output must therefore be
   shaped for that: one line = one decision, evidence attached, no line requiring research to answer.
4. **Scope: FULL V1-V8, in plan order.** The model-tier experiment stays uncoupled.

## 0b. MEASURED, once V1 existed - and it corrects section 0 again

Running `ingredient-vocab.ps1 -Missing` over all 30 blocked names:

**The four LIVE recipes were never gaps at all.** `Bulgur Wheat`, `Korean Rice Cakes`, `Sumac` and
`Keto Bun` all RESOLVE, with real bids (`bulgur-wheat`, `korean-rice-cakes`, `sumac`, `keto-bun`), and
the spec canon names match those rows EXACTLY. Their specs simply predate the bid rows.
**Remedy: rebuild + re-cost. No capture, no registrar, no new prices.** The efficiency plan's B12
entry, the unbid sweep's output, and the spawned live-recipes task all said otherwise; all three were
wrong, and the third was dispatched on that wrong basis.

Actual classification of the 30:
- **RESOLVES (4)** - Bulgur Wheat, Korean Rice Cakes, Sumac, Keto Bun. Rebuild only.
- **GENUINE-GAP (3)** - Cauliflower, Brandy, Broccolini. Nothing shares a core word; these need a row
  plus real capture. Cauliflower is the notable one: a staple, in many blocked recipes, simply absent.
- **DIFFERENT-FORM (~8)** - Cream Cheese vs 1/3 Fat, Sour Cream vs Light, Broccoli vs (frozen)
  Broccoli Florets, Fresh vs Dried Parsley/Oregano, Dry White Wine vs White Wine Vinegar, Baby Bella
  vs White Mushrooms, Sun-Dried Tomatoes oil-packed vs plain, Boneless Beef Short Ribs. Brad rules
  each per decision 0a.1.
- **RENAME candidates (~15)** - but see the caveat below.

**CAVEAT, and it must be fixed before Brad is asked to rule.** The RENAME class is over-eager: it
scores on ANY shared core word, so it currently proposes `Egg Yolk -> Egg Noodles`, `Yellow Mustard ->
Yellow Onion`, `Beef Base -> Beef Flank/Sirloin Steak` and `Gruyere Cheese -> Mozzarella Cheese`.
Those are noise, and putting them in front of an adjudicator wastes the scarcest resource in this
process. Before V5's worklist goes out, the scorer must require the HEAD NOUN to match (`yolk` vs
`noodles` fails; `pepper` vs `pepper` passes), demoting the rest to a WEAK class that is listed but
never proposed. A worklist that cries wolf gets skimmed, and skimming is how the vinegar match ships.

## 0c. ADJUDICATION LOG - Brad's rulings, recorded as they are made

An alias here is a RULING, not a heuristic. Each line records what was decided and why, so a future
session can see the reasoning rather than re-deriving it (or worse, undoing it).

**Established before ruling, and it narrows the stakes:** macros come from `food-macros-db.json`,
keyed independently of the ingredient row (`build-v2-spec.ps1:119` vs `:117`). An alias therefore moves
PRICE and gram-conversion only - never calories, protein, carbs or fat. The 400-650 cal band stays
honest across every alias below. My initial framing of the cream-cheese ruling overstated this risk.

| # | Name | Ruling | Reasoning |
|---|---|---|---|
| 1 | Cream Cheese | **ALIAS -> 1/3 Fat Cream Cheese** | Unblocks ~7 recipes now. Cost is understated modestly (light cream cheese is cheaper); macros unaffected. Accepted knowingly. |
| 2 | Sour Cream | **ALIAS -> Light Sour Cream** | The row's bid is the GENERIC `sour-cream`, so the price is plain sour cream - the row NAME is misleading, the pricing is not. Honest on cost. Unblocks ~6. |
| 3 | Cauliflower | **REGISTER + CAPTURE NOW** | Genuine gap, no near row at all, and the single largest blocker (~9 recipes). A low-carb staple this catalog will need indefinitely, so it earns a real row and a real 7-store capture. |
| 4 | Broccoli | **ALIAS -> Broccoli Florets (frozen)** | Unblocks 3. Frozen florets are typically cheaper per gram, so cost may be understated; accepted knowingly. Recipe gram weights assume fresh heads - flag for the auditor if a cost looks low. |
| 5 | Fresh Parsley, Fresh Oregano | **NEW ROWS + capture** | Dried herbs are ~10x more concentrated by weight and sold as jars, not bunches. Chimichurri is mostly fresh parsley/oregano - aliasing would misprice the dish's main component. |
| 6 | Dry White Wine | **NEW ROW + capture** | Vinegar is a different product; this is the exact trap the form-flag exists for. **Check with the registrar first:** an orphan "Red Wine" row was deliberately deleted in commit 4056603f, so wine may be intentionally out of scope for this catalog. If it is, the two recipes get rewritten instead. |
| 7 | Monterey Jack, Pepper Jack, Gruyere | **NEW ROWS + capture** | Distinct products at distinct price points; Gruyere especially is far dearer than mozzarella. Three rows, one capture pass. |
| 8 | 80/20 Ground Beef, Shaved Beef Steak | **NEW ROWS (both)** | 80/20 is genuinely cheaper than 93/7 and the difference is real, so it earns its own row rather than erring high on an alias. Shaved steak is a distinct pre-sliced product (~$7.49 in the source recipe vs sirloin). |
| 9 | Smoked Sausage, Andouille | **NEW ROW: pork smoked sausage** | The vocabulary only has TURKEY smoked sausage. Aliasing would silently convert pork recipes into turkey ones for costing AND protein stamping - and the catalog's free-dinner rotation depends on that label. Andouille aliases to the new pork row. |
| 10 | Portobello Mushrooms | **NEW ROW + capture** | Portobello caps are dearer than button/crimini and the fricassee uses 1,588 g - its largest non-protein line, so the error compounds. |
| 10b | Baby Bella (Crimini) | **ALIAS -> White Mushrooms** | Same species at different maturity, close in price; the row's bid is the generic `mushrooms`, not white-specific. |
| 11 | Brandy, Broccolini, Beef Base, Egg Yolk, Sun-Dried Tomatoes (Oil-Packed), Boneless Beef Short Ribs | **CAPTURE, one pass** | Genuine gaps with nothing near enough to alias. Bundled with rulings 3, 5, 6, 7, 8, 9, 10 into a SINGLE pricer run - ~15 terms, which is exactly the batch size the singleton price lane is built for. |
| 12 | Tandoori Masala, Pepperoni | **ALIAS -> Garam Masala / Turkey Pepperoni** | Small-gram, low-cost lines where the error is pennies. Turkey pepperoni was the closer call (it touches protein stamping) but pepperoni is garnish-scale in a crustless pizza bake. |

| 13 | Yellow Bell Pepper | **NEW ROW + capture** | Missed in the first questioning round and caught when the rebuild sweep surfaced it. Ruled its own row rather than aliasing to Red Bell Pepper. |
| 14 | Yellow Mustard | **NEW ROW + capture** | Plain yellow is markedly cheaper than Dijon and is a distinct staple; aliasing would overstate cost and change the dish's character. |
| 15 | Dry White Wine | **NEW ROW + capture** (registrar NOT consulted) | Brad ruled directly: treat the 4056603f "Red Wine" deletion as unrelated cleanup. **Recorded explicitly because it overrides this plan's own recommendation to ask the registrar first** - if wine later proves deliberately out of scope, this is the decision to revisit, and the reason it was made without that check. |
| 16 | Broccoli (fresh) | **SUPERSEDES #4: NEW ROW, alias retired** | Ruling #4 aliased "Broccoli" to the frozen Broccoli Florets row on the stated premise that the board carried no fresh broccoli. **That premise was false.** Weekly commodity `broccoli` ("Broccoli (fresh)", lb) was live and priced at 7/7 stores, cheapest Hy-Vee $1.8533/lb, the whole time. commodity-registrar ruled REUSE - no id minted - and verified the fresh/frozen firewall holds both ways (`broccoli` excludes `\bfrozen\b`/`steam`/`cuts`; `frozen-broccoli`'s includes are all frozen-qualified). Vocabulary gained a fresh `Broccoli` row (bid `broccoli`, lb, gpu 453.592); the alias came off Broccoli Florets, which keeps serving the 37 recipes that spec frozen and argue for it in prose. |
| 17 | Spinach (fresh) | **REBID, no new row** | Row "Spinach" bid `frozen-chopped-spinach` - the same bid as the separate, correctly-named "Frozen Chopped Spinach" row. All 5 recipes writing canon `Spinach` say "fresh baby spinach" in prose; all 22 writing `Frozen Chopped Spinach` say "thaw and squeeze it dry". Weekly commodity `spinach` ("Spinach (fresh)", oz) was live at 7/7 stores, cheapest Walmart $0.20/oz (Marketside Fresh Spinach, 10 oz bag). Registrar ruled REUSE. Row rebid to `spinach`; fresh and frozen now have exactly one row each and no shared bid. |

| 18 | Cream Cheese | **SUPERSEDES #1's premise: recipes USE the 1/3-fat product** | Ruling #1 accepted the alias because "light cream cheese is cheaper" and cost would be "understated modestly". The feed says the opposite: `cream-cheese` (full-fat) is **$0.1381/oz at 7/7 stores** against `1-3-fat-cream-cheese` at **$0.1862/oz, 6/7** - the alias is 35% MORE per ounce, not less. Brad ruled 2026-08-16 that the recipes should USE the lower-calorie product regardless of cost. That makes the PRICE the correct field and the MACROS and COPY the wrong ones: five specs carried the USDA full-fat macro row while priced off the 1/3-fat commodity, and two told the reader in so many words to buy the full-fat brick. All five were rebased onto the "1/3 Fat Cream Cheese" (Great Value Neufchatel) food-DB row (-14 to -28 cal/serving, all still inside the 400-650 band), display and cost labels now name that product, and the two contradicting shop_smart bullets were rewritten. Cost did not move - the bid was already right. |

### The alias/macro split - a structural trap this ruling exposed

**Price resolves through aliases; macros do not.** `build-v2-spec` looks up price by ingredient ROW (following
aliases) and macros by the spec's CANON NAME against `food-macros-db` (no alias resolution). So a spec can name
one product, carry a second product's macros, and be priced off a third, with every guard green. Swept over the
live vocabulary, **seven aliases name a food-DB row distinct from the row they resolve to**:

| alias | resolves to row | macro gap |
|---|---|---|
| Cream Cheese | 1/3 Fat Cream Cheese | 350 cal/100 g vs 250 - **the one that bit us** |
| Pepperoni | Turkey Pepperoni | 150 cal/30 g vs 70/28 - cost-side only, ruled knowingly at #12 |
| Sour Cream | Light Sour Cream | 198 vs 140 cal/100 g - honest today: bid is the GENERIC `sour-cream`, macros full-fat, card says full-fat |
| Baby Bella (Crimini) Mushrooms | White Mushrooms | 22 vs 21.4 cal/100 g - immaterial |
| Tandoori Masala | Garam Masala | garnish-scale grams |
| Smoked Sausage / Andouille Smoked Sausage | Pork Smoked Sausage | row name has NO food-DB row; specs write the alias, which does |

Only cream cheese had macros contradicting its own card, and no affected recipe is published. **The open risk is
future recurrence:** the `Cream Cheese` alias survives, so a new spec writing bare "Cream Cheese" would again get
full-fat macros on a 1/3-fat price. Two candidate remedies, neither taken - Brad's call: retire the alias so the
bare name refuses and the mapper must choose, or give full-fat its own row (`cream-cheese` is live and priced
7/7, so it would be a REUSE, not a mint - the same shape as ruling #16). A build-time guard that refuses when a
canon name's price row and macro row disagree would close the class rather than the instance.

**The lesson #16 and #17 repeat, for the third time in one day.** Section 0d found ten of nineteen "new"
ids already existed. This is eleven and twelve. In both cases a ruling was made, and a recipe was held for
a day, on "the board does not carry this" - asserted by a sweep that only ever read `ingredients.json`.
Nobody checked `commodities.json` or the feed. **The standing correction: before any ruling that turns on
whether the estate prices a food, query the FEED, not the ingredient map.** A missing ingredient row and an
unpriced food look identical from the vocabulary side and are opposite problems with opposite remedies.

### The resulting capture list - ONE pricer pass, ~17 terms

Cauliflower, Fresh Parsley, Fresh Oregano, Dry White Wine, Monterey Jack Cheese, Pepper Jack Cheese,
Gruyere Cheese, 80/20 Ground Beef, Shaved Beef Steak, Pork Smoked Sausage, Portobello Mushrooms,
Brandy, Broccolini, Beef Base, Egg Yolk, Sun-Dried Tomatoes (Oil-Packed), Boneless Beef Short Ribs,
Yellow Bell Pepper, Yellow Mustard.

Measured effect of the alias rulings alone, before any capture (rebuilding all 24 in-flight intakes):
**8 recipes build, 16 blocked on UNKNOWN NAME, ZERO blocked on "unbid"** - the category that started
this incident is gone. Every remaining blocker is a name awaiting a row from the capture list above.

### The resulting alias list - zero capture, applies immediately

Cream Cheese -> 1/3 Fat Cream Cheese · Sour Cream -> Light Sour Cream · Broccoli -> Broccoli Florets ·
Andouille Smoked Sausage -> (new) Pork Smoked Sausage · Baby Bella (Crimini) Mushrooms -> White
Mushrooms · Tandoori Masala -> Garam Masala · Pepperoni -> Turkey Pepperoni

### Rebuild-only, no vocabulary change at all

Bulgur Wheat, Korean Rice Cakes, Sumac, Keto Bun - the four LIVE recipes. Their rows and bids already
exist; the specs predate them.

## 0d. EXECUTION, 2026-08-16 - what the capture list actually cost, and the ten rows that already existed

Section 0c's capture list said nineteen terms needed board commodities. **Ten of them already had one.**
That is the finding worth keeping; the prices were the easy part.

### The four that were already registered AND already priced

`cauliflower`, `fresh-parsley`, `broccolini`, `portobello-mushrooms` were live commodities in
commodities.json with real feed cells before this task started. Three matched the pricer's cheapest to the
cent. Section 0b classed cauliflower a GENUINE-GAP and "the single largest blocker"; it had been on the
board the whole time. **The sweep that produced the worklist never checked commodities.json** - it compared
canon names against ingredients.json only, so an ingredient row missing its bid looked identical to a food
the estate had never priced.

### The six that were duplicates under another spelling

| the plan's proposed id | already existed as | already priced |
|---|---|---|
| `80-20-ground-beef` | `ground-beef-8020` (label *is* "80/20 Ground Beef") | $4.77/lb Sam's, n=7 |
| `yellow-mustard` | `mustard` (label *is* "Yellow Mustard") | $0.0495/oz Aldi, n=7 |
| `egg-yolk` | `eggs` | $1.46/dozen Aldi, n=7 |
| `pork-smoked-sausage` | `kielbasa` ("Kielbasa / Smoked Sausage") | $2.336/lb Walmart, n=7 |
| `sun-dried-tomatoes-oil-packed` | `sun-dried-tomatoes` | $0.4158/oz Sam's, n=7 |
| `dry-white-wine` | `white-wine` | existed, unpriced |

In five of the six, the pricer's freshly captured cheapest was the *same store at the same price* as the
existing crown. Minting them would have been the bread-crumbs failure six times over.

**None of these pairs fires mechanically.** `80-20-ground-beef` vs `ground-beef-8020` is a word-order flip;
`pork-smoked-sausage` vs `kielbasa` shares zero tokens; `egg-yolk` vs `eggs` is a yield convention against a
purchase. audit-commodity-dupes normalizes and compares strings, so it can never see any of them. **The only
thing standing between this catalog and six permanent duplicates was the commodity-registrar gate** -
which is the argument for keeping it mandatory even when a plan has already "decided" an id is new.

Ruling 9's protection held: `kielbasa` is NOT `smoked-turkey-sausage`. It structurally excludes turkey and
chicken, so protein stamping and the free-dinner rotation are unaffected by the reuse.

### Why wine had never been priced - and it was never the band

`compare-deals.ps1` carries a **global alcohol exclude** in `$GLOBAL_EXCLUDE` (`\bwine\b`, `liquor`,
`vodka`, `whiskey`, `tequila`, `bourbon`, `\bbeer\b`, `\bale\b`) applied to *every* commodity. `white-wine`
could therefore never produce a single candidate no matter how good its rule was - and its band, 1.11-14.4
per fl oz, was authored per BOTTLE and would have rejected every real wine ($0.16-0.41/floz) even without
the global. Two independent blocks, either one fatal.

The documented escape hatch is `relax_global` on the commodity entry. `white-wine` and `red-wine` now carry
`relax_global: ["\bwine\b"]`, unit `fl_oz` -> `floz` (the spelling every other consumer uses), and a
recalibrated 0.08-1.0 band. **`brandy` escaped the filter only by accident** - "brandy" is simply not in the
list. Anything alcoholic minted in future needs `relax_global` or it will silently price nothing forever.

### Three wrong products the rebuild surfaced, all one class

Same substring-match class the pricer caught six times in the 0c capture pass:

- **Hy-Vee Dijon Mustard "with White Wine"** crowned `white-wine` -> excluded `\bmustard\b`
- **Wish-Bone Red Wine Vinaigrette Salad Dressing** crowned `red-wine` -> excluded `vinaigrette`, `\bdressing\b`
- **Franzia 5 L / Carlo Rossi 4 L box wine** crowned `white-wine` on per-ounce price

### Box wine, and the 375 ml question - measured, not assumed

Cheapest-per-unit is the board's rule, and box wine wins it: Franzia 5 L at $0.0945/floz against a 750 ml
bottle at $0.157. For a recipe needing half a cup that is the wrong answer - the reader is told to buy five
litres. Brad asked whether smaller bottles (375 ml splits) were the fix. **Measured across 49 wine rows at
Baker's: 42 are 750 ml, exactly ONE is 375 ml, one is 500 ml.** The lone 375 ml runs $0.629/floz - about
4x the per-ounce cost of a 750 ml bottle. Splits are neither stocked nor cheap; chasing them was the wrong
instinct. The fix that worked was excluding box/jug formats, after which `white-wine` crowns a real $3.99
bottle (Baker's Bay Bridge 750 ml, $0.1571/floz).

### Alcohol is no longer respec'd to broth

`meal-prep\canon-rules-standing.json` silently rewrote `white wine`, `brandy` and `red wine` to Chicken or
Beef Broth. That is why no wine had ever *needed* a price, and it meant a recipe calling for wine cooked
with broth. Brad ruled 2026-08-16 that a recipe calling for wine or brandy must use wine or brandy; those
three respecs are retired. `sake`, `shaoxing`, `chinese cooking wine`, `dashi`, the broths and **every
wine-VINEGAR rule** are deliberately untouched - `red-wine` remains unpriced by choice of scope.

### The gated writer the recipe board never had

`out\recipe-board-everyday.json` is the everyday floor baseline for recipe-only ids - the commodities that
must NOT live on the weekly board because a broader staples row steals their cells under first-match-wins
(`bell-peppers` has no yellow exclude; `bouillon`'s include literally contains `beef\s+base`; `sirloin-steak`
and `ribeye-steak` both claim shaved steak; `shredded-cheese` claims the jacks). All 156 existing rows
arrived by hand: `derive-recipe-floors.ps1 -Apply` can only REFRESH an existing row, never add one. So the
one operation that file needs most had no gated path and no proof contract.

`grocery\add-recipe-board-rows.ps1` is that path, carrying new-commodity.ps1's contract: text-level append
(the file's `\uXXXX`-escaped store names do not survive a ConvertTo-Json round trip), re-parse, every
pre-existing row proved byte-identical, +N exactly, and a **refusal** for any size it cannot resolve into
the row's unit rather than guessing a basis. It also refuses an id already priced on the weekly board,
because recipe-overlay would drop that row on its next run. 8 self-tests, 3 must-fire.

### Collateral finding: the live board was crowning a known-wrong row

Rebuilding the board re-picked Walmart's `five-spice-powder` winner, which exposed that
`walmart-regular-2026-08-06.json` records *"Spice Supreme oriental five spices, 3.5-oz. plastic shaker"* at
**size 42.007 oz** - a 12-pack total against a single-shaker price - yielding $0.279/oz against a real
~$4.75/oz. That row held the live crown and understated the commodity ~12x. It was **already ruled in
known-wrong.json** and was being published anyway. The rebuild dropped it; the stale Walmart link was
withdrawn (Walmart has no headless resolver) and guards returned to hard=0.

### Measured outcome

24 in-flight intakes went **11 building / 13 CHEAPEST-FALLBACK -> 24 building / 0 fallback**. All 19 bids
resolve on the feed. audit-vocab-integrity clean over 544 specs; audit-commodity-dupes clean over 797 ids
across 3 namespaces; audit-food-category clean over 2,816 priced cells; guards hard=0.

Nine ids were genuinely new: `fresh-oregano`, `monterey-jack-cheese`, `pepper-jack-cheese`, `gruyere-cheese`,
`shaved-beef-steak`, `boneless-beef-short-ribs`, `yellow-bell-pepper`, `beef-base` (recipe-board rows), and
`brandy` (weekly, captured live off the Kroger public API - 595 terms, 7,286 rows, headless).

## 1. The three namespaces, and the invariant nobody enforced

| namespace | lives in | governed by |
|---|---|---|
| board commodity ids (`cream-cheese`, `rice`) | grocery boards, priced weekly | commodity-registrar |
| ingredient rows (item name -> bid, gpu, package) | meal-prep\db\ingredients.json | **nobody - the gap** |
| recipe canon names (what specs/intakes write) | db\recipes, run intakes | **nobody - the gap** |

Two referential-integrity edges follow: **every recipe canon name must resolve to an ingredient row**,
and every ingredient bid must resolve to a board/feed commodity. The second edge has guards
(CHEAPEST-FALLBACK, store-integrity, the feed coverage gate). The first edge had NOTHING - not a list
the writers could see, not a gate at build, not a sweep after. Everything below closes that edge.

**The standing rule this plan adds to the estate:** an ingredient canon name is a CLOSED vocabulary.
Using it costs nothing; extending it is a deliberate, recorded act. Fuzzy matching is forbidden at
build time forever - "Dry White Wine" auto-matching "White Wine Vinegar" is a wrong dinner, and
"Fresh Parsley" auto-matching "Dried Parsley" is a wrong gram weight AND a wrong price. A plausible
wrong match is strictly worse than a visible miss; that is the tteok lesson ($0.44/lb "rice" for
Korean rice cakes) applied to names.

## 2. Improvements, each mapped to the failure it kills

### V1. Make the vocabulary visible and queryable: `ingredient-vocab.ps1`  (kills failure 1's blindness)

- `-List` emits the compact vocabulary - item name, unit, bid - sized for a prompt (282 rows, single-
  digit KB). The mapper gets this in its dispatch; map is 13.1% of run tokens and batches 5 recipes per
  call, so the cost is trivial against what a wrong name costs.
- `-Query '<name>'` returns the exact row if the name resolves (via item OR alias, per V2), else the
  nearest rows by token overlap, each carrying bid/unit/package - and a DIFFERENT-FORM flag when the
  near name differs on a form word (fresh/dried/light/florets/vinegar/ground). The flag is a warning to
  an adjudicator, never a ruling.
- **Plausibility floor (kills failure 4):** the tool REFUSES to answer if it parses fewer than 200 rows
  - "implausibly small; parse error, not data" - and the same floor pattern is retrofitted to every
  reader of a load-bearing estate file (catalog digest >= 400 recipes, etc.). A tool reporting a
  load-bearing file at 3% of its known scale is broken, and a broken tool must say so rather than
  testify.
- Must-fire fixtures: 'Cream Cheese' surfaces '1/3 Fat Cream Cheese' as a candidate; 'Dry White Wine'
  lists 'White Wine Vinegar' ONLY with the different-form flag; an 8-row fixture file is refused.

### V2. Aliases as first-class, recorded data  (kills failure 1's recurrence)

Ingredient rows gain an `aliases` array - one purchasable item, many accepted names - resolved by
build-v2-spec exactly like the item name. Policy:

- **Prefer renaming the intake** to the canonical name for one-off misses (keeps the vocabulary small).
- **Add an alias** when the foreign name is natural phrasing that will recur from source recipes
  forever ("Cream Cheese" will never stop arriving).
- **Every alias is an adjudicated act with evidence** that it is the SAME purchasable item - recorded
  who/when/why on the row, registrar-discipline. Note the trap hiding in the flagship example: "Cream
  Cheese" -> "1/3 Fat Cream Cheese" is NOT obviously same-item (full-fat vs light differ in price and
  macros). That is Brad's call or the registrar's, not a script's - which is exactly why aliases are
  data, not heuristics.
- Integrity: an alias resolves to exactly one row; a collision (alias equal to another row's name or
  alias) refuses at write. Must-fire both ways.

### V3. Split build-v2-spec's refusal into the two truths  (kills failure 2's wrong diagnosis)

Today's guard throws "UNBID INGREDIENT" for both cases. Split it:

- **UNKNOWN NAME** (resolves to no row, no alias): the common case, and the message does the work -
  "not in the ingredient vocabulary; nearest rows: <V1 query output>. Rename the intake, add an
  adjudicated alias, or register a new row." Points at the mapper, not at capture.
- **KNOWN NAME, NO BID** (resolves to one of the ~6 bid-less rows): the existing throw with the
  existing `not-price-tracked-ok.json` escape, unchanged.

Must-fire: 'Cream Cheese' produces the UNKNOWN-NAME error naming '1/3 Fat Cream Cheese', not the unbid
error. Clean twins: an aliased name builds; an allowlisted bid-less row builds.

### V4. Bind the mapper to the vocabulary  (kills failure 1 at source)

The mapper's contract changes from "map every ingredient to a commodity id" to: **resolve every
ingredient to a vocabulary row** (exact or alias), and for anything that will not resolve, choose
explicitly - propose a rename, propose an alias with same-item evidence, or propose a NEW row through
the registrar gate with the different-form case made ("Portobello Mushrooms is not White Mushrooms;
different product, different price; needs its own row and a capture"). The intake carries only
resolved names, so the writer cannot inherit an invented one. The registrar's remit explicitly grows
to cover vocabulary rows: minting a name and minting an id are the same act of extending a controlled
namespace, and they get the same gate.

**AMENDED 2026-08-16, after this paragraph was tested in anger and proved insufficient.** As written above,
V4 checks NAMES against the vocabulary. That is necessary and not sufficient: six proposed ids resolved
perfectly well as names and were still duplicates as IDS, because `80-20-ground-beef` and
`ground-beef-8020` are two strings for one commodity. A name-resolution contract alone would have passed
every one of them. So the contract carries **two** obligations, and the second is the expensive one:

1. **Resolve the NAME** against `db\ingredients.json` (item or adjudicated alias), via `ingredient-vocab.ps1`.
2. **Prove the ID is not already priced under another spelling**, across all four of `commodities.json`,
   `recipe-commodities.json`, `out\recipe-board-everyday.json` and the live `out\smp-feed.json` - searching
   by FOOD and reading the LABELS of near rows, not by slug. `mustard`'s label is literally "Yellow
   Mustard"; `kielbasa` shares zero tokens with "pork smoked sausage"; a word-order flip defeats every
   normalization audit-commodity-dupes runs. No mechanical sweep reaches these, which is precisely why the
   obligation sits on the mapper and the registrar rather than on a script.

Both obligations are now written into `.claude\agents\recipe-ingredient-mapper.md` (rule 1b) and
`.claude\agents\commodity-registrar.md` (the fourth-namespace section). See 0d for the measurement.

### V5. Estate-wide reconciliation - the remediation, shaped as an adjudication worklist  (fixes the damage)

One sweep over: the 23 unbid specs, the 30 seeded resolution rows, and every in-flight intake. For
each failing name, a three-way classification with evidence, and NO auto-apply:

| class | example | remedy |
|---|---|---|
| RENAME - same food, wrong string | Broccoli -> Broccoli Florets | fix intake/spec name (or alias), rebuild, re-cost |
| DIFFERENT FORM - near name, different food | Dry White Wine vs White Wine Vinegar; Fresh vs Dried Parsley; Portobello vs White Mushrooms | NEW row via registrar + capture; never alias |
| GENUINE GAP - nothing near | Cauliflower, Keto Bun, Bulgur Wheat, Sumac, Korean Rice Cakes | capture/registrar (the queued live-recipes task already covers the four live ones) |

Output is a worklist for adjudication - Brad or the registrar rules each line, the ruling is recorded
(rename applied / alias added / row registered), and rebuilds flow through the now-enforcing build.
Expected outcome, stated so it can be checked: MOST of the 17 blocked in-flight recipes and most of
the 19 blocked specs turn out to be RENAME-class and unblock without a single new price.

### V6. Correct the poisoned memory  (kills failure 5)

- Purge the 2026-08-16 backfill batch from `ingredient-resolutions.json` - it was derived from the
  mischaracterization and is wrong in bulk. Re-record each term only as its V5 adjudication lands,
  with the resolution it actually got (row, alias, or genuine gap).
- Re-scope the queued live-recipes bid task if V5 changes any of its four (current reading: those four
  are genuine gaps and stand, but the task must cite this plan, not "wire the bids" generically).
- The efficiency plan gets one correction paragraph pointing here; its B12 mechanism (silent $0.00)
  remains true, its inventory ("23 specs missing bids") does not.

### V7. Referential integrity as a standing sweep: `audit-vocab-integrity.ps1`  (keeps the edge closed)

Every spec canon name resolves (item or alias); every alias unique; every row parseable; every bid
resolves on board/feed (the existing guards' edge, cross-checked). Wired into wave-publish P5 beside
the unbid sweep - which becomes, correctly, a SUBSET of this. Scoped to the wave at publish, whole-
estate on demand. Must-fire: a spec naming an unknown canon fails the sweep even though its cost file
looks internally consistent - the class that shipped four live pages.

### V8. The auditor names the right repair owner  (kills failure 3)

The batch auditor's cost battery distinguishes UNKNOWN-NAME from KNOWN-BUT-UNBID in its findings, so a
NO-GO routes to the mapper (rename/alias) or to capture (real gap) instead of the generic "unpriced"
that sent this whole incident down the wrong road. One line in its prompt; its verdict format is
already machine-read per the S8 trim work.

## 3. Build order

1. **V1** (vocab tool + plausibility floor) - everything else consumes it.
2. **V5** (reconciliation worklist) - produced BEFORE any enforcement changes, so Brad adjudicates
   against today's reality; expected to unblock most of the 36 blocked recipes as renames.
3. **V2 + V3** (aliases + split refusal), one commit, fixtures together - enforcement lands only after
   the worklist exists, so the gate never blocks a recipe the worklist would have renamed.
4. **V6** (memory correction) as V5 rulings land.
5. **V4** (mapper contract + registrar remit) + prompt-backup sync.
6. **V7 + V8** (standing sweep + auditor wording).
7. Rebuild + re-cost the unblocked specs; the four live pages republished per the existing task, with
   Brad's go-ahead.

Every item ships its must-fire fixture and clean twin in the same commit. Acceptance for the whole
plan, written before it is built: **a recipe writing "Cream Cheese" cannot reach a $0.00 cost, cannot
reach the auditor, and cannot strand a wave - it fails at build with the three nearest vocabulary rows
in the error text, or it builds correctly through an adjudicated alias.**

## 4. Risks

- **Over-aliasing is the new tteok.** An alias equating different foods hides a price difference
  forever and no gate ever fires again. That is why aliases carry evidence and an adjudicator, why
  the different-form flag exists, and why fuzzy matching stays banned at build time.
- **V3 makes the vocabulary a bottleneck if V5 lags** - the gate refuses names the worklist would
  rename. Mitigated by build order (worklist first) and by the error text carrying the fix.
- **The registrar becomes two-namespace** (ids + names). Its prompt must keep the distinction crisp or
  it will alias across the id/name boundary. One fixture in its dispatch template: a name proposal may
  not mint an id as a side effect.
- **Plausibility floors can false-refuse** during a legitimate estate migration that shrinks a file.
  The floor message says how to override deliberately (an explicit flag), so the override is a choice,
  never a default.

## 5. Out of scope

- Auto-matching names at build time, at any confidence. Permanently.
- Changing costing math, the wave gate, or the publish path - this plan is about names resolving, not
  about what happens after they do.
- The four live pages' capture work (queued separately; V5 re-scopes it if warranted).
