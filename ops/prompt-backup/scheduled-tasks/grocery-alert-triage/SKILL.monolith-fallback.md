---
name: grocery-alert-triage
description: Daily 6:30am drain of the grocery ops-alert triage queue (plus catch-up on app launch): investigate every alert, fix it, fix the root cause, mark resolved. IDLE-stops in seconds when clear. Runs right after the 6am Baker's scan + pipeline generate the morning's flags.
---

Triage agent for the Thrifty Crew Omaha grocery pipeline (C:\Codex\income\grocery). Brad's standing rule (2026-07-25): an issue email must NEVER wait for a human. The email is visibility; THIS agent is the response. Born from the 07-25 session where 8 wrong cells (sushi as cucumbers, cinnamon ROLLS as the spice, $0.0023/oz grits from a dropped decimal, a per-unit price shipped as an item price) sat live for days because sanity flags emailed and then waited.

STEP 0 - GUARD: run  powershell -ExecutionPolicy Bypass -File C:\Codex\income\grocery\triage-due.ps1
IDLE means report one line and STOP. DUE means proceed. Items with status 'needs-brad' are PARKED - never re-triage them.

STEP 0.5 - SYNC: powershell -Command "git -C C:\Codex\income pull --rebase --autostash origin main"

STEP 1 - INVESTIGATE each open item in triage-queue.json. The 'body' field carries the alert's detail; ad-cycle-log.txt and the out\ audit jsons carry the rest. Recipes by alert type:
- "price(s) to review" (sanity/multibuy flags): for EVERY flagged extreme, pull the winning row from the newest comparison json and READ ITS ITEM NAME. Classify: (a) real bulk/promo economics (Sam's big packs legitimately run 40-70% under small-pack runner-ups) - note it, change nothing; (b) WRONG PRODUCT (sushi on cucumbers, a dessert on a spice) - add a tight exclusion to commodities.json; (c) parse/basis bug (a 46x size, a per-unit price as an item price) - fix the DATA row AND the builder/regex that produced it, with a self-test case. Never dismiss a flag without classifying it.
- "GUARDS FAILED / board not published": read the HARD FAIL lines in ad-cycle-log.txt. Fix the data or the code, NEVER weaken a guard to make it pass. Guards must reach rc=0 before any publish.
- "store(s) dropped from a commodity": run audit-cell-drops.ps1 + check carry-forward; classify each drop (policy-expired / capture gap / matching change) and recover what the 14-day policy allows.
- "link price drift / consistency": the daily self-heal owns API stores; browser-store link gaps (Hy-Vee adds, Aldi, Walmart, Sam's) WAIT for the Wednesday browser agent - mark resolved-with-reason, do not fight them headlessly.
- "pipeline did not refresh / publish FAILED / pull failed": diagnose local-daily-log.txt + ad-cycle-log.txt, re-run the failed stage manually, verify the feed date advanced.
- Anything else: investigate from the body text; the alert's wording names its source script.

STEP 2 - ROOT CAUSE, not just symptom: every class-(b) and class-(c) finding gets a source-level fix (exclusion, regex, builder, guard) so the same failure cannot recur; if the fix reveals a NEW failure class, add a guard or audit for it. Rule changes to commodities.json WILL trip the match-soundness gate on publish: review its moved/dropped report line by line, and only then run audit-match-soundness.ps1 -Accept. Intended drops only; an unexplained move means STOP and park the item as needs-brad.

STEP 3 - SHIP after any change, full gated chain: compare-deals.ps1 -MinStores 1 with the newest bakers-deals and fareway-deals files pinned via -BakersFile/-FarewayFile, then audit-name-drift.ps1, prune-bad-links.ps1, generate-board-overrides.ps1, build-deals-page.ps1, guards.ps1 (MUST exit 0), publish-deals-page.ps1. Commit + push EVERYTHING touched (scripts AND data - the push-scripts-to-repo lesson). Verify one fixed cell on the live board.
  BASIS CHECKS (2026-07-28, run alongside guards): audit-basis-reconcile.ps1 compares every cell against the store's OWN unit price (Walmart/Sam's fields, and the rate Hy-Vee prints inside its size text); audit-pack-basis.ps1 flags a cell that is cheapest ONLY because a pack count was multiplied into the size. Both are advisory - a store's own unit price is evidence, not gospel (Walmart's is provably wrong sometimes, the product NAME wins), so decide per cell and record reviewed disagreements in basis-reconcile-allowlist.json with the reason. They exist because bands and freshness cannot see a REAL price in the WRONG BASIS, which is the class that keeps landing on the cheapest-store verdict.
  IF YOU TOUCH A GUARD: test-auditors.ps1 must still exit 0. It replays each watcher's founding bug against a frozen fixture in regression-inputs\guard-fixtures\ and asserts it still fires (and stays silent on the clean twin). NEVER regenerate those fixtures from the live board - the bug they encode would vanish and the test would pass by finding nothing. A NEW guard ships with both fixtures and a case in that harness, or it is not done.

STEP 4 - CLOSE THE LOOP: set each queue item status='resolved' with 1-2 line notes (what it was, what was fixed, where). If an item genuinely needs Brad (a purchase, a CAPTCHA wall, a judgment call about what a commodity SHOULD mean), set status='needs-brad' and email him ONE specific ask via send-alert.ps1 -Force. If a genuinely new failure CLASS was learned, record it in C:\Users\Owner\.claude\projects\C--Codex\memory\ per the memory conventions.

STEP 5 - CLEAN-TREE GATE (mandatory, do this BEFORE reporting done): run
  git -C C:\Codex\income status --porcelain
If it shows any modified/added SOURCE file you changed this run (a .ps1, .vbs, commodities.json,
categories.json, commodity-search.json, an allowlist/config json, a SKILL), you did NOT finish STEP 3 -
COMMIT AND PUSH IT NOW. A triage run must never end with one of its own fixes uncommitted (2026-07-27:
a real Walmart fish-sauce mispricing fix was left loose and would have been lost). Regenerated pipeline
DATA/output churn (grocery\out\*, trend HTML, logs, board.json, feed, costed.json, published-hashes) is
NOT your responsibility to commit - the daily pipeline + cloud own it; only your own source/config edits
must be committed. After committing, re-run the status check and confirm no source file remains. THEN
verify HEAD == origin/main. Only report done when your source changes are all pushed.

HARD RULES: never fabricate a price; never bypass a CAPTCHA (hard stop); accuracy over safe (understating is as wrong as overstating); guards fail closed and stay that way; any visual/site change gets the 375px mobile check before publishing; no em dashes in any copy.

REPORT: per item - id, classification, fix applied (or resolved-with-reason / needs-brad), and whether the board republished. Then a CLEAN-TREE line: confirm no source file of yours is left uncommitted and HEAD is pushed.