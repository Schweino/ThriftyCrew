---
name: grocery-browser-stores-refresh
description: STAGE TWO of the daily grocery pipeline, 8:30am - the browser work a scheduled script physically cannot do. The three TC Windows tasks own the pipeline but run PowerShell, which can never reach Brad Chrome; some stores answer his real browser and refuse an automated one. Scope - everyday rotation for Walmart and Aldi (always) plus Fareway/Sams only when the 0800 driver failed, the Bakers weekly ad vision-read on rollover, rescue terms, sale-fallback research, and a bounded batch of product-URL chips. Works out what is outstanding FROM THE DATA, not from the flag. Captures and builds only - never publishes, compares or pushes; 0800 owns the one chain a day.
---

STAGE TWO of the daily grocery pipeline: the browser work that a scheduled script physically cannot do.

WHY YOU EXIST, IN ONE PARAGRAPH. Three Windows tasks own the pipeline (TC Grocery Ad Pulls 0700,
Daily Capture 0800, Capture Watchdog 0930). They run PowerShell, and PowerShell can never reach
Brad's Chrome. Some stores answer his real browser and refuse an automated one - measured
2026-08-22: an automated Chrome gets a bot wall or a price-less payload, his own tab gets 1.3 MB of
products. You are a Claude session, so you have the claude-in-chrome extension, and you are the only
thing in this estate that can drive his actual browser. That is your entire reason for being: do the
browser half, then stop. You do NOT publish, compare, verify or push - 0800 owns all of that.

HARD RULES. Breaking any of these costs more than the data you were fetching.
 1. NEVER HEADLESS. Headless Chrome puts "HeadlessChrome" in its own user-agent. Use Brad's Chrome
    through the extension, always.
 2. ONE PROBE ON A WALL. If a store answers with a bot wall, that IS the diagnosis. Repeating cannot
    change the answer, only the score against us. Stop that store, run notify-desktop.ps1, move on.
    On 2026-08-22 repeated probing walled Walmart AND Sam's for hours.
 3. BLINDNESS IS NOT EMPTINESS. A page you could not read is UNUSABLE, never EMPTY. EMPTY is a claim
    about the STORE and downstream turns it into a not-carried ruling that retires a real cell. If a
    search returns products but you extract none, the parser is wrong - say so, capture nothing.
 4. PROVE THE STORE BEFORE YOU TRUST A PRICE. Every capture must confirm the Omaha store AND
    In-Store mode. A fresh Fareway session reads plausibly while sitting on Des Moines.
 5. NEVER FABRICATE. Skip anything you cannot verify. A missing cell is recoverable; a wrong price
    that looks right is not.

STEP ZERO - MAKE SURE THE 0800 CHAIN HAS FINISHED. You run at 09:00, and the 0800 task's downstream
chain (compare -> guards -> publish -> commit) measured 08:12-08:43 on 2026-08-22 - 31 minutes. It
writes the same out\regular files your builders write and touches the same git index, so starting a
build inside it is a torn read by construction. Before running ANY builder, check the same named
mutex capture-run itself uses:

    powershell -NoProfile -File C:\Codex\ThriftyCrew\grocery\chain-idle.ps1

It prints FREE (the chain is done - proceed) or HELD (still running). If HELD, wait a few minutes and
re-check, up to about 20. If it is STILL held after that, do the CAPTURES anyway - they only write
out\captures and out\fareway, which nothing else touches - but SKIP the builders and say so in your
report; the next 0800 will build from your capture files. Capturing is the part that cannot be redone
later, because the store's prices move; building always can.

FIRST, WORK OUT WHAT IS ACTUALLY OUTSTANDING - FROM THE DATA, NOT FROM A FLAG.
out\browser-capture-due-<date>.flag is a hint and it has been INCOMPLETE before (a store marked
"paused" in the driver returns success and silently drops off it). So check each source yourself:

  A. EVERYDAY ROTATION - out\worklists\capture-<store>-<date>.json, ~7 terms per store.
     Needed for a store only if out\regular\<prefix>-regular-<date>.json (or, for Sam's,
     out\sams\sams-deals-<date>.json) has no rows dated today.
       Walmart, Aldi  - ALWAYS yours. They refuse the automated driver.
       Fareway, Sam's - normally captured by the 0800 driver. Yours only when it failed
                        (expired cookies, a wall). Check before doing the work twice.
       Hy-Vee, Baker's, Family Fare - headless APIs. NEVER yours.
  B. BAKER'S WEEKLY AD - a flyer VISION READ, and the only ad that needs a browser. Due when
     ad-schedule.json's Baker's next_pull is today or past. Every other store's ad is a server feed
     (Aldi/Hy-Vee/Family Fare via Flipp, Fareway via its own CDN); Walmart and Sam's have no ad
     cycle at all. Do not go looking for ads that arrive on their own.
  C. RESCUE TERMS - out\rescue-terms-<store>.txt. Cells already DROPPED or about to EXPIRE off the
     board. These are known losses, so they come BEFORE ordinary rotation.
  D. SALE-FALLBACK RESEARCH - out\research-worklist.json. A commodity on sale with no everyday item
     to revert to: when the sale ends that store vanishes from the cell. Find the cheapest NON-sale
     everyday item and add it to that store's out\regular\ file.
  E. PRODUCT-URL CHIPS - out\url-worklist.json, the "See item" links, across ALL SEVEN stores
     (446 outstanding on 2026-08-22). Search the chip's exact `term`, confirm the price matches, and
     write {id,url,price,size,name} to out\url-inputs\store-<store>N-urls.json.

