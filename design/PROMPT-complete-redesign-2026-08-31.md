# Session prompt: complete the Thrifty Crew redesign

Complete the ENTIRE grocery board + meal prep redesign, end to end, to live. Two of fourteen
design elements shipped on 2026-08-31; the remaining twelve are below. Do not stop at a
portion, and do not treat "committed" as done - nothing counts until it is published and
verified on the live site.

## The design is already decided - build to it, do not re-invent it

The canvas: https://claude.ai/code/artifact/c0f1a2cd-7f37-4bc3-bea5-03a5d14bfa0c
Working artboards: `design/canvas-redesign-2026-08-31/` (Main, GroceryTrip, MealPrep, Density
`.dc.html` + `canvas.json`). Re-seed with the `design` skill's helper if you need to edit them.

Brad ratified: rethink the pages (not a restyle), clickable prototypes, and a NO-PHOTO system
for meal prep - identity comes from typography, cuisine colour and the data itself.

Read `design/redesign-board-mealprep-2026-07-31.md` first. It is a ratified plan whose P0s
mostly SHIPPED (sticky rail, floating trip bar, content-visibility, hub search/cuisine/sort,
FREE badges). Its constraints section is still binding. Do not redo what it already delivered.

## Already done (2026-08-31, commits 5dd94efb + 4404f66b, both live)

1. Board row head is two lines - name wraps and is never clipped (was 410/637 truncated at
   375px), store moved under the name, price stays top-right. Desktop >=700px keeps the
   one-line ledger and its dotted leader.
2. Hub default sort is now "Most protein per dollar" (the option already existed).
3. Fixed, not redesign: `creme-fraiche.label` mojibake + the PS 5.1 ANSI read that doubled it.

## Remaining work - all twelve

### A. Grocery board (`grocery/build-deals-page.ps1`)
1. Open on the 37 on-sale items, not all 637. The filter pills already exist; this is a
   default-state change plus making search reach the full set.
2. Redesign the expanded panel: the seven stores as a ranked bar list (bar length by price,
   cheapest highlighted), with an explicit "not carried" row instead of a bare "?".
3. Cut the preamble. Today ~3 screens (~2,500px) pass before the first price on a phone.
4. Consolidate the controls (two checkbox toggles + search + chips are four idioms) and
   finish the sticky picked-items bar per the Main artboard.

### B. Split my trip (`GroceryTrip.dc.html` - entirely unbuilt)
5. Make the planner a destination, not a card in the preamble.
6. Store-count stepper (1 / 2 / 3) showing the real total for each.
7. The verdict line, including the honest "a third store saves nothing this week" case.
8. Per-store leg cards with subtotals and store-colour dots.

### C. Meal prep hub (`meal-prep/build-hub-grid.ps1`)
9. Compact rows: ~300px cards -> ~76px rows. Cal + protein on one line; carbs and fat move to
   the recipe page. Page is 185,744px at 375px today (~229 phone screens).
10. Cuisine tiles (colour + serif monogram). NOTE: the monogram collides - "Italian" and
    "Italian-American" are both "I". Needs a real cuisine -> mark mapping, not first-letter.
11. Protein-per-dollar bar per row, so ranking is visible without reading a number.
12. "Best value this week" picks section above the full list. Watch for a real finding: the
    top of that ranking is dominated by slow-cooker recipes (9 of the top 12). Ask Brad
    whether to enforce variety.

## Sequencing - read before starting section A

Several board items are much cheaper AFTER one structural change, and doing them first means
writing the code twice.

`public/board.json` stores RENDERED HTML STRINGS per row, not structured prices. That is why
the trip planner, the hide-Sam's recompute and expand-all all read prices out of chip DOM,
which is why `build-deals-page.ps1` eagerly hydrates all 637 rows at idle (line ~1345),
taking the runtime DOM from 9,270 to 36,370 nodes. It is a deliberate, documented tradeoff -
not a bug - but it is the root of most friction on this page.

Recommended: make the feed carry structured data (`store`, `per_unit`, `unit`, `sale`,
`membership`) ALONGSIDE the existing HTML, then move one consumer at a time, each independently
gated. Items 2, 4, 6, 7 and 8 all get easier once it exists. Get Brad's go-ahead before doing
it - the July doc scopes itself "presentation-layer only" and this crosses that line.

## Hard constraints - violating any of these breaks something silently

- `build-hub-grid.ps1 -Validate` parses the LIVE page by regex, and guards at lines ~679/684
  assert card shape. ANY card markup change must update them IN THE SAME COMMIT or the
  validator silently rots. `-Validate` cannot be tested until after publish.
- `/meal-prep-recipes/` is the live Google Ads landing page (AW-18314028055). Do not change the
  H1, title tag, or top-of-page semantic structure; re-verify the conversion tag after publish.
  Layout-shift regressions cost real money via Quality Score.
- NODE BUDGET is the board's stated design constraint (target under 8,000 initial elements;
  served HTML is ~9,270 today). The check, chevron, store dot and leader are all pure CSS on
  existing elements precisely to save 6 nodes/row. Do not add nodes per row casually.
- `pgSummaries()` rewrites the row head on load AND on every Hide-Sam's toggle. Anything you
  change in the row head must be changed there too or it reverts at runtime.
- Script-bearing pages MUST publish as a lexical html card. NEVER `?source=html` - Ghost strips
  scripts silently.
- Keep `publish-deals-page.ps1`'s coverage gate and change gate exactly as they are.

## Tooling traps that cost time on 2026-08-31

- `build-deals-page.ps1 -Out <temp>` still rewrites `public/board.json` and
  `public/price-history.json`. `git checkout -- public/` after any local build.
- The board's item NAMES come from `grocery/out/comparison-*.json` (gitignored, rebuilt daily,
  has a UTF-8 BOM), not from `commodities.json`. A fix to the source will not appear on the live
  board until that file regenerates.
- `publish-deals-page.ps1` builds internally - do not build first. It has `-SelfTest` (hermetic).
- `file://` is blocked in the browser pane. Serve previews over `127.0.0.1` and give the harness
  a RESPONSIVE column (`max-width:720px;margin:0 auto`) - a fixed phone-width column runs the
  desktop media queries inside it and shows catastrophic fake breakage.
- Verify CSS against a REAL BUILD at 375px and >=700px. Reasoning about flexbox is not
  verification: a "one-line CSS fix" made truncation worse, and a wrapping name pushed the price
  onto a third row until `flex-basis` went from `auto` to `0`.
- run-gates: check the EXIT CODE and diff the case-NAME list against a pre-change run. The tally
  alone will not catch a case that stopped being discovered. It is blind inside worktrees.
- PS 5.1 `Get-Content -Raw` with no `-Encoding UTF8` decodes UTF-8 as ANSI; any read that is
  written back corrupts and grows non-ASCII text. ~20 such reads of commodities.json remain
  (read-only today, so harmless until one gains a write-back).
- Use `C:\Codex\Python312\python.exe`, never bare `python`.
- Compose commit messages in a file and use `git commit -F` - backticks run as commands.
- The ~07:00 bot's `commit` takes the whole index. Stage only your own files; the tree carries
  ~330 dirty daily-chain artifacts at any time.

## Definition of done

Every one of the twelve is LIVE on thriftycrew.com and verified by fetching the live page - not
"committed", not "built". For each: gates green (exit code + case-name diff), verified at 375px
and >=700px against a real build, committed and pushed to main, published, then re-fetched to
confirm. Report anything you could not finish and why, rather than narrowing the scope quietly.
