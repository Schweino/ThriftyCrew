r"""I101 rung 2, reading 2: is POSITION or CLICK-THROUGH the binding constraint?

    python ops/seo_reach_position.py             # the 28-day read
    python ops/seo_reach_position.py --days 90
    python ops/seo_reach_position.py --selftest  # hermetic, no network

WHY THIS EXISTS (2026-09-09, backlog I101). Reading 1 established that the silent pages are INDEXED -
30 of 30, against a control arm of 15 of 15 - so admission is not the constraint. That leaves two
candidates and they want opposite work:

  * POSITION-BOUND: the pages rank too low to be seen. Zero clicks is then ARITHMETIC, not a copy
    problem, and titles and snippets are the wrong thing to touch.
  * CLICK-BOUND: the pages reach visible positions and are not clicked. Then titles, snippets and
    the search appearance are exactly the thing to touch.

THE READINGS ARE PRE-REGISTERED, BEFORE THE RUN (backlog E21):

  READING U - fewer than MIN_IMPRESSIONS in the window, OR page-1 traffic so thin that even a
              healthy click-through would predict FEWER THAN ONE click. Then the data cannot carry
              the reading being asked of it. A real outcome, not a failure.
  READING P - at least 80% of impressions land BELOW position 10  -> POSITION-BOUND.
  READING C - at least 20% of impressions land at position <= 10, AND that page-1 traffic is large
              enough to have expected several clicks, and got ~none                 -> CLICK-BOUND.
  READING M - anything else. Reported, never smoothed into one of the above.

ORDER MATTERS, AND MY FIRST VERSION HAD IT BACKWARDS. The power check ran ahead of the position
reading, so a distribution with 94% of its impressions below position 10 came back "cannot
distinguish" purely because its page-1 slice was thin. That is wrong: WHERE THE IMPRESSIONS LAND IS
DIRECTLY OBSERVED and needs no click power to be true. Only the click-through question is an
inference. So it reads: too little data at all, then position (observed), then click-through
(inferred) - and the power note rides inside the position verdict instead of pre-empting it. Caught
by this file's own must-fire, which is what they are for.

THE POWER CHECK IS THE POINT OF READING U, and it is this file's reason for existing rather than a
one-line query. Rung 1's caveat is that 1 click over 28 days is a sample of one. Made precise: if
there are 12 page-1 impressions, then even a generous 10% click-through predicts 1.2 clicks, so
observing 0 is entirely ordinary and tells you NOTHING about the copy. Concluding "our titles are
bad" from that is selection on noise, which this estate has a memory about.

NO INDUSTRY CTR CURVE IS USED as a benchmark, because that would be a number this estate did not
measure. The only external constant is a deliberately GENEROUS upper bound on page-1 click-through,
stated in the source as CTR_GENEROUS and used ONLY to answer "could we even have expected one click?"
- a power question, never a performance verdict.

A RATE IS PRINTED WITH ITS DENOMINATOR, always.

PRIVACY: Search Console page and query rows only. Aggregate search data, no member data of any kind.

Exit 0 = read. 3 = no credential, or nothing to read, and 3 is NEVER a pass.
"""
from __future__ import annotations

import argparse
import collections
import datetime
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

OUT = os.path.join(REPO, "ops", "out", "seo-reach-position.jsonl")
EXIT_OK, EXIT_CANNOT_RUN = 0, 3

