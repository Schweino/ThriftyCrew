---
name: grocery-bakers-daily-flash-check
description: RETIRED 2026-07-26: converted to the zero-token Windows task "SMP Bakers Daily Scan" (grocery\bakers-daily-scan.ps1, 6:00 daily incl. Wed). This agent is kept disabled for prompt reference only. Flyer vision-reads: weekly Wednesday agent; mid-week ADFLIP raises a triage alert.
---

Daily Baker's price refresh for the Thrifty Crew Omaha grocery price board (www.thriftycrew.com/omaha-grocery-prices). The scan is HEADLESS (Kroger public API) and cheap, so it runs UNCONDITIONALLY every morning - Brad's call 2026-07-25, the day an unadvertised overnight promo (Heritage Farm chicken breast $2.29 -> $1.99) proved the event-driven skip's blind spot: an IDLE morning only means no KNOWN boundary, and unadvertised promos are invisible to the window log by definition. Running the API scan daily at 6:00 catches those 2.5 hours before the 8:30 pipeline backstop. All scripts + data live in C:\Codex\income\grocery\ .

STEP 0 - GUARD (still first, but it now only decides TWO things): run
  powershell -ExecutionPolicy Bypass -File C:\Codex\income\grocery\bakers-daily-due.ps1
  - FRESH - Baker's was ALREADY refreshed today (a prior run, manual, or the weekly agent). Report and STOP; nothing to do.
  - ADFLIP anywhere in the output - the weekly ad has rolled; do STEP B (flyer) in addition to the scan.
  - ANY other answer (IDLE or DUE) - proceed with STEP A regardless. IDLE no longer skips the scan: the
    window log can only see ADVERTISED boundaries, and the daily API scan exists precisely for the
    unadvertised ones. The guard's DUE/IDLE distinction is informational now - include it in the report.

STEP 0.5 - SYNC REPO: run  powershell -Command "git -C C:\Codex\income pull --rebase --autostash origin main"  so you recompute on top of the cloud's latest committed prices. A second or two; "Already up to date" is fine.

FIRST read these two memory files for the exact tested procedures + gotchas: grocery-deal-comparison.md (Baker's pull method) and grocery-product-urls.md (the product-URL layer). TWO HARD RULES for every price: (a) current shelf price from Kroger/Baker's OWN first-party source (the developer API for the scan; bakersplus.com for the flyer), and (b) the OMAHA store - the API is pinned to locationId 61500319 = Saddlecreek, and any browser step's store selector must read "Pickup at Saddlecreek" (888 S Saddle Creek Rd, Omaha 68106). NEVER fabricate a price - skip anything you cannot verify.

A browser is ONLY needed for STEP B (ad-flip flyer capture). The price scan is HEADLESS as of 2026-07-24 (Kroger's sanctioned public API). On a plain DUE (no ADFLIP), never open a browser at all. If ADFLIP and browser tools are unavailable, still run STEP A + C + D (prices refresh headlessly) and report that only the flyer capture is pending for the weekly agent or a manual pass.

STEP A - CURRENT-PRICE SCAN (headless, ~4 minutes, NO browser): run
  powershell -ExecutionPolicy Bypass -File C:\Codex\income\grocery\pull-regular-bakers-api.ps1
This pulls the current shelf AND promo price for every commodity term from Kroger's public API, scoped to the Saddlecreek Omaha store (locationId 61500319), under the guard-10 current_price contract. Its size-basis resolver refuses any row whose pack basis it cannot PROVE from soldBy/netWeight (refusals listed in out\kroger-api-eval\refused-<date>.json - they are coverage gaps, never guessed prices). If it exits non-zero (thin pull or API failure), STOP and report; the newest existing capture keeps serving. On success ALSO run
  powershell -ExecutionPolicy Bypass -File C:\Codex\income\grocery\refresh-bakers-links.ps1
so the "See item" link snapshots carry the same reading the board is about to publish (without this, guard 4 reads every legitimately moved price as a link disagreement).

STEP B - ONLY IF the guard said ADFLIP: also pull the weekly FLYER per the weekly SKILL step A - open https://www.bakersplus.com/weeklyad , confirm "Pickup at Saddlecreek" and read the ad dates, capture the przone flyer image URLs (read_network_requests urlPattern=przone) to out\bakers\urls.txt (imwidth=2400), run pull-bakers.ps1 -StoreLabel "Pickup at Saddlecreek" -AdFrom <yyyy-MM-dd> -AdTo <yyyy-MM-dd> -UrlsFile out\bakers\urls.txt , vision-read out\bakers\page-*.jpg to out\bakers\bakers-deals-<today>.json, and edit ad-schedule.json Baker's {current:{from,to}, next_pull = to+1, append old to history}. On a normal (no-ADFLIP) day, SKIP this step entirely.

STEP C - RE-COMPARE + PUBLISH-ONLY-IF-CHANGED (reuses the tested downstream): run
  powershell -ExecutionPolicy Bypass -File C:\Codex\income\grocery\check-ad-cycles.ps1 -NoPull
The -NoPull flag means it does NOT re-pull the server stores; it re-runs compare-deals with the fresh Baker's data you just wrote, rebuilds the per-item sale-window log (build-sale-windows.ps1, so any new/changed Baker's sale dates + prices are captured), refreshes the product-URL worklist (resolve-worklist), and republishes the live page ONLY IF the board price signature changed (a Baker's flash sale starting or ending flips it). It self-gates on coverage and preserves the page's current visibility. Read its printed summary - it will say PUBLISHED (price change) or CURRENT (no change).

STEP D - COMMIT the fresh Baker's data to the repo (so the cloud recomputes with it instead of clobbering it): run  powershell -ExecutionPolicy Bypass -File C:\Codex\income\grocery\push-data.ps1  . It commits ONLY the raw store inputs (derived files are gitignored; cloud-owned files are discarded), rebases on the cloud's latest, and pushes. Report its one-line result (pushed / no changes / retry-next-run).

Report concisely: the guard result (DUE/FRESH/ADFLIP), whether any Baker's price actually changed versus the board, whether the page republished or stayed current, and any commodity you could not verify.