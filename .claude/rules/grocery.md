---
description: Traps when working on the grocery board, captures, or the comparison pipeline.
globs: "grocery/**"
alwaysApply: false
---

> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `grocery/`

Loaded only when you touch a file under `grocery/`. These are the traps that have actually cost this
estate a day; each names the memory or file holding the full account rather than restating it, so there
is one copy of every rule and nothing here can drift from it.

- **`known-wrong.json` is the MAIN-board corrector, and `comparison-*.json` is rebuilt daily.** A fresh
  ruling reads as red until the next build. That is on purpose, not a bug to chase.
  [[known-wrong-is-the-main-board-corrector]]
- **`compare-deals.ps1` is not standalone.** A mid-day rebuild needs identity emission AND link repair.
  Never revert-to-isolate. **MANY scripts LIFT its functions**, against a `three` that stood in
  this file for months. **DO NOT QUOTE A NUMBER HERE. RUN THE SCRIPT.** This quantity was counted
  SIX times on 2026-09-08 and produced six answers, and not one disagreement was about the code -
  every one was about which test the writer meant:
  ```
  powershell -NoProfile -File ops\count-source-lifters.ps1 -Script compare-deals.ps1
  ```
  It defines and prints all three tests - NAMES, READS, EXECUTES - splits one-off scratch out,
  names each executing file with the line that runs the lifted text, and carries frozen fixtures.
  On 2026-09-08 over 562 scanned files: 54 name it, 18 read its source (15 outside
  `grocery\out\`), and 12 executed by the OLD test below. Say which test you mean or the number
  means nothing.
  **Backlog I82 shipped both halves on 2026-09-09** - the pricing math is `pricing-math-lib.ps1` and
  the exclude list is `global-exclude-lib.ps1`.
  **EXECUTES was a co-occurrence until 2026-09-10** - a read plus an Invoke-Expression ANYWHERE in the
  same file - so it named `test-auditors`, which only `-match`es compare-deals' text and runs text cut
  from OTHER files, and it could not see a `[scriptblock]::Create` at all. It now follows the text from
  the read to the call that runs it. Over 596 files on 2026-09-11 it read 57 NAME it, 8 READ its
  source, and **1 EXECUTES: `test-match-lib.ps1:78`**, which runs the original matcher cut out of
  compare-deals so it can prove match-lib decides identically. That one is on purpose.
  **The live production lift was not from compare-deals at all.** `-Script build-walmart-deals.ps1`
  named `import-walmart-batch.ps1` (Build-Row, six helpers and `$script:UnitFamily`) until 2026-09-11,
  when they moved to `walmart-row-lib.ps1` and both Walmart writers began dot-sourcing it
  (`design/PLAN-walmart-row-lib-2026-09-11.md`). What remains is `-Script import-walmart-batch.ps1`
  naming `import-instacart-batch.ps1` (Merge-IwbRows), and `ops/audit-lift-completeness.ps1` checks that
  list is closed. **Still run the script rather than quoting any of these numbers.**
  A lifted `$script:` constant does not
  travel - the lift needs functions, parens and a column-0 brace, which is why the exclude list is
  exported as `Get-TcGlobalExclude` and not as a variable.
  [[compare-deals-is-not-standalone]], [[compare-deals-functions-are-lifted-by-many-scripts]]
- **A wrong product is a SELLER SHAPE, not a brand.** Blocking the brand hands the cell to the next
  bulk seller. [[wrong-product-class-is-a-seller-shape]]
- **One bad Walmart pull holds a ship-only cell for 90 days** once Marketplace rows enter the union.
  [[walmart-marketplace-rows-pollute-the-union]]
- **A CAPTURE THAT CANNOT NAME ITS STORE IS REFUSED, at Walmart and at Aldi** (2026-09-12, Aldi
  2026-09-10). Both emitters open their capture with a `#tc-store` line naming the store each row was
  READ at, and both builders write `source` from that line instead of a literal. **Post the emitter's
  output UNALTERED and never strip the line.** Walmart's `build-walmart-deals` refuses a capture with no
  store line, an `UNRECORDED` one, one read anywhere but the sanctioned storeId (stores.json -> Walmart
  -> `store_identity`, currently 5361 / 68137 on Brad's 2026-08-28 ruling), or one that straddles two
  stores; `pull-walmart-instore.js` refuses to sweep at the wrong store at all and re-reads the store
  from EVERY `/search` response, because a session flips mid-sweep. **The id is the discriminator, never
  the word "Omaha"** - the drifted 3153 Neighborhood Market is an Omaha address too, which is why
  414 rows on 2026-08-27 and 380 on 2026-09-12 read as perfectly normal and both had to be quarantined
  by hand. Right prices in the wrong basis is the hardest defect here to find later.
  **Aldi's OLA number is deliberately NOT pinned** and Walmart's storeId deliberately IS: that session
  legitimately moves between Omaha Aldis, where one Walmart is ruled. What neither may do is claim a
  store nobody read. [[walmart-session-store-3153-drift]], [[aldi-store-is-ola-42]]
- **A STANDING RULING'S OWED TERMS ARE DERIVED AND LEAD THE WORKLIST**, never hand-picked and never
  hand-discharged (2026-09-12). Brad's store-drift ruling named 23 terms to recapture and said to put
  them at the head of the next Walmart worklist; nothing carried that anywhere for a fortnight, because
  a list in a JSON file and a line in a runbook are reminders and not mechanisms. `Get-WalmartRulingOwed`
  in `capture-policy-lib.ps1` now derives what is owed - the ruling's own list, minus terms a built
  `walmart-regular` file PROVES were recaptured at the sanctioned store - and `Get-CaptureWorklist` puts
  the result at the head as `ruling_terms`. Two properties are what make it a mechanism: it **empties
  itself** as captures land (so **do not edit a ruling file to mark a term done**), and the owed terms
  come out of the allowance the **sale expiries** get, never out of the rotation's daily drip, so the
  cursor can never advance over a term a prepend displaced. A file built under `-WaiveMissingStoreLine`
  discharges NOTHING - its own stamp says the store was never recorded.
- **No hard-coded bands** (Brad, 2026-09-04). [[no-hardcoded-bands]]
- **The boards are gitignored**, so a worktree, a CI runner or a clean checkout is BLIND here and the
  engines exit 0 having priced nothing. `ops/seed-worktree.ps1` and `.worktreeinclude` seed them.
  **A RE-SEED REFRESHES a seeded FILE whose source was rewritten since the copy** (2026-09-11). A board is
  rebuilt under the SAME dated name several times a day, and a seeder that left every present file alone gave
  a half-old, half-new set: a stale board under a fresh ruling. Directory seeds are not refreshed.
- **A check that compares a derived file with a board reads that file by the BOARD'S road** (2026-09-11). A
  board reaches a checkout by copy; a tracked file reaches it only by commit, and a hand-run chain rebuilds a
  board and commits its source only. test-auditors' capture-eviction currency case read the tracked report and
  refused unrelated pushes from every worktree carrying the rebuilt board, until somebody committed it; it now
  reads a gitignored stamp that `.worktreeinclude` carries. **Do not repair a lag like that by untracking a file
  the bot rewrites daily.** Measured in scratch repos: the bot's commit-then-`rebase -X theirs` hits a
  modify/delete conflict and aborts, and an autostash rebase over a local edit exits 0 with the path left
  unmerged, so the next commit exits 128. `design/PLAN-capture-eviction-stamp-2026-09-11.md`.
  **Putting the record on the right road is only half: with NO record on that road the answer is a counted SKIP,
  never a FAIL** (same day, second pass). The stamp only reaches a checkout seeded after the first live pass writes
  one, so every checkout made before that still fell back to the tracked report - the same commit-lag measurement,
  still refusing pushes, and main's dirty working copy still passing what a clean checkout failed. The question is
  now asked in two steps: could this checkout ever have RUN the pass? It reads `out/candidates-*.json`, which
  `.worktreeinclude` does not carry, so a worktree exits 3 BLIND there. With none present the case says so and
  counts a SKIP; with candidates present - the chain's own checkout, where the report is that run's own output -
  it is judged exactly as before, message for message. Nothing is weakened: the FAIL that goes away could never
  tell "the pass did not run" from "nobody has committed a report yet".
- **`cohort` here means the PEER GROUP OF PRODUCTS holding a commodity's board cells** - never a group
  of members or a group of recipes (2026-09-08, backlog I100). `build-arrivals-docket.ps1:27-31,56-57`,
  `check-ad-cycles.ps1:1791`, `adjudicate-discovery.ps1:23`, `aisle-test.ps1:35-36` and
  `sidecar/probe_peer.py:59-80` all use it that way and keep the bare word. In the skills store it also
  means a release cohort; `retention` there is LOG retention and `churn` is TEST-SUITE churn. **A future
  session grepping `cohort` while working on members gets a page of grocery hits and reads them as
  coverage** - the `identity-graph-commodity-is-namespaced` shape, an agreeing answer about something
  else. **If member work ever lands it is written `member cohort` IN FULL, every time.**
  Worth stealing in the other direction: `build-arrivals-docket.ps1:56-57` already **refuses to score a
  cohort it cannot form** and reports it BLIND rather than passing it - scoring needs at least 2 other
  priced cells, and 41 of 492 commodities on the 2026-07-30 board could not reach that.
- **A 200 with a correct selector and ZERO ROWS has FOUR causes and only two have names**
  (2026-09-08, backlog I72). `blocked` (a wall, a CAPTCHA, a challenge) and `not-carried` (the store
  genuinely does not stock it) are first-class and enforced - *UNCHECKED IS NEVER NOT-CARRIED*,
  `[[a-could-not-look-must-not-settle-the-question]]`. The two the vocabulary was missing:
  - **`unrendered`** - HTTP 200, markup present, selector right, and the rows are absent because the
    content is injected by JavaScript that nothing executed. It currently reads as a SELECTOR BUG and
    gets a selector fix, when the repair is to render the page or find the underlying JSON call.
  - **`unsettled`** - the element exists but was still filling behind a loading screen. **This is the
    worse of the two, because it produces a PARTIAL result rather than an empty one and so looks like a
    success.** Not hypothetical: `[[fareway-capture-defects]]`'s repeated exact 9 is this shape, and it
    was diagnosed by hand weeks after the fact.

  **The mechanism, and it is the useful half: do not sleep and hope - WAIT ON A COUNT-BASED SELECTOR.**
  After a scroll, wait for an element that can only exist if the scroll actually produced more rows
  (`div.row:nth-child(11)` when the page starts with 10). If the eleventh never appears the wait fails
  LOUDLY. **The assertion that the load worked is built into the wait condition rather than bolted on
  after**, which a fixed `Start-Sleep` can never do: a sleep cannot tell "the page finished and there
  were only 10" from "page 2 never loaded".
  **And the cheaper repair that may retire half of this:** open the Network tab, filter to Fetch/XHR,
  and read the URL the page's own JavaScript calls - that call usually returns the data as JSON with no
  browser needed. Three of the seven feeds here are already server-side JSON. **Nobody has checked
  whether any of the four browser-required stores is browser-required only because nobody looked.**
  That is one hour per store and it could retire the 75-minute Walmart pull.

- **A DEEP DISCOUNT IS EVIDENCE ABOUT A CELL'S FUTURE, not only about its price today** (2026-09-12,
  backlog I126). A retailer's markdown is either **temporary** (a promotion, the item stays) or
  **permanent** (an exit: clear the inventory at the end of the product's life, then drop it from the
  assortment in a reviewed deletion, not by drift). The two are INDISTINGUISHABLE in one day's
  capture, and today a deep discount and a later `not-carried` are recorded here as unrelated events.
  **Nothing automated is proposed and none should be.** The forward habit is only this: an unusually
  deep discount must NOT raise confidence that a store carries an item, because it can mean the
  opposite. And if a cheap signal is ever wanted, a commodity that showed a deep discount and THEN
  went quiet is a better `not-carried` candidate than one that simply went quiet - which bears on
  `[[a-could-not-look-must-not-settle-the-question]]`, since it is the one case where the silence
  carries information rather than none.

Regime: this holds for files under `grocery/`. It says nothing about `meal-prep/`, which has its own
rules file and its own corrector.
