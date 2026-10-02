# Browser refresh: hardening and cost (2026-10-02)

Brad, 2026-10-02, after the 06:15 browser-stores refresh: "With this browser run, are there areas to address? Either
issues, inefficiencies etc?" and then "create a holistic plan that addresses all the items above. I'll do a new session
for the actual implementation."

This plan is for that implementation session. Every number below was measured on 2026-10-02 from that run's files,
unless it says otherwise. The implementer re-measures before changing anything (the estate moves daily).

## Knowledge consulted

- `skills/growth-craft/applies-here.md` section 7, "Price is a store-CLUSTER fact": *"Treat the store identity as part
  of the price observation, not as capture metadata."* Drives W1 (Sam's club pin).
- `skills/mcp-craft/intelligence-budget.md` section 6, "Scripted orchestration": move mechanical work below the model
  boundary so intermediate data never enters context (the course's figure: about 500,000 tokens against 500). Drives
  W3 and W4 (fewer agent turns, scripts do the polling and posting).
- `skills/software-craft/applies-here.md` section 63: a new plan names at least one alternative it rejected and why.
  Each work item below carries a "Rejected" line.
- `.claude/rules/grocery.md` gr-07 (a capture that cannot name its store is refused; the id is the discriminator, never
  the word "Omaha"), gr-11 (every price fetched by the pipeline), gr-17 (UNCHECKED IS NEVER NOT-CARRIED).
- `.claude/rules/ops-and-gates.md` og-05 (MUST FIRE / MUST NOT FIRE / CLEAN TWIN), og-39 (tracked files written LF),
  og-47/og-48 (land through `ops\push-main.ps1`; a lane writes only what it owns).
- `.claude/rules/measurement.md` ms-01 (denominators), ms-03 (bar before the run).
- `grocery\build-sams-deals.ps1` lines 757-775: *"THE CLUB IS NEVER PINNED. There are two Omaha clubs and no ruling
  names one."* That is why W1 needs Brad first.
- `stores.json` Walmart `store_identity` (store 5361, the pattern W1 copies) and `ops\audit-prompt-backup.ps1`'s header
  (its `-Daily` mode already pages on mirror drift older than 24 hours; W7 builds on it).

## What happened on 2026-10-02 (the evidence)

| store | terms with rows | raw rows | built | agent tokens | agent tool calls |
|---|---|---|---|---|---|
| Walmart | 16 of 16 | 789 | 408 priced, 266 after de-dupe | 165,206 | 38 |
| Sam's Club | 11 of 11 | 289 | 239 priced, 210 after de-dupe | 143,900 | 23 |
| Aldi | 29 of 29 | 1,840 | 1,077 priced | 171,468 | 34 |
| Fareway | 27 of 27 | 1,782 candidates | 24 of 27 commodities selected | 133,452 | 28 |
| **total** | **83 of 83** | | | **614,026** | **123** |

The sweeps themselves ran 1 to 9 minutes each. Nearly all of the agents' cost was the pasted scripts (about 50 KB per
agent) being read in, written out again into the page, and then re-billed as context on every later turn.

All four agents' posts to the sink failed (8 attempts): the orchestrator's brief told them to target a hidden iframe and
"not navigate the tab". walmart.com's `frame-src` blocks localhost; Aldi, Sam's and Fareway failed silently. The
orchestrator re-posted each one as a top-level submit, and all four arrived AGREE on the first try. That wording is
already fixed in the live task file (the "AND NEVER TARGET AN IFRAME EITHER" paragraph). W4 removes the class.

## The work items, in order

Ordered by risk of a wrong number on the board first, then cost per run, then upkeep. W1 waits on a ruling; everything
else can start at once. One branch per item, named `browser-refresh/w<N>-<slug>`, landed through `ops\push-main.ps1`.

### W1. Pin Sam's Club to one club, by id (accuracy) - RULED 2026-10-02: 13130 L St, 68137

**The problem.** Today's capture says `#tc-store store="Omaha Sam's Club"`. `samsIdentity()` in
`grocery\pull-sams-instore.js` (line 56) reads the club from page TEXT, falling back to any line containing "Omaha", and
`build-sams-deals.ps1` accepts any store that contains the word Omaha (line 813). Omaha has two clubs (13130 L St 68137
and 15429 Blackwell Dr 68116), and the session has been seen at Blackwell (2026-09-18) while the files claimed L St.
This is exactly the Walmart 3153 failure that gr-07 closed for Walmart: a word test passes the wrong store.

