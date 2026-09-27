> **Resolving the `[[citations]]` below.** Each is a filename without its extension, under
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/`. So `[[propagate-has-no-slugs]]` is
> `~/.claude/projects/C--Codex-ThriftyCrew/memory/propagate-has-no-slugs.md`. The line here is a
> pointer; the file is the account. Read it before acting on the pointer, and never write to that
> directory - it is outside the repo and outside your worktree.


# Working in `grocery/`

Loaded in every ThriftyCrew session: this file has no `paths:` key, on purpose
(design/PLAN-brain-consults-on-code-and-analysis-2026-09-22.md, W2.3). These are the traps that have
actually cost this estate a day.

**HOW THIS FILE IS WRITTEN** (design/PLAN-rules-trim-2026-09-25.md). Each rule holds its OPERATIVE text only. The
measurements, dates, incidents and Brad's verbatim rulings behind a rule live in `docs/rules-history/grocery.md` at
the anchor its tag names (`full: gr-NN`), word for word. Every rule ends with `gate <path>` when a push gate enforces
it, or `judgement` when only this text carries it. `ops/audit-rule-format.ps1` refuses a push that breaks the shape.

- **A BAD CELL QUARANTINES ITSELF; A BAD STORE DROPS ITSELF; ONLY A BOARD-SCOPED FAILURE OR THE CIRCUIT BREAKER HOLDS
  THE BOARD** (Brad; a held cell shows its last verified published price and date). `guards.ps1`
  sorts each hard failure into CELL, STORE or BOARD scope; an unscoped failure is BOARD scope and holds. Under the
  breaker (over 2% of priced cells, or 10% of one store's) guards exits 2 `GUARDS QUARANTINE-REQUIRED`,
  `apply-cell-quarantine.ps1` holds or WITHHOLDS each named cell against `public/board.json` at origin/main, and guards
  must then exit 4 `GUARDS QUARANTINED`: neither clean nor held, so the served paths ship and it pages once as
  `grocery board cells quarantined`, never `GUARDS FAILED`. WITHHELD instead of held: no prior value, a prior sale,
  older than the publish window, or the value a VALUE guard condemned. Delegated audits scope via `QUARANTINE-CELL`
  and `QUARANTINE-SCOPE complete` lines. **Teaching a guard to scope is a per-guard change with its own fixture, never
  a default.** (channel: gate grocery/test-cell-quarantine.ps1; full: gr-01)
- **"NOW" IS NEVER `week_of`.** `week_of` and the board's file-name date name the AD SET; ages run from per-cell
  `as_of`, or `judged_on`, to the real date (`lib/board-clock.ps1`), never `built_at`.
  [[the-board-has-three-dates]] (channel: gate ops/audit-board-clock.ps1; full: gr-02)
- **`known-wrong.json` is the MAIN-board corrector, and `comparison-*.json` is rebuilt daily.** A fresh ruling reads
  red until the next build, on purpose. [[known-wrong-is-the-main-board-corrector]] (channel: judgement; full: gr-03)
- **`compare-deals.ps1` is not standalone.** A mid-day rebuild needs identity emission AND link repair; never
  revert-to-isolate. Many scripts lift its functions: never quote a count, run
  `powershell -NoProfile -File ops\count-source-lifters.ps1 -Script <script>` and say which test (NAMES, READS,
  EXECUTES) you mean. Pricing math is `pricing-math-lib.ps1`, the exclude list `Get-TcGlobalExclude` in
  `global-exclude-lib.ps1`; a lifted `$script:` constant does not travel, so export a function.
  [[compare-deals-is-not-standalone]], [[compare-deals-functions-are-lifted-by-many-scripts]]
  (channel: gate ops/audit-lift-completeness.ps1; full: gr-04)
- **A wrong product is a SELLER SHAPE, not a brand.** Blocking the brand hands the cell to the next bulk seller.
  [[wrong-product-class-is-a-seller-shape]] (channel: judgement; full: gr-05)
- **One bad Walmart pull holds a ship-only cell for 90 days** once Marketplace rows enter the union.
  [[walmart-marketplace-rows-pollute-the-union]] (channel: judgement; full: gr-06)
- **A CAPTURE THAT CANNOT NAME ITS STORE IS REFUSED.** Walmart, Aldi and Sam's captures open with a `#tc-store` line;
  Fareway rows carry a per-row `loc` stamp. **Post the emitter's output UNALTERED and never strip the stamp.** The
  builders refuse no stamp, `UNRECORDED`, two stores, and (Walmart and Fareway, pinned in `stores.json` ->
  `store_identity`) any other store. `pull-walmart-instore.js` re-reads the store from EVERY `/search` response,
  because a session flips mid-sweep: keep that. **The id is the discriminator, never the word "Omaha".** Aldi and Sam's are not
  pinned; Hy-Vee, Family Fare and Baker's need no line (store is a request parameter).
  [[walmart-session-store-3153-drift]], [[aldi-store-is-ola-42]] (channel: judgement; full: gr-07)
