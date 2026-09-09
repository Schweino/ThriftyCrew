r"""seo_url_inspect.py - what Google's own index says about our recipe pages, per URL.

    python ops/seo_url_inspect.py            # inspect a deterministic sample of built recipes
    python ops/seo_url_inspect.py --n 30     # a wider sample
    python ops/seo_url_inspect.py --url URL  # one specific page
    python ops/seo_url_inspect.py --selftest # hermetic, no network

WHY THIS EXISTS (2026-09-09, backlog I44). I44's remaining half was recorded as needing the Search
Console UI, which put it on Brad's list. IT DOES NOT. The site-wide enhancement report has no public
API, but the URL Inspection API returns `richResultsResult` PER URL, and I44's own stated cheapest
confirmation is exactly a per-URL question: fix a recipe, request indexing, and watch whether the
Recipe rich result comes back on it. **A block recorded against an external system goes stale
silently, and this is the third one today that had.**

WHAT IT CAN AND CANNOT SEE. Per URL: coverage, last crawl time, and the rich-result verdict with its
issues and their severity. NOT the site-wide "Recipe rich results: VALID" count - that report is UI
only, and this file does not pretend otherwise.

THE CRAWL DATE IS THE FIRST THING TO READ, and it is why this file prints it before the verdict. A
rich-result verdict describes the page AS GOOGLE LAST SAW IT. Measured on the first run: 13 dated
crawls across a 14-URL sample, of which exactly ONE postdated the 2026-09-07 markup fix - so twelve of
the verdicts were about the pre-fix page, and reading them as a verdict on the fix would have been
reading a month-old photograph as today's weather.

THE SAMPLE IS A DETERMINISTIC STRIDE over the built recipe slugs, sorted then strided, so a second run
is comparable to the first. Picking URLs by hand samples whatever the writer happened to remember, and
this estate has a rule about exactly that shape.

A RATE IS PRINTED WITH ITS DENOMINATOR. `12 of 14` is a measurement; `86%` is a mood.

Exit 0 = inspected. 2 = a page carries a rich-result ERROR. 3 = no credential, or nothing inspected -
and 3 is never a pass.
"""
from __future__ import annotations

import argparse
import collections
import glob
import io
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

ENDPOINT = "https://searchconsole.googleapis.com/v1/urlInspection/index:inspect"
BUILT = os.path.join(REPO, "meal-prep", "db", "built")
SITE_BASE = "https://www.thriftycrew.com/"

EXIT_OK, EXIT_FINDING, EXIT_CANNOT_RUN = 0, 2, 3


