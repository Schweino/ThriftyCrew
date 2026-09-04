#!/usr/bin/env python3
r"""browser_price_work.py - the hand-off between the hunt daemon and an ATTENDED browser worker.

WHY THIS EXISTS, AND WHY IT IS NOT A SCHEDULED TASK.

Some stores answer Brad's own Chrome and refuse an automated one. That is not a preference and not a
permission: since Chrome 136 `--remote-debugging-port` is ignored unless `--user-data-dir` is
non-default, and copying his session into a driver profile was measured and failed - same cookies,
same fingerprint, same IP, still no prices. The extension reaches his browser through
`chrome.debugger`, a different door, and ONLY A CLAUDE SESSION CAN OPEN IT.

The daemon cannot open it. It is a Python process, so the only agent it can start is `claude -p`,
which is headless: no MCP host, therefore no `mcp__claude-in-chrome__*` and no `mcp__Claude_Browser__*`
however many of them the agent's frontmatter declares. A dispatched pricer proved this in its own
evidence - "the in-app browser pane and list_connected_browsers were NOT present in this agent session
toolset at all" - and the daemon's price prompt states it as fact.

So the work is handed OUT. The daemon leaves a request; a live app session claims it, spawns ONE
worker that does have the browser, and the worker writes verdicts back through the sanctioned road.
Brad ruled on 2026-09-04 that this must NOT be another scheduled task, so nothing here polls on a
clock of its own: `--watch` is a stream a session's own watcher consumes, and the session decides.

THE REQUEST AND THE REPLY ARE BOTH THE QUEUE. Nothing new is invented to carry them:

  request   grocery\ingredient-queue.json - a term whose status is not `resolved` and whose blocking
            stores include a browser store the daemon could not reach. The daemon already writes this.
  reply     ingredient-queue.ps1 -RecordBatch, the same road the dispatched pricer uses.
  pickup    the daemon's price lane runs `hunt-run.ps1 -Derive` after every batch, and its own comment
            says derived counts are the ONLY thing that moves a recipe out of pricing/parked. So the
            loop closes with no message and no new channel, and it survives a restart because a file
            does.

ONE WORKER AT A TIME, ENFORCED BY A CLAIM FILE. The price lane is a deliberate singleton: "N
concurrent pricers means N tabs per store domain, which is the sweep shape that walled Walmart at 55
of 526 terms and Sam's at 205." Ad-hoc spawning must not become the thing that re-creates that shape,
so a claim is taken before a worker is spawned and released after.

USAGE
  python browser_price_work.py --list                    what needs a browser, as JSON
  python browser_price_work.py --prompt                  the brief to hand a spawned worker
  python browser_price_work.py --claim --owner <name>    take the singleton claim
  python browser_price_work.py --release                 give it back
  python browser_price_work.py --watch --interval 30     one line per CHANGE, for a session's watcher
  python browser_price_work.py --selftest
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)

QUEUE = os.path.join(REPO, "grocery", "ingredient-queue.json")
CLAIM = os.path.join(REPO, "grocery", "out", "browser-price-worker.claim.json")

# The stores no automated browser reaches. Fareway and Sam's Club are NOT here: the daemon's own
# pre-pass drives those two through pull-browser-stores.py, which is why LOOKUP_STORES is exactly
# ("fareway", "samsclub"). Walmart is refused there by name - "captured through Brad's own Chrome
# (attended, like Aldi)" - and Hy-Vee has no driver lane at all.
BROWSER_STORES = ("Walmart", "Aldi", "Hy-Vee")

# A claim older than this is stale: a session that died mid-worker must not wedge the singleton shut.
CLAIM_STALE_SEC = 45 * 60

EXIT_CLEAN, EXIT_FINDINGS, EXIT_CANNOT_RUN = 0, 1, 2


# =====================================================================================================
# PURE PREDICATES - every rule provable without a queue on disk, a browser, or a claim.
# =====================================================================================================

def blocked_browser_stores(item, browser_stores=BROWSER_STORES):
    """Which BROWSER stores this queue item is blocked at, in the order the caller declared them.

    `blocked` is the daemon's honest record of a store nobody reached - it is not `not-carried`, and
    the difference is the whole point: a capture MISS is never absence from the store, so only
    `blocked` is work for a browser. An item shaped in a way this does not recognise yields nothing,
    because inventing work is worse than missing it.
    """
    if not isinstance(item, dict):
        return []
    stores = item.get("stores")
    if not isinstance(stores, dict):
        return []
    out = []
    for name in browser_stores:
        v = stores.get(name)
        if isinstance(v, dict) and str(v.get("state") or "").strip().lower() == "blocked":
            out.append(name)
    return out


def pending_work(doc, browser_stores=BROWSER_STORES):
    """[{term, stores, recipes, why}] for every UNRESOLVED item blocked at a browser store.

    A resolved item is never work however its stores read: the verdict is already in, and re-opening
    it would be the re-dispatch loop this estate already paid for once - one term sent to the pricer
    19 times across restarts, 54% of the price lane's turns.
    """
    if not isinstance(doc, dict):
        return []
    out = []
    for item in (doc.get("items") or []):
        if not isinstance(item, dict):
            continue
        if str(item.get("status") or "").strip().lower() == "resolved":
            continue
        stores = blocked_browser_stores(item, browser_stores)
        if not stores:
            continue
        term = str(item.get("term") or "").strip()
        if not term:
            continue
        out.append({"term": term, "stores": stores,
                    "recipes": [str(r) for r in (item.get("recipes") or []) if r],
                    "why": str(item.get("why") or "")[:200]})
    return out


def claim_is_stale(claim, now=None, stale_sec=CLAIM_STALE_SEC):
    """A claim nobody released. True when it is old enough that its owner is presumed gone.

    Without this the singleton is a deadlock waiting for a crash: one worker that dies with the claim
    held would stop every future browser lookup, silently, and the symptom would be terms parking
    exactly as they do today.
    """
    if not isinstance(claim, dict):
        return True
    try:
        at = float(claim.get("at") or 0)
    except (TypeError, ValueError):
        return True
    return ((now if now is not None else time.time()) - at) > stale_sec


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:                                             # noqa: BLE001
        return None


def take_claim(path, owner, now=None, stale_sec=CLAIM_STALE_SEC):
    """(ok, why). Refuses while a LIVE claim is held; takes over a stale one and says so."""
    cur = read_json(path)
    if isinstance(cur, dict) and not claim_is_stale(cur, now, stale_sec):
        return False, ("a browser worker is already claimed by %r since %s - ONE at a time, because "
                       "N concurrent pricers means N tabs per store domain"
                       % (cur.get("owner"), cur.get("when")))
    took_over = isinstance(cur, dict)
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    now_t = time.time() if now is None else now
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"owner": str(owner or "unknown"), "at": now_t,
                   "when": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now_t))},
                  f, ensure_ascii=False, indent=1)
    return True, ("took over a stale claim" if took_over else "")


def release_claim(path):
    try:
        os.remove(path)
        return True
    except OSError:
        return False


def worker_prompt(work, queue_path=QUEUE):
    """The brief handed to the spawned worker. It is BUILT, not typed by hand each time, so the hard
    rules travel with every spawn instead of being remembered."""
    terms = "\n".join("  - %-40s blocked at: %s" % (w["term"], ", ".join(w["stores"])) for w in work)
    return (
        "ATTENDED BROWSER PRICING. You are being spawned from a live app session, so unlike a "
        "dispatched pricer you DO have the browser tools - the capability probe confirmed both "
        "surfaces and Brad's Chrome reachable. That is the only reason this job exists.\n\n"
        "%d TERM(S) THE DAEMON COULD NOT REACH:\n%s\n\n"
        "THE TWO SURFACES, in this order:\n"
        "  1. mcp__Claude_Browser__* - the in-app pane. No logged-in session, but it works for "
        "storefronts that need none. START HERE.\n"
        "  2. mcp__claude-in-chrome__* - Brad's REAL Chrome, with his sessions. Use it when a store "
        "needs a login, and for Walmart and Aldi, which answer his browser and refuse an automated "
        "one. Check list_connected_browsers first; an empty array means say so plainly.\n\n"
        "HARD RULES, each of which cost more than the data when it was learned:\n"
        "  * ONE REQUEST, THEN STOP. A challenge page, an error page or a price-less shell IS the "
        "answer - record UNUSABLE/blocked and move on. Retrying deepens the wall.\n"
        "  * ONE TAB AT A TIME. N concurrent tabs per store domain is the sweep shape that walled "
        "Walmart at 55 of 526 terms and Sam's at 205.\n"
        "  * NEVER DESCRIBE A PAGE YOU DID NOT LOAD. On 2026-08-24 a pricer wrote three "
        "verified-sounding store visits that never happened, then corrected itself.\n"
        "  * A CANDIDATE IS NOT A CARRIAGE RULING. Ask of each row whether it is THE INGREDIENT, in "
        "a form a cook would buy for this recipe.\n"
        "  * `blocked` is honest and keeps the term PENDING. `not-carried` is a claim about the "
        "STORE and needs a real look.\n\n"
        "RECORD THROUGH THE SANCTIONED ROAD, never by editing the queue file:\n"
        "  grocery\\ingredient-queue.ps1 -RecordBatch -File <a JSON array>\n"
        "  each row {term, store, state, price, size, item, evidence}; state is one of "
        "carried / not-carried / blocked / error.\n"
        "  The queue is %s.\n\n"
        "Then STOP. Do not price anything else, do not touch board cells, do not advance any recipe "
        "state - the daemon runs `hunt-run.ps1 -Derive` after every batch and that is what moves a "
        "recipe out of pricing. Your verdicts reaching the queue IS the message back."
        % (len(work), terms or "  (none)", queue_path))


# =====================================================================================================
def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    def item(term, stores, status="pending", recipes=("r1",)):
        return {"term": term, "status": status, "recipes": list(recipes),
                "why": "tier1 ABSENT", "stores": stores}

    B = {"state": "blocked"}
    C = {"state": "carried", "price": 2.99}
    NC = {"state": "not-carried"}

    T("MUST FIRE  a term blocked at a BROWSER store is work",
      blocked_browser_stores(item("star anise", {"Walmart": B})) == ["Walmart"])
    T("CLEAN TWIN a term blocked only at a store the daemon's own pre-pass drives is NOT work - "
      "Fareway and Sam's go through pull-browser-stores.py, and duplicating them here would spend "
      "Brad's browser on a lookup a script already did",
      blocked_browser_stores(item("x", {"Fareway": B, "Sam's Club": B})) == [])
    T("CLEAN TWIN `not-carried` and `carried` are answers, not work - only `blocked` means nobody "
      "reached the store", blocked_browser_stores(item("x", {"Walmart": NC, "Aldi": C})) == [])
    T("MUST FIRE  several browser stores are all reported, so one worker can batch them",
      blocked_browser_stores(item("x", {"Walmart": B, "Aldi": B, "Hy-Vee": B}))
      == ["Walmart", "Aldi", "Hy-Vee"])
    T("CLEAN TWIN a shape this does not recognise yields NOTHING rather than inventing work",
      blocked_browser_stores({"stores": "nope"}) == [] and blocked_browser_stores(None) == [])

    doc = {"items": [item("star anise", {"Walmart": B}),
                     item("gochujang", {"Aldi": B, "Hy-Vee": B}),
                     item("already done", {"Walmart": B}, status="resolved"),
                     item("server only", {"Fareway": B}),
                     item("", {"Walmart": B})]}
    work = pending_work(doc)
    T("MUST FIRE  pending_work returns exactly the unresolved browser-blocked terms",
      [w["term"] for w in work] == ["star anise", "gochujang"],
      json.dumps([w["term"] for w in work]))
    T("MUST FIRE  a RESOLVED item is never work again, whatever its stores say - re-opening it is "
      "the re-dispatch loop that sent one term to the pricer 19 times across restarts",
      "already done" not in [w["term"] for w in work])
    T("CLEAN TWIN a nameless item is skipped rather than queued as an empty lookup",
      all(w["term"] for w in work))
    T("MUST FIRE  the work carries the stores and the recipes waiting on it",
      work[1]["stores"] == ["Aldi", "Hy-Vee"] and work[1]["recipes"] == ["r1"],
      json.dumps(work[1]))
    T("CLEAN TWIN a queue with nothing pending is empty work, not an error",
      pending_work({"items": []}) == [] and pending_work(None) == [])

    # ---- the claim ------------------------------------------------------------------------------
    import tempfile                                              # noqa: PLC0415
    import shutil                                                # noqa: PLC0415
    tmp = tempfile.mkdtemp(prefix="bpw-")
    try:
        cpath = os.path.join(tmp, "sub", "claim.json")
        ok1, _ = take_claim(cpath, "session-A", now=1000.0)
        T("MUST FIRE  the first claim is granted and the directory is created for it", ok1)
        ok2, why2 = take_claim(cpath, "session-B", now=1001.0)
        T("MUST FIRE  a SECOND worker is refused while the claim is live - one tab-opener at a time, "
          "because concurrent pricers are the sweep shape that walled Walmart",
          not ok2 and "ONE at a time" in why2, why2)
        ok3, why3 = take_claim(cpath, "session-C", now=1000.0 + CLAIM_STALE_SEC + 1)
        T("MUST FIRE  a STALE claim is taken over and the takeover is stated - a worker that died "
          "holding it must not wedge every future lookup shut",
          ok3 and "stale" in why3, why3)
        T("CLEAN TWIN a claim with no timestamp reads as stale rather than as a permanent lock",
          claim_is_stale({"owner": "x"}) and claim_is_stale(None))
        T("MUST FIRE  releasing removes it, and releasing twice is not an error",
          release_claim(cpath) and not release_claim(cpath))

        # ---- --list over a scratch queue, never the live one ------------------------------------
        qpath = os.path.join(tmp, "queue.json")
        with open(qpath, "w", encoding="utf-8") as f:
            json.dump(doc, f)
        got = pending_work(read_json(qpath))
        T("MUST FIRE  the same answer comes off a queue FILE, so --list and the watcher agree",
          [w["term"] for w in got] == ["star anise", "gochujang"])
        T("CLEAN TWIN an unreadable queue is (no work), never an exception - a missing file must not "
          "take down a session's watcher", pending_work(read_json(os.path.join(tmp, "nope.json"))) == [])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # ---- the prompt ------------------------------------------------------------------------------
    p = worker_prompt(work)
    T("MUST FIRE  the brief NAMES every term and the stores it is blocked at",
      "star anise" in p and "gochujang" in p and "Walmart" in p and "Hy-Vee" in p)
    T("MUST FIRE  the brief carries the hard rules that cost something to learn - one request, one "
      "tab, never describe a page you did not load",
      ("ONE REQUEST" in p and "ONE TAB" in p and "NEVER DESCRIBE A PAGE" in p), p[:200])
    T("MUST FIRE  the brief routes the write through ingredient-queue.ps1 -RecordBatch, never a "
      "hand edit of the queue file", "-RecordBatch" in p and "never by editing the queue file" in p)
    T("MUST FIRE  ...and tells the worker its verdicts ARE the message back, so nobody builds a "
      "second channel for it", "IS the message back" in p and "-Derive" in p)
    T("CLEAN TWIN an empty work list still renders a brief rather than crashing",
      "(none)" in worker_prompt([]))

    print("")
    if bad:
        print("browser-price-work SELF-TEST FAIL (%d)" % len(bad))
        print("BROWSER-PRICE-WORK-COMPLETE")
        return EXIT_CANNOT_RUN
    print("browser-price-work SELF-TEST PASS")
    print("BROWSER-PRICE-WORK-COMPLETE")
    return EXIT_CLEAN


def main(argv=None):
    ap = argparse.ArgumentParser(description="the hand-off to an attended browser worker")
    ap.add_argument("--queue", default=QUEUE)
    ap.add_argument("--claim-file", dest="claim_file", default=CLAIM)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--prompt", action="store_true")
    ap.add_argument("--claim", action="store_true")
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--owner", default="")
    ap.add_argument("--watch", action="store_true")
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)

    if a.selftest:
        return selftest()

    if a.claim:
        ok, why = take_claim(a.claim_file, a.owner or "session")
        print(("CLAIMED %s" % why).strip() if ok else "REFUSED %s" % why)
        return EXIT_CLEAN if ok else EXIT_FINDINGS
    if a.release:
        print("RELEASED" if release_claim(a.claim_file) else "no claim held")
        return EXIT_CLEAN

    work = pending_work(read_json(a.queue))
    if a.prompt:
        print(worker_prompt(work, a.queue))
        return EXIT_CLEAN
    if a.watch:
        # A STREAM, NOT A SCHEDULE. Brad ruled on 2026-09-04 that this must not become another
        # scheduled task, so nothing here decides to act - it prints when the work set CHANGES and a
        # live session decides what to do about it. Printing only on change is what keeps a session's
        # watcher from firing on every tick of an unchanged backlog.
        last = None
        while True:
            work = pending_work(read_json(a.queue))
            key = json.dumps(sorted(w["term"] for w in work))
            if key != last:
                last = key
                if work:
                    print("BROWSER-WORK %d term(s): %s"
                          % (len(work), ", ".join("%s [%s]" % (w["term"], "/".join(w["stores"]))
                                                  for w in work[:6])), flush=True)
                else:
                    print("BROWSER-WORK cleared", flush=True)
            time.sleep(max(5, a.interval))

    print(json.dumps(work, ensure_ascii=False, indent=1))
    return EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main())
