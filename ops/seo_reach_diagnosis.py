r"""I101 rung 2, reading 1: are the silent pages INDEXED but unranked, or absent from Google's index?

    python ops/seo_reach_diagnosis.py            # 30 silent + 15 earning, the default arms
    python ops/seo_reach_diagnosis.py --n 40 --control 20
    python ops/seo_reach_diagnosis.py --selftest # hermetic, no network

WHY THIS EXISTS (2026-09-09, backlog I101). Rung 1 measured the reach: 639 published pages earn 300
impressions and one click in 28 days, and 535 of them earn NOTHING. Rung 1 deliberately did not
diagnose. This is the diagnosis, and it exists because THE TWO CAUSES WANT OPPOSITE FIXES:

  * pages ABSENT from the index cannot rank at any quality, and the work is admission - sitemap,
    internal linking, thin-content consolidation, indexing requests.
  * pages INDEXED and not ranking are already admitted, and the work is relevance and competition.

Spending a quarter on the wrong one of those is the whole cost this reading exists to avoid.

THE READINGS ARE PRE-REGISTERED, below, BEFORE the run. A threshold or an interpretation chosen after
seeing the number is not a threshold, it is a description of a decision already taken (backlog E21).

  READING A - silent largely NOT indexed, earning largely indexed  -> the constraint is ADMISSION.
  READING B - both arms largely indexed                            -> indexing is NOT the
              differentiator; the 535 are admitted and simply not ranking. The work is relevance.
  READING C - both arms largely NOT indexed                        -> a property-wide crawl problem,
              and the earning 104 are surviving on something else.
  READING D - anything else, including a large NOT-PUBLISHED or 404 bucket -> the universe is wrong
              and this reading is void until that is fixed. Reported, never smoothed over.

THERE IS A CONTROL ARM, and it is the point. "78% of the silent pages are indexed" is UNQUALIFIED on
its own: if the earning pages are indexed at the same rate then indexing explains nothing about the
difference between them, and the conclusion flips. So a sample of pages that DO earn impressions is
inspected the same way, in the same run, through the same code.

THE UNIVERSE IS THE PUBLISHED MANIFEST, not the built directory. meal-prep/db/published-hashes.json
carries 583 slugs against 584 built files, so one built recipe was never published and would have
inspected as "not indexed" while really being "not published" - a confound that would have been
invisible in the total.

ONE ROW PER URL PER ARM is written to ops/out/seo-reach-diagnosis.jsonl, and every total in the
report is derived from that file (backlog E24). A pair of totals cannot be un-aggregated later.

A RATE IS PRINTED WITH ITS DENOMINATOR, always.

PRIVACY: this reads Search Console PAGE rows and Google's per-URL index status. It touches no member
data of any kind, and the standing boundary on this estate - that no per-member row enters the repo -
is untouched by it.

Exit 0 = read. 3 = no credential, or nothing inspected, and 3 is NEVER a pass.
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

PUBLISHED = os.path.join(REPO, "meal-prep", "db", "published-hashes.json")
OUT = os.path.join(REPO, "ops", "out", "seo-reach-diagnosis.jsonl")
EXIT_OK, EXIT_CANNOT_RUN = 0, 3

# Coverage states Google returns. Grouped ONCE, here, so the two arms cannot be bucketed differently.
INDEXED_HINTS = ("submitted and indexed", "indexed, not submitted", "indexed")
ABSENT_HINTS = ("crawled - currently not indexed", "discovered - currently not indexed",
                "not found", "404", "excluded", "noindex", "redirect", "duplicate",
                "blocked", "soft 404", "alternate page")


def bucket(coverage_state):
    """indexed / absent / unknown. One mapping, both arms - never two."""
    s = (coverage_state or "").strip().lower()
    if not s:
        return "unknown"
    # order matters: "indexed, not submitted" is indexed; "currently not indexed" is not.
    if "not indexed" in s or "not found" in s or "soft 404" in s:
        return "absent"
    for h in INDEXED_HINTS:
        if h in s:
            return "indexed"
    for h in ABSENT_HINTS:
        if h in s:
            return "absent"
    return "unknown"


def stride(items, n):
    """A deterministic spread sample - sorted, then strided. Never Get-Random, never hand-picked."""
    items = sorted(items)
    if n >= len(items) or n <= 0:
        return items
    step = len(items) / float(n)
    return [items[int(i * step)] for i in range(n)]


def build_arms(published_slugs, earning_urls, base, n, control):
    """(silent_sample, earning_sample, diagnostics). Pure, so the fixtures drive it exactly."""
    universe = set(base + s + "/" for s in published_slugs)
    earning_in_universe = universe & set(earning_urls)
    silent = universe - earning_in_universe
    return (stride(silent, n), stride(earning_in_universe, control),
            {"universe": len(universe), "earning_in_universe": len(earning_in_universe),
             "silent": len(silent), "earning_rows_total": len(earning_urls)})


def summarise(rows):
    """Counters and lines from the per-URL rows. Every total here is derived from these rows."""
    by_arm = collections.defaultdict(collections.Counter)
    states = collections.defaultdict(collections.Counter)
    crawls = collections.defaultdict(list)
    for r in rows:
        by_arm[r["arm"]][r["bucket"]] += 1
        states[r["arm"]][r["coverage_state"] or "(none)"] += 1
        if r.get("last_crawl"):
            crawls[r["arm"]].append(r["last_crawl"][:10])

    lines = []
    for arm in ("silent", "earning"):
        c = by_arm[arm]
        n = sum(c.values())
        if not n:
            lines.append("  %s arm: NOTHING INSPECTED" % arm)
            continue
        lines.append("  %s arm - %d URL(s) inspected" % (arm.upper(), n))
        for b in ("indexed", "absent", "unknown"):
            if c[b]:
                lines.append("      %-9s %d of %d  (%.0f%%)" % (b, c[b], n, 100.0 * c[b] / n))
        for k, v in states[arm].most_common():
            lines.append("        coverageState: %-38s %d of %d" % (k, v, n))
        if crawls[arm]:
            lines.append("      last crawl: %d of %d dated, %s .. %s"
                         % (len(crawls[arm]), n, min(crawls[arm]), max(crawls[arm])))
        else:
            lines.append("      last crawl: NONE of the %d carries a crawl date" % n)
    return by_arm, lines


def verdict(by_arm):
    """Which pre-registered reading fired. Named before the run, matched after it."""
    def rate(arm, b):
        n = sum(by_arm[arm].values())
        return (by_arm[arm][b] / float(n)) if n else None

    si, ei = rate("silent", "indexed"), rate("earning", "indexed")
    su = rate("silent", "unknown")
    if si is None or ei is None:
        return "D", "one arm inspected nothing, so no reading is supported"
    if su is not None and su >= 0.30:
        return "D", ("%.0f%% of the silent arm came back UNKNOWN, so the universe or the coverage "
                     "mapping is wrong and this reading is VOID until that is fixed" % (100 * su))
    if si >= 0.70 and ei >= 0.70:
        return "B", ("both arms are largely indexed (silent %.0f%%, earning %.0f%%), so INDEXING IS "
                     "NOT THE DIFFERENTIATOR - the silent pages are admitted and not ranking, and "
                     "the work is relevance and competition, not admission" % (100 * si, 100 * ei))
    if si < 0.50 and ei >= 0.70:
        return "A", ("the silent arm is %.0f%% indexed against the earning arm's %.0f%%, so the "
                     "constraint is ADMISSION - sitemap, internal linking, thin-content "
                     "consolidation, indexing requests" % (100 * si, 100 * ei))
    if si < 0.50 and ei < 0.50:
        return "C", ("both arms are largely absent (silent %.0f%%, earning %.0f%%), so this is a "
                     "property-wide crawl problem and the earning pages survive on something else"
                     % (100 * si, 100 * ei))
    return "D", ("silent %.0f%% indexed, earning %.0f%% - between the pre-registered bands, so no "
                 "reading fires cleanly and the honest answer is that this sample does not settle it"
                 % (100 * si, 100 * ei))


def selftest():
    ok = True

    def chk(name, got, want):
        nonlocal ok
        good = got == want
        ok = ok and good
        print("  %-58s %s" % (name, "ok" if good else ("FAIL got=%r want=%r" % (got, want))))

    # MUST FIRE - the founding confusion: "indexed, not submitted" is INDEXED, and
    # "Crawled - currently not indexed" is ABSENT, and both contain the word "indexed".
    chk("MUST FIRE  'Crawled - currently not indexed' is absent",
        bucket("Crawled - currently not indexed"), "absent")
    chk("MUST FIRE  'Discovered - currently not indexed' is absent",
        bucket("Discovered - currently not indexed"), "absent")
    chk("CLEAN TWIN 'Submitted and indexed' still reads indexed",
        bucket("Submitted and indexed"), "indexed")
    chk("CLEAN TWIN 'Indexed, not submitted in sitemap' still reads indexed",
        bucket("Indexed, not submitted in sitemap"), "indexed")
    chk("MUST NOT FIRE an empty state is unknown, never indexed",
        bucket(""), "unknown")
    chk("MUST NOT FIRE None is unknown, never indexed", bucket(None), "unknown")
    chk("MUST FIRE  a 404 is absent, not unknown", bucket("Not found (404)"), "absent")
    chk("MUST FIRE  a noindex tag is absent", bucket("Excluded by 'noindex' tag"), "absent")

    # The stride is deterministic and spread, and never returns more than asked.
    xs = ["u%02d" % i for i in range(10)]
    chk("stride is deterministic", stride(xs, 3), stride(xs, 3))
    chk("stride returns exactly n", len(stride(xs, 4)), 4)
    chk("stride of n >= len returns all", len(stride(xs, 99)), 10)
    chk("MUST NOT FIRE stride(0) does not explode", len(stride(xs, 0)), 10)

    # Arms: the universe is the PUBLISHED manifest, and an earning URL outside it is not counted in.
    silent, earning, d = build_arms(
        ["a", "b", "c", "d"], ["https://x/b/", "https://x/OUTSIDE/"], "https://x/", 2, 1)
    chk("universe is the published manifest", d["universe"], 4)
    chk("earning counted only INSIDE the universe", d["earning_in_universe"], 1)
    chk("MUST FIRE  an earning URL outside the universe is excluded", d["earning_rows_total"], 2)
    chk("silent is universe minus earning", d["silent"], 3)
    chk("earning arm holds the earning URL", earning, ["https://x/b/"])
    chk("MUST NOT FIRE the earning URL is not in the silent arm", "https://x/b/" in silent, False)

    # The verdict function fires the reading it was told to, and refuses between the bands.
    def arms(si, sn, ei, en):
        return {"silent": collections.Counter({"indexed": si, "absent": sn - si}),
                "earning": collections.Counter({"indexed": ei, "absent": en - ei})}
    chk("READING B when both arms indexed", verdict(arms(9, 10, 9, 10))[0], "B")
    chk("READING A when silent absent and earning indexed", verdict(arms(1, 10, 9, 10))[0], "A")
    chk("READING C when both arms absent", verdict(arms(1, 10, 1, 10))[0], "C")
    chk("MUST FIRE  refuses between the bands rather than guessing",
        verdict(arms(6, 10, 9, 10))[0], "D")
    v = {"silent": collections.Counter({"unknown": 5, "indexed": 5}),
         "earning": collections.Counter({"indexed": 10})}
    chk("MUST FIRE  a large unknown bucket VOIDS the reading", verdict(v)[0], "D")

    # Totals are derived from the rows, never carried alongside them.
    rows = [{"arm": "silent", "bucket": "indexed", "coverage_state": "Submitted and indexed",
             "last_crawl": "2026-08-01T00:00:00Z"},
            {"arm": "silent", "bucket": "absent", "coverage_state": "Crawled - currently not indexed",
             "last_crawl": None},
            {"arm": "earning", "bucket": "indexed", "coverage_state": "Submitted and indexed",
             "last_crawl": "2026-09-01T00:00:00Z"}]
    by_arm, lines = summarise(rows)
    chk("totals derive from the rows", by_arm["silent"]["indexed"], 1)
    chk("MUST NOT FIRE an undated crawl is not counted as dated",
        any("1 of 2 dated" in l for l in lines), True)

    print("SEO-REACH-DIAGNOSIS-COMPLETE selftest=%s" % ("pass" if ok else "FAIL"))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--n", type=int, default=30, help="silent-arm sample size")
    ap.add_argument("--control", type=int, default=15, help="earning-arm sample size")
    ap.add_argument("--days", type=int, default=28)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()

    import seo_search_console as S                                     # noqa: E402
    import seo_url_inspect as U                                        # noqa: E402

    if not os.path.isfile(S.KEY_FILE):
        print("SEO REACH DIAGNOSIS BLIND: no service-account credential, so Google's own index status")
        print("  for these pages has NOT been read. This is the honest state, not a clean one.")
        print("SEO-REACH-DIAGNOSIS-COMPLETE blind=no-credential")
        return EXIT_CANNOT_RUN
    with io.open(S.KEY_FILE, encoding="utf-8-sig") as fh:
        key = json.load(fh)
    try:
        tok = S.access_token(key)
    except Exception as e:                                             # noqa: BLE001
        print("SEO REACH DIAGNOSIS BLIND: the key would not exchange for a token - %s" % e)
        print("SEO-REACH-DIAGNOSIS-COMPLETE blind=no-token")
        return EXIT_CANNOT_RUN

    start, end = S.window(datetime.date.today(), a.days)
    sc_rows = S.search_analytics(tok, S.query_body(start, end, ["page"], row_limit=25000)).get("rows", [])
    earning = [r["keys"][0] for r in sc_rows if int(r.get("impressions", 0)) > 0]

    with io.open(PUBLISHED, encoding="utf-8-sig") as fh:
        slugs = list(json.load(fh))

    silent_s, earning_s, d = build_arms(slugs, earning, S.SITE, a.n, a.control)

    print("window %s .. %s   (input fingerprint: %d Search Console page row(s))"
          % (start, end, len(sc_rows)))
    print("UNIVERSE: %d published recipe(s) from the published manifest" % d["universe"])
    print("  earning an impression, inside that universe: %d of %d"
          % (d["earning_in_universe"], d["universe"]))
    print("  silent (zero impressions in the window):     %d of %d"
          % (d["silent"], d["universe"]))
    print("  Search Console page rows overall: %d (the rest are lessons and non-recipe pages)"
          % len(earning))
    if d["earning_in_universe"] == 0:
        print("SEO REACH DIAGNOSIS BLIND: not one Search Console URL matched the published universe,")
        print("  so the URL shape is wrong and no control arm exists. Refusing to read the silent arm")
        print("  on its own, because a rate with no control is exactly what this file exists to avoid.")
        print("SEO-REACH-DIAGNOSIS-COMPLETE blind=url-shape")
        return EXIT_CANNOT_RUN
    print("SAMPLING: %d silent + %d earning, deterministic stride over the sorted sets"
          % (len(silent_s), len(earning_s)))
    print()

    rows = []
    for arm, urls in (("silent", silent_s), ("earning", earning_s)):
        for u in urls:
            try:
                res = U.inspect(tok, u, S.SITE)
            except Exception as e:                                     # noqa: BLE001
                rows.append({"arm": arm, "url": u, "coverage_state": None, "bucket": "unknown",
                             "last_crawl": None, "error": str(e)[:200]})
                continue
            idx = res.get("indexStatusResult", {}) or {}
            cs = idx.get("coverageState")
            rows.append({"arm": arm, "url": u, "coverage_state": cs, "bucket": bucket(cs),
                         "last_crawl": idx.get("lastCrawlTime"), "error": None})

    if not rows:
        print("SEO-REACH-DIAGNOSIS-COMPLETE blind=nothing-inspected")
        return EXIT_CANNOT_RUN

    try:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with io.open(OUT, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")
        print("one row per URL per arm written to %s" % os.path.relpath(OUT, REPO))
    except OSError as e:
        print("could not write the per-URL rows (%s) - the totals below are still derived from them" % e)

    by_arm, lines = summarise(rows)
    print()
    for l in lines:
        print(l)
    code, why = verdict(by_arm)
    print()
    errs = [r for r in rows if r.get("error")]
    if errs:
        print("  %d of %d inspection(s) FAILED and are counted as unknown, not dropped:"
              % (len(errs), len(rows)))
        for r in errs[:3]:
            print("      %s  %s" % (r["url"], r["error"][:90]))
    print("READING %s: %s." % (code, why))
    print("SEO-REACH-DIAGNOSIS-COMPLETE reading=%s silent=%d earning=%d"
          % (code, sum(by_arm["silent"].values()), sum(by_arm["earning"].values())))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
