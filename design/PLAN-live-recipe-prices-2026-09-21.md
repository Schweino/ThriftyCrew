# PLAN - every recipe price renders live from the feed (2026-09-21)

Brad, 2026-09-21: *"The recipe pages should be fetching the pricing from our database. That should be a
constant and we shouldn't need to 'republish'. If a pricing updates in the DB its automatically updated on
all recipe pages."* and *"Yes - build it that way. Be thorough so this can't ever 'break' again."*
Standing the same weekend: *"a recipe page should ALWAYS be able to be costed."* and *"The pricing must be
fetched from a store always."*

Stage 1 of 2: build, gate, test, republish a 3-recipe CANARY, stop. Stage 2 (the catalogue) waits for
Brad's browser check.

## Knowledge consulted

Searched the skills store ("client side render feed", "prose token expand publish", "ghost republish
catalogue", "paywall members content script"): nothing applicable. Used, from memory and rules:
`prose-templating` (tokens expand at build time), `recipe-cost-basis-map` (four bases plus the client
receipt), `recipe-paywall-split` (html | paywall | html at `<!--TC-PAYWALL-->`), `recipe-card-feed-repoint`
(the card reads `pricing_inputs`, `ingredients`, `recipes`), `price-mode-in-store` (30-minute edge cache on
the feed), `node-and-jsdom-available` (node + jsdom@24 in `C:\Codex\tools`), `same-fact-published-twice`,
`.claude\rules\ops-and-gates.md` (fixture vocabulary, bar cases, `<NAME>-COMPLETE`).
Exemplar harness: `meal-prep\pipeline\run-scaler-pricing-test.ps1` (node resolution, refuse-not-skip).

## What the investigation found (measured 2026-09-21, before any change)

1. **The "$2.40 each" sentence is not in the casserole post.** It is a quote card
   (`<a class="mts-free-card" href="/free-chicken-alfredo/">`) inside SITE-WIDE code injection (the
   `ghost_foot` script, after `</main>`), inside a block gated on `body.home-template`. It is in the HTML
   source of every page and RENDERS ONLY ON THE HOMEPAGE. An anonymous fetch that greps the source finds
   it; a reader of the casserole page never sees it. It is still a frozen price, on the homepage, about a
   recipe (`free-chicken-alfredo`) that is not even in today's feed `recipes` map. Residual R1.
2. **The casserole post itself ships no frozen grocery price, public or members.** The built card
   (`db\built\turkey-wild-rice-casserole.body.html`) carries exactly one money literal outside scripts:
   the membership price "$1 a month". Every other figure is either a `data-tc-live-price` span or drawn by
   the card script from the feed. Read in a PAID member session in Chrome: 25 money figures on the page,
   all feed-rendered except "$1 a month".
3. **The spec's per-line and batch figures are never rendered into a card.** `cost_lines` ("Parmesan
   Cheese, 2.25 oz: ~$0.76 ..."), `cost_batch` ($51.72), `cost_batch_true` ($75.23), `cost_pantry_add`
   ($11.62), `cost_first_run` ($86.85), `cost_per_serving` (3.69) exist in `db\recipes\<slug>.json` and
   `recipes-db.json`; `build-card2.ps1` reads none of them. A paid member sees no "Batch total" and no
   "empty pantry" sentence (checked live). The receipt a member sees is computed in the browser.
4. **The live fill had a hidden dependency that could break it.** `updateStats()` in
   `pipeline\tpl2-scaler-prefix.html` opened with `var bar=document.querySelector('.mts-recipe-stats');
   if(!bar) return;` and the `[data-tc-live-price]` fill sat at the END of that function. `.mts-recipe-stats`
   is created by the SITE-WIDE code injection, not by the post. So every prose price on every recipe page
   filled only because a different piece of code, edited through Ghost settings in a browser, happened to
   insert a div first. Run the post alone (jsdom, the real card bytes, the real feed): 65 of 65 sampled
   cards left every span at "current price loading". Change the site injection and every recipe page on the
   site stops showing a price, with no gate anywhere able to see it.
5. **The fallback was not a price.** A span's build-time text was "current price loading" / "current
   release price loading", so a reader whose feed failed, a no-script reader and a search engine read
   "for about current release price loading a serving". The fill also accepted any number: `tev!==null`
   lets `NaN` and `0` through, so an empty or unparseable feed could print "~$NaN" or "~$0.00".

So the root cause Brad named (tokens expand at publish) was already half-cured on 2026-09-01 by
`Move-SpecPriceToReleaseHydration`; what was missing is that the cure was unguarded: no numeric fallback, no
refusal of a bad fill, a fill that depended on the theme injection, no build gate on the built output, no
feed contract naming what a placeholder reads, and no monitor of the live page.

## PART 0 - Inventory: every money figure a reader can see

Three cards, three shapes. `chicken-fried-rice-skillet` is FREE (public, in this week's free rotation),
the other two are PAID. `beef-birria-burrito` is the burrito shape: one span in the public half and NONE
behind the paywall (10 cards share that shape). Span counts are public | members.

| Card | Visibility | Spans (public / members) |
|---|---|---|
| turkey-wild-rice-casserole | paid | 2 / 2 |
| chicken-fried-rice-skillet | public (free) | 2 / 2 |
| beef-birria-burrito | paid | 1 / 0 |

Catalogue shapes (584 built cards): 2/2 x329, 1/2 x144, 2/1 x75, 1/1 x22, 1/0 x10, 2/3 x4. Every card has
at least one span in the public half.

| # | Figure (text a reader sees) | Where | Produced by | Basis | Feed carries it? | Decision |
|---|---|---|---|---|---|---|
| F1 | "~$5.87" in the stat line "Makes 14 servings ... ~$5.87." | public | span, filled by the card script `totalAt(n,'everyday')/n` | `feed-everyday-whole-package`: each line billed whole packages at its cheapest NON-SALE store cell in `pricing_inputs`, at the store's package, per serving at the scaler's servings (the receipt's Everyday tab) | the INPUTS: `pricing_inputs[bid]` for every bid in the card's `smp-sc-data`. No per-recipe figure on this basis exists in the feed (`recipes[slug].per_serving` is a CHEAPEST figure, 5.41) | KEEP LIVE. Fallback = the value the card's own script fills against the canonical feed at build time, stamped with the feed's `generated`. NOT `stat.cost_ps` (see Basis finding). |
| F2 | "for about ~$5.87 a serving" in `intro_html` | public | `{{cost_ps}}` token -> `Move-SpecPriceToReleaseHydration` -> span | same as F1 | same as F1 | KEEP LIVE, same span. It reads the SAME computation as the receipt's Everyday tab, so it is one fact, not a second copy. |
| F3 | "About ~$5.87 a serving" in `cost_closing_html` | members (casserole, fried rice); absent on burrito | same as F2 | same | same | same |
| F4 | "lands at about ~$5.87 a serving" in `upsell_html` | members on 2/2 cards; public on some | same as F2 | same | same | same |
| F5 | Receipt line costs "2 x 16 oz $21.98" ... and grand "$79.75, about $5.70 a serving" (Customized tab, default) | members | card script, `price(it,n,basis)` | WHOLE-PACKAGE at the CHEAPEST cell (Customized/Cheapest tabs) or EVERYDAY (Everyday tab) | yes, `pricing_inputs` | ALREADY LIVE, no fallback text (renders only with the feed). Unchanged. |
| F6 | "saves $2.38 versus everyday prices this week" | public | card script `renderSave()` | difference of the two whole-package totals | yes | ALREADY LIVE, hidden until the feed lands. Unchanged. |
| F7 | Composition bar percentages | members | build-time snapshot from `util_cost`, rebuilt live by `renderComp()` | shares, not money | n/a | NOT MONEY. Unchanged. |
| F8 | "$1 a month" in `upsell_html` | members/public | authored | the site's own membership price | n/a, not a grocery price | ALLOWLISTED literal, by exact phrase. |
| F9 | Related cards "Current price loads on the recipe page" | members | build-card2 `Build-Related` | none | n/a | No figure. Unchanged. |
| F10 | JSON-LD `description` "579 calories, 48g protein, with live pricing shown on the page." | head | `Move-SpecPriceToReleaseHydration` | none - no price | n/a | NO PRICE IN STRUCTURED DATA. Not changed in this stage (Brad: do not touch SEO). |
| F11 | `custom_excerpt` / `meta_description` / og / twitter | Ghost fields | publish.ps1 `$desc` = the same stripped description | none | n/a | No price. Unchanged. |
| F12 | Spec `cost_lines`, `cost_batch`, `cost_batch_true`, `cost_pantry_add`, `cost_first_run`, `cost_per_serving` | NOT RENDERED on any recipe page | cost-recipes / sync-recipesdb-cost | UTILIZATION (cost_batch/14) and whole-package at cost-run prices | n/a | NOT SHIPPED. They must never be: they would be the same fact as F5 published twice on a different basis. The build gate (Part 3) is what now guarantees it. |
| F13 | Blue stat rectangle `.mts-recipe-stats` | public | site-wide injection; `updateStats()` relabels it | cheapest whole-package when it shows a price | yes | Shows servings/cal/protein on the casserole today. Unchanged; the prose fill no longer depends on it. |
| F14 | Homepage quote "Fourteen servings at about $2.40 each" | HOMEPAGE only, site-wide injection | hand-authored | unknown, frozen | no (`free-chicken-alfredo` is not in `recipes`) | OUT OF THE POST. Residual R1. |

Calories and protein (stat line, intro, portion, JSON-LD nutrition) stay BUILD-TIME: they come from the
food DB and grams, which a price move does not change, and they are already tokenised from the spec's own
stat.

## Basis finding (measured 2026-09-21, before any fallback was chosen)

Three numbers all called "everyday, whole package, per serving" disagree on the canary:

| card | card script fill (receipt Everyday tab) | `v2-perserving.everyday_ps` | `stat.cost_ps` |
|---|---|---|---|
| turkey-wild-rice-casserole | 5.87 | 6.02 | 6.20 |
| chicken-fried-rice-skillet | 2.23 | 1.99 | 2.00 |
| beef-birria-burrito | 4.86 | 4.97 | 4.58 |

`everyday_ps` and `stat.cost_ps` bill the RECIPE BOARD's everyday cell at the RECIPE's package (`costed.json`,
`compute-v2-perserving.ps1` line 3); the card bills each line's cheapest non-sale STORE cell at the STORE's
package. They are different bases, so `stat.cost_ps` cannot be a placeholder's fallback and `everyday_ps` cannot
be the monitor's oracle. The fill is what readers have been shown since the 2026-09-01 hydration, so it is the
basis the placeholder names; the fallback is produced by the same code. Which "everyday" the site should quote
everywhere is residual R5.

## PART 1 - The mechanism

The placeholder, emitted by ONE function (`Format-TcLivePriceSpan`, `meal-prep\lib\render-tokens.ps1`):

    <span data-tc-live-price data-tc-slug="turkey-wild-rice-casserole" data-tc-field="cost_ps"
          data-tc-basis="feed-everyday-whole-package" data-tc-fallback="5.87"
          data-tc-asof="2026-09-21T05:22:59">~$5.87</span>

- The TEXT is the build-time value on the SAME basis the fill computes: build-card2 writes `stat.cost_ps` as a
  provisional value, then `engine\build-cards.ps1` runs `pipeline\stamp-live-price-fallback.ps1`, which executes
  each card's own script (`live-price-fill.js`, jsdom) against `grocery\out\smp-feed.json` and rewrites every
  span to the filled value with `data-tc-asof` = the feed's `generated`. A card whose fill is refused is a build
  error (fail closed). `publish.ps1` refuses a span with no stamp.
- The fill moves out of `updateStats()` into its own `fillLivePrices()`, called from `renderAll()` and from
  the feed callback, so it no longer depends on `.mts-recipe-stats` or anything else the theme injects.
- A fill is REFUSED client-side unless the value is a finite number greater than zero, the feed loaded,
  and the span's field is one the script knows (`cost_ps`). A refused fill leaves the fallback. A good fill
  sets `data-tc-filled="<value>"` so a monitor can tell a filled span from its fallback.
- The same `~$` shape as before, so what a reader sees on a working page does not change.
- Paywall: the fill queries the whole document at DOMContentLoaded (`go()`), after Ghost has rendered the
  members card for a member, so members-half spans are reached. Measured in Chrome as a paid member before
  the change: 4 of 4 spans filled on the casserole.
- One fetch: the fill reads the card script's existing `feedData`; no new request.
- Edge cache: unchanged. The feed URL and its 30-minute cache are not touched.
- `Remove-GhostStaticCurrencyClaims` rewrites every other `$N` in the body into words. It now shields
  live-price spans first, or it would turn the fallback "~$6.20" into "restaurant money".

## PART 2 - The feed contract

`meal-prep\pipeline\audit-live-price-contract.ps1` reads every built card and fails if a placeholder:
names a slug other than its own card, names a field outside the registry (`cost_ps` only), names a basis
other than the registry's basis for that field, carries a fallback that is not a positive money value, or
sits in a card whose `smp-sc-data` bids do not all resolve in the feed's `pricing_inputs` with a current
price (what `totalAt` reads), or whose slug is missing from the feed's `recipes`. Default feed is
`grocery\out\smp-feed.json` (what the next deploy ships); `-Live` reads the deployed URL.

## PART 3 - The build gate

`Test-TcBuiltPriceLiterals` (`meal-prep\lib\price-literal-gate.ps1`) reads the BUILT body and head, drops
`<script>`/`<style>` and live-price spans, and refuses any remaining `$<digit>` in text or in
`alt/title/aria-label/content` attributes, and any `"price"`/`costPerServing`/`estimatedCost` key in
JSON-LD. The allowlist is two exact phrases, each with a reason: `$1 a month` and `$10 a year` (the site's
own membership price; not a grocery price and not derived from any board). A stated bound never reaches a
built card: `Remove-GhostStaticCurrencyClaims` already rewrites it into words at render, so there is no
bound entry to allow. `build-card2.ps1` throws before writing; `engine\publish.ps1` refuses the slug.

## PART 4 - The live monitor

`meal-prep\pipeline\monitor-live-recipe-prices.ps1` (daily, `check-ad-cycles` fan-out) with
`live-price-fill.js`: fetches the live page (cache-busted), asserts the post references the feed, asserts
no money literal in the post outside a placeholder (the same library as Part 3), runs the post's OWN
scripts in jsdom against the deployed feed, and asserts every span filled and equals an independent
reading on the SAME page: the receipt's Everyday tab grand total divided by its servings (within one cent,
the most the receipt's rounding can move it). `everyday_ps` was the planned independent oracle and is on a
different basis (Basis finding), so it cannot be one; there is no independent implementation of this basis
today, which is residual R5. Sample: the canary daily plus a rotating window of 12 of the published catalogue
(every page about every 48 days), denominator printed. Members-half spans: the anonymous page cannot see them; the
Admin API post HTML is run the same way (it is what Ghost renders for a member). Pages through
`grocery\send-alert.ps1`, registered in `grocery\alert-registry.json`.

## PART 5 - Rules

`.claude\rules\meal-prep.md` and `.claude\rules\site-and-publish.md`, dated 2026-09-21, Brad's instruction.

## What shipped, and the canary (2026-09-21)

Self-tests, exit 0 each: render-tokens 33 lines, price-literal-gate 24 cases, stamp-live-price-fallback 9,
audit-live-price-contract 13, monitor-live-recipe-prices 13. Neighbours re-run green: build-card2,
gated-republish-lib 18/18, test-guards, audit-allergen-line 28, feed-covers-published 28, run-scaler-pricing-test,
audit-alert-registry.

Corpus, before stage 2: price-literal gate over 584 built cards found 0 price literals; every finding was a
legacy placeholder. Contract over 577 published cards: 0 findings, 574 legacy, 58 BASIS WARNINGS (R4).

Canary republished through `engine\publish.ps1 -Slugs` (a hand `propagate -SlugsFile` refuses: 375 other specs
are dirty, and `-AllowCatalogue` is the catalogue republish this stage must not do; `sync-recipesdb-cost` dry run
reported 0 fields). Live, cache-busted: placeholders shipped with stamped fallbacks (5.87, 2.23, 4.86); monitor
3 of 3 clean, members halves filled and equal to their own Everyday tab; Chrome as a paid member read 4 of 4
casserole spans at ~$5.87 against an Everyday tab of $82.13 / 14; 375px (Browser pane emulation) no horizontal
scroll, stat line and intro read "~$5.87".

## Residuals (owners)

- R1 homepage "$2.40 each" quote in site-wide code injection (Ghost settings, browser-only write): Brad.
- R2 stage 2, the catalogue republish so every card carries the new span and fill: next session after
  Brad's canary check. Until then the monitor reports pre-canary pages as LEGACY.
- R3 JSON-LD carries no price at all today; if a price is ever wanted there it is build-time by nature and
  needs its own ruling: Brad (SEO).
- R4 58 published cards say "(at everyday cost)" over a SALE price: red bell pepper is priced only by one Family
  Fare sale cell, and the card's everyday lane falls back to `current` when no non-sale cell exists. Refusing it
  would black out 58 prices (against "a recipe page should ALWAYS be able to be costed"). Counted daily by the
  contract as `basis_warnings`. Ruling: Brad; repair: a store fetch of an everyday red-pepper price.
- R5 Three "everyday" per-serving numbers (card fill, `everyday_ps`, `stat.cost_ps`) disagree by up to $0.33 on
  the canary. The rankings, top-5 and planner read the manifest; the page reads the fill. Which basis is "the"
  everyday, and an independent implementation of it for the monitor to compare against: Brad, then a basis pass.
- R6 `sync-recipesdb-cost` printed "costed COULD NOT READ (0 row(s))" for its partial-cost input. Observed, not
  investigated: next meal-prep session.
