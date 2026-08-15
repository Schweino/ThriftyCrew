# PLAN: Make the "cheapest" receipt pick the store that is actually cheapest to buy at

Written 2026-08-15 from a read-only survey of the live estate. Every code quote below was read from
disk today; re-verify line numbers before editing, files move. This plan is the opening prompt for a
fresh session with no prior context. Work through it in order. Do not skip section 5 (measurement
before change) or section 9 (verification).

Read these memory files FIRST, they are binding context:

- C:\Users\Owner\.claude\projects\C--Codex\memory\recipe-cost-basis-map.md
- C:\Users\Owner\.claude\projects\C--Codex\memory\recipe-card-feed-repoint.md
- C:\Users\Owner\.claude\projects\C--Codex\memory\board-match-collisions.md
- C:\Users\Owner\.claude\projects\C--Codex\memory\prose-templating.md
- C:\Users\Owner\.claude\projects\C--Codex\memory\golden-test-frozen-inputs.md
- C:\Users\Owner\.claude\projects\C--Codex\memory\two-copies-of-a-rule.md
- C:\Users\Owner\.claude\projects\C--Codex\memory\free-dinner-rotation.md
- C:\Users\Owner\.claude\projects\C--Codex\memory\mobile-first-rule.md

House rules that apply to everything below: no em dashes in anything you write; every guard ships a
frozen must-fire fixture of its founding bug plus a clean twin; verify at 375px AND dark mode before
publishing anything visual; republishing 544 cards is a real cost, canary first.

---

## 1. The problem, with the measured example

The recipe cards' cost section has three tabs. The tab labelled "Current cheapest pricing" (receipt
label "Register total at the cheapest stores") selects, for each ingredient, the store with the
lowest PER-UNIT price, then charges the reader for WHOLE PACKAGES at that store. Those two rules
fight: a warehouse store wins per-unit with a huge package, and the reader is billed for the huge
package.

Measured live 2026-08-15, recipe `bangers-and-mash-onion-gravy`, ingredient `butter`. The card needs
88 g = 0.194 lb (base 14 servings; the built card's data block reads
`{"item":"Butter","grams":88,"bid":"butter","gpu":453.592,"pkg_g":453.592,"pkg_l":"lb box"}`).
From `public\smp-feed.json` (verified today, values below are the exact feed contents):

| store       | perUnit $/lb | packageBasisUnits (lb) | pkgs needed | register cost |
|-------------|--------------|------------------------|-------------|---------------|
| Sam's Club  | 2.555        | 4                      | 1           | $10.22  (chosen: lowest per-unit) |
| Aldi        | 2.89         | 1                      | 1           | $2.89   (actually cheapest to buy) |
| Walmart     | 2.976        | 2.003                  | 1           | $5.96 |
| Fareway     | 3.48         | 1                      | 1           | $3.48 |
| Baker's     | 3.49         | 1                      | 1           | $3.49 |
| Hy-Vee      | 3.99         | 1                      | 1           | $3.99 |
| Family Fare | 5.39         | 1                      | 1           | $5.39 |

So the tab labelled "cheapest" bills $10.22 for 20 cents of butter. Whole-recipe effect measured on
that one recipe on 2026-08-15: receipt "cheapest" total $58.37; the card's own "Shop this recipe"
store picker with all 7 stores ticked (which already minimises actual purchase cost) totals $37.25
for the same basket. Same page, same feed, same servings.

This is PRE-EXISTING, not a regression. It became much more visible on 2026-08-15 when the cards
were repointed from the deleted V3 feed to smp-feed.json and 231 previously "Unavailable" totals
became real numbers (see memory recipe-card-feed-repoint).

The same defect exists on the EVERYDAY tab: `inputs.everyday` is the cheapest NON-SALE per-unit
cell, so butter's "Everyday register total" line is the same $10.22 Sam's four-pound package,
labelled "typical Omaha shelf prices". Fix both tabs or the card trades one absurd tab for another.

