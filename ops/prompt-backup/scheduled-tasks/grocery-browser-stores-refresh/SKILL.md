---
name: grocery-browser-stores-refresh
description: STAGE ONE of the daily grocery pipeline, 06:15 - Walmart, Sam's Club, Aldi and Fareway captured in Brad's own Chrome, one tab per store, all four concurrently, then built. The 08:00 driver covers Fareway/Sam's only on a day this did not land them; the 10:30 watchdog pages any browser store with no capture today. Brad's ruling 2026-09-19.
---

This file holds each rule's OPERATIVE text only (trimmed 2026-10-02, design\PLAN-browser-refresh-hardening-2026-10-02.md
W6). The dates, incidents and measurements behind a rule are in C:\Codex\ThriftyCrew\docs\rules-history\browser-refresh.md
at the anchor its tag names (`full: br-NN`), word for word. Read it only when a rule's reason matters to a decision.

## SHAPE (Brad's ruling 2026-09-19; full: br-01)
"All browser-needed stores should be using my Chrome... each store gets its own tab and it's running concurrently."
- You run at 06:15, before the 07:00 ad pull and the 08:00 chain; 08:00 builds the board from your captures. It drives
  Fareway or Sam's ONLY when you left no capture dated today with a data row. Walmart and Aldi have no fallback.
- ALL FOUR STORES ARE YOURS EVERY DAY: Walmart, Sam's Club, Aldi, Fareway. One tab per store, concurrently.
- You are the only thing in the estate that can drive Brad's real browser (full: br-02). Do the browser half, then stop.
- IF CHROME OR THE EXTENSION IS NOT CONNECTED: capture nothing and say so. Never launch an automated Chrome.

## SETUP, in this order (full: br-01)
1. `powershell -NoProfile -File C:\Codex\ThriftyCrew\grocery\chain-idle.ps1` (must print FREE).
2. `powershell -NoProfile -File C:\Codex\ThriftyCrew\grocery\capture-policy.ps1 -Emit` (today's worklists; on a FULL
   RECAPTURE day, which Brad asks for, add -Full). Check each worklist's `rescue_blind`/`rescue_why`: blind means its
   rescue list was missing or older than yesterday, so nothing was added. Rescue terms are already in `terms`.
3. Start the committed sink ONCE, as a BACKGROUND command, with an ABSOLUTE -OutDir and -MaxIdleMinutes 90:
   `powershell -NoProfile -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\capture-sink.ps1 -OutDir C:\Codex\ThriftyCrew\grocery\out\captures\_sink -MaxIdleMinutes 90`
   Never write or hand-roll another receiver. Probe the sink from the shell before a slow store posts.
4. CREATE THE TABS YOURSELF, before spawning: `tabs_context_mcp(createIfEmpty)`, keep that first tab as a KEEPER nobody
   uses or closes, then one `tabs_create_mcp` per store. You close all five tabs after the last agent reports.

## STORE AGENTS (full: br-01, br-04, br-08)
- Write each store's brief with the committed template, never by hand:
  `powershell -NoProfile -File C:\Codex\ThriftyCrew\grocery\fill-browser-brief.ps1 -Store <walmart|sams|aldi|fareway> -TabId <id> -Out <scratch file>`
  Pass the file's text as the agent's whole prompt, unedited. It carries the tab rule, the byte-for-byte inject wrapper
  that refuses a mis-pasted script, the store assertion, start, wait (`tcWait`), finish (which posts top-level through
  `tcPostToSink`, the only route to the sink) and the report shape. Do not add method prose to it.
- FAIL-SAFE: if fill-browser-brief.ps1 is missing or prints REFUSED, that store is not captured today; say why in the
  report. Never compose a brief from memory in its place. (Missing means the main checkout is stale.)
- Spawn the four agents in ONE message, model "sonnet" (Sonnet 5.5, Medium effort; Brad 2026-09-26 and 09-29). This
  session stays Opus: it decides what is due, reads builder refusals and writes the report.
- TRIAL BAR, written 2026-09-26 before any Sonnet run (full: br-01 for the Opus baselines). Over the first 5 Sonnet
  days, per store: zero builder refusals for store, mode or straddle, and for Fareway scope or climb (any one sends
  that store back to Opus); terms with rows / terms requested >= 90%, stated with both numbers; capture rows per term,
  5-day mean within 20% of the Opus baseline (a miss on that line alone is a reason to look, not to revert). Record each
  trial day as one row per store in grocery\out\logs\browser-refresh-model-trial.jsonl
  ({date, store, model, requested, with_rows, rows, unusable, builder_refused}).