def sample_urls(n=14, built_dir=BUILT, base=SITE_BASE):
    """A deterministic, spread sample of built recipe slugs."""
    slugs = sorted(set(os.path.basename(f).split(".")[0]
                       for f in glob.glob(os.path.join(built_dir, "*.body.html"))))
    if not slugs:
        return []
    stride = max(1, len(slugs) // max(1, n))
    return [base + s + "/" for s in slugs[::stride][:n]]


def inspect(token, url, site):
    body = json.dumps({"inspectionUrl": url, "siteUrl": site}).encode("utf-8")
    req = urllib.request.Request(ENDPOINT, data=body, method="POST", headers={
        "Authorization": "Bearer " + token, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.loads(r.read().decode("utf-8")).get("inspectionResult", {})


def summarise(results):
    """(counters, lines) over [(url, inspectionResult)]. Pure, so the fixtures drive it exactly."""
    cov, rich, sev = collections.Counter(), collections.Counter(), collections.Counter()
    crawls, errors = [], []
    for url, res in results:
        idx = res.get("indexStatusResult", {}) or {}
        rr = res.get("richResultsResult", {}) or {}
        cov[idx.get("coverageState") or "unknown"] += 1
        has_recipe = any(d.get("richResultType") == "Recipes"
                         for d in rr.get("detectedItems", []) or [])
        rich[(rr.get("verdict") or "NONE") + ("  with a Recipes item" if has_recipe
                                              else "  no Recipes item")] += 1
        if idx.get("lastCrawlTime"):
            crawls.append(str(idx["lastCrawlTime"])[:10])
        for d in rr.get("detectedItems", []) or []:
            for item in d.get("items", []) or []:
                for iss in item.get("issues", []) or []:
                    sev[iss.get("severity") or "?"] += 1
                    if iss.get("severity") == "ERROR":
                        errors.append((url, d.get("richResultType"), iss.get("issueMessage")))
    n = len(results)
    lines = ["seo-url-inspect: %d URL(s) inspected (deterministic stride over the built recipes)" % n]
    lines.append("  COVERAGE")
    for k, v in cov.most_common():
        lines.append("    %-36s %d of %d" % (k, v, n))
    lines.append("  RICH RESULT")
    for k, v in rich.most_common():
        lines.append("    %-36s %d of %d" % (k, v, n))
    if crawls:
        lines.append("  LAST CRAWL: %d of %d dated, earliest %s, latest %s"
                     % (len(crawls), n, min(crawls), max(crawls)))
    else:
        lines.append("  LAST CRAWL: none of the %d carries a crawl date" % n)
    lines.append("  ISSUES by severity: %s" % (dict(sev) or "none"))
    for url, kind, msg in errors:
        lines.append("    ERROR  %s  [%s]  %s" % (msg, kind, url))
    return {"n": n, "coverage": dict(cov), "rich": dict(rich), "crawls": crawls,
            "severity": dict(sev), "errors": errors}, lines


def selftest():
    bad = []

    def T(label, name, ok, got=""):
        if not ok:
            bad.append(name)
        print("  %-14s %-58s %s" % (label, name, "ok" if ok else "FAIL " + str(got)))

    def res(cov, verdict, issues=(), crawl="2026-09-08T00:00:00Z", kind="Recipes"):
        return {"indexStatusResult": {"coverageState": cov, "lastCrawlTime": crawl},
                "richResultsResult": {"verdict": verdict, "detectedItems": [
                    {"richResultType": kind,
                     "items": [{"issues": [{"severity": s, "issueMessage": m} for s, m in issues]}]}]}}

    ok_rows = [("u1", res("Submitted and indexed", "PASS")),
               ("u2", res("Submitted and indexed", "PASS", [("WARNING", "Missing field \"video\"")]))]
    s, lines = summarise(ok_rows)
    T("MUST NOT FIRE", "warnings alone do not make a finding", not s["errors"], s["errors"])
    T("MUST FIRE", "the rate carries its denominator", any("2 of 2" in l for l in lines), lines)

    err = ok_rows + [("u3", res("Submitted and indexed", "FAIL",
                                [("ERROR", "Missing field \"image\"")]))]
    s2, _ = summarise(err)
    T("MUST FIRE", "a rich-result ERROR is reported with its URL",
      len(s2["errors"]) == 1 and s2["errors"][0][0] == "u3", s2["errors"])

    # A page Google has never crawled has no verdict, and must not read as a passing one.
    unknown = [("u4", {"indexStatusResult": {"coverageState": "URL is unknown to Google"},
                       "richResultsResult": {}})]
    s3, l3 = summarise(unknown)
    T("MUST FIRE", "an uncrawled page reports NONE, never PASS",
      "NONE  no Recipes item" in "".join(s3["rich"].keys()), s3["rich"])
    T("MUST FIRE", "a sample with no crawl dates says so rather than printing a range",
      any("none of the" in l for l in l3), l3)

    # THE CRAWL DATE IS THE POINT. A verdict describes the page as Google last saw it.
    s4, l4 = summarise([("u5", res("Submitted and indexed", "PASS", crawl="2026-07-19T00:00:00Z"))])
    T("MUST FIRE", "the last-crawl date is reported beside the verdict",
      any("2026-07-19" in l for l in l4), l4)

    T("MUST NOT FIRE", "an empty result set does not invent a summary",
      summarise([])[0]["n"] == 0)

    urls = sample_urls(4)
    T("CLEAN TWIN", "the sample is deterministic across calls", urls == sample_urls(4), urls[:2])
    T("CLEAN TWIN", "the sample is spread, not the first N alphabetically",
      len(urls) < 2 or urls != [SITE_BASE + s + "/" for s in
                                sorted(set(os.path.basename(f).split(".")[0]
                                           for f in glob.glob(os.path.join(BUILT, "*.body.html"))))[:4]])

    print("")
    if bad:
        print("seo-url-inspect SELF-TEST: %d FAILED of 9" % len(bad))
        print("SEO-URL-INSPECT-COMPLETE selftest failed=%d" % len(bad))
        return 1
    print("seo-url-inspect SELF-TEST PASS (9 cases)")
    print("SEO-URL-INSPECT-COMPLETE selftest ok")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--n", type=int, default=14)
    ap.add_argument("--url", action="append", default=None)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)

    if a.selftest:
        return selftest()

    import seo_search_console as S                                # noqa: E402
    if not os.path.isfile(S.KEY_FILE):
        print("SEO URL INSPECT BLIND: no service-account credential, so Google's own verdict on these")
        print("  pages has NOT been read. This is the honest state, not a clean one.")
        print("SEO-URL-INSPECT-COMPLETE blind=no-credential")
        return EXIT_CANNOT_RUN
    with io.open(S.KEY_FILE, encoding="utf-8-sig") as fh:
        key = json.load(fh)
    try:
        tok = S.access_token(key)
    except Exception as e:                                        # noqa: BLE001
        print("SEO URL INSPECT BLIND: the key would not exchange for a token - %s" % e)
        print("SEO-URL-INSPECT-COMPLETE blind=no-token")
        return EXIT_CANNOT_RUN

    urls = a.url or sample_urls(a.n)
    if not urls:
        print("SEO URL INSPECT BLIND: no built recipe to sample, so nothing was examined")
        print("SEO-URL-INSPECT-COMPLETE blind=no-urls")
        return EXIT_CANNOT_RUN

    results, refused = [], 0
    for u in urls:
        try:
            results.append((u, inspect(tok, u, S.SITE)))
        except urllib.error.HTTPError as e:
            refused += 1
            print("  HTTP %d on %s" % (e.code, u))
            if e.code in (401, 403):
                print("SEO URL INSPECT BLIND: the credential is not permitted to inspect URLs on this")
                print("  property. Inspection needs the service account to be a full user, not a reader.")
                print("SEO-URL-INSPECT-COMPLETE blind=forbidden")
                return EXIT_CANNOT_RUN
        except Exception as e:                                    # noqa: BLE001
            refused += 1
            print("  could not inspect %s - %s" % (u, e))

    if not results:
        print("SEO URL INSPECT BLIND: %d of %d URL(s) could not be inspected" % (refused, len(urls)))
        print("SEO-URL-INSPECT-COMPLETE blind=all-refused")
        return EXIT_CANNOT_RUN

    summary, lines = summarise(results)
    for line in lines:
        print(line)
    if refused:
        print("  NOTE: %d of %d URL(s) could not be inspected, so the counts above are over %d"
              % (refused, len(urls), len(results)))
    print("SEO-URL-INSPECT-COMPLETE inspected=%d errors=%d" % (summary["n"], len(summary["errors"])))
    return EXIT_FINDING if summary["errors"] else EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
