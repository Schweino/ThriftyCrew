# Elite layer: build status, 2026-07-31

Implementation of `design-elite-layer-2026-07-31.md` (which assumes `redesign-board-mealprep-2026-07-31.md`,
also unbuilt at the start of this session, so both were built together).

**SHIPPED 2026-07-31**, except the board, which stays staged behind the grocery freeze. Committed as
`da9ae9f8` and pushed. What went live and what is verified is at the bottom.

---

## What shipped into the repo

### Wave 0: the design system (`income\lib\design-tokens.ps1`, new)

One include, dot-sourced by all three page builders, so the surfaces cannot drift into three products.

- `Get-TcTokenCss -Parts` emits only the primitives a surface uses (a recipe post does not carry the
  board's ledger tabs). Variables, three-step Georgia type scale, three-level depth, navy bands, the
  money-gold rule, focus rings, 44px touch, the z-ladder, receipt and ledger materials, one motion
  vocabulary inside `prefers-reduced-motion: no-preference`, skeletons.
- `Get-TcMotionJs` emits the shared runtime: one rAF number tween that announces once at the end, haptics,
  wake lock with re-acquire on `visibilitychange`, a focus trap with Escape and return-focus, and
  `TC.mode()` which broadcasts a `tc:mode` event so bars can obey the stacking ladder instead of guessing.
- `Get-TcStoreAccents` reads the seven hues from `grocery\stores.json` (a `color` field was added there,
  registry rule); the board rows, the trip receipts and the Aisle Mode header all read that one source.
- `Test-TcNavyAdjacency` / `Test-TcGoldDiscipline` are cheap greps the builders run on their own output
  and hard-fail on. The elite spec asked for these to be enforced by a check rather than a comment.
- `Compress-TcCss/Js/Asset`: comments and indentation are load-bearing in source and pure weight on the
  wire, and the recipe template ships 513 times.
- `Get-TcPrintCss`: one print block for the whole site.

`income\brand\tc-touch-icon-{180,512}.png` rendered with the existing GDI+ pipeline and copied into
`public\` (worker-served). `income\design\wave0-codeinjection-head.html` is the ready-to-paste head block.

### Wave 1a: recipe pages (`pipeline\build-card2.ps1` + `tpl2-scaler-prefix.html`)

513 cards rebuild clean in 20 seconds, 0 errors, average body 46 KB.

- **The receipt.** "What This Batch Costs" is a register receipt: warm paper, CSS zigzag tear edges,
  monospace quantities, dotted rows, TOTAL under a 3px double rule, an ink stamp. Unchecking an ingredient
  dims and strikes the row, rolls the total with the shared tween, and accumulates
  "Already in your kitchen: $6.40".
- **The savings delta**, above the tabs: the subtraction of two totals the widget already computes,
  suppressed under $1. This is what resolves v1's two-price confusion with a reason instead of a label.
- **Cost-composition bar**, computed at build time from the same whole-package prices as the checklist
  (the array normalized, never a second sum), top three labeled, payoff line in Brad's voice, owned
  ingredients re-tint gray on uncheck.
- **Cook Mode**, built at tap time from the Make It list: right two-thirds advances, left third goes back,
  wake lock, per-slug resume, ingredients half-sheet reading the scaler's current quantities, hardware
  back closes. Inline fallback (tappable steps, "Picking up at step 4") for anyone who never opens it.
- **Jump nav**, sticky **mini-scaler** obeying the ladder, scaler feel (44px steppers, servings pop, row
  pulse), **related-recipes footer** (next-cheapest same protein, a free-this-week pick badged, an
  adjacent cuisine), **Shop This Recipe** (gated on per-recipe board-id coverage; all 513 clear 70%),
  `id="stepN"` anchors the JSON-LD has always pointed at and nothing provided, and print styles.

### Wave 1b: the hub (`build-hub-grid.ps1`)

Rewritten around five marked, idempotently-replaced blocks. 11,060 nodes, sort in 3 ms.

Free-this-week snap rail with dots, kitchen ticker, protein-per-dollar leaderboard (navy, static height,
no JS, max two per protein), search + cuisine + sort + calories, FLIP shuffle on the visible slice only,
pressable protein-spined cards with FREE ribbons and a protein-per-dollar figure, tonight-mode picker that
visibly drives the real controls, empty states whose relax chips are computed by re-running the real
filter function, `content-visibility` on cards, and touch ergonomics (16px inputs, `type=search`,
`enterkeyhint`, native selects).

### Wave 2: the board (`build-deals-page.ps1`), STAGED ONLY, the grocery freeze is live

`out\deals-page-embed.html` builds green. **7,632 initial nodes** (v1 target: under 8,000, was 33,091) and
**601 KB** (target: under 900 KB, was 2,258 KB).

Masthead (one band: freshness + ad countdown, round-down tally, the wrong-store stat, a tappable
biggest-drop chip), trust copy collapsed into a `<details>`, email capture moved to after the first
category, ledger rows (index-tab category heads, dotted leaders, registry-hue store dots, sale ticks, gold
record flags capped per category), chalkboard records strip, 24px checkbox, picks persisted per board
week with a resume pill, `content-visibility` on sections, sticky bar on a diet with a scroll-synced rail,
bottom sheets under 640px, sparklines drawn from the same lazy history fetch the pill already uses, the
demo basket, per-store trip **receipts**, share, and **Aisle Mode**.

---

## Bugs found and fixed on the way

1. **`356¢/oz`** (live). The ounce branch never rolled over to dollars.
2. **`$0.00 each`** on the records strip (live). Premise verified against the data first: cotton swabs are
   genuinely $0.0043 per swab. The price was right, two decimal places was wrong.
3. **`100¢/oz`**. The first rollover tested the raw value, leaving a half-cent gap: $0.9962/oz is under a
   dollar, took the cents branch, and rounded to three digits. Now the test is on the rounded cents.
4. **`$0.00/oz` inside a tooltip**. The record and verdict titles were a second copy of the same
   formatting. They now call the one implementation through a plain-text twin (the HTML one emits
   `&cent;`, and those strings go through `HtmlEnc`).
5. **The stat band froze at the pre-feed number.** The first pass relabeled the cell, so no later pass
   could find it again by its original wording, and the band contradicted its own receipt.
6. **`income\lib\` was entirely untracked** by git, including `ghost-lib.ps1`, which every publisher
   dot-sources. A fresh clone could not build a page. `.gitignore` now allow-lists `lib\` and `design\`.
7. **`-Validate` could not run.** It required a `hub-live.html` someone had to place by hand, with no note
   anywhere saying so. It now fetches the page itself, and throws if it parses zero cards.

Bugs 1, 3 and 4 all live in `income\grocery\fmt-lib.ps1` now, extracted so the formatter has a fixture
that can actually reach it (it used to be a private function 355 lines into a builder that loads five data
files first). 34 frozen cases, must-fire plus clean twins, wired into `test-auditors.ps1`:
**279 checks, all passing.**

---

## Where the build disagreed with the spec, and why

- **No dollar total in the trip ticker or "You keep $5.20".** The solver scores a dimensionless ratio on
  purpose: these per-unit prices are $/lb, $/dozen, ¢/oz and each, and summing them is not a number. The
  comparison is made on **coverage** instead, which is comparable and true: "One store can cover this whole
  list: Sam's Club, at the cheapest price on 8 of 15. This 2-store split gets you 13." The line is dropped
  when no single store covers the basket. Receipt lines keep each price's unit for the same reason.
- **The wrong-store stat is cheapest-vs-typical, not cheapest-vs-worst.** Best-vs-worst computes to a
  median 94% on this data, driven by whichever store stocks a tiny package. Cheapest-vs-typical is 38%,
  answers what a shopper actually pays for not checking, and is robust to one outlier store. Dropped under
  15% as specified; **also** dropped with a log line above 75%, because a number that size usually means a
  pack-basis problem rather than a pricing one.
- **The biggest-drop chip requires four priced stores and caps at 60%.** Without it the first build
  headlined "Achiote Paste down 91%", which is a coverage change wearing a price change's clothes.
- **Icons never reached board rows, and neither did the SVG check.** The check, chevron, store dot and
  dotted leader are all pure CSS on elements that already exist: 6 nodes x 572 rows is the difference
  between missing and clearing the node target. Recipe pages, where nodes are cheap, keep the SVG.
- **The free rail says twenty, not five.** The rotation frees the five cheapest *per protein*. The rail
  shows the cheapest eight and says how many more are badged below.
- **Half-cent rounding left alone.** `[math]::Round` is banker's rounding, so 12.5¢ displays as 12¢. That
  is frozen in a fixture rather than quietly changed mid-freeze. Whether money should round half-up here
  is Brad's call.

---

## What went live, and how it was verified

1. **The hub** (`build-hub-grid.ps1 -Publish`). 521 cards live (513 grid + 8 rail), free rail, leaderboard,
   ticker, sort control and the client script all present on the public page. The Ads contract held: the
   H1 and hero copy are byte-identical and the **AW-18314028055 conversion tag is still on the page**.
   At 375px there is zero horizontal page scroll and zero element overflowing the viewport outside the
   free rail, which is a horizontal scroller by design. Reversible from
   `site-backups\meal-prep-recipes-BEFORE-elite-2026-07-31.html`.
2. **Wave 0 site chrome**, appended to `codeinjection_head` through a logged-in owner browser session (the
   Admin API key is read-only for settings). Head went 28,424 -> 29,659 of 65,535. Verified live:
   theme-color, apple-mobile-web-app-title, both touch icons (served 200 by the worker), `color-scheme:
   light`, and exactly **one** theme-color on the page, so nothing in the theme is competing with it.
3. **513 recipe posts**, through `engine\publish.ps1 -All` and its existing change-gate/resume path.
   Spot-checked live at 375px: the stat band reads "$1.51 cheapest this week / $2.01 everyday" and agrees
   with the receipt total of $21.08, the savings sentence is showing, the composition bar has its
   segments, three related cards render, the mini-scaler is present, and nothing overflows.
   `publish.ps1` preserves each post's existing visibility (the rotation owns it), so the twenty
   currently-free dinners stayed free.

**`codeinjection_foot` has 164 chars free.** That blocks the Wave 3 interstitial restyle until something
there is minified. It is the one hard resource limit in the way of finishing the program.

## Still parked

**The board publishes after the freeze lifts (~08-07), with your go.** It builds green and is staged at
`out\deals-page.html`. Two live display bugs (`356¢/oz` and the `$0.00` record card) are fixed there;
whether they ride ahead of the freeze was already your call, and the fix is one publish away whenever
you want it.

Not built, deliberately: the de-Ghost frame and the Portal pass (both need your sign-off on a screenshot
first), the interstitial restyle (blocked on foot budget, and it ships last by design), OG images, the
unlock moment, and the board half of Shop-This-Recipe. Those are Wave 3.

Not built, and deliberately: the de-Ghost frame and the Portal pass (both need your sign-off on a
screenshot first), the interstitial restyle (blocked on foot budget, and it ships last by design), OG
images, the unlock moment, and the board half of Shop-This-Recipe. Those are Wave 3.

Also open: 107 distinct cuisine strings survive Title-Casing, including near-duplicates like
"Cajun / Creole" and "Cajun/Creole". Casing is fixed; merging variants is a data decision, not a render one.
