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
  **The live production lift is not from compare-deals at all.** `-Script build-walmart-deals.ps1`
  names `import-walmart-batch.ps1:58` (Build-Row, six helpers and `$script:UnitFamily`), and
  `-Script import-walmart-batch.ps1` names `import-instacart-batch.ps1:68` (Merge-IwbRows).
  `ops/audit-lift-completeness.ps1` checks both lists are closed. **Still run the script rather than
  quoting any of these numbers.**
  A lifted `$script:` constant does not
  travel - the lift needs functions, parens and a column-0 brace, which is why the exclude list is
  exported as `Get-TcGlobalExclude` and not as a variable.
  [[compare-deals-is-not-standalone]], [[compare-deals-functions-are-lifted-by-many-scripts]]
- **A wrong product is a SELLER SHAPE, not a brand.** Blocking the brand hands the cell to the next
  bulk seller. [[wrong-product-class-is-a-seller-shape]]
- **One bad Walmart pull holds a ship-only cell for 90 days** once Marketplace rows enter the union.
  [[walmart-marketplace-rows-pollute-the-union]]
- **No hard-coded bands** (Brad, 2026-09-04). [[no-hardcoded-bands]]
- **The boards are gitignored**, so a worktree, a CI runner or a clean checkout is BLIND here and the
  engines exit 0 having priced nothing. `ops/seed-worktree.ps1` and `.worktreeinclude` seed them.
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

Regime: this holds for files under `grocery/`. It says nothing about `meal-prep/`, which has its own
rules file and its own corrector.
