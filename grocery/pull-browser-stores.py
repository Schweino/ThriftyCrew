r"""
pull-browser-stores.py - drive the bot-walled grocery stores in a real Chrome, unattended.

WHY THIS EXISTS (Brad, 2026-08-22: "the job should automatically be using Chrome tabs to do the
job/pull. If it's not set up to do that, we need to fix it.")

Until today capture-run.ps1 could not capture Walmart, Sam's Club, Aldi or Fareway at all. It wrote
a worklist and a flag file that said "a human must open Chrome", and the only thing that ever worked
that flag was a Claude agent on a 6:15am schedule. When the schedule was cut to three Windows tasks
those four stores lost their capture path entirely - Sam's was already 21 days cold and Walmart 11.

The pull agents were always written FOR a driver. pull-agent-lib.js's waitForOperator() sets
`window.__tcWall` with the comment "the signal the driver polls for", and resumes on
`window.__tcResume` "set by the driver". That driver was never built. This is it.

WHAT IT DOES
  For each store: launch Chrome on a PERSISTENT profile, prove we are on the right Omaha store,
  inject pull-agent-lib.js + pull-<store>-instore.js, run that store's paced sweep over TODAY'S
  worklist only, and write the capture file its PowerShell builder already knows how to read.

FIVE THINGS THAT ARE DELIBERATE
  1. PERSISTENT PROFILE, NOT A THROWAWAY. Every one of these stores identifies the Omaha store or
     club from cookies. A fresh profile silently lands on some default store, and a plausible price
     from the wrong store is worse than no price - the estate has been burned by exactly that
     (Fareway defaulting to Des Moines). The profile is seeded ONCE by a human (--seed) and reused.
  2. IT REFUSES RATHER THAN GUESSES. Each agent's assertIdentity() throws unless it can prove the
     store. We do not catch that and carry on: an unseeded or logged-out profile ends the store with
     a NEEDS-SEEDING verdict, and captures nothing.
  3. A WALL NOTIFIES AND MOVES ON - IT DOES NOT WAIT. Solving a CAPTCHA is off limits, and there is
     nobody at the keyboard at 08:00. So on a wall we raise Brad's Windows prompt immediately (his
     standing rule) and tell the sweep to STOP. Everything settled so far is already persisted in
     the page's localStorage, so when he clears it the next run resumes from that exact term.
  4. HEADED, NOT HEADLESS. Headless Chrome advertises itself (navigator.webdriver, a Headless UA)
     and these stores already walled us once. A visible window is the lower-risk option, and this
     runs as an interactive scheduled task so it has a desktop to draw on.
  5. TODAY'S WORKLIST ONLY. The quarterly policy hands each store ~7 terms a day. This reads
     out\worklists\capture-<store>-<date>.json and sweeps exactly that. Being deep within those
     terms is the rule; being broad across the catalogue is what trips a wall.

NEVER HEADLESS - IT ADVERTISES ITSELF IN THE USER-AGENT (measured 2026-08-22)
  Every store here is marked never_headless, and this is the measurement behind it. On about:blank,
  with no site involved:
      headless : navigator.userAgent = "... HeadlessChrome/151.0.0.0 ..."   <- says it outright
      headed   : navigator.userAgent = "... Chrome/151.0.0.0 ..."           <- indistinguishable
  navigator.webdriver is false either way, plugins/languages/window.chrome all look normal. The UA is
  the tell, and it needs no cleverness to read.

  I WAS THE PROBLEM, AND I MISDIAGNOSED IT TWICE. Bringing this up I ran repeated ad-hoc probes at
  Walmart from a fresh HEADLESS profile, bypassing pull-agent-lib's pacing, backoff and wallLimit -
  the whole apparatus built to prevent that. Walmart walled hard. Sam's Club, measured OPEN at 08:15
  (22 rows, no login), was walled by 09:25. I concluded the IP was burned and both stores had to be
  left for days.
  That was wrong. Brad opened Sam's in his own Chrome and it was fine: "the way you are doing this is
  causing a problem." The reputation damage was never IP-wide - it was earned by a browser wearing a
  HeadlessChrome user-agent, hammering with no pacing, from a profile with no history.

  THE RULES THAT FOLLOW, in order of how much they cost to learn:
   1. Never headless against these stores. Enforced per store, not documented.
   2. One probe. A bot-wall verdict IS the diagnosis; repeating cannot change the answer, only the
      score. Anything beyond one goes through runPacedSweep, which paces and hands off to a human.
   3. When something fails, suspect YOUR OWN SETUP before concluding the world has changed. A
      conclusion as expensive as "the IP is burned, wait days" needs a control - Brad's working tab
      was the control I never thought to ask for, and it took ten seconds.

LOOKUP MODE (added 2026-08-24, PLAN-recipe-hunter-v3 D10 - the price-evidence pre-pass)
  `--lookup-terms-file <json array of terms> --lookup-out <path>` sweeps an AD-HOC term list and
  writes per-term SEARCH VERDICTS instead of a capture. It is the Recipe Hunter's unattended
  browser pre-pass: the hunt daemon gathers evidence for a batch of never-priced terms so the
  pricer agent spends its minutes adjudicating rows rather than driving five browsers.

  WHAT IT REUSES, UNTOUCHED: the store's existing agent, its pacing profile, its identity
  assertion, and its wall handling. Nothing about how this driver talks to a store changes.

  WHAT IT MUST NOT TOUCH, AND WHY THE FLAGS ARE NARROW:
    * it reads NO worklist and writes NO capture file. Pointing the daily surfaces at hunter terms
      would destroy the day's real worklist AND land hunter rows in the capture files the board
      builders parse. The daily capture estate is load-bearing; this is a different question asked
      of the same store.
    * the paced lane writes its verdicts under a SEPARATE localStorage key (LOOKUP_STORAGE_KEY),
      never the store's capture key. sweepToCsv() exports every MATCHES term it finds under that
      key, so a lookup term left in the capture key would be published as a captured price by the
      next morning's run.
    * legal only WITH BOTH FLAGS and only for `--store fareway` or `--store samsclub`. Walmart is
      refused with its own pause note quoted: it is captured through Brad's Chrome, and retrying it
      from here is his call to make, never a side effect of a hunter batch.

  ONE RUNG, NOT A LADDER. Each term is searched exactly ONCE, as given. search-verdict-lib's retry
  ladder is not walked here - widening a term is a judgment the pricer makes with the whole
  evidence file in front of it, and a driver that ladders would multiply requests against exactly
  the stores that wall us. So an EMPTY in a lookup file is a RUNG-1 EMPTY and says so in its
  reason: it permits `not-carried` only after the pricer completes the ladder.

  DEGRADING IS THE POINT. NEEDS-SEEDING, a wall, a dead CDP or a crash all end as UNUSABLE for
  every term of the batch, written to `--lookup-out` with the failure as the reason. Could-not-look
  never reads as EMPTY, and the caller is never handed silence.

EXIT CODES  0 = every requested store captured. 1 = at least one store failed or was walled.
            2 = nothing could run (no Chrome, no worklists). Unchanged by lookup mode - existing
            scripts keep their own exit codes, in both directions.
"""
import argparse
import datetime
import json
import random
import re
import os
import subprocess
import sys
import time
from urllib.parse import quote_plus

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(ROOT), "media", "reels"))

try:
    from cdp import Chrome, find_chrome
except Exception as e:  # pragma: no cover - a missing driver must say so plainly
    print(f"FATAL: cannot import the CDP driver ({e}). Expected media\\reels\\cdp.py.")
    sys.exit(2)