- If a worklist predates rescue terms (no `rescue_terms` field), run a second start after the main sweep and before
  the post; for Fareway append its rescue terms to TERMS and COMMS before it starts (farewaySweep replaces its state).

## BUILD, one store at a time (full: br-01, br-05, br-08, br-09)
Re-run chain-idle.ps1 IMMEDIATELY BEFORE EACH BUILDER. HELD: wait a few minutes and re-check, up to about 20. If it is
still held, keep the captures (only out\captures and out\fareway) but SKIP the builders and say so; 08:00 builds them.
Confirm the sink's RECV line read chars=AGREE for the file first. Then, with the sink's file as -In:
- `build-walmart-deals.ps1 -In <file> -Date <date>`
- `build-sams-deals.ps1 -In <file> -Date <date>`
- `build-aldi-regular.ps1 -In <file> -Date <date>`
- `select-fareway-shop.ps1 -In <file> -Today <date>`, then `build-fareway-regular.ps1 -Today <date> -ModeVerified <date>`.
  -ModeVerified is legitimate only because the agent's identity check proved In-Store; without it compare-deals drops
  every Fareway cell.
The builders advance the capture cursor themselves, and only when the build produced rows: never advance it by hand. A
capture that priced nothing re-attempts the same slice tomorrow. A builder REFUSAL is the store's answer for today: report
it, never edit the capture to get it through.

## WHAT IS OUTSTANDING, FROM THE DATA, NOT FROM A FLAG (full: br-06)
- Hy-Vee, Baker's, Family Fare everyday prices are headless APIs: NEVER yours.
- BAKER'S WEEKLY AD LIST (one page load, no vision read). Due when no out\bakers\bakers-ad-list-*.json has
  ad_from <= today <= ad_to; ad-schedule.json's "current" window is NOT evidence. If due: open
  https://www.bakersplus.com/weeklyad in one tab, read the /api/dacs/<guid> request (performance.getEntriesByType
  ('resource')), run `pull-bakers-ad-list.ps1 -AdId <guid>`; exit 0 with "N offer(s) for 61500319" is landed. If the page
  names a store other than Saddlecreek (888 S Saddle Creek Rd, 61500319, pickup), switch it back in the page's picker.
- FAREWAY'S WEEKLY AD (a VISION READ of the flyer pull-fareway-ads.ps1 downloads). Due when no fareway-deals-*.json has
  ad_from >= the manifest's weekly.from AND ad_to >= its weekly.to, OR when the last read was partial: every
  fareway-deals file MUST carry "pages_read" and "pages_total", and the ad is due unless pages_read == pages_total ==
  the manifest's weekly.pages. READ THE WHOLE FLYER. Take the window from the ad's OWN PRINTED FOOTER, never the
  filename or the manifest. Exclude what the board cannot verify ("WHEN YOU BUY N" conditionals, BOGOs, basket offers);
  record a simple N/$X at its arithmetic unit price. Write out\fareway\fareway-deals-<today>.json, then advance Fareway
  current/next_pull in ad-schedule.json (hand-maintained). pull-fareway-ads.ps1 exit 3 is your work order, not a fault.
- RESCUE TERMS (out\rescue-terms-<store>.txt) are in the worklists already; they come before ordinary rotation.
- SALE FALLBACKS arrive in each store's worklist (Get-CapturePlan SaleFallbacks); out\research-worklist.json is retired.
- COMPREHENSIVE FULL PULL, Walmart or Sam's: due only when
  `powershell -NoProfile -File C:\Codex\ThriftyCrew\grocery\audit-walmart-fullpull.ps1` exits 1 (it names the store). Do
  not take it from a flag, this file or memory.
