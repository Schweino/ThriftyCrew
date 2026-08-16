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