# Per store: the origin to sit on, the agent file, and the JS entry points it exposes.
# `capture` is the file the store's existing PowerShell builder already reads - this driver changes
# HOW the capture is produced, never the contract downstream of it.
STORES = {
    "walmart": {
        "name": "Walmart",
        "origin": "https://www.walmart.com/",
        "agent": "pull-walmart-instore.js",
        "sweep": "pullWalmartInStore",
        "to_csv": "walmartSweepToCsv",
        "verdicts": "walmartSweepVerdicts",
        "storage_key": "TC_WALMART_SWEEP",
        "identity": "walmartIdentity()",
        # The header the PowerShell builder parses with. sweepToCsv emits DATA ONLY - Import-Csv
        # needs a header line or the first product row is eaten as one. Must match
        # walmartSweepToCsv's cell order exactly: [term, n, lp, up, id, was, rb].
        "csv_header": "q|n|lp|up|id|was|rb",
        "capture": os.path.join("out", "captures", "walmart-capture-{date}.csv"),
        # BRAD'S RULE, 2026-08-22: "walmart can never be headless." (Now true of every store here -
        # see NEVER_HEADLESS_REASON below; kept on Walmart explicitly because he named it.)
        # Measured the same day on a fresh profile: walmartProbe('milk') returned
        # {"state":"UNUSABLE","why":"bot-wall"} and the page title was literally "Robot or human?".
        # PerimeterX flags this store hardest, and a headless run cannot be rescued - there is no
        # window for anyone to clear the challenge in, so the whole worklist records as UNUSABLE and
        # the wall gets deeper. Enforced below rather than written down as guidance, because a flag
        # that is only documented is a flag someone passes anyway.
        "never_headless": True,
        # PAUSED 2026-08-22 - AND NOT BECAUSE OF A WALL.
        # With the browsing-mode launch the hard wall is gone (unusable went to 0 on the first clean
        # run). What replaced it is worse to diagnose and worse to keep probing: Walmart serves this
        # automated browser pages that CONTAIN items but carry no prices. Measured the same minute,
        # same machine, same cookies:
        #     Brad's own Chrome   /search?q=milk -> 119 item nodes, prices present, parser keeps 59
        #     the driver's Chrome /search?q=...  -> 83-111 item nodes, no extractable price, keeps 0
        # So it is a SOFT block on the automation channel, not the profile, the fingerprint or the
        # IP - all of which were measured identical. Left paused rather than retried daily because
        # every attempt spends request budget on a store that cannot currently return a price, and
        # raises the score against an account that still works fine for Brad by hand.
        # To retry: delete this flag and run ONE capture. If item nodes appear with real prices, it
        # is fixed. Do not iterate against the live store - use Brad's Chrome as the control, which
        # is what finally separated the two faults here.
        # NOT DRIVABLE HERE - CAPTURED THROUGH BRAD'S OWN CHROME INSTEAD (Brad, 2026-08-22:
        # "Im okay with you using MY chrome to do the search like you do with Aldi. For walmart that
        # is."). This driver stays out of Walmart's way entirely rather than probing it daily.
        # Proven the same day through the claude-in-chrome extension: the same paced sweep, the same
        # fixed parser, 7/7 terms MATCHES, 333 rows, zero walls -> 136 priced commodities. So the
        # store is fine and the AGENT is fine; what Walmart declines is this automated browser.
        # That makes Walmart an ATTENDED lane: it needs a session with the extension, so the 08:00
        # job cannot do it and correctly reports it as outstanding on the browser flag.
        "paused": "captured through Brad's own Chrome (attended, like Aldi) - this driver's browser "
                  "gets price-less payloads, his does not",
        # Walmart is the one store with nothing to assert: prices are already the local store's and
        # there is no store toggle in the payload, so walmartIdentity() only proves we are on
        # walmart.com and not already walled. Seeding is therefore about the SESSION (a warm,
        # cookied profile is less wall-prone than a cold one), not about store selection.
        "seed_hint": "browse a couple of pages so the profile has a normal session, and set the "
                     "pickup store to an Omaha store (Omaha L St Supercenter, 12850 L ST, 68137).",
    },
    "samsclub": {
        "name": "Sam's Club",
        "origin": "https://www.samsclub.com/",
        "agent": "pull-sams-instore.js",
        "sweep": "pullSamsInStore",
        "to_csv": "samsSweepToCsv",
        "verdicts": "samsSweepVerdicts",
        "storage_key": "TC_SAMS_SWEEP",
        "identity": "samsIdentity()",
        # The page-global agent object runPacedSweep takes. Lookup mode clones it with a different
        # storageKey so a hunter sweep can never land in the capture key (see LOOKUP MODE above).
        # Declared here rather than derived from a name, for the same reason `identity` is: a
        # derived handle that misses does not fail loudly, it substitutes something harmless-looking
        # and the guard quietly stops guarding (see _identity_call).
        "lookup_agent": "samsAgent",
        # samsSweepToCsv emits [term, n, lp, up, id, was] - six columns. The captures before
        # 2026-08-21 had five (no `was`); `was` arrived with the rollback-TTL work. A stale
        # five-name header over six-column data does not error, it SHIFTS every field one place.
        "csv_header": "q|n|lp|up|id|was",
        "capture": os.path.join("out", "captures", "sams-capture-{date}.csv"),
        "never_headless": True,
        # 15429 Blackwell Dr, NOT the 13130 L St in the older runbooks. The live session moved on
        # 2026-08-15 and several docs still name L St. Seeding the wrong Omaha club would not be
        # caught by samsIdentity() - it matches the word "Omaha", not a specific club - and Sam's
        # prices are per-club, so the board's history would silently change basis.
        "seed_hint": "sign in to the membership, then set the club to the Omaha club at "
                     "15429 Blackwell Dr (NOT 13130 L St - that is the stale runbook value).",
    },
    "fareway": {
        "name": "Fareway",
        "origin": "https://shop.fareway.com/store/fareway-meat-grocery/",
        # TWO FILES, AND THE SPLIT IS THE WHOLE POINT.
        # pull-fareway-instore.js supplies farewayIdentity() - the only honest way to know which
        # store we are on (it reads retailerLocation from the Apollo cache; the on-screen label lies,
        # a fresh session reads plausibly while sitting on Des Moines). Its PROBE, though, is dead:
        # shop.fareway.com went fully client-rendered, so fetch-and-regex sees a shell with zero
        # product JSON. Its own header says so and says the fix is driver-side.
        # pull-fareway-shop.js is that fix: navigate per term, then read window.__APOLLO_CLIENT__.
        # It also recovers "Sale ends in N days", which is never painted into the DOM at all.
        "agent": "pull-fareway-instore.js",
        "extra_agent": "pull-fareway-shop.js",
        "lane": "navigate",                  # NOT the paced same-origin fetch sweep
        # Asserts BOTH retailerLocation == 531573 (Omaha) AND mode == In-Store, from the Apollo
        # cache. This is what licenses capture-run to pass -ModeVerified downstream.
        "identity": "farewayIdentity()",
        "extract": "farewayShopExtract",
        "search_url": "https://shop.fareway.com/store/fareway-meat-grocery/s?k={term}",
        # Mirrors stores.json -> Fareway -> pull_profile. audit-pull-profiles.ps1 fails if they disagree.
        "delay_ms": 900, "jitter_ms": 600, "retries": 3,
        "capture": os.path.join("out", "fareway", "fareway-shop-{date}.jsonl"),
        "never_headless": True,
        "seed_hint": "set the store to Omaha 17070 Audrey Street (68136) and confirm the header "
                     "reads In-Store.",
    },
}

# ALDI IS CAPTURED THROUGH BRAD'S OWN CHROME, LIKE WALMART - AND I HAD THE REASON WRONG.
# An earlier note here said Aldi could not be driven because pull-aldi-instore.js walks PRODUCT
# SLUGS rather than search terms. True of that file, and beside the point: that agent is the
# SECONDARY tool, a re-pricer for products whose slug we already know (product-urls.json has 410 of
# 625). The PRIMARY Aldi lane has always been a SEARCH sweep - build-aldi-regular.ps1 reads
# `id|term|name|prices|unit|size|href` and stamps found_by_term, which only a search can produce.
# So the blocker was never the slug mapping. Proven 2026-08-22 through the claude-in-chrome
# extension: 7 terms, 392 rows, 310 priced, mode verified In-Store at ALDI - OLA 48 - Omaha.
#
# THE METHOD, because it is not obvious and cost two false starts:
#   * Client-side router, not navigation: window.__do_not_use_me_history.push('/aldi/s?k=<term>').
#     The path is '/aldi/s' NOT '/store/aldi/s' - the router is already scoped under /store/, and
#     doubling it produced /store/store/aldi/s, a page with no mode label at all. The In-Store
#     assertion caught that and refused rather than capturing from a broken page.
#   * SCROLL, or you get a tenth of the shelf. Results lazy-load: the first paint carries 8 tiles,
#     and scrolling to the bottom until the count stops growing gave 21-90 per term. A sweep that
#     stops at 8 is not a shallow sweep, it is a sweep that will miss the cheapest item.
#   * NAME FROM THE SLUG, never the card text - the longest card line is often a descriptor
#     ("Sold individually"). The slug cannot hold a decimal, so "15.5 oz" arrives as "15 5 oz";
#     build-aldi-regular's Repair-SlugDecimals fixes it FROM THE SIZE COLUMN, so the size must be
#     captured from the card rather than derived from the slug.
#   * PRICE ONLY FROM "Current price: $X.XX". The card also carries a glued form ("$249" beside a
#     $2.49 item) - the same 100x trap Fareway's extractor has.
#
# Not in STORES because this driver cannot run it: like Walmart, Aldi answers Brad's Chrome and not
# an automated one, so it is an ATTENDED lane and the 08:00 job correctly reports it outstanding.
ALDI_NOTE = ("Aldi is captured through Brad's own Chrome (attended, search sweep with lazy-load "
             "scrolling) - see the note above for the method. Not drivable from here.")


def today_str(override=""):
    return override or datetime.date.today().strftime("%Y-%m-%d")


def profile_dir(store_key):
    """One persistent Chrome profile PER STORE.

    Sharing one profile across all four would mean a wall or a logout at one store could take the
    others with it, and the store-selection cookies of two grocery sites have no business sharing a
    cookie jar. Kept out of the repo (out\\ is gitignored) - it holds a real logged-in session.
    """
    return os.path.join(ROOT, "out", "browser-profiles", store_key)


def read_worklist(store_key, date_s):
    p = os.path.join(ROOT, "out", "worklists", f"capture-{store_key}-{date_s}.json")
    if not os.path.exists(p):
        return None, f"no worklist at {os.path.relpath(p, ROOT)} - run capture-policy.ps1 -Emit first"
    with open(p, "r", encoding="utf-8-sig") as fh:
        doc = json.load(fh)
    terms = doc.get("terms") or doc.get("Terms") or []
    terms = [str(t) for t in terms if str(t).strip()]
    if not terms:
        return None, "worklist is empty - nothing owed today"
    return terms, None


def read_worklist_pairs(store_key, date_s):
    """(term, commodity_id) pairs. The navigate lane needs the COMMODITY id, not just the term.

    The worklist carries `terms` and `commodities` as PARALLEL arrays, and select-fareway-shop.ps1
    keys each JSONL line on the commodity id (it dedupes by it, last capture wins). Pairing by index
    is what the file's own shape intends - but a length mismatch would silently shift every id by
    one, filing pork prices under the previous commodity, so that is checked rather than assumed.
    """
    p = os.path.join(ROOT, "out", "worklists", f"capture-{store_key}-{date_s}.json")
    if not os.path.exists(p):
        return None, f"no worklist at {os.path.relpath(p, ROOT)}"
    with open(p, "r", encoding="utf-8-sig") as fh:
        doc = json.load(fh)
    terms = [str(t) for t in (doc.get("terms") or [])]
    cids = [str(c) for c in (doc.get("commodities") or [])]
    if not terms:
        return None, "worklist is empty - nothing owed today"
    if len(cids) != len(terms):
        return None, (f"worklist is malformed: {len(terms)} terms but {len(cids)} commodities. "
                      "Pairing them by index would file every price under the wrong commodity.")
    return list(zip(terms, cids)), None