## 2. The two code paths that disagree (both in one file)

File: `C:\Codex\income\meal-prep\pipeline\tpl2-scaler-prefix.html`. This template is baked verbatim
into every built card (`C:\Codex\income\meal-prep\db\built\<slug>.body.html`; verified today that a
built card carries the full script), rendered by `meal-prep\engine\build-cards.ps1`, published by
`meal-prep\engine\publish.ps1`. A template change therefore requires rebuild + republish of all 544
cards. There is no site-wide injection of this script; the copy in each post is the copy that runs.

Path 1, wrong, used by the receipt, both non-custom tabs, the composition bar, the savings delta,
and the blue stat band. Lines 233-254 today:

```js
function price(it,nn,basis){
  var inputs=(feedData&&feedData.pricing_inputs&&it.bid)?feedData.pricing_inputs[it.bid]:null;
  var source=inputs?((basis==='everyday')?(inputs.everyday||inputs.current):inputs.current):null;
  var required=(it.gpu>0)?it.grams*(nn/data.base)/it.gpu:0;
  if(!source||!(source.perUnitMicros>0)||!(required>0)) return {cost:null,live:false,k:0,unavailable:true};
  var up=source.perUnitMicros/1000000;
  var variable=source.variableWeight===true, packageBasis=variable?0:pkgBasis(it,source);
  var k=variable?0:(packageBasis>0?Math.max(1,Math.ceil(required/packageBasis-1e-9)):0);
  var cost=variable?up*required
    :((Number(source.packageBasisUnits)>0&&source.purchasePriceMinor>0&&k>0)?source.purchasePriceMinor*k/100
    :((packageBasis>0&&k>0)?up*packageBasis*k:null));
  if(!(cost>=0)) return {cost:null,live:false,k:k,unavailable:true};
  var e=(feedData&&feedData.ingredients&&it.bid)?feedData.ingredients[it.bid]:null;
  return {cost:cost,live:true,k:k,required:required,variable:variable,packageBasis:packageBasis,
    store:source.store||(e&&e.store),url:source.url||(e&&e.url),unit:source.unit||(e&&e.unit),
    up:source.perUnitMicros/1000000,sale:basis!=='everyday'&&e&&e.type==='sale',cn:e&&e.n};
}
```

`inputs.current` is ONE pre-selected cell, chosen server-side by `grocery\export-feed.ps1` as the
minimum per-unit price (line 173 there: `if ($null -eq $lo -or $p -lt $lo) { $lo = $p; ... }`).

Path 2, correct, used only by "Shop this recipe". Lines 446-464 today:

```js
function priceAtStores(it,nn,sel){
  var inputs=(feedData&&feedData.pricing_inputs&&it.bid)?feedData.pricing_inputs[it.bid]:null;
  var required=(it.gpu>0)?it.grams*(nn/data.base)/it.gpu:0,best=null,bs=null,bp=null,sid;
  if(inputs&&inputs.stores&&required>0){ for(sid in inputs.stores){ var x=inputs.stores[sid],name=x.store||sid;
    if(!sel[name]||!(x.perUnitMicros>0))continue;
    // ... the SAME variable/packageBasis/k/cost block price() has, duplicated line for line ...
    if(cost!==null&&(best===null||cost<best)){best=cost;bs=name;bp={k:k,up:up};}
  }}
  if(bs){ return {k:bp.k,cost:best,store:bs,up:bp.up,unit:(feedOf(it)||{}).unit}; }
  return {k:0,cost:null,store:null};
}
```

It iterates every store cell and keeps the minimum COST. Note the two functions are already TWO
COPIES of the per-store package-cost rule. Memory two-copies-of-a-rule applies directly: the fix
must leave ONE copy.

## 3. Which of the four per-serving cost numbers this touches

Per recipe-cost-basis-map there are four numbers and most gaps are by design. Restated against
today's code:

1. `db\recipes\<slug>.json cost_per_serving`, utilization basis, authored by
   `engine\cost-recipes.ps1`. NOT TOUCHED. The golden test pins this engine; since the engine does
   not change, NO -Rebaseline is needed for this work (see section 8).
2. `recipes-db.json cost_per_serving`, a copy of (1). NOT TOUCHED.
3. spec `stat.cost_ps`, whole-package at everyday prices, re-anchored by
   `reanchor-machine-fields.ps1`. NOT TOUCHED. This is what the `{{cost_ps}}` prose tokens expand
   from, which is why NO prose re-propagation is needed (section 7).
4. `pipeline\v2-perserving.json cheapest_ps`, computed by `pipeline\compute-v2-perserving.ps1`.
   NOT TOUCHED in phase 1, but it carries the SAME defect in a different flavor (line 114 today:
   `$ch += $k * ($pkgG/$gpu) * [double]$fe.cheapest`, i.e. the min PER-UNIT feed price times the
   RECIPE's own package size). This number feeds, verified today:
   - `meal-prep\top5-weekly.ps1` line 33 reads cheapest_ps as per_serving into
     `grocery\out\recipe-costs.json`
   - `meal-prep\rotate-free-dinners.ps1` line 57 ranks the FREE DINNER ROTATION by that per_serving
     (top 5 per protein rotate free weekly)
   - `meal-prep\gen-planner-data.ps1` line 29 reads cheapest_ps for the Meal Plan Builder
   - the hub grid and related surfaces via the same manifest

   LOUD FLAG: aligning cheapest_ps to min-cost selection would RE-RANK the free-dinner top-5 sets
   and change WHICH RECIPES ARE FREE, a member-visible consequence. That is deliberately split out
   as PHASE 2, gated on a measurement (section 5) and an explicit decision from Brad. Phase 1 (the
   card widget) does not move recipe-costs.json, so the free set cannot change from phase 1.

The card widget's client-rendered numbers (receipt lines, receipt totals, savings delta, blue stat
band "cheapest this week", composition bar) are what phase 1 changes. They are a fifth surface not
in the basis map's table; after phase 1 they will match what "Shop this recipe" already computes.

## 4. Decision: client-side or server-side selection

RECOMMENDATION: CLIENT-SIDE, in the card template. Reasoning:

- The cheapest-to-buy store depends on the REQUIRED QUANTITY: packages needed is
  ceil(required/packageBasis), and required scales with the reader's serving count. Butter at 14
  servings needs 0.194 lb, so Aldi's 1 lb box wins at $2.89. For a quantity over ~3.5 lb the Sam's
  4 lb pack at $10.22 becomes genuinely cheapest (four Aldi boxes are $11.56). A server-side
  "cheapest" pinned in the feed cannot be correct for every serving count, and the feed does not
  even know recipe quantities (export-feed keys on commodity, not recipe).
- The card already has all inputs client-side: `pricing_inputs[bid].stores` carries every store's
  per-unit, package basis, shelf tag and variable-weight flag, and priceAtStores() proves the
  selection is computable in the card today. `stores` is populated in the same loop that picks
  `current` (export-feed lines 164-175), so wherever `current` exists, `stores` exists, including
  the 231-recipe alias clones (`$pin[$rid] = $pin[$wid]`, line 245).
- Server-side alternatives considered and rejected: (a) a per-recipe pre-pick in the feed's
  recipes{} block would be wrong at any scaled serving count and would duplicate the client rule,
  the exact two-copies-of-a-rule trap; (b) changing `current` itself to a min-cost-at-one-package
  pick would silently change semantics for every other consumer of per-unit cheapest and still be
  wrong once k > 1.
- The feed's `ingredients[bid].store` and `.cheapest` stay min-PER-UNIT. That is the correct basis
  for board surfaces (comparing unit prices). The card must simply STOP printing that store next to
  a cost it did not win. The standing lesson about a store chip disagreeing with the price beside
  it (export-feed lines 169-171 comment, and board-match-collisions) is honoured by construction:
  chip, per-unit figure and cost all come from the same scan winner.