**The fix, after the ruling.**
1. Read the club's id from the search response itself (`__NEXT_DATA__` on `/s/<term>`), on EVERY response, the way
   `walmartProbe` re-reads storeId. First find where the club id lives in that payload (one search in Brad's Chrome,
   read the JSON, record the path in the file's header). A term whose response names another club settles UNUSABLE.
2. Add `store_identity` to Sam's in `stores.json` (club id, postal code, label, `ruled` with Brad's words), mirror it in
   `pull-sams-instore.js` as a constant, and extend the existing mirror-check self-test pattern
   (`build-walmart-deals.ps1`'s self-test fails when mirror and registry disagree).
3. `samsSweepToCsv` writes `id="<club id>"` on the `#tc-store` line; `build-sams-deals.ps1` refuses a missing id, an
   UNRECORDED one, any other id, or two ids.
4. Fixtures (og-05): MUST FIRE a capture read at the other club; MUST FIRE a line with no id; MUST NOT FIRE the pinned
   club; CLEAN TWIN `-WaiveMissingStoreLine` still rebuilds an old pre-line capture exactly as today.

**Rejected:** keep recording the club without pinning it (today's design). It is honest, but a price read at the wrong
club still reaches the board, and a word test cannot tell the clubs apart.

**Done when:** a self-test run shows the new cases pass, and one real morning's capture builds with the pinned id on its
store line.

### W2. Walmart in-store rows Walmart prints no unit price for (accuracy and coverage, measure first)

**Corrected framing.** The run report said "Walmart throws away 43%". Re-measured: 343 of 789 rows had no unit price, but
322 of those 343 are third-party marketplace listings (270 MARKETPLACE, 53 ship-only FC), which gr-11 already keeps off
the board. The rejects are mostly correct. **Only 19 rows were in-store at 5361 with no unit price**, and several are
plainly priceable from the size in their own name: Gold Medal All Purpose Flour 5 lb at $3.97, Pine-Sol 60 fl oz at
$8.98, Old El Paso jalapeno slices 12 oz at $2.63, La Costena jalapenos 28 oz, Northland cranberry juice 64 fl oz, Del
Monte cut green beans 14.5 oz. Others cannot be (rotisserie chicken meals sold each).

**Step 1, measure (no code change).** Over the last 14 days of `out\captures\walmart-capture-*.csv`, count in-store
(`pk=5361`) rows with a line price and no unit price, and for each, whether a size parses unambiguously from the name
(single unit, no "pack of", no "N ct" multiplier). Then count how many of those would have been the cheapest row for
their commodity on that day's board. Write the bar before the run, in the run's units: **build W2 step 2 only if at least
5 distinct board cells over the 14 days would have changed winner.** Record one row per case
(ms-04) in `design\MEASURE-walmart-missing-unitprice-2026-10.md` with the harness committed.

**Step 2, only if the bar is met.** In `build-walmart-deals.ps1`, an in-store row with no Walmart unit price may derive
one from its line price and a size parsed from its own name, by arithmetic only, stamped `qty_basis 'name size'` so it
is visible and auditable (the Sam's builder already carries sizes this way: `qty_basis 'package; qty carried'`). A
name with two sizes, a pack count, or a size that contradicts the tile is refused, never guessed. Marketplace and
ship-only rows stay rejected whatever they print. This changes a pricing rule, so it needs Brad's OK before landing
(gr-11 says every price is fetched; the line price and the name both are, but the unit price would be ours).

**Rejected:** sweeping fewer marketplace rows at capture time. The marketplace rows cost no extra requests (one search
per term returns them all) and `build-walmart-deals` uses them for the ship-only signal.

### W3. Stop paying the model to retype 50 KB of script per store (cost; measure, then choose)

**The problem.** 614,026 agent tokens for about 20 minutes of sweeping. The scripts are pasted by the model, which is
slow (output tokens), costly, and fragile: the Aldi agent's first paste carried a one-word typo, caught only by the
length check.

**Step 1, measure what each store's page will load (30 minutes, Brad's Chrome, one tab).** For each of walmart.com,
aldi.us, samsclub.com and shop.fareway.com, read the page's Content-Security-Policy (response header and any meta tag)
and record whether `script-src` admits `http://localhost:8791`. Also try, in one tab per store, whether a `<script
src="http://localhost:8791/...">` element added from `javascript_tool` loads. Record per store: loads / blocked and by
which directive. Bar written now: the loader route (step 2a) is worth building for any store where it loads.

**Step 2a, where a localhost script loads.** Extend `capture-sink.ps1` to also SERVE the committed scripts read-only
(GET of an allow-listed name returns that file's bytes from the checkout, nothing else), and inject with a one-line
`<script src>`. The model never sees the script text. Verify by hashing what the page received against the file
(`__tcInject` length check stays). Then the orchestrator can drive those tabs itself, without an agent.

**Step 2b, where it is blocked (Walmart likely is).** Cut the turns instead of the paste: W4's committed runner makes
each agent about 6 calls (inject, assert and start in one call, two or three polls that each wait up to 40 seconds
inside the page, one finish call that builds and posts). Context re-billing scales with turns, so 30-plus calls down to
about 6 is most of the saving even with the paste kept.

**Done when:** one real morning run with the new route, per-store agent tokens recorded beside today's table. Bar
written now: total agent tokens at or below 300,000 for the same four stores (today 614,026), with zero builder
refusals and coverage at or above 90% per store.

**Rejected:** (a) a comment-stripped bundle to shrink the paste: Brad ruled on 2026-09-30 that the reviewed file is
injected byte-for-byte, and a generated bundle needs its own ruling for a smaller saving than either route above.
(b) The orchestrator pasting all four scripts itself: it saves agent overhead but puts about 200 KB into the Opus
context for the rest of the run, which costs more per token.

### W4. Committed post helper and per-store brief templates (removes the class of today's failure)

1. Add `tcPostToSink(name, text)` to `grocery\pull-agent-lib.js`: builds the form on the tab's own document, no target,
   `enctype text/plain`, `?chars=text.length`, submits in `setTimeout(...,0)`. One tested way to post, used by every
   store. Its header records why there is no iframe (today's 8 failed attempts) and that the tab navigates, so it is
   the last call.
2. Add per-store finish functions next to each emitter, for example `walmartFinish()` = build the CSV, return its length
   and first line, then post via `tcPostToSink`. Fareway: `farewayFinish()` around `farewaySweepJsonl()`.
3. Add committed brief templates under `grocery\browser-briefs\<store>.md` (Walmart, Aldi, Sam's, Fareway). The
   orchestrator fills in only the date, the tabId, TERMS and COMMS from the worklist, and pastes the template. The
   templates carry the inject wrapper, the expected lengths (read from the files at fill time, never typed), the store
   assertion, the start, poll and finish calls, and the report shape.
4. The task file then says "use the templates" in place of the long per-store method text (feeds W6).

**Rejected:** fixing only the wording in the task file (already done today). Wording is re-read and re-composed by
the orchestrator every run; a committed function cannot be re-composed wrong.

**Done when:** one real run where all four agents' own posts land AGREE without orchestrator help.

### W5. Fareway terms that match nothing: record them (small)

**Corrected framing.** The run report said Fareway "searches the same dead terms every day". Wrong: 2026-10-01's
no-matches were fresh dill and fresh sage; today's were fresh stir-fry blend, sweet Italian turkey sausage and whole
nutmeg. Different terms each day, each asked about once a quarter by the rotation, so the cost is small. Today's look
like real absences (whole nutmeg returned ground nutmeg and whole cloves; stir-fry returned bean sprouts and baby corn).

**The fix.** `select-fareway-shop.ps1` prints its no-match ids but does not write them to `fareway-shop-<date>.json`.
Write them (`no_match: [{id, term, candidates}]`) so they are on disk. Do NOT turn them into not-carried rulings here:
gr-17, a no-match is evidence for a later reader with its own rules, never a ruling.

**Rejected:** auto-marking not-carried. A selector's include list missing a real product would retire a real cell.

### W6. Trim the task file to its operative text (upkeep)

The live task file (`C:\Users\Owner\.claude\scheduled-tasks\grocery-browser-stores-refresh\SKILL.md`) is 499 lines,
44,991 characters, read in full by Opus every morning. It still carries retired instructions that contradict "THE
SHAPE" at its top: the per-store section calls Baker's a flyer vision read (ended 2026-09-18); "SAM'S CLUB (everyday,
only if 0800 failed)" (retired 2026-09-19); "STEP ZERO" written for a 09:00 run.

Follow the pattern of `design/PLAN-rules-trim-2026-09-25.md`: keep each rule's operative text; move dates, incidents
and measurements to a history file in the repo (`docs/rules-history/browser-refresh.md`), word for word, with an anchor
per rule. Delete what is retired outright. After W4, the per-store method collapses to "use the template" plus the
store's identity rule. Bar: under 200 lines with nothing operative lost; check by listing every MUST/NEVER/REFUSE line
before and after and accounting for each one.

**Rejected:** leaving it and relying on "THE SHAPE overrides". A Sonnet-run future, or a tired orchestrator, follows
the wrong paragraph; the cost is every morning's read.

### W7. Land the task file's own backup (upkeep) - RULED 2026-10-02: yes

The repo mirror (`ops/prompt-backup/scheduled-tasks/grocery-browser-stores-refresh/SKILL.md`) was already behind and
uncommitted before today, and the task's own rule "DO NOT ... push" means it can never land an edit to itself.
`audit-prompt-backup.ps1 -Daily` already pages after 24 hours of drift, so the gap is an owner, not a detector.

**Proposal.** When a run edits the task file, it ends by landing ONLY the mirror: a throwaway worktree off
origin/main, copy the live file in, commit with a pathspec, land through `ops\push-main.ps1`. It touches no board file,
so it cannot race the 08:00 chain, and from a fresh worktree it carries no one else's unpushed commits. Cost: one gated
push (about 8 minutes) on the days the file changed, which is a few a week.

**Rejected:** (a) leave it to the -Daily page (today's state: it works, but every edit waits a day and needs a human);
(b) a new sync script (new machinery; push-main already does the landing).

### W8. Product-link chips: move them off the browser task (backlog)

`out\url-worklist.json` (generated 2026-10-01) holds 157 chips: Family Fare 65, Hy-Vee 41, Aldi 28, Fareway 23. The task
puts them last, so they never move. Two of the four stores have server feeds and need no browser, and resolvers exist:
`grocery\resolve-familyfare-urls.ps1` (called only from hand fix scripts) and `grocery\resolve-chips-hyvee.ps1` (**no
production caller at all**; only `audit-script-census` names it).

1. Run both resolvers against today's chips in a scratch clone (rule: board steps never run in the landing checkout).
   Record resolved / unresolved per store. Bar: wire a resolver into the daily chain only if it resolves at least half
   its store's chips with zero wrong links on a 10-chip hand check.
2. Wire the ones that pass into the 08:00 chain after the board build, bounded.
3. Leave Aldi and Fareway chips to the browser task, bounded at 20 a day, only on days with time left; or, if they still
   do not move in two weeks, ask Brad whether to drop them.

**Rejected:** a bigger browser batch. The browser session is the scarcest resource in the estate; headless work does
not belong in it.

### W9. Small items

- **Sink favicon noise.** Each top-level post makes Chrome request `/favicon.ico`, and the sink writes
  `favicon.ico.txt` (4 today). Make `capture-sink.ps1` answer 404 to `favicon.ico` and write nothing. Fixture: MUST NOT
  FIRE a write for favicon; CLEAN TWIN a real name still writes.
- **Trial-log rows are hand-written by the orchestrator.** Leave it: the Sonnet trial ends after 5 days (2 recorded so
  far), so a generator would not pay for itself (Brad, 2026-09-27: new machinery must pay for itself). Revisit only if
  the trial is extended.

## Decisions for Brad (before the session starts)

1. **Which Sam's Club is the board's club?** Omaha has two, and Sam's prices are per club. Right now the capture just
   says "Omaha", so a price from the wrong club looks normal. Recommendation: **13130 L St (68137)**, the club the
   stores registry already prefers and the same neighborhood as the Walmart basis; the session would be switched there
   in your Chrome when it drifts, as Walmart is. W1 cannot start without this.
2. **May the morning task push one file, its own backup, on days it edits itself?** It would push from a clean side
   copy, never the board. Recommendation: **yes** (W7).

**RULED 2026-10-02 (Brad, implementation session, answering the two questions above):** decision 1, *"13130 L St
(Recommended)"*: the board's Sam's Club is 13130 L St, Omaha 68137. Decision 2, *"Yes (Recommended)"*: the morning task
lands its own backup, and only that file, on days it edits itself. W1 and W7 are unblocked.

3. **(Later, only if W2's measurement passes its bar.)** May Walmart's in-store price per unit be worked out from the
   price and the size in the product's own name, when Walmart prints none? Recommendation: decide after the numbers.

## Sequencing for the implementation session

1. W1 (if ruled), W4, W9 favicon: independent, small, start together.
2. W3 step 1 (CSP measurement) needs Brad's Chrome; do it in the same session as a W4 trial run.
3. W3 step 2 after W4 lands (the runner is shared).
4. W2 step 1 and W8 step 1 are measurements in scratch clones; any time.
5. W6 last, once W4 has changed what the task file needs to say. W7 with or after W6.

## What this does not change

No gate is weakened. Every builder keeps its refusals; W1 and W2 add refusals, never remove one. The store sweeps keep
their committed pacing. Nothing here publishes; the 08:00 chain still owns the board.

## Open items at the time of writing

- The repo mirror of the task file was synced to the live file on 2026-10-02 and landed with this plan, from a
  follow-up interactive session. W7 is about the morning task landing its own future edits.
- W2 and W3 bars are written above; neither has been run.