# A deliberately GENEROUS page-1 click-through rate, used ONLY for the power question
# ("could we have expected even one click?"), never as a performance benchmark.
CTR_GENEROUS = 0.10
# ...and its opposite, which is what READING C actually needs. A BOUND IS DIRECTIONAL: the generous
# rate answers "could we even have expected one click?" (READING U), and using it to declare that
# pages are seen-and-not-clicked INFLATES that claim, because it credits every page-1 impression with
# a top-of-page rate. Most page-1 impressions here sit at positions 4-10. So READING C must clear a
# CONSERVATIVE floor instead: even pessimistically, several clicks should have appeared.
# 0.02 is a deliberately pessimistic page-1 rate and C additionally requires MIN_EXPECTED_CLICKS
# under it, so the reading cannot fire on one or two clicks' worth of noise.
CTR_CONSERVATIVE = 0.02
MIN_EXPECTED_CLICKS = 3.0
# A floor under ANY reading. A "100% below page 1" distribution built from five impressions is not a
# finding, it is a rounding artefact.
#
# 30 IS NOT THE FIRST NUMBER TRIED, AND IT INTERACTS WITH CTR_GENEROUS ABOVE. It was 50, and 50 made
# the click-power refusal below DEAD CODE: that branch needs page-1 >= 20% of total AND page-1 <= 9
# (so that a generous CTR predicts under one click) AND under 80% below position 10, and those three
# together force total <= 45. The floor fired first every time. The reachability condition is
# MIN_IMPRESSIONS < (1 / CTR_GENEROUS) / 0.20 = 50, so 50 sits exactly on the boundary and anything
# at or above it kills the branch. 30 clears it with room, and is still enough impressions that a
# distribution means something. Caught by a fixture that could not be satisfied, not by reasoning.
MIN_IMPRESSIONS = 30

BUCKETS = ((0.0, 3.0, "1-3    (top of page 1)"),
           (3.0, 10.0, "4-10   (rest of page 1)"),
           (10.0, 20.0, "11-20  (page 2)"),
           (20.0, 50.0, "21-50  (pages 3-5)"),
           (50.0, 1e9, "51+    (page 6 and beyond)"))


def bucket_of(pos):
    for lo, hi, name in BUCKETS:
        if lo < pos <= hi or (lo == 0.0 and pos <= hi):
            return name
    return BUCKETS[-1][2]


def distribute(rows):
    """Impression-weighted position distribution. Pure, so the fixtures drive it exactly."""
    imps = collections.Counter()
    clicks = collections.Counter()
    total_i = total_c = 0
    for r in rows:
        pos = float(r.get("position", 0) or 0)
        i = int(r.get("impressions", 0) or 0)
        c = int(r.get("clicks", 0) or 0)
        b = bucket_of(pos)
        imps[b] += i
        clicks[b] += c
        total_i += i
        total_c += c
    return imps, clicks, total_i, total_c


def page1(imps):
    return imps[BUCKETS[0][2]] + imps[BUCKETS[1][2]]


