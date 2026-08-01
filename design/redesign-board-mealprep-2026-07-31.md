# Design Plan: Grocery Board + Meal Prep surfaces

Written 2026-07-31 by Fable (analysis pass). Implementer: Opus. Brad approves scope before anything ships.

The short version: both pages have great bones and honest content, but they were grown feature by feature and it shows. The board is now a 2.26 MB, 33,000-node, 42,000-pixel page that freezes Chrome's renderer on scroll jumps. The hub is a wall of 513 identical text cards with no search, no free-recipe badges, and one sort order. The fixes below are ranked; the P0s are performance and findability, because a beautiful page that white-flashes on a phone is not beautiful.

Evidence from the live-site pass (Brad's Chrome, 2026-07-31): full-page scroll-through of /omaha-grocery-prices/, /meal-prep-recipes/, and /chicken-bulgogi-rice-bowls/ plus DOM measurements via JS.

---

## Measured findings

| Surface | Height | DOM nodes | HTML size | Notes |
|---|---|---|---|---|
| /omaha-grocery-prices/ | 41,978 px | 33,091 | 2,258 KB | Renderer froze >30s on Ctrl+End; white-flash on fast scroll |
| /meal-prep-recipes/ | 51,977 px | 10,942 | 506 KB | 513 cards all in DOM; 3 images total |
| /chicken-bulgogi-rice-bowls/ | 5,167 px | 466 | small | Healthy. White-flash still repro'd here (see Investigation) |

Lighthouse starts complaining at ~1,500 nodes. The board is 22x that. This is the single biggest design problem on the site: the audience shops on phones, and mid-range phones will do worse than Brad's desktop Chrome.

### Confirmed bugs found during the pass

1. **356¢/oz formatter bug.** `Fmt-Price` in `income\grocery\build-deals-page.ps1` (line ~355): the `oz` and `floz` branches always render cents and never roll over to dollars. Live example: Mint (fresh) shows "356¢/oz" at Walmart. Fix: at >= 100¢ render `$X.XX/oz`. Add a must-fire fixture per the guard-fixture rule (founding case: 3.56/oz must render `$3.56/oz`; clean twin: 0.35/oz stays `35¢/oz`).
2. **"$0.00 each" price-record cards.** "Cotton Swabs $0.00 each, ties record" is live in the Price Records strip. The `each` formatter is fine, so this is upstream data (a true near-zero price or a records bug). Verify the premise against the data before "fixing" the display; if the price is real but sub-cent, records cards should suppress or floor the display ("under 1¢").
3. **Sticky-bar ghost bleed.** The sticky filter block is narrower than the row column at some widths, so rows scroll visibly past its right edge and peek through the translucent background (rgba(255,255,255,.96)). Rows also slide under it with a hard cut. Seen repeatedly at 1568px.
4. **Cuisine casing inconsistency on the hub.** "german", "palestinian" lowercase next to "Korean", "Tex-Mex". Data fix in recipes-db (or Title Case at render), not a CSS fix.
5. **Free recipes are unmarked in the hub library.** `build-hub-grid.ps1` contains no free/FREE logic. The five-per-protein weekly free rotation (the whole top-of-funnel hook) is invisible in the 513-card grid. Only the 3 hand-picked intro cards say FREE.

### What is already good (do not redesign away)

- Recipe page structure: stat band, Heads up note, source credit, Make It Your Size scaler, the "What This Batch Costs" whole-package checklist with uncheck-what-you-have. That checklist is the best thing on the site. Keep all of it.
- Board expanded-row store cards: CHEAPEST highlight, EVERYDAY/SALE label, membership/bulk tags, See item links, "No price yet at Fareway, see it? Let us know" honesty cell.
- Wins-per-store score strip and Price Records strip: good content, needs tightening not replacing.
- The trip planner concept, the gate modal copy, the hub's intro sections (Start free / How members use this / member-tool promo).
- Brand: navy #16263F, gold #E2A43C, Georgia serif heads, pill chips. The identity is consistent and warm; this is a polish job, not a rebrand.

---

## Design direction

One sentence: keep the trustworthy-ledger personality, make it fast, scannable, and phone-first, and surface the things that convert (free recipes, sale flags, the trip planner) instead of burying them.

Design tokens to codify (currently re-declared ad hoc inside each builder's CSS):

- Ink navy `#16263F`, link navy `#1E3A5F`, gold `#E2A43C` (hover `#d9992f`), green (price) and green-dark as already used, cream panel `#fdf8ec`, border grays.
- Type: Georgia serif for h1/h2/section heads, system sans for UI/body, `tabular-nums` everywhere a price column exists.
- Per-store accent colors: define once in `grocery\stores.json` (registry-driven, per the stores-registry rule) and use them for a small color dot next to store names in rows, expanded cards, and the score strip. Seven stores, seven stable hues. This gives instant "which store keeps winning" scanning that text alone cannot.
- Per-protein accent colors on the hub (chicken/pork/beef/turkey) used as a 3px card left border and on the filter chips.

Put the shared token block in one place both builders include (a small `income\lib\design-tokens.ps1` emitting a CSS `:root{}` string is enough; do not attempt the full runtime consolidation, that is overhaul item 5).

---

## A. Board page (/omaha-grocery-prices/), builder: income\grocery\build-deals-page.ps1

### P0-1. Cut the DOM: lazy-build the expanded store panels
Each of ~430 rows ships its full 7-store card grid in the initial HTML, hidden. That is where most of the 33k nodes live. Change to: each row carries a compact `data-stores` JSON attribute (or one page-level JSON `<script type="application/json">` blob keyed by item id), and the expansion panel DOM is created by JS on first toggle, then cached. Keep in static HTML: item name, checkbox, cheapest price, winning store, sale flag. That preserves SEO and the no-JS reading of "the cheapest place for X is Y at $Z", which is the page's whole search promise.
Target: under 8,000 initial nodes and under 900 KB HTML. Measure before/after with the same JS one-liner used in this audit.

### P0-2. content-visibility on category sections
`.pg-cat { content-visibility: auto; contain-intrinsic-size: auto 3000px; }` so offscreen categories skip layout and paint. This is the 80/20 for scroll jank and the Ctrl+End freeze. Verify anchors and the search filter still work (searching must un-skip matching sections; filtering already re-renders visibility so test both together at 375px).

### P0-3. Ship the formatter and records fixes
Items 1 and 2 from the bug list, with fixtures.

### P0-4. Put the sticky filter bar on a diet
Today the pinned block is search + 15 category chips in 3 rows, roughly 270 of 740 viewport pixels, worse proportionally on a phone. Redesign:
- One compact sticky row: search field (shrunk) + a single horizontally scrollable chip rail with fade-out edges + the On sale chip pinned first after All.
- Move Hide Sam's Club and Show all prices toggles into a small "Options" popover on the rail (they are set-once controls, not per-scroll controls).
- Solid background (no translucency), full column width, bottom border, `scroll-margin-top` on rows/sections so expanded items and anchor jumps never hide under it. This also kills the ghost bleed.
- Chips double as anchors: tapping a category chip filters AND scrolls to that section head as today, but the rail stays one line tall.

### P1-5. Floating trip-planner bar
The planner box sits at the top and tells you to "come back here". Selection state should follow the user: when 1+ items are checked, show a slim fixed bottom bar: "3 items picked · Plan my trip" (gold button, navy bar). Tapping scrolls to the planner (current behavior already has a scroll hook at pg-tripbox). On mobile this is the difference between the feature being used and being trivia. Respect safe-area insets at 375px.

### P1-6. Row scanability
- Keep one row per item (density is fine), but: price column right-aligned on a fixed edge with tabular-nums (already), store rendered as a mini-chip with its registry color dot, and a small SALE tick on rows whose winning price is a sale price (the On sale filter exists but unsorted rows do not show which ones qualify).
- Category heads get the item count inline (exists) plus a subtle top border band so section breaks read while flying past.

### P2-7. Top-of-page tightening
- Collapse "I'm Brad, no store pays to be here" and the methodology lines into one styled `<details>` ("How this board works") under the H1. The trust copy matters but it currently pushes the actual board below two viewports. Keep the H1, dek, and Wednesday-refresh line as is for SEO.
- Move the Friday-email capture panel from above the board to between the first and second category sections. Ask-after-value converts better than ask-before.
- Records strip: cap at one row of 4 chips with a "+315 more marked below" line (exists); tighten padding.

### Explicitly out of scope for the board
The data pipeline, guards, pricing logic, publish gates, and the paywall/visibility-preserving upsert in publish-deals-page.ps1. This is a presentation-layer change only.

---

## B. Meal prep hub (/meal-prep-recipes/), builder: income\meal-prep\build-hub-grid.ps1

### P0-1. Free-this-week shelf + FREE badges
Read the current free rotation (public-visibility recipes / free-rotation.json) at build time and:
- Add a "Free this week" shelf above the library: the 5 free dinners as cards with a gold FREE badge, with the weekly-rotation line ("Five dinners are free every week. They rotate Fridays.").
- Badge those same cards inside the grid too.
This is the highest-leverage conversion change on the whole site and it is currently absent. Note: the hub is rebuilt on publish but the rotation flips daily-ish; either re-run build-hub-grid after rotate-free-dinners.ps1 in the same scheduled chain, or have the badge applied client-side from a tiny JSON the rotation script publishes. Prefer the build-chain wiring (no new runtime dependency).

### P0-2. Search + cuisine filter + sort
513 recipes, and today you can only filter by protein and calorie min/max. Add to the filter panel:
- Text search over title + cuisine (client-side substring, same pattern as the board's search).
- Cuisine dropdown (data already on every card).
- Sort toggle: Cheapest (default, current), Most protein per dollar, Lowest calories. Protein-per-dollar is the brand argument in one number; compute at build time and stamp as a data attribute.

### P0-3. Render cost of 513 cards
`content-visibility: auto` + `contain-intrinsic-size` on cards (or card rows). Keep all 513 in the HTML for SEO, skip layout for offscreen ones. Add a "Showing 48 of 513, Show more" progressive reveal only if measurement says content-visibility alone is not enough on mobile. Measure, do not assume.

### P1-4. Card polish
- Protein-colored 3px left border per card (token set above); filter chips pick up the same colors.
- Drop "14 servings" from every card (all recipes are 14 servings; say it once in the library intro). Frees a line per card.
- Title Case the cuisine labels (fix the data at the source).
- Add the protein-per-dollar figure as a fifth small stat or replace the fat chip on the card (fat stays on the recipe page); pick one, do not grow the card.

### P2-5. Sticky compact filter on scroll
Same one-line sticky pattern as the board once you are past the filter panel: search + protein chips + sort. Shared CSS with the board's rail if practical.

### Hard constraint for this page
This is the live Google Ads landing page ($5/day, AW-18314028055 conversion tag). Do not change the H1, title tag, or the top-of-page semantic structure; do not add anything that delays first paint of the hero text; re-verify the conversion tag fires after publishing. Layout-shift regressions here cost real money via Quality Score.

---

## C. Recipe pages (builder: income\meal-prep\pipeline\build-card2.ps1, 513 live posts)

Healthy pages; polish only. Batch-republishing 513 posts is the expensive part, so bundle all card changes into ONE build+publish wave.

1. **Reconcile the two prices at the top.** The stat band says "$1.51 PER SERVING" unlabeled while the dek and prose say "about $2.44 (at everyday cost)". A first-time reader sees two prices for the same recipe with no explanation until the cost section. Change the band's first cell to carry both numbers with micro-labels: "$1.51 cheapest this week" over "$2.44 everyday". The two-number model is deliberate (cost-redesign v2); the band just predates its labeling.
2. **In-page jump nav.** A slim chip row under the stat band: Ingredients · What it costs · Make it · Portion it. These are 10-minute-read pages; cooks arrive mid-task with wet hands. `scroll-margin-top` on the section heads.
3. **Related recipes footer.** Replace the two bare "KEEP GOING" text links with three real cards from recipes-db: next-cheapest same protein, one free-this-week recipe (badge it), and one adjacent cuisine. Build-time selection, no JS.
4. **Align the cost checklist to the article column.** It currently renders wider than the prose column on desktop (visibly off-grid at 1568px).
5. **Casing normalization** rides along from the hub data fix.

---

## Investigation item (before any perf work is declared done)

The white-flash-on-scroll-jump repro'd on the small recipe page too, not just the giant board. So DOM size is not the whole story. Suspects: site-wide injected scripts (join interstitial in codeinjection_foot with its engagement trigger, print-button injector, 32 scripts loaded on the board). Opus: profile one page with the Performance panel before and after the DOM fixes, and check the injected scripts for scroll/intersection listeners doing work on every tick. Do not guess; measure. If the injection scripts are the cause, that fix benefits every page on the site.

---

## Constraints and gotchas (read before writing code)

1. **Publish method.** Script-bearing pages MUST publish as a lexical html card. NEVER `?source=html` (Ghost strips scripts silently). The board publishes via publish-deals-page.ps1; keep its coverage gate and change gate exactly as they are, and keep the visibility-preserving upsert.
2. **build-hub-grid.ps1 -Validate regex.** It parses the live hub HTML (`data-protein="..."` followed by `<h3>` and the href). Any card markup change must update that regex in the same commit and re-run -Validate green, or the validator silently rots (rules-that-silently-disarm class).
3. **Guard fixtures.** New formatter behavior (Fmt-Price rollover) ships with a frozen must-fire fixture + clean twin wired into test-auditors.ps1. Never regenerate fixtures from the live board.
4. **Card rebuild trap.** Before touching build-card2 output, read the spec-guards-prose-merge REVERT trap notes (recipe-cost-redesign-v2 memory). 400+ post republish must use the existing resume/change-gate publish path (scale-hardening), not a blind loop.
5. **Mobile-first rule.** Every one of these changes gets verified at 375px before publishing. The sticky rail, floating trip bar, and card grid are the risky ones. Also verify with the join interstitial ON (it overlays the same bottom area as the new trip bar; make sure they do not stack).
6. **Copy rules.** Brad's voice, no em dashes anywhere in new copy, no swearing, plain punctuation. Reuse existing microcopy where possible; new microcopy goes past Brad if it carries a claim (like the free-rotation wording).
7. **PS 5.1 traps** apply to any new build code (json array unroll, empty-string parse, logger EAP).
8. **SEO.** H1s, titles, and the static cheapest-price-per-item text stay in the initial HTML on the board. The hub keeps all 513 recipe links in HTML.

## Sequencing (the code freeze is live until ~08-07)

Brad froze new grocery code on 2026-07-31. Meal-prep is not under the freeze.

- **Wave 1 (now, meal-prep only):** Hub P0s (free shelf + badges, search/cuisine/sort, content-visibility), hub card polish, recipe-page changes 1-5 as one build-card2 wave. Data casing fix. Design-token include created here.
- **Wave 2 (staged now, shipped after the freeze lifts, with Brad's go):** All board work. Build and test locally against the newest board file (build-deals-page.ps1 writes out\deals-page-embed.html without publishing; diff it, measure nodes, screenshot at 375px), but no publish until ~08-07.
- **Bug exceptions Brad may want sooner:** the 356¢/oz display and the $0.00 record card are live wrongness on the board, not new features. His call whether they ride ahead of the freeze; do not assume.

Each wave ends with: gates green, test-auditors green, 375px screenshots, publish, then the post-publish-reviewer agent over everything that shipped.

## Success criteria

- Board: initial DOM under 8k nodes, HTML under 900 KB, no renderer freeze on Ctrl+End, no white flash at fast scroll on a mid phone, sticky bar max ~100px tall on mobile, trip planner usable without scrolling back to top.
- Hub: free recipes visible and badged within one viewport of the library top, search/sort live, no layout jank while scrolling 513 cards at 375px, ads conversion tag verified firing.
- Recipe pages: one coherent price story at the top, jump nav, real related-recipe cards, everything still passing the batch gates.
- Nothing about pricing math, gating, or data pipelines changed.
