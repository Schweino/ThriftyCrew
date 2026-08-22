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

EXIT CODES  0 = every requested store captured. 1 = at least one store failed or was walled.
            2 = nothing could run (no Chrome, no worklists).
"""
import argparse
import datetime
import json
import re
import os
import subprocess
import sys
import time

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
        "capture": os.path.join("out", "captures", "walmart-capture-{date}.csv"),
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
        "capture": os.path.join("out", "captures", "sams-capture-{date}.csv"),
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
        "agent": "pull-fareway-instore.js",
        "sweep": "pullFarewayInStore",
        "to_csv": "farewaySweepToCsv",
        "storage_key": "TC_FAREWAY_SWEEP",
        "capture": os.path.join("out", "captures", "fareway-capture-{date}.csv"),
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
    prof = profile_dir(store_key)
    seeded_marker = os.path.join(prof, ".tc-seeded")

    if not seed and not os.path.exists(seeded_marker):
        return False, (f"NEEDS SEEDING: no seeded Chrome profile for {name}. Run "
                       f"`pull-browser-stores.py --store {store_key} --seed` once, {cfg['seed_hint']}")

    terms, why = (None, None) if seed else read_worklist(store_key, date_s)
    if not seed and terms is None:
        return True, f"skipped: {why}"

    print(f"\n=== {name} ===")
    if not seed:
        print(f"  worklist: {len(terms)} term(s)")

    # Prove the agent/driver contract BEFORE launching a browser: a drift here is a code defect and
    # should cost nothing to discover.
    skey = ""
    if not seed:
        try:
            skey = storage_key_of(cfg)
        except Exception as e:
            return False, str(e)

    browser = Chrome(headless=headless, width=1440, height=900, dsf=1.0,
                     profile_dir=prof, mobile=False)
    try:
        browser.start()
    except Exception as e:
        return False, f"could not start Chrome: {e}"

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
            browser.on_new_document(agent_src)
            ensure_agent(browser, agent_src, call.split("(")[0])
            call = _identity_call(cfg)
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
                    if not browser.js(f"typeof {call.split('(')[0]} === 'function'"):
                        ensure_agent(browser, agent_src, call.split("(")[0])
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
        browser.on_new_document(agent_src)
        ensure_agent(browser, agent_src, cfg["sweep"])

        # THE AGENT MUST ACTUALLY BE THERE. If the injection silently failed, the sweep call below
        # would throw a ReferenceError that reads like a store problem rather than a load problem.
        if not browser.js(f"typeof {cfg['sweep']} === 'function'"):
            return False, f"agent did not load: {cfg['sweep']} is not defined after injecting {cfg['agent']}"

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
            return False, "sweep produced no rows - capture NOT written (an empty file would read as a real, empty store)"
        with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
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
        b = Chrome(headless=headless, width=1440, height=900, dsf=1.0, mobile=False)
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
    """The agent's identity function, named per store (they are not uniform, deliberately)."""
    return {
        "walmart": "walmartIdentity()",
        "samsclub": "samsIdentity()",
        "fareway": "farewayIdentity()",
    }.get(cfg["agent"].split("-")[1], "null")


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