def verdict(imps, clicks, total_i, total_c):
    """Which pre-registered reading fires. Named before the run, matched after it."""
    if total_i < MIN_IMPRESSIONS:
        return "U", (
            "only %d impression(s) in the whole window, under the floor of %d, so no reading is "
            "supported at all - a distribution this thin is a rounding artefact, not a finding"
            % (total_i, MIN_IMPRESSIONS))
    p1 = page1(imps)
    p1_clicks = clicks[BUCKETS[0][2]] + clicks[BUCKETS[1][2]]
    below10 = total_i - p1
    share_below = below10 / float(total_i)
    expected = p1 * CTR_GENEROUS

    # POSITION FIRST: where the impressions land is OBSERVED, not inferred, so it does not wait on
    # click-through power. The power note rides along, because the page-1 slice is usually too thin
    # to say anything about the copy and a reader deserves telling so in the same breath.
    if share_below >= 0.80:
        # THE NOTE USES THE CONSERVATIVE RATE, for the same directional reason READING C does: the
        # question here is "can this page-1 slice tell us anything about the copy?", and answering it
        # with the generous rate would credit every impression with a top-of-page click-through and
        # make a thin slice look informative. Pessimistic is the honest side of that bound.
        note = ("The page-1 slice is %d impression(s), where even a pessimistic %.0f%% predicts "
                "%.1f click(s) - under the %.0f needed to judge click-through - so it says NOTHING "
                "about titles or snippets either way"
                % (p1, CTR_CONSERVATIVE * 100, p1 * CTR_CONSERVATIVE, MIN_EXPECTED_CLICKS))
        return "P", (
            "%d of %d impression(s), %.0f%%, land below position 10, so the pages rank too low to be "
            "seen. Zero clicks is ARITHMETIC here, not a copy problem, and titles and snippets are "
            "the wrong thing to touch. %s"
            % (below10, total_i, share_below * 100, note))
    # CLICK-THROUGH SECOND, and only where there is enough page-1 traffic to have expected a click.
    if p1 / float(total_i) >= 0.20 and expected < 1.0:
        return "U", (
            "%d of %d impression(s) reached page 1, so even a generous %.0f%% click-through would "
            "predict %.1f clicks. Observing %d is entirely ordinary. THE DATA CANNOT settle whether "
            "click-through is the constraint, and claiming it would be invention"
            % (p1, total_i, CTR_GENEROUS * 100, expected, p1_clicks))
    conservative = p1 * CTR_CONSERVATIVE
    if (p1 / float(total_i) >= 0.20 and p1_clicks == 0
            and conservative >= MIN_EXPECTED_CLICKS):
        return "C", (
            "%d of %d impression(s) reached page 1 and earned %d click(s), where even a PESSIMISTIC "
            "%.0f%% would have predicted %.1f. The pages are seen and not clicked, so search "
            "appearance is the work"
            % (p1, total_i, p1_clicks, CTR_CONSERVATIVE * 100, conservative))
    return "M", (
        "%d of %d impression(s) below position 10 (%.0f%%), %d on page 1 earning %d click(s). A "
        "pessimistic %.0f%% predicts only %.1f click(s) there, under the %.0f needed to call it, and "
        "the below-10 share is under 80%%. BETWEEN THE PRE-REGISTERED BANDS, so no reading fires and "
        "this sample does not settle position against click-through"
        % (below10, total_i, share_below * 100, p1, p1_clicks, CTR_CONSERVATIVE * 100,
           p1 * CTR_CONSERVATIVE, MIN_EXPECTED_CLICKS))