ORDER OF WORK, because you will not finish everything and the order decides what is lost:
  1. Rescue terms (cells leave the board if you skip them)
  2. Everyday rotation for stores genuinely outstanding
  3. Baker's ad, if due
  4. Sale-fallback research
  5. Product-URL chips - a BOUNDED batch, say 40, newest-flagged first. This list is long by design
     and will never be empty; do not let it eat the session.
Spend at most ~45 minutes. Stopping with items 1-3 done beats timing out inside item 5.

PER-STORE METHOD. All of it lives in memory grocery-method-<store>.md - read ONLY the stores you are
actually touching. The parts that cost a whole day to rediscover on 2026-08-22:

  ALDI (aldi.us, everyday). Client-side router, NOT navigation:
    window.__do_not_use_me_history.push('/aldi/s?k=' + encodeURIComponent(term))
    The path is '/aldi/s' - NOT '/store/aldi/s'. The router is already scoped under /store/, and
    doubling it gives /store/store/aldi/s, a page with no mode label at all.
    SCROLL OR LOSE THE SHELF: first paint is 8 tiles; scroll to the bottom until the count stops
    growing and you get 21-90. Eight is not a shallow sweep, it is one that misses the cheapest item.
    Name from the URL SLUG (the longest card line is often "Sold individually"), size from the CARD
    (the slug cannot hold a decimal: "15.5 oz" arrives as "15 5 oz"). Price ONLY from
    "Current price: $X.XX" - the card also carries a glued "$249" for a $2.49 item.
    Assert: header says In-Store AND "ALDI - OLA 48 - Omaha".
    Emit id|term|name|prices|unit|size|href -> out\captures\aldi-capture-<date>.csv
    Then: build-aldi-regular.ps1 -In <that> -Date <date>

  WALMART (everyday). fetch('/search?q=<term>') from a walmart.com tab, parse <script id="__NEXT_DATA__">.
    The price shape is FLAT STRINGS: priceInfo.linePrice "$1.74", priceInfo.unitPrice "2.7 c/fl oz".
    The older nested shape (currentPrice.price / priceDetails.priceLines[0].price) may still appear -
    read both. lp MUST reach the CSV as "$x.xx"; the builder rejects a bare number as "no linePrice".
    If a page holds item nodes but you extract none, that is UNUSABLE, not EMPTY.
    Pace 3500ms +/- 2000. Emit q|n|lp|up|id|was|rb -> out\captures\walmart-capture-<date>.csv
    Then: build-walmart-deals.ps1 -In <that> -Date <date>

  SAM'S CLUB (everyday, only if 0800 failed). fetch('/s/<term>'), same __NEXT_DATA__ approach.
    Capture BOTH linePrice AND unitPrice. Pace 2600ms +/- 1400.
    Emit q|n|lp|up|id|was -> out\captures\sams-capture-<date>.csv
    Then: build-sams-deals.ps1 -In <that> -Date <date>

  FAREWAY (everyday, only if 0800 failed). Navigate per term to
    /store/fareway-meat-grocery/s?k=<term>, then read window.__APOLLO_CLIENT__ via
    farewayShopExtract(term) from pull-fareway-shop.js. The fetch-and-regex probe is DEAD - the
    storefront is client-rendered and returns a shell.
    Assert retailerLocation 531573 AND In-Store before trusting anything.
    Emit JSONL {id,term,candidates:[...]} -> out\fareway\fareway-shop-<date>.jsonl
    Then: select-fareway-shop.ps1 -In <that> -Today <date>
          build-fareway-regular.ps1 -Today <date> -ModeVerified <date>
    -ModeVerified is only legitimate because the identity check proved In-Store. Without it
    compare-deals silently drops all ~433 Fareway cells.

  BAKER'S (weekly ad only). bakersplus.com/weeklyad, store "Pickup at Saddlecreek". Capture przone
    flyer image URLs, run pull-bakers.ps1, then VISION-READ the pages meta.json lists (not a bare
    page-*.jpg glob - a shorter ad leaves the previous one's extra pages behind). Scan for EVERY
    tracked commodity, including multibuy/BOGO call-outs: capture ad_price verbatim ("Buy 1 Get 2
    Free"), the numeric regular, and the unit basis ("lb" / "each" / a pack size). The engine does
    the maths; a multibuy without a regular cannot be priced.

AFTER EACH STORE, ADVANCE ITS CURSOR - but only if the build really produced rows. The builders call
commit-capture-cursor.ps1 themselves and it re-checks; do not advance by hand. A capture that priced
nothing must re-attempt the same slice tomorrow, never skip it.

DO NOT PUBLISH. No compare-deals, no check-ad-cycles, no publish-deals-page, no push. The 0800 task
owns the whole downstream chain and runs ONE chain a day; a second one races it on the same working
tree. Your rows reach the live board at the next 0800. If something is urgent enough to publish
today, say so in your report and let Brad decide.

IF BRAD'S CHROME IS NOT AVAILABLE (no extension, browser closed, locked screen): report that plainly
and stop. Do not fall back to launching an automated Chrome - that is what gets these stores walled,
and a wall costs days.

REPORT: which stores you captured and how many priced rows each produced; what you deliberately did
not reach and why; any store that walled (and confirm you notified); any commodity you skipped
because you could not verify it; and the outstanding counts still on the url-worklist and rescue
lists, so the size of the backlog is visible rather than implied.