- **AN ALDI MULTIPACK CARD IS EITHER ONE UNIT OR THE PACK TOTAL, AND THE ROW USUALLY CANNOT SAY WHICH.**
  `build-aldi-regular`'s `Resolve-PackBasis` resolves the basis by arithmetic proof only (the name's size is N times
  the card, or the card N times the name's); a name size EQUAL to the card proves nothing and is refused. **Do not add
  a plausibility bar.** Rule 4 has the same ambiguity and is NOT fixed. `design/MEASURE-aldi-pack-basis-2026-09-19.md`.
  (channel: judgement; full: gr-08)
- **A STANDING RULING'S OWED TERMS ARE DERIVED AND LEAD THE WORKLIST**, never hand-picked or hand-discharged:
  `Get-WalmartRulingOwed` (`capture-policy-lib.ps1`) derives them and `Get-CaptureWorklist` puts them first as
  `ruling_terms`, out of the sale-expiry allowance. **Do not edit a ruling file to mark a term done**; a file built
  under `-WaiveMissingStoreLine` discharges nothing. (channel: judgement; full: gr-09)
- **No hard-coded bands** (Brad). [[no-hardcoded-bands]] (channel: judgement; full: gr-10)
- **EVERY PRICE IS FETCHED FROM AN OMAHA STORE'S AD OR WEBSITE BY THE PIPELINE, never typed or agent-captured**
  (Brad's standing ruling; full rule in `.claude/rules/meal-prep.md`). `pull-regular-hyvee.ps1` asks first for rows
  withheld only for its store (`Get-HyVeeUncoveredIds`) and builds its lookup from `$script:HvRequest*` by name, never
  a bare dynamically-scoped `$StoreId`. (channel: judgement; full: gr-11)
- **AN EVERYDAY PRICE IS RE-READ ABOUT ONCE EVERY 90 DAYS, AT EVERY STORE** (Brad's standing rule). Rotation and
  publish limit are both the quarter (`capture-policy-lib.ps1`); sale prices follow their ad windows. Never shorten
  them. [[graph-time-gates-decision]] (channel: gate grocery/test-capture-policy.ps1; full: gr-12)
- **A script you edit that holds its own copy of the store list reads `stores.json` instead, in the same change**
  (Brad: convert on touch, no sweep). (channel: gate grocery/audit-store-registry.ps1; full: gr-13)
- **The boards are gitignored**, so a worktree, CI runner or clean checkout is BLIND here and the engines exit 0
  having priced nothing. `ops/seed-worktree.ps1` and `.worktreeinclude` seed them; a re-seed refreshes a copied file
  whose source was rewritten, and `ops\push-main.ps1` re-seeds before every gate. A file deleted from the source is
  not removed. (channel: judgement; full: gr-14)
- **A check that compares a derived file with a board reads that file by the BOARD'S road** (a gitignored stamp
  `.worktreeinclude` carries, not a tracked report). With NO record on that road the answer is a counted SKIP, never a
  FAIL. **Do not repair a lag by untracking a file the bot rewrites daily.**
  `design/PLAN-capture-eviction-stamp-2026-09-11.md`. (channel: judgement; full: gr-15)
- **`cohort` here means the PEER GROUP OF PRODUCTS holding a commodity's board cells**, never members or recipes.
  **Member work, if it lands, is written `member cohort` IN FULL, every time.** A cohort that cannot be formed (fewer
  than 2 other priced cells) is BLIND, never passed (`build-arrivals-docket.ps1`). (channel: judgement; full: gr-16)
- **A 200 with a correct selector and ZERO ROWS has FOUR causes**: `blocked`, `not-carried` (UNCHECKED IS NEVER
  NOT-CARRIED), `unrendered` (JavaScript nothing executed: render it or find the JSON call, not a selector fix) and
  `unsettled` (still loading: a PARTIAL result that looks like success). **Never sleep and hope: WAIT ON A COUNT-BASED
  SELECTOR** (`div.row:nth-child(11)` after a scroll from 10), so a failed load fails loudly. Prefer the page's own
  Fetch/XHR JSON call. [[a-could-not-look-must-not-settle-the-question]], [[fareway-capture-defects]]
  (channel: judgement; full: gr-17)
- **A DEEP DISCOUNT IS EVIDENCE ABOUT A CELL'S FUTURE**: a temporary promotion and a permanent exit are
  indistinguishable in one capture. It must NOT raise confidence that a store carries an item. Nothing automated is
  proposed. (channel: judgement; full: gr-18)

Regime: this holds for files under `grocery/`. It says nothing about `meal-prep/`, which has its own
rules file and its own corrector.