- PRODUCT-URL CHIPS (out\url-worklist.json): a BOUNDED batch of 20, Aldi and Fareway first, only with time left. Search
  the chip's exact `term`, confirm the price matches, write {id,url,price,size,name} to
  out\url-inputs\store-<store>N-urls.json. (No headless resolver met its bar on 2026-10-02: design\MEASURE-chip-
  resolvers-2026-10.md. If chips still do not move by 2026-10-16, say so in the report: it is Brad's call to drop them.)

## ORDER OF WORK, because the order decides what is lost (full: br-07)
1. Any weekly ad due today (Baker's list on its rollover; Fareway when missing OR partial). If you do nothing else, do this.
2. Rescue terms. 3. One comprehensive full pull when due AND no ad is due: about 45 minutes, so it REPLACES items 4-6
for the day; one store per day, Walmart before Sam's; NEVER on an ad-rollover day. 4. The everyday rotation (the four
stores' sweeps). 5. Sale fallbacks. 6. Product-URL chips, bounded. Spend at most ~45 minutes; stopping with 1-4 done
beats timing out inside 6.

## HARD RULES (full: br-03)
1. USE BRAD'S OWN BROWSER, NEVER A HEADLESS ONE. His signed-in session with the Omaha store and In-Store mode is what
   makes a price the right price.
2. A WALL IS THE ANSWER. A challenge page, error page or price-less shell is UNUSABLE for that store today: do not retry
   by hand (the committed sweep's paced backoff is the only retry) and run notify-desktop.ps1 so Brad knows the store
   is cold. Never solve a CAPTCHA.
3. BLINDNESS IS NOT EMPTINESS. A page you could not read is UNUSABLE, never EMPTY: EMPTY becomes a not-carried ruling
   that retires a real cell. Products shown but none extracted means the parser is wrong: capture nothing.
4. PROVE THE STORE AND THE MODE BEFORE YOU TRUST A PRICE (the templates assert both; see STORES).
5. NEVER FABRICATE. Skip anything you cannot verify. A missing cell is recoverable; a wrong price that looks right is not.

## BRAD'S REAL PROFILE (full: br-04)
- NEVER clear or read a site's own localStorage keys, and never trust a TC_* key you did not set this run: it is Brad's
  live session. The template's wrapper gives the scripts an in-memory store for exactly this.
- The capture leaves the page only through the sink: never through tool output (it truncates near 1 KB), never by
  fetch (connect-src), never through an iframe or a form `target` (failed 8 of 8 on 2026-10-02). The post is
  top-level and LAST, and the tab navigates to the sink's reply.
- Every capture is posted UNALTERED, and a rescue comes from the same committed sweep, line and all. Never
  hand-assemble, merge or strip a capture file, never prepend anything above a #tc-store line and never strip one: the
  builders REFUSE a capture that cannot name its store.

## STORES: the identity rules (full: br-08; the method is in grocery\browser-briefs\)
- WALMART: storeId 5361, Omaha L St Supercenter 68137 (Brad 2026-08-28). The id is the discriminator: 3153 is an Omaha
  address too. If the agent refuses the store, SWITCH THE STORE in Brad's Chrome (yours to do) and re-run; do not
  re-escalate the ruling. Ruling-owed terms lead the worklist as `ruling_terms`: never hand-pick them and NEVER edit a
  ruling file to mark something done.
- SAM'S CLUB: club #8146, 13130 L St 68137 (Brad 2026-10-02). Every search response's pickup club must be 8146; a term
  read elsewhere is UNUSABLE (wrong-club). If it happens, switch the club in Brad's Chrome and re-run.
- ALDI: In-Store mode and a store line ending in Omaha, asserted per term. NEVER assert the OLA number.
- FAREWAY: retailerLocation 531573 AND In-Store (Pickup at the right store is still wrong). If farewaySweep is
  missing after the inject, capture NOTHING for Fareway, never hand-roll a router loop, and report "Fareway: main
  checkout stale"; the 08:00 driver covers it.

## WHAT YOU DO NOT DO (full: br-09)
DO NOT PUBLISH. No compare-deals, no check-ad-cycles, no publish-deals-page, and no push of anything but the one file
below and the review's committed groups (DAILY END-TO-END REVIEW), each through push-main and the full gate. The 08:00
task owns the downstream chain. If something is urgent enough to publish today, say so and let Brad decide.

LANDING THIS FILE'S OWN BACKUP (Brad's ruling 2026-10-02, PLAN W7). Only on a day you EDITED this file, and as your last
step, land the repo mirror and nothing else, from a throwaway worktree so no board file or unpushed commit rides along:
1. `git -C C:\Codex\ThriftyCrew fetch origin`, then
   `git -C C:\Codex\ThriftyCrew worktree add -b tc/skill-backup-<date> C:\Codex\ThriftyCrew\.claude\worktrees\skill-backup-<date> origin/main`
2. Copy this file byte for byte (Copy-Item, never Get-Content/Set-Content) to
   `<worktree>\ops\prompt-backup\scheduled-tasks\grocery-browser-stores-refresh\SKILL.md`.
3. Write the message to a file (with [IO.File]::WriteAllText and UTF-8 without BOM) ending in
   `Store: searched "prompt backup mirror", nothing applicable` and commit with
   `git -C <worktree> commit -F <msgfile> -- ops/prompt-backup/scheduled-tasks/grocery-browser-stores-refresh/SKILL.md`;
   check `git -C <worktree> show --stat HEAD` names that one file.
4. From the worktree: `powershell -NoProfile -File ops\push-main.ps1` (about 8 minutes). LANDED: remove the worktree.
   REFUSED: leave it, and put push-main's last line in the report; audit-prompt-backup -Daily pages after 24 hours.

## DAILY END-TO-END REVIEW (Brad's ruling 2026-10-02: "Everything, gated")
Every day, after BUILD and the ORDER OF WORK, as the last work before the report. Captures and builds come first: a
usage limit or a short morning may cost the review, never the data. It answers Brad's question about every run: "With
this browser run, are there areas to address? Either issues, inefficiences etc?"
1. Write the run record to `%LOCALAPPDATA%\ThriftyCrew\browser-refresh\run-<date>.md` in the shape the RUN RECORD
   section of `.claude\agents\browser-refresh-reviewer.md` gives. Every deviation goes in, your own included: a brief
   you wrote wrong is a finding (2026-10-02's failed iframe posts were the orchestrator's brief, not an agent's).
2. Spawn `browser-refresh-reviewer` (subagent_type; pinned to Opus 5.5, Medium) with the date, the record's path and a
   `## Knowledge consulted` section, and wait. It writes `plan-<date>.md` (items) or `review-<date>.md` (clean) there.
3. No build items: say so in the report; the review is done. Otherwise spawn one `browser-refresh-implementer`
   (subagent_type; pinned to Sonnet 5.5, Medium) per plan GROUP, with `isolation: "worktree"`, naming the plan path, the
   group, its item ids, a run ceiling of 120 tool calls, and a `## Knowledge consulted` section pasted from the plan's.
   Groups that share no file may run together. A report with open items and no blocker named goes back to the same
   agent up to twice ("Your list still has X and Y open. Continue. If one is blocked, say what blocks it."), then it is
   reported stuck. The implementer commits and stops: it never pushes.
4. YOU land each committed group, one at a time, from its worktree:
   `powershell -NoProfile -ExecutionPolicy Bypass -File ops\push-main.ps1`, run in the background. A group the plan
   marks chain-touching lands only once `grocery\out\logs\capture-run-status.json` shows `daily.date` = today with a
   non-null `daily.exit_code` AND chain-idle prints FREE; wait for that. A red gate goes back to that group's
   implementer with push-main's failing lines (fix the cause, never the gate), at most twice. Still unlanded at the
   end: say so and leave the branch; never put it on main.
5. A group that changed this file's mirror: once it has LANDED, copy the landed mirror over this live file byte for
   byte. That landing carries the backup, so the own-backup steps above are not needed for that edit.
6. If either agent type is missing from this session (the main checkout predates 925b14506), skip the review and say
   so. Never stand in for it with a general-purpose agent or by hand.

## WHEN SOMETHING ELSE GOES WRONG (full: br-10)
- If a browser tool is refused by a SAFETY CHECK rather than a store ("auto mode", "could not evaluate", earlier
  conversation content): do not rephrase, switch tools or route around it. Do the items that need no browser (the
  Fareway ad vision read from local JPEGs, sale-fallback research on out\regular), report the refusal plainly, and say
  a fresh session is what clears it. Keep names accurate and boring.

## REPORT (full: br-11)
Which stores you captured and the priced rows each built; what you deliberately did not reach and why; any store that
came back UNUSABLE (and confirm you notified); any commodity you skipped as unverifiable; builder refusals verbatim; the
trial rows written; the outstanding counts on the url-worklist and rescue lists; if you edited this file, the
backup's push-main result; and the review: its verdict by class, each group's landed hash or why it did not land, and
any decision for Brad in plain words.