def notify_wall(store_name, detail, also_email=True):
    """Brad's standing rule: a bot wall puts a prompt on his screen WHILE the run is going.

    notify-desktop.ps1 detaches and always exits 0, so this can never block or fail the pull.
    """
    script = os.path.join(ROOT, "notify-desktop.ps1")
    if not os.path.exists(script):
        print(f"  ! notify-desktop.ps1 missing - cannot raise the wall prompt for {store_name}")
        return
    args = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script,
            "-Store", store_name, "-Detail", detail]
    if also_email:
        args.append("-AlsoEmail")
    try:
        subprocess.run(args, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        print(f"  ! could not raise the wall prompt: {e}")


def js_file(name):
    with open(os.path.join(ROOT, name), "r", encoding="utf-8") as fh:
        return fh.read()


def release_profile(prof):
    """Kill any Chrome still holding this persistent profile, before we try to launch on it.

    THE TRAP (hit twice while building this, 2026-08-22): Chrome silently refuses to start a second
    instance on a profile directory another process owns. It does not error - the process exits, the
    debug port never opens, and the driver reports "Chrome never opened a debugging port", which
    reads like a broken driver rather than a stale lock. cdp.py documents this trap and avoids it by
    using a throwaway profile every time; a PERSISTENT profile cannot, so it has to clean up instead.
    It bites in exactly the situation that matters: a seeding run that crashed, or a window someone
    closed by hand, leaves the profile owned and EVERY later run fails until something kills it.
    Nobody would guess that from the message.

    Narrow on purpose - matched on this specific profile path, so it can never touch Brad's own
    Chrome, which is the whole reason the driver keeps its own profiles in the first place.
    """
    if os.name != "nt":
        return 0
    try:
        out = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | "
             f"Where-Object {{ $_.CommandLine -like '*{prof}*' }} | "
             "ForEach-Object { $_.ProcessId }"],
            capture_output=True, text=True, timeout=30)
        pids = [p.strip() for p in (out.stdout or "").splitlines() if p.strip().isdigit()]
        for pid in pids:
            subprocess.run(["taskkill", "/PID", pid, "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        if pids:
            print(f"  cleared {len(pids)} stale Chrome process(es) still holding this profile")
            time.sleep(2)
        return len(pids)
    except Exception as e:
        print(f"  ! could not check for stale Chrome on the profile: {e}")
        return 0


def wait_for_identity(browser, call, timeout_s=45):
    """Poll the store's OWN assertIdentity until it passes. Returns (ok, last_verdict).

    THE BUG THIS FIXES (2026-08-22). Seeding polls for up to 15 minutes, so it happily waits for the
    club name to render. The sweep asserted identity ONCE, immediately after injection - and
    samsIdentity() reads the club out of document.body.innerText, which on a client-rendered header
    is simply not there yet a few seconds after navigation. Same profile, same club, same page:
    seeding said OK and the capture said "could not read an Omaha club from the page".

    This waits for the PAGE, it does not weaken the CHECK. The assertion is unchanged and still has
    to pass on its own terms; the only thing added is patience. Weakening it instead - accepting a
    blank header as "probably still Omaha" - is how a capture ends up pricing another market's shelf,
    which is the one failure mode this whole driver exists to prevent.
    """
    deadline = time.time() + timeout_s
    last = ""
    while time.time() < deadline:
        last = browser.js(
            "(function(){ try { %s; return 'OK'; } "
            "catch(e){ return 'REFUSED: ' + String((e&&e.message)||e).slice(0,200); } })()" % call)
        if last == "OK":
            return True, last
        time.sleep(2)
    return False, last


def ensure_agent(browser, agent_src, probe_fn):
    """Inject the agent only if this document does not already have it.

    INJECTING TWICE IS A HARD ERROR, not a harmless repeat: pull-agent-lib.js declares `const sleep`
    at top level, so a second evaluation in the same document throws
    "Identifier 'sleep' has already been declared" and takes the whole run with it. That is easy to
    trip, because the agent arrives by two routes - addScriptToEvaluateOnNewDocument (which fires on
    every navigation) and an explicit evaluate for the page that is already open. Today the two are
    kept apart by call ORDER, which is exactly the kind of invisible constraint that breaks when
    someone reorders two lines. Asking the page whether it already has the agent removes the
    ordering dependency altogether.
    """
    try:
        if browser.js(f"typeof {probe_fn} === 'function'"):
            return False
    except Exception:
        pass
    browser.js(agent_src)
    return True


MULTIPACK_RE = re.compile(r'^\s*(\d+)\s*x\s*([\d.]+)\s*([a-z ]+)$', re.I)
SLUG_SIZE_RE = re.compile(r'-(\d+(?:-\d+)?)-(oz|fl-oz|lb|ct|count|each|g|ml|l)$')


def corroborate_multipack_sizes(rows):
    """Refuse to publish a multipack size the product's own URL does not corroborate.

    THE ROW THAT FORCED THIS (2026-08-22, first run of this lane). Fareway's own pricingUnitString
    said "6 x 288 oz" for Mott's applesauce at $3.48 - 1,728 oz, or 108 lb of applesauce for three
    and a half dollars. The product slug says what it really is:
        .../products/35024-mott-s-original-applesauce-4-oz
    Six 4 oz cups. The bad size survived selection and WON the applesauce cell at $0.002/oz, which
    is the estate's most familiar failure shape: a size error does not look wrong, IT LOOKS CHEAP,
    and the smaller number wins a sort ([[cheapest-is-per-unit-not-per-purchase]]).

    THE SLUG IS THE SECOND WITNESS, NOT THE NEW TRUTH. It is corrupt in its own way - it cannot hold
    a decimal point, so "12 x 3.17 oz" appears as "317 oz", the same defect already known at Aldi.
    So this does not "correct" one from the other; it only asks whether they AGREE, in the three
    ways they legitimately can:
        count x member == slug total      the slug states the pack total
        slug == member x 100              the slug dropped the decimal
        slug == member                    the slug states the per-member size
    Anything else is a size no evidence supports, and the size is DROPPED rather than guessed.
    A size-less row is unscorable, sorts last and cannot win a cell (select-fareway-shop:
    "UNSCORABLE SORTS LAST, IT DOES NOT SORT AS ZERO"), so the row stays visible as a candidate
    while losing the power to publish a false per-unit. Correcting it instead would mean choosing a
    winner between two witnesses that are each wrong sometimes - see
    [[label-scales-wrong-was-already-wrong]].

    Measured on that first capture: 56 multipack sizes, 35 corroborated, 18 not comparable
    (no slug size, or a different unit family), 3 dropped - both Mott's rows and one GoGo Squeez
    where 12 x 3.2 = 38.4 but the slug says 32.
    """
    dropped = []
    for c in rows:
        sz = str(c.get("size") or "").strip()
        m = MULTIPACK_RE.match(sz)
        if not m:
            continue
        n, member, unit = int(m.group(1)), float(m.group(2)), m.group(3).strip().lower()
        sm = SLUG_SIZE_RE.search(str(c.get("url") or ""))
        if not sm:
            continue                      # no second witness: leave it alone, do not invent doubt
        slugv = float(sm.group(1).replace("-", "."))
        slugu = sm.group(2).replace("-", " ")
        if slugu.replace("fl ", "") != unit.replace("fl ", ""):
            continue                      # different unit family - not comparable, not disagreeing
        total = n * member
        if (abs(total - slugv) <= max(0.02 * slugv, 0.05)
                or abs(slugv - round(member * 100)) < 0.51
                or abs(slugv - member) <= 0.01):
            continue
        c["size"] = ""
        c["size_dropped"] = f"uncorroborated: '{sz}' implies {total:g} {unit} but the product URL says {slugv:g} {slugu}"
        dropped.append((str(c.get("name", ""))[:45], sz, f"{slugv:g} {slugu}"))
    return dropped


def navigate_probe(browser, cfg, term, agent_src, retries=3):
    """ONE term through the navigate lane: go to the search url, read the page's own Apollo cache.
    Returns (rows, why) - rows is None when the page could never be read, which is BLINDNESS and
    must never be recorded as an empty shelf.

    Factored out of run_navigate_lane 2026-08-24 so the D10 lookup lane asks the store the exact
    same question the daily capture asks. Two copies of "navigate, inject, retry, scroll, extract"
    would drift, and the half that drifted would be the one nobody watches every morning.
    """
    url = cfg["search_url"].format(term=quote_plus(term))
    rows, why = None, ""
    for attempt in range(retries):
        try:
            browser.goto(url, wait_ms=3500)
            ensure_agent(browser, agent_src, cfg["extract"])
            # Results lazy-load, and the cache fills as they do. Give hydration a few chances
            # before believing the page: an extract attempted too early throws for the same
            # reason an empty store would, and the two must not be confused.
            for _ in range(8):
                raw = browser.js(
                    "(function(){ try { return JSON.stringify(%s(%s)); } "
                    "catch(e){ return 'ERR:' + String((e&&e.message)||e); } })()"
                    % (cfg["extract"], json.dumps(term)))
                if raw and not raw.startswith("ERR:"):
                    rows = json.loads(raw)
                    break
                why = (raw or "no response")[:160]
                browser.js("window.scrollTo(0, document.body.scrollHeight);")
                time.sleep(1.2)
            if rows is not None:
                break
        except Exception as e:
            why = f"threw: {e}"
        time.sleep(2 + attempt * 3)
    return rows, why


def run_navigate_lane(browser, cfg, pairs, out_path, agent_src):
    """Fareway's lane: navigate per term, then read the page's own Apollo cache.

    WHY THIS IS NOT THE PACED-FETCH SWEEP. runPacedSweep works by same-origin fetch from inside the
    page, which is perfect for Walmart and Sam's - their search response carries the product JSON.
    Fareway's does not any more: the storefront is fully client-rendered, so the response is a shell
    and fetch-and-regex reads zero products from a store that sells thousands. The only place the
    data exists is the hydrated app's Apollo cache, and reaching it means NAVIGATING, which unloads
    whatever script was doing the sweeping. That is precisely the work a driver can do and an
    in-page agent cannot, and it is why pull-fareway-instore.js's header says to do it here.

    BLINDNESS IS NOT EMPTINESS, ENFORCED. farewayShopExtract THROWS when the cache holds no priced
    nodes rather than returning []. This keeps that distinction: a term whose extract never succeeds
    is recorded as an error and reported, never written out as "Fareway carries none of these".
    Writing a confident empty here would retire real cells - the most expensive failure this estate
    has.
    """
    delay = cfg.get("delay_ms", 900) / 1000.0
    jitter = cfg.get("jitter_ms", 600) / 1000.0
    retries = cfg.get("retries", 3)
    lines, errors = [], []

    for i, (term, cid) in enumerate(pairs, 1):
        rows, why = navigate_probe(browser, cfg, term, agent_src, retries)

        if rows is None:
            errors.append(f"{term}: {why}")
            print(f"  [{i}/{len(pairs)}] {term!r}: COULD NOT READ - {why[:90]}")
        else:
            dropped = corroborate_multipack_sizes(rows)
            lines.append({"id": cid, "term": term, "candidates": rows})
            note = f"  [{i}/{len(pairs)}] {term!r}: {len(rows)} candidate(s) -> {cid}"
            if dropped:
                # Named, never a silent count: a dropped size is a cell that may now go unfilled,
                # and the reader has to be able to see which product and why.
                note += f"  [{len(dropped)} size(s) dropped as uncorroborated]"
                for nm, sz, sl in dropped:
                    note += f"\n        - {nm}: '{sz}' vs URL '{sl}'"
            print(note)

        time.sleep(delay + random.uniform(0, jitter))

    if not lines:
        return False, (f"every term failed to read ({len(errors)} of {len(pairs)}) - capture NOT "
                       f"written. First: {errors[0] if errors else 'n/a'}")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        for ln in lines:
            fh.write(json.dumps(ln, ensure_ascii=False) + "\n")

    note = f"wrote {os.path.relpath(out_path, ROOT)} ({len(lines)} of {len(pairs)} term(s))"
    if errors:
        # Reported, never silently dropped: a partial capture is fine, a partial capture nobody
        # mentioned is how a term quietly stops being covered.
        note += f"; {len(errors)} unreadable: " + "; ".join(e[:60] for e in errors[:3])
    return True, note


def drive_paced_sweep(browser, cfg, name, terms, skey, timeout_min, sweep_expr=None):
    """Kick the store's own paced sweep off, poll it, and answer a wall. Returns (done, walled).

    Factored out of run_store 2026-08-24 for the D10 lookup lane, which differs from a capture in
    exactly ONE way - which localStorage key the sweep writes to - and in no way at all in how it
    talks to the store. A second copy of the wall handling is a second copy that can stop noticing
    a wall.
    """
    payload = json.dumps(list(terms))
    expr = sweep_expr or f"{cfg['sweep']}({payload}, {{}})"
    # Kick the sweep off WITHOUT awaiting it over the socket. awaitPromise would hold the
    # connection for the whole sweep, and a wall pause is unbounded - the driver has to stay
    # responsive enough to notice the wall and answer it.
    browser.js(
        "window.__tcRun = {done:false, err:null, summary:null};"
        f"(async () => {{ try {{ window.__tcRun.summary = await {expr}; }}"
        "  catch (e) { window.__tcRun.err = String((e && e.message) || e); }"
        "  finally { window.__tcRun.done = true; } })();"
    )

    deadline = time.time() + timeout_min * 60
    walled = False
    last_report = 0
    while time.time() < deadline:
        if browser.js("!!(window.__tcRun && window.__tcRun.done)"):
            break

        wall = browser.js("window.__tcWall ? JSON.stringify(window.__tcWall) : ''")
        if wall:
            w = json.loads(wall)
            detail = f"walled on term '{w.get('term')}' ({w.get('why')})"
            print(f"  WALL: {detail} - notifying Brad and stopping this store")
            notify_wall(name, detail)
            # Unattended: STOP rather than hang. Everything settled is already in localStorage,
            # so a later run (after he clears it) resumes at this exact term.
            browser.js("window.__tcResume = 'stop';")
            walled = True

        now = time.time()
        if now - last_report > 60:
            last_report = now
            try:
                key = json.dumps(skey)
                n = browser.js(f"Object.keys(JSON.parse(localStorage.getItem({key}) || '{{}}')).length")
                print(f"  ... {n} of {len(terms)} term(s) settled")
            except Exception:
                pass
        time.sleep(3)

    return bool(browser.js("!!(window.__tcRun && window.__tcRun.done)")), walled


def storage_key_of(cfg):
    """Read the agent's localStorage key OUT OF THE AGENT, and prove it matches what we expect.

    The key is how we count progress and how a resumed run finds its earlier work. Writing it down
    a second time here would be a copy that can drift silently: rename it in the JS and this file
    would go on reading an empty object and report "0 settled" forever, which reads like a dead
    sweep. So the JS source is the single copy and the value in STORES is an ASSERTION about it -
    if they ever disagree, that is a real defect and this says so instead of guessing.
    """
    src = js_file(cfg["agent"])
    m = re.search(r"const\s+\w*_?STORAGE_KEY\s*=\s*'([^']+)'", src)
    if not m:
        raise RuntimeError(f"{cfg['agent']} declares no *_STORAGE_KEY - cannot track sweep progress")
    found = m.group(1)
    if found != cfg["storage_key"]:
        raise RuntimeError(
            f"storage key drift: {cfg['agent']} now uses '{found}' but this driver expects "
            f"'{cfg['storage_key']}'. Update STORES, or progress and resume both break silently.")
    return found


# =====================================================================================================
# LOOKUP MODE (D10) - the same stores, asked a different question, writing nowhere near the capture
# estate. Read the LOOKUP MODE block in this file's header before changing anything below.
# =====================================================================================================

# The paced lane's verdicts go HERE, never under a store's capture key. sweepToCsv() exports every
# MATCHES term it finds under the capture key, so a hunter term left there would be published as a
# captured price by the next morning's run - the drill-writes-live class in a different costume.
LOOKUP_STORAGE_KEY = "TC_LOOKUP_SWEEP"

# Section 4.5's price-evidence contract caps hits at 8, the same cap probe-ingredient.ps1 applies.
LOOKUP_HIT_CAP = 8

# Stores this driver can actually look up for. Walmart is refused rather than paused-and-skipped,
# because a hunter asking for Walmart evidence must be TOLD the answer comes from Brad's Chrome.
LOOKUP_STORES = ("fareway", "samsclub")


def validate_lookup_args(store_keys, terms_file, out_path):
    """The flag contract, as a pure function so it can be proven without a browser.

    Returns (ok, message). Both flags or neither; exactly one store; that store must be lookup-able.
    """
    want = bool(terms_file) or bool(out_path)
    if not want:
        return True, ""
    if not (terms_file and out_path):
        return False, ("--lookup-terms-file and --lookup-out are legal ONLY together: one without "
                       "the other would either sweep with nowhere to report or report nothing swept.")
    if len(store_keys) != 1:
        return False, ("lookup mode needs exactly one explicit --store (got: "
                       f"{', '.join(store_keys) if store_keys else 'none - it does not default to all'}). "
                       "A lookup is a question about ONE store's shelf and its answer is filed per store.")
    k = store_keys[0]
    if k not in STORES:
        return False, f"unknown store '{k}'. Known: {', '.join(STORES)}"
    if k not in LOOKUP_STORES:
        cfg = STORES[k]
        paused = cfg.get("paused")
        if paused:
            return False, (f"{cfg['name']} is not looked up from this driver: PAUSED - {paused}. "
                           "Ask the pricer to attend it through Brad's Chrome; retrying it from here "
                           "is his call to make, never a side effect of a hunter batch.")
        return False, f"{cfg['name']} has no lookup lane here. Lookup-able: {', '.join(LOOKUP_STORES)}"
    return True, ""


def read_lookup_terms(path):
    """A JSON array of term strings. Returns (terms, why)."""
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            doc = json.load(fh)
    except Exception as e:
        return None, f"could not read the lookup term list at {path}: {e}"
    if not isinstance(doc, list):
        return None, f"{path} must hold a JSON ARRAY of term strings, got {type(doc).__name__}"
    terms = [str(t).strip() for t in doc if str(t).strip()]
    if not terms:
        return None, f"{path} holds no terms"
    return terms, None


def lookup_verdict(term, state, term_used="", attempts=None, hits=None, reason=""):
    """search-verdict-lib.ps1's New-SearchVerdict, serialized. Same three states, same field names -
    this is a SERIALIZATION of that contract, never a second definition of it."""
    assert state in ("MATCHES", "EMPTY", "UNUSABLE"), f"not a search state: {state}"
    return {"term": term, "state": state, "term_used": term_used or term,
            "attempts": list(attempts or []), "hits": list(hits or [])[:LOOKUP_HIT_CAP],
            "reason": reason}


def _num(v):
    """A price as a number, or None. NEVER 0 for 'no price' - a zero sorts cheapest and wins a cell."""
    try:
        t = str(v).replace("$", "").replace(",", "").strip()
        return float(t) if t else None
    except Exception:
        return None


def _fareway_hits(rows):
    """farewayShopExtract rows -> section 4.5 hits.

    `relevance` is deliberately null: probe-ingredient's relevance is a PowerShell sort hint and
    porting its formula here would fork a heuristic across two languages. These rows arrive in the
    store's own ranking, which is the honest hint, and relevance is never a verdict anyway.
    """
    out = []
    for r in rows or []:
        out.append({"item": str(r.get("name") or "").strip(),
                    "price": _num(r.get("price")),
                    "size": str(r.get("size") or r.get("unit") or ""),
                    "relevance": None,
                    "url": str(r.get("url") or "")})
    return out[:LOOKUP_HIT_CAP]


def _sams_hits(rows):
    """samsProbe rows (n/lp/up/id/was) -> section 4.5 hits, plus the club's own unit price.

    `unit_price` is the one field beyond the five: Sam's rows carry no pack size at all, and its
    unit price is exactly what an adjudicator compares a club pack against. Evidence, never a
    verdict (AS-BUILT note in section 4.5).
    """
    out = []
    for r in rows or []:
        out.append({"item": str(r.get("n") or "").strip(),
                    "price": _num(r.get("lp")),
                    "size": "",
                    "unit_price": str(r.get("up") or ""),
                    "relevance": None,
                    "url": (f"https://www.samsclub.com/p/-/{r.get('id')}" if r.get("id") else "")})
    return out[:LOOKUP_HIT_CAP]


RUNG1 = ("rung 1 only - this driver searches the term AS GIVEN and never walks search-verdict-lib's "
         "retry ladder. EMPTY here permits not-carried ONLY after the pricer completes the ladder.")


def write_lookup(out_path, store_key, verdicts, note=""):
    """The lookup output file. One writer, one path, per store per batch - no lock needed."""
    cfg = STORES[store_key]
    doc = {"store": cfg["name"], "store_key": store_key,
           "generated": datetime.datetime.now().isoformat(timespec="seconds"),
           "ladder": RUNG1, "note": note, "results": list(verdicts)}
    d = os.path.dirname(os.path.abspath(out_path))
    if d:
        os.makedirs(d, exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=1)
    return doc


def write_lookup_unusable(out_path, store_key, terms, reason):
    """The degrade path, and the whole reason lookup mode can be trusted by a caller that must not
    block: NEEDS-SEEDING, a wall, a dead CDP or a crash all reach the caller as UNUSABLE for every
    term, with the failure as the reason. Could-not-look never reads as EMPTY."""
    return write_lookup(out_path, store_key,
                        [lookup_verdict(t, "UNUSABLE", reason=reason) for t in terms],
                        note="store UNUSABLE for the whole batch")


def run_lookup_navigate(browser, cfg, terms, agent_src):
    """Fareway: navigate per term, read the Apollo cache, one rung, no capture file.

    FAREWAY RARELY REPORTS EMPTY, AND THAT IS CORRECT. farewayShopExtract THROWS when the cache
    holds no priced nodes, which is the same signal as "has not hydrated yet" - the extractor
    refuses to tell blindness and emptiness apart, so this lane does not either, and the honest
    state for an unreadable page is UNUSABLE (which reads PENDING). Its MATCHES rows come from the
    whole page cache and may include suggestion tiles, which is exactly what the pricer adjudicates.
    """
    delay = cfg.get("delay_ms", 900) / 1000.0
    jitter = cfg.get("jitter_ms", 600) / 1000.0
    retries = cfg.get("retries", 3)
    out = []
    for i, term in enumerate(terms, 1):
        rows, why = navigate_probe(browser, cfg, term, agent_src, retries)
        if rows is None:
            out.append(lookup_verdict(term, "UNUSABLE",
                                      attempts=[{"term": term, "state": "UNUSABLE", "hits": 0}],
                                      reason=f"could not read the page: {why[:160]}"))
            print(f"  [{i}/{len(terms)}] {term!r}: UNUSABLE - {why[:80]}")
        else:
            hits = _fareway_hits(rows)
            out.append(lookup_verdict(term, "MATCHES" if hits else "EMPTY",
                                      attempts=[{"term": term, "state": "OK", "hits": len(rows)}],
                                      hits=hits,
                                      reason=(RUNG1 + " Rows are the page's priced Apollo nodes and may "
                                              "include suggestion tiles - adjudicate.")))
            print(f"  [{i}/{len(terms)}] {term!r}: {len(rows)} candidate(s)")
        time.sleep(delay + random.uniform(0, jitter))
    return out


def run_lookup_paced(browser, cfg, name, terms, timeout_min):
    """Sam's Club: the store's OWN paced sweep, pointed at a lookup-scoped localStorage key.

    THE SAM'S PRECONDITION IS THIS RUN. There is no separate session probe and there must not be
    one: an unseeded or logged-out profile fails samsIdentity() upstream of here and the store ends
    NEEDS-SEEDING with nothing captured. The puller owns the session and is the only honest source
    on it.
    """
    handle = cfg.get("lookup_agent")
    if not handle:
        # Same discipline as _identity_call: a driver that cannot name what it is about to run
        # refuses, rather than substituting something that cannot fail.
        raise RuntimeError(f"no lookup_agent declared for {name} - refusing to guess the agent object")
    key = json.dumps(LOOKUP_STORAGE_KEY)
    # Start clean. The key is on a PERSISTENT profile, so last batch's verdicts would otherwise be
    # resumed as this batch's evidence, and stale evidence is worse than none.
    browser.js(f"localStorage.removeItem({key});")
    expr = (f"runPacedSweep(Object.assign({{}}, {handle}, {{storageKey: {key}}}), "
            f"{json.dumps(list(terms))}, {{}})")
    done, walled = drive_paced_sweep(browser, cfg, name, terms, LOOKUP_STORAGE_KEY, timeout_min,
                                     sweep_expr=expr)
    raw = browser.js(f"localStorage.getItem({key}) || '{{}}'")
    try:
        res = json.loads(raw)
    except Exception:
        res = {}
    err = browser.js("(window.__tcRun && window.__tcRun.err) || ''") or ""
    # Leave nothing behind: this key lives on the persistent capture profile.
    browser.js(f"localStorage.removeItem({key});")

    out = []
    for t in terms:
        r = res.get(t)
        if not r:
            why = "the sweep never reached this term"
            if walled:
                why += " (stopped by a bot wall)"
            elif not done:
                why += f" (timed out after {timeout_min} min)"
            elif err:
                why += f" ({err[:120]})"
            out.append(lookup_verdict(t, "UNUSABLE", attempts=[], reason=why))
            continue
        v = str(r.get("v") or "UNUSABLE")
        if v not in ("MATCHES", "EMPTY", "UNUSABLE"):
            v = "UNUSABLE"
        rows = r.get("rows") or []
        reason = str(r.get("why") or "")
        out.append(lookup_verdict(t, v, attempts=[{"term": t, "state": v, "hits": len(rows)}],
                                  hits=_sams_hits(rows) if v == "MATCHES" else [],
                                  reason=(reason + "  " + RUNG1) if v != "UNUSABLE"
                                  else (reason or "blocked")))
    return out


def run_store(store_key, date_s, headless=False, seed=False, timeout_min=40, slot=None,
              lookup=None):
    """Capture one store. Returns (ok: bool, note: str).

    slot: when several stores run at once, the index of this lane. It only decides where the
    window is parked - each lane is otherwise fully independent already (its own persistent
    profile, its own OS-assigned debug port, its own worklist and its own output file), which
    is what makes running them together safe rather than merely faster.

    lookup: {"terms": [...], "out": <path>} puts this store in LOOKUP MODE (see the header block).
    Everything up to and including the identity assertion is IDENTICAL - same profile, same seeded
    check, same agent, same patience. Only the question and the destination change: no worklist is
    read and no capture file is written.
    """
    cfg = STORES[store_key]
    name = cfg["name"]

    # A store marked never_headless is FORCED visible rather than refused: refusing would mean the
    # 08:00 job silently skips it forever if anything ever passes --headless, which is the failure
    # this flag exists to prevent. Say so in the output so the override is never invisible.
    if cfg.get("never_headless") and headless:
        print(f"  note: {name} cannot run headless (it walls instantly) - running visible instead.")
        headless = False
    prof = profile_dir(store_key)
    seeded_marker = os.path.join(prof, ".tc-seeded")

    # A PAUSED STORE IS SKIPPED, NOT ATTEMPTED. Reported as outstanding so it stays visible on the
    # browser flag and in the watchdog, but never probed - a store that cannot currently return a
    # price should not spend request budget every morning proving it again.
    if not seed and cfg.get("paused"):
        return True, f"skipped: PAUSED - {cfg['paused']}"

    if not seed and not os.path.exists(seeded_marker):
        return False, (f"NEEDS SEEDING: no seeded Chrome profile for {name}. Run "
                       f"`pull-browser-stores.py --store {store_key} --seed` once, {cfg['seed_hint']}")

    navigate_lane = cfg.get("lane") == "navigate"
    pairs = None
    if seed:
        terms, why = None, None
    elif lookup:
        # THE DAILY WORKLIST IS NOT READ IN LOOKUP MODE. It is not merely unnecessary: a lookup that
        # fell back to the worklist would sweep today's capture terms and file them as hunter
        # evidence, and one that WROTE one would destroy the day's real worklist.
        terms, why = list(lookup["terms"]), None
    elif navigate_lane:
        pairs, why = read_worklist_pairs(store_key, date_s)
        terms = [t for t, _ in pairs] if pairs else None
    else:
        terms, why = read_worklist(store_key, date_s)
    if not seed and terms is None:
        return True, f"skipped: {why}"

    print(f"\n=== {name} ===")
    if not seed:
        kind = "lookup" if lookup else "worklist"
        print(f"  {kind}: {len(terms)} term(s)" + ("  [navigate lane]" if navigate_lane else ""))

    # Prove the agent/driver contract BEFORE launching a browser: a drift here is a code defect and
    # should cost nothing to discover. The navigate lane has no localStorage sweep, so no key.
    skey = ""
    if not seed and not navigate_lane:
        try:
            skey = storage_key_of(cfg)
        except Exception as e:
            return False, str(e)

    release_profile(prof)
    # Parked off-screen when this is one of several concurrent lanes, so two visible browsers do
    # not fight over focus while Brad is working. Seeding is ATTENDED - he has to see and drive
    # that window - so a seed run is never parked.
    win_pos = None if (seed or slot is None) else (-2400, -2400 + (slot * 40))
    browser = Chrome(headless=headless, width=1440, height=900, dsf=1.0,
                     profile_dir=prof, mobile=False, browsing=True, window_position=win_pos)
    try:
        browser.start()
    except Exception as e:
        # Say what this almost always means, rather than leaving the raw CDP message to be
        # interpreted. "Never opened a debugging port" reads as a broken driver; nine times out of
        # ten it is a Chrome window still holding the profile.
        return False, (f"could not start Chrome: {e}. If this persists, close any Chrome window "
                       f"opened from {os.path.relpath(prof, ROOT)} and try again.")

    try:
        browser.goto(cfg["origin"], wait_ms=4000)

        if seed:
            # SEEDING SAVES ITSELF WHEN THE STORE IS PROVABLY RIGHT - it does not wait on a keypress.
            # An input() prompt means seeding only works from a terminal someone is watching, and it
            # also saves on a keypress rather than on evidence: press Enter with the wrong store
            # selected and you have blessed the wrong store. Polling the agent's OWN assertIdentity()
            # means the marker is written because the page proved the Omaha store, not because a
            # human said so. Walmart is the exception it cannot cover (nothing to assert), so that
            # one gets a dwell instead - stated plainly rather than dressed up as verification.
            # INJECTED SCRIPTS DO NOT SURVIVE NAVIGATION, AND SEEDING IS ALL NAVIGATION.
            # Picking a store reloads the page (Fareway and Sam's both do a full navigation), which
            # wipes anything evaluated into the old document. A first version injected once before
            # the loop, so from the operator's very first click every poll returned
            # "REFUSED: farewayIdentity is not defined" and the profile could never be seeded - a
            # bug that would have made this whole feature look broken on first use.
            # addScriptToEvaluateOnNewDocument re-installs both files on EVERY document, so the
            # identity check is available no matter how far the operator navigates. The explicit
            # inject below covers the page that is already open.
            agent_src = js_file("pull-agent-lib.js") + "\n;\n" + js_file(cfg["agent"])
            call = _identity_call(cfg)
            identity_fn = call.split("(")[0]
            browser.on_new_document(agent_src)
            ensure_agent(browser, agent_src, identity_fn)
            print(f"  SEEDING {name}. A Chrome window is open.")
            print(f"  Do this now: {cfg['seed_hint']}")
            print("  This saves ITSELF as soon as the page proves the right store. Ctrl-C to abort.")

            dwell_until = time.time() + 20     # give a person time to act before the first verdict
            deadline = time.time() + 15 * 60
            last = ""
            while time.time() < deadline:
                # Belt and braces: if a page somehow loaded without the on-new-document hook (a
                # cross-origin sign-in redirect, say), put the agent back before judging. Judging a
                # page that has no identity function would report "not defined" as if it were the
                # store's answer.
                try:
                    if not browser.js(f"typeof {identity_fn} === 'function'"):
                        ensure_agent(browser, agent_src, identity_fn)
                except Exception:
                    pass
                verdict = browser.js(
                    "(function(){ try { %s; return 'OK'; } "
                    "catch(e){ return 'REFUSED: ' + String((e&&e.message)||e).slice(0,160); } })()" % call
                )
                if verdict == "OK" and time.time() >= dwell_until:
                    os.makedirs(prof, exist_ok=True)
                    with open(seeded_marker, "w", encoding="utf-8") as fh:
                        fh.write(f"seeded {datetime.datetime.now().isoformat()}\n"
                                 f"{cfg['seed_hint']}\n"
                                 f"identity at seed time: {call} -> OK\n")
                    return True, "profile seeded (store proved by the agent's own identity check)"
                if verdict != last:
                    last = verdict
                    print(f"    {verdict}")
                time.sleep(3)
            return False, "seeding timed out after 15 min - the store was never provably correct"

        # Inject the shared library first, then the store agent. Both are plain scripts that define
        # globals; evaluating them in order is exactly the "paste lib, then paste agent" contract
        # their own headers describe.
        # Registered for every document as well as the current one. The sweep itself works by
        # same-origin fetch and should not navigate, but a store that bounces us through an
        # interstitial would otherwise land on a page with no agent on it.
        agent_src = js_file("pull-agent-lib.js") + "\n;\n" + js_file(cfg["agent"])
        if cfg.get("extra_agent"):
            agent_src += "\n;\n" + js_file(cfg["extra_agent"])
        browser.on_new_document(agent_src)
        probe_fn = cfg["extract"] if navigate_lane else cfg["sweep"]
        ensure_agent(browser, agent_src, probe_fn)

        # THE AGENT MUST ACTUALLY BE THERE. If the injection silently failed, the call below would
        # throw a ReferenceError that reads like a store problem rather than a load problem.
        if not browser.js(f"typeof {probe_fn} === 'function'"):
            return False, f"agent did not load: {probe_fn} is not defined after injecting {cfg['agent']}"

        # IDENTITY BEFORE EITHER LANE, AND WAIT FOR IT.
        # The navigate lane never enters runPacedSweep, so its identity check has to be made here.
        # The PACED lane does call assertIdentity() itself - but it calls it once, the instant the
        # sweep starts, which is too early on a client-rendered header (see wait_for_identity).
        # Proving it here first means the sweep's own assertion is a formality that cannot fail for
        # a timing reason, while still failing for a real one.
        ok, verdict = wait_for_identity(browser, _identity_call(cfg))
        if not ok:
            return False, f"identity check failed - {verdict}"

        # LOOKUP MODE BRANCHES HERE - AFTER the identity assertion and before anything that
        # touches the capture estate. Everything above this line is the daily capture's own
        # preparation, unchanged, which is the point: the hunter gets the same proven approach to
        # the store, not a second one written beside it.
        if lookup:
            if navigate_lane:
                verdicts = run_lookup_navigate(browser, cfg, terms, agent_src)
            else:
                verdicts = run_lookup_paced(browser, cfg, name, terms, timeout_min)
            write_lookup(lookup["out"], store_key, verdicts)
            tally = {}
            for v in verdicts:
                tally[v["state"]] = tally.get(v["state"], 0) + 1
            note = (f"lookup wrote {os.path.basename(lookup['out'])} ("
                    + ", ".join(f"{k} {n}" for k, n in sorted(tally.items())) + ")")
            # A batch nobody could read is a FAILED store even though the file was written: the
            # caller degrades on it, and the run's own exit code must still say it went wrong.
            ok = any(v["state"] != "UNUSABLE" for v in verdicts)
            return ok, note if ok else note + " - every term UNUSABLE"

        if navigate_lane:
            out_path = os.path.join(ROOT, cfg["capture"].format(date=date_s))
            return run_navigate_lane(browser, cfg, pairs, out_path, agent_src)

        done, walled = drive_paced_sweep(browser, cfg, name, terms, skey, timeout_min)
        if not done:
            return False, f"timed out after {timeout_min} min (partial results kept for the next run)"

        err = browser.js("window.__tcRun.err || ''")
        summary_raw = browser.js("window.__tcRun.summary ? JSON.stringify(window.__tcRun.summary) : ''")

        if err and not summary_raw:
            # assertIdentity failures land here and are the important ones: they mean the profile
            # is on the wrong store or logged out, NOT that the store has no prices.
            return False, f"sweep failed: {err}"

        out_rel = cfg["capture"].format(date=date_s)
        out_path = os.path.join(ROOT, out_rel)
        os.makedirs(os.path.dirname(out_path), exist_ok=True)

        body = browser.js(f"{cfg['to_csv']}()") or ""
        if not body.strip():
            # BLINDNESS IS NOT EMPTINESS - AND THE DRIVER MUST SAY WHICH (fixed 2026-08-22).
            # This used to report every empty capture as "sweep produced no rows", collapsing three
            # different outcomes into one sentence: a store that genuinely lists nothing, a store we
            # were BLOCKED from reading, and a broken parser. The agents are scrupulous about this
            # distinction - EMPTY is a claim about the store, UNUSABLE is a claim about us - and the
            # driver was throwing that away at the last step. Measured the day it was fixed: Walmart
            # reported "produced no rows" when every term had settled UNUSABLE/bot-wall, and the real
            # answer had to be recovered by grepping the profile's LevelDB off disk.
            counts = {}
            why = ""
            try:
                s = json.loads(summary_raw) if summary_raw else {}
                counts = {k: s.get(k) for k in ("matches", "empty", "unusable") if s.get(k) is not None}
                blocked = browser.js(
                    "(function(){ try { const r = JSON.parse(localStorage.getItem(%s)||'{}');"
                    "  for (const k in r) if (r[k] && r[k].v === 'UNUSABLE') return String(r[k].why||'blocked');"
                    "  return ''; } catch(e){ return ''; } })()" % json.dumps(skey))
                why = blocked or ""
            except Exception:
                pass
            if counts.get("unusable"):
                detail = f"{counts['unusable']} term(s) UNUSABLE" + (f" ({why})" if why else "")
                if why and "wall" in why.lower():
                    notify_wall(name, f"every term blocked - {why}")
                return False, (f"BLOCKED, not empty: {detail}. Capture NOT written - recording this as "
                               f"'no products' would retire real cells. Counts: {counts}")
            return False, (f"sweep produced no rows and nothing reported as blocked - suspect the parser, "
                           f"not the store. Counts: {counts}. Capture NOT written.")

        # HEADER, AND PROVE IT FITS. sweepToCsv emits data rows only; Import-Csv needs a header or it
        # eats the first product as one. Worse than missing is WRONG: Sam's captures carried five
        # columns until `was` was added for the rollback TTL on 2026-08-21, and a five-name header
        # over six-column data does not error - it shifts every field one place, so a product id
        # lands in the price column and the row still looks like a row.
        header = cfg.get("csv_header")
        if not header:
            return False, f"no csv_header declared for {name} - refusing to write an unparseable capture"
        cols = len(header.split("|"))
        first = body.strip().split("\n")[0]
        got = len(first.split("|"))
        if got != cols:
            return False, (f"capture shape drift: {cfg['to_csv']}() emits {got} columns but the declared "
                           f"header '{header}' names {cols}. Refusing to write - a mismatched header "
                           f"silently shifts every field rather than failing.")
        with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(header + "\n")
            fh.write(body if body.endswith("\n") else body + "\n")

        summary = json.loads(summary_raw) if summary_raw else {}
        m = summary.get("matches", "?")
        e_ = summary.get("empty", "?")
        u = summary.get("unusable", "?")
        note = f"wrote {out_rel} (MATCHES {m}, EMPTY {e_}, UNUSABLE {u})"
        if walled:
            return False, note + " - STOPPED BY A BOT WALL, tail not captured"
        return True, note

    finally:
        try:
            browser.close()
        except Exception:
            pass


def lookup_self_test():
    """LOOKUP MODE's own fixtures. HERMETIC: no Chrome, no network, no capture file, no profile.

    What it proves is the set of things that, if they broke, would break quietly:
      * the flag contract refuses every illegal shape, and refuses Walmart WITH its pause note;
      * a lookup verdict is search-verdict-lib's three states and nothing else;
      * the lookup storage key is not any store's capture key (a lookup term left under a capture
        key is published as a captured price by the next morning's run);
      * the degrade path writes a readable all-UNUSABLE file rather than nothing;
      * lookup mode reads NO worklist, proven by making the worklist readers throw.
    """
    import tempfile
    print("lookup-mode self-test (hermetic: no browser, no network, no capture)")
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("    ok    " + name)
        else:
            print("    X     %s   got: %s" % (name, got))
            bad.append(name)

    # ---- the flag contract -------------------------------------------------------------------
    ok, why = validate_lookup_args(["fareway"], "t.json", "")
    T("MUST FIRE  --lookup-terms-file without --lookup-out is refused",
      not ok and "ONLY together" in why, why)
    ok, why = validate_lookup_args(["fareway"], "", "o.json")
    T("MUST FIRE  --lookup-out without --lookup-terms-file is refused",
      not ok and "ONLY together" in why, why)
    ok, why = validate_lookup_args([], "t.json", "o.json")
    T("MUST FIRE  lookup with NO explicit --store is refused - it never defaults to all",
      not ok and "exactly one explicit --store" in why, why)
    ok, why = validate_lookup_args(["fareway", "samsclub"], "t.json", "o.json")
    T("MUST FIRE  lookup with two stores is refused - one file, one store's shelf",
      not ok and "exactly one explicit --store" in why, why)
    ok, why = validate_lookup_args(["walmart"], "t.json", "o.json")
    T("MUST FIRE  Walmart is refused WITH its own pause note quoted, not silently skipped",
      not ok and "PAUSED" in why and "Brad's own Chrome" in why, why)
    ok, why = validate_lookup_args(["hyvee"], "t.json", "o.json")
    T("MUST FIRE  a store that has no driver lane at all (Hy-Vee) is refused as unknown",
      not ok and "unknown store" in why, why)
    for k in LOOKUP_STORES:
        ok, why = validate_lookup_args([k], "t.json", "o.json")
        T(f"CLEAN TWIN {k} with both flags is accepted", ok, why)
    ok, why = validate_lookup_args(["fareway"], "", "")
    T("CLEAN TWIN neither flag is a normal capture run, not a refusal", ok and not why, why)

    # ---- the verdict contract ----------------------------------------------------------------
    v = lookup_verdict("guacamole", "EMPTY", reason="none")
    T("a verdict carries exactly the search-verdict fields",
      sorted(v) == ["attempts", "hits", "reason", "state", "term", "term_used"], sorted(v))
    T("term_used defaults to the term as given (rung 1)", v["term_used"] == "guacamole", v["term_used"])
    try:
        lookup_verdict("x", "PENDING")
        T("MUST FIRE  a state outside MATCHES/EMPTY/UNUSABLE is refused", False, "accepted PENDING")
    except AssertionError:
        T("MUST FIRE  a state outside MATCHES/EMPTY/UNUSABLE is refused", True)
    T("MUST FIRE  hits are capped at 8 (section 4.5's cap, probe-ingredient's cap)",
      len(lookup_verdict("x", "MATCHES", hits=[{"item": str(i)} for i in range(20)])["hits"]) == 8)

    # ---- the key that must never collide -----------------------------------------------------
    clash = [k for k, c in STORES.items() if c.get("storage_key") == LOOKUP_STORAGE_KEY]
    T("MUST FIRE  the lookup storage key is NO store's capture key - sweepToCsv exports every "
      "MATCHES term under a capture key, so a hunter term left there would publish as a price",
      not clash, str(clash))

    # ---- row -> hit conversion (3+ rows, per the estate's collection-fixture rule) ------------
    fw = _fareway_hits([
        {"name": "Fareway Guacamole 8 oz", "price": "3.99", "size": "8 oz", "url": "u1"},
        {"name": "Wholly Guacamole Minis", "price": "5.49", "size": "", "unit": "$3.99 / lb", "url": "u2"},
        {"name": "No Price Row", "price": "", "size": "12 oz", "url": "u3"}])
    T("fareway rows become hits with a numeric price", fw[0]["price"] == 3.99, str(fw[0]))
    T("a rate lands in size when there is no pack size", fw[1]["size"] == "$3.99 / lb", str(fw[1]))
    T("MUST FIRE  a row with no honest price is None, NEVER 0 - a zero sorts cheapest and wins",
      fw[2]["price"] is None, str(fw[2]))
    sm = _sams_hits([
        {"n": "Member's Mark Guacamole", "lp": "$14.98", "up": "$0.09/oz", "id": "980123"},
        {"n": "Wholly Guacamole", "lp": "$12.48", "up": "", "id": "980124"},
        {"n": "Broken", "lp": "", "up": "", "id": ""}])
    T("sam's rows parse '$14.98' into a number", sm[0]["price"] == 14.98, str(sm[0]))
    T("sam's rows keep the club's own unit price as evidence", sm[0]["unit_price"] == "$0.09/oz", str(sm[0]))
    T("MUST FIRE  a sam's row with no line price is None, never 0", sm[2]["price"] is None, str(sm[2]))

    # ---- the degrade path --------------------------------------------------------------------
    tmp = tempfile.mkdtemp(prefix="lookup-selftest-")
    out = os.path.join(tmp, "deep", "batch-1-samsclub.json")
    write_lookup_unusable(out, "samsclub", ["a", "b", "c"], "NEEDS SEEDING: no seeded profile")
    doc = json.load(open(out, encoding="utf-8"))
    T("MUST FIRE  a store that could not be looked at writes every term UNUSABLE, with the reason",
      len(doc["results"]) == 3
      and all(r["state"] == "UNUSABLE" for r in doc["results"])
      and all("NEEDS SEEDING" in r["reason"] for r in doc["results"]),
      json.dumps(doc["results"])[:200])
    T("MUST FIRE  and never as EMPTY - could-not-look is not an empty shelf",
      not any(r["state"] == "EMPTY" for r in doc["results"]))
    T("the lookup file names the ladder it did NOT walk", "rung 1 only" in doc["ladder"], doc["ladder"])

    # ---- lookup mode reads no worklist -------------------------------------------------------
    global read_worklist, read_worklist_pairs, profile_dir, Chrome
    _rw, _rwp, _pd, _ch = read_worklist, read_worklist_pairs, profile_dir, Chrome

    def _boom(*a, **k):
        raise AssertionError("THE WORKLIST WAS READ IN LOOKUP MODE")

    class _DeadChrome(object):
        def __init__(self, *a, **k):
            pass

        def start(self):
            raise RuntimeError("stub: no browser in a hermetic fixture")

    prof = tempfile.mkdtemp(prefix="lookup-profile-")
    with open(os.path.join(prof, ".tc-seeded"), "w", encoding="utf-8") as fh:
        fh.write("fixture\n")
    read_worklist = _boom
    read_worklist_pairs = _boom
    profile_dir = lambda k: prof                                          # noqa: E731
    Chrome = _DeadChrome
    try:
        got = ""
        try:
            ok2, note = run_store("fareway", "2026-01-01", lookup={"terms": ["a", "b", "c"],
                                                                  "out": os.path.join(tmp, "x.json")})
            got = note
            fired = (not ok2) and "could not start Chrome" in note
        except AssertionError as e:
            fired, got = False, str(e)
        T("MUST FIRE  lookup mode reads NO worklist file - the readers throw and it never calls them",
          fired, got)
        try:
            run_store("fareway", "2026-01-01")
            T("CLEAN TWIN a normal capture run DOES read the worklist (so the fixture above can fire)",
              False, "the capture path did not read a worklist either")
        except AssertionError:
            T("CLEAN TWIN a normal capture run DOES read the worklist (so the fixture above can fire)",
              True)
    finally:
        read_worklist, read_worklist_pairs, profile_dir, Chrome = _rw, _rwp, _pd, _ch

    print(f"  LOOKUP-SELFTEST-COMPLETE checks={len(bad)}failed" if bad else
          "  LOOKUP-SELFTEST-COMPLETE failed=0")
    return len(bad)


def self_test(headless=False):
    r"""Prove the DRIVER<->AGENT plumbing without capturing anything.

    The expensive failure this guards against is a driver that launches, injects nothing useful, and
    reports a clean empty result - which downstream reads as "the store carries none of this". So
    this checks the three things that must be true before any capture can be trusted:

      1. pull-agent-lib.js + the store agent actually LOAD (the sweep and CSV functions exist).
      2. The storage key in this file still matches the one in the agent (resume/progress contract).
      3. assertIdentity() is REACHABLE and does its job - on a throwaway profile the store-scoped
         agents must REFUSE, because an unseeded profile is not provably the Omaha store.

    It writes no capture file and touches no persistent profile. A store that refuses here is
    PASSING: refusal on an unverified profile is the whole safety property.
    """
    print("driver self-test - injection, contract and identity refusal (captures nothing)")
    failures = lookup_self_test()
    print("")
    for key, cfg in STORES.items():
        print(f"\n  --- {cfg['name']} ---")
        # THE NAVIGATE LANE HAS NO SWEEP, NO CSV AND NO STORAGE KEY, AND THIS LOOP USED TO ASSUME
        # OTHERWISE (fixed 2026-08-24). Fareway has been the navigate lane since the storefront went
        # client-rendered, so `storage_key_of` raised KeyError('storage_key') and the suite reported
        # `FAIL 'storage_key'` for it - a message that reads like agent drift and is actually the
        # test asking a paced-lane question of a store that does not have one. The consequence was
        # worse than the noise: Fareway's REAL contract - that its extractor loads and is callable -
        # was never checked by anything, on one of the two stores D10's lookup mode drives.
        navigate_lane = cfg.get("lane") == "navigate"
        if not navigate_lane:
            try:
                found = storage_key_of(cfg)
                print(f"    ok    storage key agrees with {cfg['agent']} ({found})")
            except Exception as e:
                print(f"    FAIL  {e}")
                failures += 1
                continue
        else:
            missing = [k for k in ("extract", "search_url") if not cfg.get(k)]
            if missing:
                print(f"    FAIL  navigate lane declares no {', '.join(missing)}")
                failures += 1
                continue
            print(f"    ok    navigate lane declares {cfg['extract']}() and a search url")

        # Throwaway profile ON PURPOSE: this must never inherit a seeded session, or the identity
        # check below would pass for the wrong reason and prove nothing.
        b = Chrome(headless=headless, width=1440, height=900, dsf=1.0, mobile=False, browsing=True)
        try:
            b.start()
            b.goto(cfg["origin"], wait_ms=4000)
            b.js(js_file("pull-agent-lib.js"))
            b.js(js_file(cfg["agent"]))
            # The navigate lane's extractor lives in a SECOND file, and a run injects both. A
            # self-test that injected only the first would report the extractor missing on a store
            # where nothing is wrong.
            if cfg.get("extra_agent"):
                b.js(js_file(cfg["extra_agent"]))

            want = ([cfg["extract"]] if navigate_lane else [cfg["sweep"], cfg["to_csv"]])
            missing = [fn for fn in want if not b.js(f"typeof {fn} === 'function'")]
            if missing:
                print(f"    FAIL  agent loaded but these are not defined: {', '.join(missing)}")
                failures += 1
            else:
                print(f"    ok    {', '.join(fn + '()' for fn in want)} defined")

            # LOOKUP MODE'S OWN HANDLE, on the stores that have one. `lookup_agent` names a
            # page-global object this driver clones with a different storageKey; if it ever stopped
            # existing, lookup mode would throw at the first Sam's batch and nothing else would say
            # why.
            if key in LOOKUP_STORES and cfg.get("lookup_agent"):
                h = cfg["lookup_agent"]
                if b.js(f"typeof {h} === 'object' && !!{h} && typeof {h}.probe === 'function'"):
                    print(f"    ok    lookup mode can clone {h} (an agent object with a probe)")
                else:
                    print(f"    FAIL  {h} is not a usable agent object - lookup mode would throw")
                    failures += 1

            if not b.js("typeof runPacedSweep === 'function'"):
                print("    FAIL  pull-agent-lib.js did not load (runPacedSweep undefined)")
                failures += 1
            else:
                print("    ok    pull-agent-lib.js loaded (runPacedSweep defined)")

            # waitForOperator is the wall contract this driver polls. If it ever stops setting
            # __tcWall, a wall becomes invisible and the driver would sit until timeout.
            src = js_file("pull-agent-lib.js")
            if "__tcWall" in src and "__tcResume" in src:
                print("    ok    wall contract intact (__tcWall / __tcResume present)")
            else:
                print("    FAIL  pull-agent-lib.js no longer uses __tcWall/__tcResume - "
                      "this driver could not see or clear a bot wall")
                failures += 1

            verdict = b.js(
                "(function(){ try { %s; return 'NO-THROW'; } "
                "catch(e){ return 'REFUSED: ' + String((e&&e.message)||e).slice(0,120); } })()"
                % _identity_call(cfg)
            )
            if str(verdict).startswith("REFUSED"):
                print(f"    ok    identity guard refuses an unseeded profile -> {verdict}")
            elif key == "walmart":
                # Walmart's guard only asserts the origin (it has no store toggle), so NO-THROW is
                # legitimate there and must not be reported as a failure.
                print(f"    ok    identity guard reachable, returned {verdict} "
                      f"(expected: Walmart has no store toggle to assert)")
            else:
                # AND FOR EVERY OTHER STORE, NO-THROW IS A CAUTION, NOT A PASS (2026-08-24). This
                # line used to print the Walmart sentence for any store that did not refuse, which
                # reads as "checked and fine" on a store that has a club to prove. samsIdentity()
                # matches the WORD "Omaha" anywhere in the page text, so a cold profile the site
                # geolocates can satisfy it: it proves the ORIGIN, not the club and not the member
                # session. Not a failure here, because a stricter club assertion is a change to the
                # store agent rather than to this driver - and D10's Sam's precondition does not
                # lean on it: it leans on the seeded marker, and on a logged-out sweep failing to
                # produce rows (which reads UNUSABLE, which reads PENDING).
                print(f"    note  identity guard did NOT refuse an unseeded throwaway profile "
                      f"({verdict}). It proves the origin, not the club or the session - see the "
                      f"comment here before trusting it as a session check.")
        except Exception as e:
            print(f"    FAIL  {e}")
            failures += 1
        finally:
            try:
                b.close()
            except Exception:
                pass

    print(f"\nDRIVER-SELFTEST-COMPLETE stores={len(STORES)} lookup=hermetic failed={failures}")
    return 1 if failures else 0


def _identity_call(cfg):
    """The agent's identity function. Declared per store in STORES - never derived, never defaulted.

    THE BUG THIS REPLACES (2026-08-22) IS THE WORST KIND THIS DRIVER CAN HAVE.
    This used to look the name up by slicing the AGENT FILENAME - cfg["agent"].split("-")[1] - and
    fall back to the string "null" when that missed. For Walmart and Fareway the slice happened to
    match the STORES key. For Sam's Club it did not: "pull-sams-instore.js" yields "sams" while the
    key is "samsclub". So the lookup missed, the call became the literal `null`, and:

        (function(){ try { null; return 'OK'; } catch(e){ ... } })()   ->   'OK', always.

    Sam's identity was therefore never checked AT ALL. Worse, seeding reported "profile seeded
    (store proved by the agent's own identity check)" on the strength of it - a marker written
    against a check that could not fail, on the one store where the club genuinely is ambiguous and
    prices differ per club. A guard whose miss path is a no-op does not fail loudly, it PASSES
    quietly, and everything downstream inherits that false confidence
    ([[fallback-tests-absence-not-function]]).

    So: the name is declared alongside the store it belongs to, and an unknown store RAISES. A driver
    that cannot name the check it is about to run must refuse to run it, not substitute a pass.
    """
    fn = cfg.get("identity")
    if not fn:
        raise RuntimeError(
            f"no identity function declared for {cfg.get('name', '?')} - refusing to proceed. "
            "An unverified store is exactly what this driver exists to prevent.")
    return fn


def main():
    ap = argparse.ArgumentParser(description="Drive the bot-walled grocery stores in a real Chrome.")
    ap.add_argument("--sequential", action="store_true",
                    help="drive the stores one at a time (the pre-2026-08-23 behaviour). "
                         "Seeding is always sequential regardless.")
    ap.add_argument("--store", action="append",
                    help="store key (walmart, samsclub, fareway). Repeatable. Default: all.")
    ap.add_argument("--date", default="", help="capture date (yyyy-MM-dd). Default: today.")
    ap.add_argument("--seed", action="store_true",
                    help="interactive: open the store so a human can set the Omaha store/club, then save the profile.")
    ap.add_argument("--headless", action="store_true",
                    help="run headless. NOT recommended - these stores detect it and have walled us before.")
    ap.add_argument("--timeout-min", type=int, default=40)
    ap.add_argument("--lookup-terms-file", default="",
                    help="LOOKUP MODE (see the header): a JSON array of terms to search. Legal only "
                         "with --lookup-out and an explicit --store fareway|samsclub. Reads no "
                         "worklist and writes no capture file.")
    ap.add_argument("--lookup-out", default="",
                    help="LOOKUP MODE: where the per-term search verdicts are written.")
    ap.add_argument("--selftest", action="store_true",
                    help="prove the driver<->agent plumbing on a throwaway profile. Captures nothing.")
    ap.add_argument("--selftest-lookup", action="store_true",
                    help="lookup mode's hermetic fixtures only - no browser, no network at all.")
    args = ap.parse_args()

    if args.selftest_lookup:
        return 1 if lookup_self_test() else 0
    if args.selftest:
        return self_test(headless=args.headless)

    date_s = today_str(args.date)
    keys = args.store or list(STORES.keys())
    bad = [k for k in keys if k not in STORES]
    if bad:
        print(f"unknown store(s): {', '.join(bad)}. Known: {', '.join(STORES)}")
        return 2

    # LOOKUP MODE IS REFUSED BEFORE ANYTHING OPENS. A malformed lookup must never fall through to a
    # capture run: the flags that separate the two are the only thing standing between a hunter
    # batch and the day's real worklist.
    lookup = None
    lok, lwhy = validate_lookup_args(args.store or [], args.lookup_terms_file, args.lookup_out)
    if not lok:
        print(f"REFUSED: {lwhy}")
        return 2
    if args.lookup_terms_file:
        lterms, lwhy = read_lookup_terms(args.lookup_terms_file)
        if lterms is None:
            print(f"FATAL: {lwhy}")
            return 2
        lookup = {"terms": lterms, "out": args.lookup_out}

    try:
        find_chrome()
    except Exception as e:
        print(f"FATAL: {e}")
        if lookup:
            # Degrade, never go silent: the caller reads UNUSABLE and hands the store to a human.
            write_lookup_unusable(lookup["out"], keys[0], lookup["terms"], f"no Chrome: {e}")
        return 2

    if lookup:
        print(f"browser LOOKUP  -  {STORES[keys[0]]['name']}  -  {len(lookup['terms'])} term(s)  "
              f"-  out: {args.lookup_out}")
    else:
        print(f"browser pull  -  {date_s}  -  stores: {', '.join(keys)}")

    # ONE THREAD PER STORE (2026-08-23). This was a sequential loop, so the browser stage cost the
    # SUM of its lanes when it only ever needed to cost the slowest one. Nothing about a lane is
    # shared: profile_dir() already gives each store its own persistent Chrome profile (and says
    # why - a wall or a logout at one store must not take the others with it), cdp.free_port()
    # binds :0 so the OS hands out a distinct debug port per launch, the worklist and the output
    # path are both keyed by store, and release_profile() is deliberately narrow-matched to ONE
    # profile path, so no lane can kill another lane's Chrome - or Brad's.
    #
    # SEEDING STAYS SEQUENTIAL. It is an attended operation: Brad has to watch and drive the
    # window, which he cannot do for two at once, and a seed run is never parked off-screen.
    #
    # --sequential is the escape hatch. If a lane ever turns flaky under concurrency, the old
    # behaviour is one flag away rather than one revert away.
    results = {}
    run_together = (len(keys) > 1) and (not args.seed) and (not args.sequential)

    def _one(k, slot):
        try:
            return run_store(k, date_s, headless=args.headless, seed=args.seed,
                             timeout_min=args.timeout_min, slot=slot, lookup=lookup)
        except Exception as e:
            return False, f"threw: {e}"

    if run_together:
        import concurrent.futures as _cf
        with _cf.ThreadPoolExecutor(max_workers=len(keys)) as ex:
            futs = {ex.submit(_one, k, i): k for i, k in enumerate(keys)}
            for f in _cf.as_completed(futs):
                results[futs[f]] = f.result()
    else:
        for k in keys:
            results[k] = _one(k, None)

    # THE LOOKUP FILE ALWAYS EXISTS WHEN THIS RETURNS. NEEDS-SEEDING, a wall before the first
    # term, a Chrome that would not start, a crash inside the lane - every one of them lands here
    # with the failure as the reason for every term, because a caller that must not block needs to
    # read UNUSABLE rather than to guess at silence. (A process killed outright leaves no file at
    # all; that case belongs to the caller, and the daemon reads a missing file as UNUSABLE too.)
    if lookup and not os.path.exists(lookup["out"]):
        _ok, _note = results[keys[0]]
        write_lookup_unusable(lookup["out"], keys[0], lookup["terms"], _note)
        print(f"  wrote an all-UNUSABLE lookup file: {_note}")

    # PRINTED IN THE ORDER ASKED FOR, NOT THE ORDER FINISHED. Concurrent lanes interleave their own
    # progress output, so this summary is the one stable thing a reader (and capture-run's parser)
    # can rely on.
    for k in keys:
        ok, note = results[k]
        print(f"  {STORES[k]['name']:<12} {'ok  ' if ok else 'FAIL'} {note}")

    failed = [k for k, (ok, _) in results.items() if not ok]
    print("\nBROWSER-PULL-COMPLETE stores={} failed={}".format(len(keys), len(failed)))
    if failed:
        print("FAILED: " + ", ".join(f"{k} ({results[k][1]})" for k in failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
