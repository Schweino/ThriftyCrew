Work in `C:\Codex\income`. This is the deterministic local producer for authenticated V3 real-Chrome grocery captures. Before acting, read `platform/CLAUDE.md`, `platform/docs/lessons.md`, and `platform/docs/BROWSER-CAPTURE-RUNBOOK.md` completely. The runbook and checked-in capture-session commands are authoritative. Never execute the legacy compare, Ghost publication, link-repair, commit, or push tail.

Use the connected real Chrome profile. Never substitute web search, server HTTP, a different retailer, or marketplace pricing. Page evaluation is read-only. Navigate normally, extract only projected first-party product fields, and write data outside the page. Never read or persist cookies, tokens, tracking payloads, or unrelated page state.

Schedule routing:

1. Determine the America/Chicago date and weekday.
2. Wednesday-Saturday, run `platform/scripts/browser-capture-due.ps1 -Json`. `FRESH` means skip the weekly sweep. `INFLIGHT` means do not recapture; run `platform/scripts/run-pc-capture-client.ps1 -Mode Watchdog`. `DUE` means capture only listed sources. Thursday-Saturday are retry days.
3. On non-Wednesday days, only when no weekly sweep is running, run `grocery/fareway-daily-due.ps1`. Honor `FRESH` and `IDLE`; on `DUE`, capture Fareway if it was not captured today.
4. Never run two store sweeps concurrently in the shared Chrome profile.

For each due store, generate the complete pull order, initialize a durable session with `pnpm tc capture session init <store> <worklist> <session-dir> <started-at>`, and use `pnpm tc capture session status <session-dir>` to resume. Process 10-20 terms per chunk. Each chunk JSON must contain the exact query results, term outcomes, retry counts and intervals, plus a fresh Omaha location/price-mode canary. Append it with `pnpm tc capture session append <session-dir> <chunk.json>`. A canary is required for every chunk. Bind at least the initial or final canary to the SHA-256 of a visible proof screenshot. A retailer challenge is `blocked`, never `empty`.

Projected fields:

- Walmart: `q,n,lp,up,id,taxonomy_path,url,image_url`; retain `usItemId`, Omaha L St Supercenter pickup mode, and store taxonomy as `departmentName/category.categoryPathId` when present in `__NEXT_DATA__`.
- Sam's Club: `q,n,lp,up,id,taxonomy_path,url,image_url`; retain product ID, Omaha club/pickup mode, and store taxonomy as `departmentName/category.categoryPathId` when present in `__NEXT_DATA__`.
- Aldi: `id,term,name,prices,unit,size,href,taxonomy_path`; prove ALDI OLA 42 Omaha and In-Store independently; use authoritative `Current price` text, product URL identity, and the explicit category/aisle label printed on the card.
- Fareway: `id,term,name,price,per,orig,unit,size,url,taxonomy_path`; prove 17070 Audrey Street Omaha and In-Store independently; use authoritative current/original price text, product URL identity, and the explicit category/aisle label printed on the card.

Retry an ordinary empty/error once. If a human-verification wall survives one retry, do not evade or solve it. Record `blocked`, run `grocery/notify-desktop.ps1 -Store <store> -Detail <progress> -AlsoEmail`, preserve the session, continue other stores, and leave the source due.

Finalize with `pnpm tc capture session finalize <session-dir> <projected-capture> <session-manifest> <finished-at>`. Run the existing deterministic store builder against that projected capture. Do not declare or enqueue `full` unless every expected term is `success` or verified `empty`. Then call `platform/scripts/enqueue-browser-capture.ps1` with `-Store`, `-RegularFile`, `-SessionManifest`, `-RawCapture`, `-Screenshot`, `-EvidenceUrl`, and `-Statement`. The wrapper must validate the session/raw/screenshot hashes and enqueue all three evidence classes.

At the end run `platform/scripts/run-pc-capture-client.ps1 -Mode Cycle` and rerun the due gate. `INFLIGHT` after upload is normal until engine-owned matching and promotion complete. Success requires a full batch, passed matching, and remote promoted/superseded truth; a local upload receipt alone is not success. Report store, expected/attempted/success/empty/blocked terms, accepted/rejected rows, taxonomy rows, evidence paths, queue/remote status, and operator action. Preserve unrelated dirty files.
