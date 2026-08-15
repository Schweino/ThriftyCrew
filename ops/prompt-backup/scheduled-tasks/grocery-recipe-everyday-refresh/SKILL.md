---
name: grocery-recipe-everyday-refresh
description: "Monthly (1st, 8am): refresh the recipe EVERYDAY floor prices by DERIVING them from the board's own weekly pull data (derive-recipe-floors.ps1); hand-verify only the flagged residue. Rewritten 2026-07-23 - the old 158-item x 6-store hand-browse is obsolete."
---

Monthly refresh of the recipe-ingredient EVERYDAY (non-sale) floor prices behind the Thrifty Crew grocery board's recipe rows (www.thriftycrew.com/omaha-grocery-prices). All scripts + data in C:\Codex\ThriftyCrew\grocery\ .

WHY THIS IS NOW DERIVED, NOT BROWSED (2026-07-23): since R100 put every recipe ingredient on the 7-store staple board, the weekly/daily pulls already capture everyday prices for these commodities. candidates-<date>.json records every matched row WITH price_type, so the floor per store is simply the cheapest everyday-typed candidate. Hand-browsing 158 items x 6 stores duplicates work the automation already did. Your job is the RESIDUE the derivation honestly refuses.

STEP 0 - SYNC: run  powershell -Command "git -C C:\Codex\ThriftyCrew pull --rebase --autostash origin main"

STEP 1 - DRY RUN: run  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\derive-recipe-floors.ps1  and read out\recipe-floors-report.json. It updates nothing yet; it proposes.

STEP 2 - REVIEW THE THREE FLAG LISTS (this is the whole human job):
  a. deltas_over_25pct: for each, open that store's product page for the named item and confirm the new floor is real (a floor moving >25% in a month is either a genuine reprice or a wrong match). If a delta is a WRONG MATCH (different product won the everyday slot), fix the commodity's include/exclude in commodities.json, re-run compare-deals.ps1 -MinStores 1, then re-run the dry run.
  b. ids_with_no_board_match: these recipe-era ids don't match a board commodity id. For each you have time for, find the board id for the SAME commodity in the SAME form (check commodities.json; fresh vs frozen and block vs shredded are DIFFERENT), verify one store's price agrees between the two, and add the mapping to recipe-floor-id-map.json with a reviewed date. Every mapping you add automates that row forever - the list should shrink every month. For ids with NO board equivalent, verify their floors the old way (browser, first-party store source, Omaha location, never fabricate) directly in recipe-board-everyday.json.
  c. ids_with_unit_mismatch: the row unit and board unit differ non-convertibly (e.g. 'each' vs 'oz'). Decide which unit is RIGHT for the recipe cost math, fix the row's unit + per_unit values coherently by hand, or leave it (it is refused, not guessed - safe either way).

STEP 3 - APPLY: once the flags are reviewed, run  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\derive-recipe-floors.ps1 -Apply  (it applies the SAME derivation you just reviewed - no re-read drift).

STEP 4 - REBUILD + PUBLISH: run  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\recipe-overlay.ps1  (re-applies current ad sales onto the fresh floors -> recipe-board.json), then  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\guards.ps1  (must exit 0), then  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\publish-deals-page.ps1 .

STEP 5 - COMMIT: run  powershell -ExecutionPolicy Bypass -File C:\Codex\ThriftyCrew\grocery\push-data.ps1  and report its one-line result.

Report: cells updated, how many no-match ids you converted to mappings (and how many remain), any wrong-match fixes made, notable floor moves, and whether the page republished.
