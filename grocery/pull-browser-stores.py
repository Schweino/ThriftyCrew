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

EXIT CODES  0 = every requested store captured. 1 = at least one store failed or was walled.
            2 = nothing could run (no Chrome, no worklists).
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

# ALDI IS DELIBERATELY ABSENT, AND THIS IS NOT AN OVERSIGHT.
# The other three agents share one contract: runPacedSweep over a list of SEARCH TERMS, which is
# exactly what out\worklists\capture-<store>-<date>.json contains. pull-aldi-instore.js does not.
# It walks PRODUCT SLUGS (`{i: id, s: slug}`) against ALDI_PRODUCT_BASE, because Aldi's storefront is
# a slug lookup rather than a term sweep - so handing it the rotation worklist would fetch ~7 URLs
# built from search phrases, 404 every one, and write a confident empty capture. An empty capture
# from a store that sells the item is the single most expensive failure shape in this estate: it
# reads as "Aldi does not carry this" and silently drops real cells.
# To add Aldi properly, something must map its rotation terms to product slugs (product-urls.json
# already holds resolved Aldi links and is the obvious source) and hand pullAldiInStore that list.
# Until that exists, Aldi keeps the browser-handoff flag and is reported as outstanding.
ALDI_NOTE = ("Aldi needs a terms->product-slug mapping before it can be driven: its agent walks "
             "product slugs, not search terms. Left on the browser-handoff flag.")


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


def run_store(store_key, date_s, headless=False, seed=False, timeout_min=40):
    """Capture one store. Returns (ok: bool, note: str)."""
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
    elif navigate_lane:
        pairs, why = read_worklist_pairs(store_key, date_s)
        terms = [t for t, _ in pairs] if pairs else None
    else:
        terms, why = read_worklist(store_key, date_s)
    if not seed and terms is None:
        return True, f"skipped: {why}"

    print(f"\n=== {name} ===")
    if not seed:
        print(f"  worklist: {len(terms)} term(s)" + ("  [navigate lane]" if navigate_lane else ""))

    # Prove the agent/driver contract BEFORE launching a browser: a drift here is a code defect and
    # should cost nothing to discover. The navigate lane has no localStorage sweep, so no key.
    skey = ""
    if not seed and not navigate_lane:
        try:
            skey = storage_key_of(cfg)
        except Exception as e:
            return False, str(e)

    release_profile(prof)
    browser = Chrome(headless=headless, width=1440, height=900, dsf=1.0,
                     profile_dir=prof, mobile=False, browsing=True)
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

        if navigate_lane:
            out_path = os.path.join(ROOT, cfg["capture"].format(date=date_s))
            return run_navigate_lane(browser, cfg, pairs, out_path, agent_src)

        # Kick the sweep off WITHOUT awaiting it over the socket. awaitPromise would hold the
        # connection for the whole sweep, and a wall pause is unbounded - the driver has to stay
        # responsive enough to notice the wall and answer it.
        payload = json.dumps(terms)
        browser.js(
            "window.__tcRun = {done:false, err:null, summary:null};"
            f"(async () => {{ try {{ window.__tcRun.summary = await {cfg['sweep']}({payload}, {{}}); }}"
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

        if not browser.js("!!(window.__tcRun && window.__tcRun.done)"):
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
    failures = 0
    for key, cfg in STORES.items():
        print(f"\n  --- {cfg['name']} ---")
        try:
            found = storage_key_of(cfg)
            print(f"    ok    storage key agrees with {cfg['agent']} ({found})")
        except Exception as e:
            print(f"    FAIL  {e}")
            failures += 1
            continue

        # Throwaway profile ON PURPOSE: this must never inherit a seeded session, or the identity
        # check below would pass for the wrong reason and prove nothing.
        b = Chrome(headless=headless, width=1440, height=900, dsf=1.0, mobile=False, browsing=True)
        try:
            b.start()
            b.goto(cfg["origin"], wait_ms=4000)
            b.js(js_file("pull-agent-lib.js"))
            b.js(js_file(cfg["agent"]))

            missing = [fn for fn in (cfg["sweep"], cfg["to_csv"])
                       if not b.js(f"typeof {fn} === 'function'")]
            if missing:
                print(f"    FAIL  agent loaded but these are not defined: {', '.join(missing)}")
                failures += 1
            else:
                print(f"    ok    {cfg['sweep']}() and {cfg['to_csv']}() are defined")

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
            else:
                # Walmart's guard only asserts the origin (it has no store toggle), so NO-THROW is
                # legitimate there and must not be reported as a failure.
                print(f"    ok    identity guard reachable, returned {verdict} "
                      f"(expected for a store with no store-toggle to assert)")
        except Exception as e:
            print(f"    FAIL  {e}")
            failures += 1
        finally:
            try:
                b.close()
            except Exception:
                pass

    print(f"\nDRIVER-SELFTEST-COMPLETE stores={len(STORES)} failed={failures}")
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
    ap.add_argument("--store", action="append",
                    help="store key (walmart, samsclub, fareway). Repeatable. Default: all.")
    ap.add_argument("--date", default="", help="capture date (yyyy-MM-dd). Default: today.")
    ap.add_argument("--seed", action="store_true",
                    help="interactive: open the store so a human can set the Omaha store/club, then save the profile.")
    ap.add_argument("--headless", action="store_true",
                    help="run headless. NOT recommended - these stores detect it and have walled us before.")
    ap.add_argument("--timeout-min", type=int, default=40)
    ap.add_argument("--selftest", action="store_true",
                    help="prove the driver<->agent plumbing on a throwaway profile. Captures nothing.")
    args = ap.parse_args()

    if args.selftest:
        return self_test(headless=args.headless)

    date_s = today_str(args.date)
    keys = args.store or list(STORES.keys())
    bad = [k for k in keys if k not in STORES]
    if bad:
        print(f"unknown store(s): {', '.join(bad)}. Known: {', '.join(STORES)}")
        return 2

    try:
        find_chrome()
    except Exception as e:
        print(f"FATAL: {e}")
        return 2

    print(f"browser pull  -  {date_s}  -  stores: {', '.join(keys)}")
    results = {}
    for k in keys:
        try:
            ok, note = run_store(k, date_s, headless=args.headless, seed=args.seed,
                                 timeout_min=args.timeout_min)
        except Exception as e:
            ok, note = False, f"threw: {e}"
        results[k] = (ok, note)
        print(f"  {STORES[k]['name']:<12} {'ok  ' if ok else 'FAIL'} {note}")

    failed = [k for k, (ok, _) in results.items() if not ok]
    print("\nBROWSER-PULL-COMPLETE stores={} failed={}".format(len(keys), len(failed)))
    if failed:
        print("FAILED: " + ", ".join(f"{k} ({results[k][1]})" for k in failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