def selftest():
    ok = True

    def chk(name, got, want):
        nonlocal ok
        good = got == want
        ok = ok and good
        print("  %-62s %s" % (name, "ok" if good else ("FAIL got=%r want=%r" % (got, want))))

    # Bucketing: the boundaries are where a reading flips, so they are pinned.
    chk("MUST FIRE  position 10.0 is page 1, not page 2", bucket_of(10.0), BUCKETS[1][2])
    chk("MUST FIRE  position 10.1 is page 2", bucket_of(10.1), BUCKETS[2][2])
    chk("CLEAN TWIN position 1.0 is still top of page 1", bucket_of(1.0), BUCKETS[0][2])
    chk("CLEAN TWIN position 3.0 is still top of page 1", bucket_of(3.0), BUCKETS[0][2])
    chk("MUST FIRE  position 3.1 leaves the top bucket", bucket_of(3.1), BUCKETS[1][2])
    chk("MUST NOT FIRE position 0 does not fall off the front", bucket_of(0.0), BUCKETS[0][2])
    chk("MUST FIRE  position 900 lands in the last bucket", bucket_of(900.0), BUCKETS[4][2])

    # READING U protects against inventing a verdict from noise - the floor first.
    i, c, ti, tc = distribute([{"position": 5, "impressions": 9, "clicks": 0}])
    chk("MUST FIRE  9 impressions is under the floor, no reading", verdict(i, c, ti, tc)[0], "U")
    chk("MUST NOT FIRE an empty window does not read as a verdict",
        verdict(*distribute([]))[0], "U")
    i, c, ti, tc = distribute([{"position": 5, "impressions": 200, "clicks": 0}])
    chk("MUST FIRE  200 page-1 impressions with 0 clicks is CLICK-BOUND",
        verdict(i, c, ti, tc)[0], "C")
    # THE FOUNDING BUG, second one (2026-09-09, found on live data): C used the GENEROUS bound, so it
    # fired on page-1 volume that a realistic rate would never have expected clicks from. A bound is
    # directional - generous answers "could we have expected one?", conservative answers "should we
    # have seen several?". 41 page-1 impressions is the live case that wrongly read C.
    i, c, ti, tc = distribute([{"position": 60, "impressions": 54, "clicks": 0},
                               {"position": 7, "impressions": 41, "clicks": 0}])
    code, why = verdict(i, c, ti, tc)
    chk("MUST FIRE  41 page-1 impressions is NOT enough to call CLICK-BOUND", code, "M")
    chk("MUST NOT FIRE the refusal names the pessimistic expectation",
        ("pessimistic" in why.lower()), True)
    # CLEAN TWIN: a volume that clears the conservative floor still reads C.
    i, c, ti, tc = distribute([{"position": 7, "impressions": 400, "clicks": 0}])
    chk("CLEAN TWIN 400 page-1 impressions with 0 clicks still reads CLICK-BOUND",
        verdict(i, c, ti, tc)[0], "C")

    # THE FOUNDING BUG (2026-09-09): the power check used to run FIRST, so a distribution that is
    # overwhelmingly below page 1 came back "cannot distinguish" because its page-1 slice was thin.
    # Where impressions LAND is observed, not inferred. Both of these must read POSITION-BOUND.
    i, c, ti, tc = distribute([{"position": 60, "impressions": 300, "clicks": 0},
                               {"position": 5, "impressions": 20, "clicks": 0}])
    chk("MUST FIRE  94% below page 1 is POSITION-BOUND despite a thin page-1 slice",
        verdict(i, c, ti, tc)[0], "P")
    i, c, ti, tc = distribute([{"position": 60, "impressions": 95, "clicks": 0},
                               {"position": 2, "impressions": 5, "clicks": 0}])
    code, why = verdict(i, c, ti, tc)
    chk("MUST FIRE  observation is read BEFORE inference", code, "P")
    chk("CLEAN TWIN the position verdict still carries the power note",
        ("says NOTHING about titles" in why), True)
    i, c, ti, tc = distribute([{"position": 60, "impressions": 3000, "clicks": 0},
                               {"position": 5, "impressions": 200, "clicks": 5}])
    chk("CLEAN TWIN mass below page 1 with real page-1 volume is still POSITION-BOUND",
        verdict(i, c, ti, tc)[0], "P")

    # And the click-through question still refuses itself when the page-1 slice cannot carry it.
    # THIS CASE IS DELIBERATELY TIGHT: 9 page-1 of 40 total is 22.5% (over the 20% bar), predicts 0.9
    # clicks (under the 1.0 bar), and is 77.5% below position 10 (under the 80% bar). All three at
    # once, which is the only way into this branch - and with MIN_IMPRESSIONS at 50 there was NO such
    # case, so the branch was unreachable and this fixture is what proved it.
    i, c, ti, tc = distribute([{"position": 15, "impressions": 31, "clicks": 0},
                               {"position": 5, "impressions": 9, "clicks": 0}])
    code, why = verdict(i, c, ti, tc)
    chk("MUST FIRE  a thin page-1 slice refuses the CLICK reading", code, "U")
    chk("MUST NOT FIRE that refusal does not claim a cause",
        ("CANNOT settle" in why), True)
    chk("CLEAN TWIN the floor still refuses a genuinely tiny window",
        verdict(*distribute([{"position": 5, "impressions": 9, "clicks": 0}]))[0], "U")

    # Totals derive from the rows.
    i, c, ti, tc = distribute([{"position": 2, "impressions": 10, "clicks": 1},
                               {"position": 30, "impressions": 40, "clicks": 0}])
    chk("impressions total derives from rows", ti, 50)
    chk("clicks total derives from rows", tc, 1)
    chk("page-1 total derives from rows", page1(i), 10)
    chk("MUST NOT FIRE a page-2 row is not counted as page 1",
        i[BUCKETS[0][2]] + i[BUCKETS[1][2]], 10)

    print("SEO-REACH-POSITION-COMPLETE selftest=%s" % ("pass" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--days", type=int, default=28)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()

    import seo_search_console as S                                     # noqa: E402
    if not os.path.isfile(S.KEY_FILE):
        print("SEO REACH POSITION BLIND: no service-account credential, so Google's own position data")
        print("  has NOT been read. This is the honest state, not a clean one.")
        print("SEO-REACH-POSITION-COMPLETE blind=no-credential")
        return EXIT_CANNOT_RUN
    with io.open(S.KEY_FILE, encoding="utf-8-sig") as fh:
        key = json.load(fh)
    try:
        tok = S.access_token(key)
    except Exception as e:                                             # noqa: BLE001
        print("SEO REACH POSITION BLIND: the key would not exchange for a token - %s" % e)
        print("SEO-REACH-POSITION-COMPLETE blind=no-token")
        return EXIT_CANNOT_RUN

    start, end = S.window(datetime.date.today(), a.days)
    qrows = S.search_analytics(
        tok, S.query_body(start, end, ["query", "page"], row_limit=25000)).get("rows", [])
    prows = S.search_analytics(
        tok, S.query_body(start, end, ["page"], row_limit=25000)).get("rows", [])

    print("window %s .. %s   (input fingerprint: %d query-page row(s), %d page row(s))"
          % (start, end, len(qrows), len(prows)))
    if not qrows:
        print("SEO REACH POSITION BLIND: Search Console returned no query-page rows for the window,")
        print("  so there is nothing to distribute. Not a clean result.")
        print("SEO-REACH-POSITION-COMPLETE blind=no-rows")
        return EXIT_CANNOT_RUN

    imps, clicks, total_i, total_c = distribute(qrows)
    print()
    page_i = sum(int(r.get("impressions", 0) or 0) for r in prows)
    q_i = sum(int(r.get("impressions", 0) or 0) for r in qrows)
    if page_i:
        print("COVERAGE: the query dimension carries %d of %d impression(s) (%.0f%%) that the page "
              "dimension reports." % (q_i, page_i, 100.0 * q_i / page_i))
        print("  Search Console ANONYMISES low-volume queries, so the missing %d are real traffic "
              "this reading cannot see," % (page_i - q_i))
        print("  and what remains skews toward COMMON queries. Every figure below is over that "
              "subset, not over all traffic.")
        print()
    print("IMPRESSION-WEIGHTED POSITION, over %d query-page pair(s)" % len(qrows))
    for _, _, name in BUCKETS:
        if imps[name] or clicks[name]:
            print("   %-28s %5d of %d impression(s)  (%4.1f%%)   %d click(s)"
                  % (name, imps[name], total_i, 100.0 * imps[name] / total_i, clicks[name]))
    print("   %-28s %5d              %d click(s) total" % ("TOTAL", total_i, total_c))

    try:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with io.open(OUT, "w", encoding="utf-8") as fh:
            for r in qrows:
                fh.write(json.dumps({
                    "query": r["keys"][0], "page": r["keys"][1],
                    "impressions": int(r.get("impressions", 0) or 0),
                    "clicks": int(r.get("clicks", 0) or 0),
                    "position": float(r.get("position", 0) or 0)}) + "\n")
        print("\none row per query-page pair written to %s" % os.path.relpath(OUT, REPO))
    except OSError as e:
        print("\ncould not write the rows (%s) - the totals above still derive from them" % e)

    top = sorted(qrows, key=lambda r: -int(r.get("impressions", 0) or 0))[:12]
    print("\nTOP QUERIES BY IMPRESSIONS - what Google currently thinks these pages are for")
    for r in top:
        print("   %4d imp  %d clk  pos %5.1f  %s"
              % (r["impressions"], r["clicks"], r["position"], str(r["keys"][0])[:58]))

    code, why = verdict(imps, clicks, total_i, total_c)
    print("\nREADING %s: %s." % (code, why))
    print("SEO-REACH-POSITION-COMPLETE reading=%s impressions=%d clicks=%d"
          % (code, total_i, total_c))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