One small SERVER-side change is still required, because the lean stores{} entries cannot express
"this cell is a sale": the everyday tab needs min-cost over NON-SALE cells, and sale/everyday type
is currently only knowable via `ingredients[bid].type` for the single per-unit winner. See 4b.

### 4a. Template changes (meal-prep\pipeline\tpl2-scaler-prefix.html)

1. Extract ONE shared coster from the duplicated block, e.g. `function costAt(it, entry, required)`
   returning `{cost,k,up,variable,packageBasis}` or null, used by both paths. Delete the inline
   copy inside priceAtStores().
2. Add `function cheapestAcross(it,nn,filter)` that scans `inputs.stores` with costAt, keeps the
   minimum cost, and returns the full shape price() returns today, including required, variable,
   packageBasis (needed by sourcePkgLabel), plus the WINNER's store name and per-unit.
   priceAtStores(it,nn,sel) becomes a thin wrapper (filter = membership in sel).
3. In price(it,nn,basis):
   - basis "cheapest" (which also serves the custom tab, see line 299
     `var basis=(tab==='everyday')?'everyday':'cheapest';`): use cheapestAcross over ALL stores;
     fall back to the current single-cell path when `inputs.stores` is absent or yields nothing
     (keeps the guard contract in section 8 intact).
   - basis "everyday": if the feed advertises sale flags (see 4b), use cheapestAcross over
     non-sale cells; otherwise keep today's `inputs.everyday||inputs.current` single-cell path.
   - Store chip: the winner's name from the scan. Never `e.store` beside a scanned cost.
   - Sale tag: true only when the WINNER cell carries the sale flag (today it is `e.type==='sale'`,
     the per-unit winner's type, which becomes wrong the moment the cost winner differs).
   - url ("See item" link): the feed only carries a URL for current/everyday cells and
     `ingredients[bid].url` (the per-unit winner's). Rule: attach a link ONLY when the scan winner
     is the store that URL belongs to. A link opening a different store's product beside a price is
     the same defect class as the chip mismatch. Optionally (measure first, 4b item 3) ship
     per-store URLs in the feed and keep links on every line.
   - cn ("checked at N of 6 stores") is per-commodity and unaffected.
4. openShop() picker rows (near line 613): `if(e.store===s) wins++;` counts "cheapest on N" by the
   per-unit winner. Recompute with the same scan (winner store per basket item over all stores),
   or the picker contradicts the receipt it sits under.
5. Copy check, receipt sub-lines (lines 335-337): the cheapest-tab sentence "Links go to the exact
   item." Drop or soften it if you choose link suppression instead of per-store URLs.
6. Invariant gained (add to verification): with every ingredient ticked and all stores selected,
   the receipt's cheapest total MUST EQUAL the store picker's total. Today they read $58.37 vs
   $37.25 on the named recipe.

Everything else follows automatically because it is already routed through price()/totalAt():
renderTabs, renderComp, renderSave (the delta stays "the subtraction of the two tabs", and
cheapest <= everyday still holds per line by construction, since the cheapest scan's candidate set
is a superset of the everyday scan's), and updateStats (blue band "cheapest this week" figure, the
[data-tc-live-price] spans and the .smp-stat rewrite, all client-side).

### 4b. Feed changes (grocery\export-feed.ps1)

1. Mark sale cells on the lean stores{} entries: in New-PricingEntry (lines 133-152) or the
   AddBoard loop, add `sale = $true` on entries whose board cell type is 'sale'. Tiny size cost
   (only sale cells carry it).
2. Add a schema marker so a NEW card can tell a NEW feed from a cached OLD one, e.g. top-level
   `schema = 2` in the $feed ordered hash (line 280). The card enables min-cost-everyday only when
   `feedData.schema>=2`; otherwise "no flags anywhere" is ambiguous between "old feed" and "no
   sales this week", and an old cached feed (30-min CDN cache, worker max-age 60) would let sale
   cells masquerade as everyday. The CHEAPEST scan needs no flag and works against old feeds.
3. OPTIONAL, decide by measurement: per-store url on lean entries ($purl[$id] already maps
   store -> url). The lean shape deliberately dropped store/unit/url to save 428 KB (lines 128-132
   comment), so measure the delta raw and gzipped before shipping; if gzipped growth is more than
   about 20 KB, prefer link suppression (4a item 3) and keep the feed lean.
4. Both changes are ADDITIVE. Old cards ignore unknown fields (the card reads exactly four fields
   off a lean entry). Deploy the feed BEFORE any card republish.

current/everyday/ingredients semantics DO NOT CHANGE. Other consumers are unaffected; a repo-wide
grep for `pricing_inputs|perUnitMicros` today hits only the template, feed-covers-published.ps1,
the exporter and the feed file itself.
## 5. Blast radius: MEASURE BEFORE CHANGING ANYTHING

Write a read-only PowerShell script (suggested `grocery\measure-cheapest-selection.ps1`, results to
`grocery\out\cheapest-selection-report.json` plus a summary in `design\`) that, using
`public\smp-feed.json` and the 544 built cards:

1. For each built card, extract the baked data block with
   [regex]::Match($html,'<script type="application/json" class="smp-sc-data">(.*?)</script>','Singleline')
   (do NOT string-search for 'smp-sc-data', the template JS itself contains that literal; the typed
   script tag is the unambiguous anchor). Note the PS 5.1 JSON array traps in
   golden-test-frozen-inputs before writing the loop.
2. For each ingredient line with a bid that resolves in pricing_inputs: compute cost under TODAY's
   rule (the current cell) and under the NEW rule (min cost across stores), at base servings AND at
   7 and 28 servings (to demonstrate the serving-count dependence that justifies client-side
   selection). Reimplement the card's exact math including the purchasePriceMinor preference and
   the pkg_g/gpu fallback, or the counts lie.
3. Report: (a) how many ingredient lines switch store at base servings, (b) per-recipe old vs new
   cheapest totals and deltas (expect every delta <= 0; any total that goes UP is a bug in the
   measurement or a real find, stop and look), (c) max and median delta, and (d) the named example:
   bangers-and-mash-onion-gravy butter must switch Sam's Club -> Aldi, $10.22 -> $2.89, and the
   recipe total must land at the store picker's all-stores figure.
4. Free-dinner check for PHASE 2: recompute a min-cost analog of cheapest_ps (state explicitly
   whether you keep compute-v2's recipe package-size basis or move to the store package basis) and
   diff the top-5-per-protein sets against today's ranking from grocery\out\recipe-costs.json using
   the exact 3-key tie-break `per_serving, week_cost, slug`. If the sets differ, phase 2 changes
   which recipes are FREE; that diff goes to Brad before any phase 2 work.
5. Everyday tab: same switch counts over non-sale cells, so the everyday deltas are known before
   shipping too.

## 6. Rollout sequence (canary first; 544 republishes are a real cost)

1. Land and run the measurement (section 5). Read it in full.
2. Ship the feed change: edit grocery\export-feed.ps1, run it, verify out\smp-feed.json and
   public\smp-feed.json (the BOM-less write is already handled in the script), spot-check butter's
   entries, deploy public\ the normal way. Old cards are unaffected (additive fields).
3. Edit the template meal-prep\pipeline\tpl2-scaler-prefix.html per 4a.
4. CANARY: engine\build-cards.ps1 -Slugs with 4 slugs chosen for coverage:
   bangers-and-mash-onion-gravy (the named example), one recipe with a variableWeight meat line,
   one of the 231 alias-bid recipes, and one with per-unit-only cells (the pkg_g/gpu fallback
   path). Identify the latter three from the measurement output; do not guess.
5. Gate: powershell -File meal-prep\pipeline\feed-covers-published.ps1 -Slugs <canary> must pass.
6. engine\publish.ps1 -Slugs <canary> (hash-gated), then LIVE verification per section 9 on the
   canary pages, at 375px and dark mode, before anything else moves.
7. Full rollout: engine\build-cards.ps1 (all), feed-covers-published.ps1, engine\publish.ps1 -All.
   Note a template-only change does not dirty any spec, so pipeline\propagate-recipes.ps1 will NOT
   pick this up on its own; drive build/publish directly.
8. AFTER the bulk republish, run meal-prep\refree-clobbered.ps1. publish.ps1 does preserve
   visibility (lines 111-114), but the standing rule from free-dinner-rotation is to run the
   reconciliation after EVERY bulk republish regardless; it is idempotent.
9. PHASE 2 (separate, gated on Brad seeing the section 5 free-set diff): if approved, align
   pipeline\compute-v2-perserving.ps1 cheapest_ps to min-cost selection, then rerun as a SET:
   top5-weekly.ps1, rotate-free-dinners.ps1 -DryRun first to see the free/paid churn, then live,
   gen-planner-data.ps1, and the hub rebuild. This step has member-visible free/paid flips; it does
   not block phase 1 and must not ride along silently.

## 7. Prose and propagation: what does NOT need re-propagating, and why

Spec prose stores {{cost_ps}}/{{cal}}/{{protein}} tokens, never money literals (prose-templating).
{{cost_ps}} expands from spec.stat.cost_ps, the everyday whole-package engine number, at exactly
two sites (build-card2.ps1 and engine\publish.ps1). Phase 1 changes no spec, no stat and no engine
output, so expanded prose is byte-identical; the republish in section 6 is driven purely by the
changed template JS baked into each body.html. The [data-tc-live-price] spans and the blue stat
band are rewritten CLIENT-side by updateStats() from the same totalAt() calls the receipt uses, so
they move in lockstep with the fix with no re-propagation. Bounded claims stay literal and are
owned by the bounded-claim gate; cheapest totals only move DOWN, which cannot break an "under"
bound. Phase 2 is different: cheapest_ps moving means planner data, the top5 box, the hub grid and
the rotation all shift together via their normal producers; run them as a set, never one alone.

## 8. Guards and the golden test

- meal-prep\engine\golden-test.ps1: NOT triggered. It pins engine\cost-recipes.ps1 over frozen
  inputs; neither phase touches that engine, so -Rebaseline is NOT needed. If you find yourself
  reaching for -Rebaseline, you have drifted out of scope.
- meal-prep\pipeline\feed-covers-published.ps1: unaffected by design (it reads bids from the baked
  smp-sc-data block, which does not change, and requires a usable pricing_inputs.current, which
  remains the fallback path). Run it at canary and at full rollout anyway; it is the hard gate
  before publish. Its 14 frozen fixtures stay valid.
- meal-prep\engine\audit-db-agreement.ps1: compares specs to the recipes-db copy; nothing here
  touches either; expect clean.
- compute-v2-perserving's cheapest<=everyday clamp and selftest: untouched in phase 1. In phase 2
  the invariant still holds under min-cost selection (min over all cells <= min over non-sale
  cells); keep the clamp as-is.
- NEW GUARD for the fix itself. The pricing rule is client JS and the estate is PS-only (checked
  2026-08-15: node is not on PATH), so the honest options are:
  (a) a checked-in FIXTURE PAGE, e.g. meal-prep\pipeline\test-scaler-pricing.html, that inlines the
  template's script plus a FROZEN mini feed and asserts, printing PASS/FAIL text. Must-fire
  fixture = the butter shape above (per-unit winner Sam's 4 lb, cost winner Aldi 1 lb; expected
  line $2.89, chip Aldi, receipt total equal to the all-stores picker total). Clean twin = a
  commodity whose per-unit winner IS the cost winner (expected: nothing changes). Run it in the
  in-app browser as a required step of section 9, and document in the file header that it is
  manual until node exists.
  (b) if Brad approves installing node, the same two fixtures as a scripted test wired into the
  daily chain. Decide explicitly; do not leave the guard unreachable.
  Do NOT write a PS guard that re-implements the JS math against live data; a checker that
  reimplements the thing it checks agrees with itself, not with reality (golden-test memory).
- Keep the section 5 measurement script as a rerunnable audit; after the fix, its old-rule vs
  new-rule delta doubles as a regression probe (a future change that reintroduces per-unit
  selection shows up as the deltas reappearing).

## 9. Verification checklist (canary pages first, spot-check after full rollout)

1. Fixture page (section 8) passes: must-fire and clean twin.
2. Live bangers-and-mash-onion-gravy page: butter line on the cheapest tab reads $2.89, chip Aldi,
   per-unit $2.89/lb. No Sam's Club chip beside a non-Sam's price anywhere on the receipt.
3. Receipt "Register total at the cheapest stores" at 14 servings equals the "Shop this recipe"
   picker total with all 7 stores ticked (was $58.37 vs $37.25; the numbers drift with the week's
   feed, the EQUALITY is the check).
4. Everyday tab: butter no longer $10.22 (if the everyday scan shipped) and everyday total >=
   cheapest total on every recipe checked; the savings sentence shows the honest delta.
5. Scale servings to 2, 14, 42: totals re-rank correctly, no NaN, no new "Unavailable". A large
   count that legitimately flips a winner to the warehouse pack is correct behaviour, not a bug.
6. Custom tab: unticking a line removes the SAME cost the line shows; "Already in your kitchen"
   accumulates; focus returns to the checkbox.
7. Store picker "cheapest on N" counts agree with the receipt chips; print list unchanged in shape.
8. Sale tag appears only on lines whose WINNING cell is a sale.
9. Every "See item" link opens the product at the store named on that line (or the line has no
   link).
10. 375px width AND dark mode, per mobile-first-rule: no horizontal overflow (use the
    getBoundingClientRect walk, not scrollWidth, which lies under overflow-x:clip), both tabs, the
    picker sheet open, chips not mid-word wrapping.
11. A variable-weight meat recipe and an alias-bid recipe render fully priced lines.
12. feed-covers-published.ps1 -Live green; smp-feed.json size delta recorded raw and gzipped.
13. After full rollout: refree-clobbered.ps1 run and clean; publish reported published+verified OK
    for all slugs (or skipped-unchanged where hash-equal).

## 10. Explicitly OUT OF SCOPE

- engine\cost-recipes.ps1 and the utilization basis (cost_per_serving); any golden-test rebaseline.
- spec.stat.cost_ps, prose tokens, reanchor-machine-fields.ps1, propagate-recipes.ps1 runs.
- Feed ingredients[bid].cheapest/.store semantics (the board's per-unit chip stays per-unit).
- pricing_inputs.current/.everyday selection rules in export-feed (still min per-unit; they are the
  fallback and the board-facing basis).
- Phase 2 (compute-v2-perserving cheapest_ps, top5, free rotation, planner data, hub grid) unless
  Brad approves it after seeing the section 5 free-set diff.
- Board matching rules, commodities.json, product-urls pins (board-match-collisions territory; none
  of those files change here).
- The everyday-vs-utilization gaps documented as by-design in recipe-cost-basis-map.
- Any change to the store picker's UX or the print flow beyond the wins-count fix.

### Critical Files for Implementation

- C:\Codex\income\meal-prep\pipeline\tpl2-scaler-prefix.html
- C:\Codex\income\grocery\export-feed.ps1
- C:\Codex\income\meal-prep\engine\build-cards.ps1
- C:\Codex\income\meal-prep\engine\publish.ps1
- C:\Codex\income\meal-prep\pipeline\feed-covers-published.ps1
- C:\Codex\income\meal-prep\pipeline\compute-v2-perserving.ps1 (phase 2 only)